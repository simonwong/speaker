# 豆包语音 WebSocket 鉴权与 Speaker 实现核对

调查日期：2026-07-15

## 结论

1. 用户给出的文档是**流式语音识别 WebSocket** 接口；Speaker 已改为官方推荐的 `bigmodel_async` 双向流式接口，不再调用录音文件极速版 HTTP 接口。
2. Speaker 设置页所称的“豆包 API Key”，就是新版豆包语音控制台生成的 **API Key**；具体接口文档也把它描述为 **APP Key**。这两个称呼在当前官方文档里指向同一种新版控制台凭据，都会被放入请求头 `X-Api-Key`。
3. WebSocket 并不意味着不需要密钥。WebSocket 在建立连接时仍先进行 HTTP Upgrade，并在这个 HTTP 请求头里完成鉴权。
4. 当前代码支持**新版控制台**的单一 API Key 鉴权，并实现 WebSocket 二进制流式协议；不支持旧版控制台的 `APP ID + Access Token` 双字段鉴权。

## 凭据和标识的区别

| 名称 | 是什么 | 是否属于秘密 | 官方传输位置 | Speaker 当前是否使用 |
|---|---|---:|---|---:|
| API Key / APP Key | 新版控制台生成的调用凭据；官方不同页面使用了这两个称呼 | 是 | `X-Api-Key` | 是 |
| APP ID | 旧版控制台中的应用标识 | 不应单独视为完整凭据 | `X-Api-App-Key` | 否 |
| Access Token | 旧版控制台与 APP ID 配套使用的访问令牌 | 是 | `X-Api-Access-Key` | 否 |
| Resource ID | 指定调用哪个已开通的产品资源及计费形态，不是用户密钥 | 否 | `X-Api-Resource-Id` | 是，可在四种流式资源中选择 |
| Request/Connect ID | 客户端生成的 UUID，用于请求追踪和排错 | 否 | `X-Api-Request-Id` 或 `X-Api-Connect-Id` | 使用 Request ID |

官方依据：

- [流式语音识别 WebSocket](https://www.volcengine.com/docs/6561/1354869?lang=zh) 的“鉴权”部分明确区分了旧版控制台的 `X-Api-App-Key`（APP ID）+ `X-Api-Access-Key`（Access Token），以及新版控制台的单一 `X-Api-Key`（APP Key）。
- 同一文档指出 WebSocket 鉴权信息应放在“websocket 建连的 HTTP 请求头”中，并建议记录握手返回的 `X-Tt-Logid`。
- [录音文件极速版识别 HTTP](https://www.volcengine.com/docs/6561/1631584?lang=zh) 也使用相同的新旧控制台鉴权分法；新版控制台只需 `X-Api-Key`。
- [API Key 使用](https://www.volcengine.com/docs/6561/1816214?lang=zh) 明确说明：API Key 可在新版控制台查看，在接口 Header 填入 `x-api-key`，不需要再填写 App ID；若泄露可在控制台禁用或删除。
- [控制台使用 FAQ](https://www.volcengine.com/docs/6561/196768?lang=zh) 说明旧版参数在开通服务后从豆包语音控制台查看。新版 APP Key 的官方入口由接口文档直接链接到[新版控制台 API Keys 页面](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default)（需要登录）。

因此，Speaker 输入框里应该填写的是**新版豆包语音控制台 API Keys 页面生成的 API Key**，不是火山引擎 IAM 的 AK/SK，不是旧版控制台的 Access Token，也不是 APP ID 或 Resource ID。

## 用户所指 WebSocket 接口

[流式语音识别 WebSocket 官方文档](https://www.volcengine.com/docs/6561/1354869?lang=zh) 给出的主要地址是：

- 双向流式：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`
- 流式输入：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`
- 推荐的双向流式优化版：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`

新版控制台建连时至少需要：

```text
X-Api-Key: <APP Key>
X-Api-Resource-Id: <已开通的流式资源 ID>
X-Api-Request-Id: <客户端生成的 UUID>
```

这里要注意官方页面当前存在一处示例不一致：鉴权表和页面附带的 Python Demo 使用 `X-Api-Request-Id`，握手示例则写成 `X-Api-Connect-Id`。这两个字段都只是追踪标识，不影响“新版使用 `X-Api-Key`、旧版使用 APP ID + Access Token”这一鉴权结论；实现时应以官方最新 Demo 和真实握手测试为准。

该接口不是发送一段普通 JSON 后等待结果。官方协议要求 WebSocket 建连后发送自定义二进制帧：先发送包含参数的 full client request，再持续发送 audio-only request，帧中包含协议头、序号、压缩方式、长度和负载。

### WebSocket Resource ID

Resource ID 必须和控制台实际开通的模型、计费形态一致。官方文档列出：

- 流式模型 1.0 小时版：`volc.bigasr.sauc.duration`
- 流式模型 1.0 并发版：`volc.bigasr.sauc.concurrent`
- 流式模型 2.0 小时版：`volc.seedasr.sauc.duration`
- 流式模型 2.0 并发版：`volc.seedasr.sauc.concurrent`

这些值都不能替代 APP Key；它们只表示调用哪个资源。

## Speaker 当前实际调用

当前实现位于 `Sources/SpeakerCore/VoiceInput/DoubaoStreamingASRClient.swift` 和 `LiveVoiceInputAdapters.swift`：

- 使用 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` 建连。
- 握手携带 `X-Api-Key`、`X-Api-Resource-Id`、`X-Api-Request-Id`、`X-Api-Connect-Id` 和 `X-Api-Sequence: -1`。
- 首帧发送 full client request，之后边录音边发送 audio-only 二进制帧，松开快捷键后把最后一帧标记为结束帧。
- 麦克风输入在内存中转换为 16 kHz、16 bit、单声道 PCM，以约 200 ms 分片发送；不落地音频文件。
- 默认启用 ITN、标点和 DDC 语义顺滑；个人词库通过上下文参数随请求发送。
- 设置页只收新版控制台 API Key，并允许选择模型 2.0/1.0 的小时版或并发版资源。如果用户只有旧版 APP ID + Access Token，当前代码无法正确鉴权。

## 对产品的影响

WebSocket 会在按住快捷键期间持续上传音频并提前识别，降低松开后的等待时间。输入目标仍严格以松开快捷键时聚焦的控件为准，录音期间是否存在焦点不会影响捕获。

无论保留 HTTP 还是改为 WebSocket，APP Key 都属于调用凭据，继续保存在 macOS Keychain 是合理的。钥匙串弹窗来自 macOS 对本地凭据读取的授权，与接口采用 HTTP 还是 WebSocket 没有直接关系。
