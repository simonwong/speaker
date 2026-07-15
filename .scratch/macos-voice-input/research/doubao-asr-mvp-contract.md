# 豆包 ASR 的 macOS MVP 接入契约

研究日期：2026-07-15

## 结论

首版推荐使用 **豆包语音识别大模型「录音文件极速版识别 HTTP」**：用户按住快捷键时只在本地录音，松开后将整段短音频一次性提交。它公开提供单次 `POST` 同步返回结果的接口，无需维护 WebSocket，也无需 `submit/query` 轮询，最贴合当前已经确定的“按住说话、松开提交”交互和最小 Swift 实现。[极速版识别 API](https://www.volcengine.com/docs/6561/1631584?lang=zh)

MVP 不选流式 WebSocket，不是因为它不适合语音输入；官方明确把大模型流式识别用于语音输入法等场景。选择 HTTP 极速版只是以更少的协议状态、取消状态和重连逻辑换取更快交付。真实账号测试若证明“松开后上传 + 识别”的尾延迟不可接受，再把传输层替换成流式识别，录音、词库、后处理和 UI 状态模型无需随之重做。[语音识别大模型产品简介](https://www.volcengine.com/docs/6561/1354871?lang=zh)

## 公开 API 选择

| 候选 | 官方定位 | MVP 判断 |
| --- | --- | --- |
| 大模型录音文件极速版识别 HTTP | 一次请求返回结果；无需提交后轮询；上限 2 小时、100 MB，支持 WAV / MP3 / OGG OPUS | **首版采用**。交互边界正好是“松开后提交”，Swift 可用普通 `URLSession` 完成 |
| 大模型录音文件标准版 HTTP | `submit` 后再 `query`，也支持回调；适合较长异步任务 | 不适合短语音输入，协议和等待状态多余 |
| 大模型流式语音识别 WebSocket | 边说边出文字；官方列出语音输入法、IM 语音转写等场景 | 作为低延迟升级项；首版没有展示中间结果的需求 |
| 一句话识别 | 官方产品页称适合不超过 60 秒、需要实时结果的短音频 | 属另一套语音识别产品；本 effort 已选择豆包大模型，并需要大模型的顺滑、context 等能力，不作为默认方案 |

来源：[极速版识别 API](https://www.volcengine.com/docs/6561/1631584?lang=zh)、[标准版识别 API](https://www.volcengine.com/docs/6561/1354868?lang=zh)、[语音识别产品页](https://www.volcengine.com/product/asr)。

## 已确认的请求契约

### 端点与鉴权

- `POST https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash`
- 新版控制台使用：
  - `X-Api-Key: <用户填写的 App Key>`
  - `X-Api-Resource-Id: volc.bigasr.auc_turbo`
  - `X-Api-Request-Id: <每次请求生成的 UUID>`
  - `X-Api-Sequence: -1`
- 旧版控制台使用 `X-Api-App-Key` 与 `X-Api-Access-Key`；MVP 设置页不同时暴露两套表单，默认只支持新版控制台的一个 API Key。是否需要兼容旧版，等真实账号验证后再决定。

上述字段、资源 ID 和新旧控制台差异均来自[极速版识别 API](https://www.volcengine.com/docs/6561/1631584?lang=zh)。用户还必须先在控制台开通 `volc.bigasr.auc_turbo` 权限；只有填入 Key 不能代替服务开通。

### 音频

官方确认极速版支持 `audio.url` 或 `audio.data` 二选一，其中 `audio.data` 是 Base64 音频；支持 WAV、MP3、OGG OPUS，音频不超过 2 小时、100 MB，二进制上传建议尽量控制在 20 MB 内。[极速版识别 API](https://www.volcengine.com/docs/6561/1631584?lang=zh)

MVP 固定客户端录音格式为 **16 kHz、16-bit、单声道 PCM WAV**。WAV 是极速版明确支持的容器；16 kHz、16-bit、mono 是标准版请求字段的默认值，也是无需压缩编码器的最简单 Swift 产物。[标准版识别 API](https://www.volcengine.com/docs/6561/1354868?lang=zh)

产品层另加以下限制（不是供应商上限）：

- 单次录音最长 60 秒；到时自动结束并提交。
- 小于约 300 ms 或本地未检测到有效音量时不请求网络。
- 仅上传内存或临时文件中的当前录音；请求结束、取消或失败后删除临时文件。

### 最小请求

```json
{
  "user": {
    "uid": "local-installation-id"
  },
  "audio": {
    "data": "<base64-wav>"
  },
  "request": {
    "model_name": "bigmodel",
    "enable_itn": true,
    "enable_punc": true,
    "enable_ddc": true
  }
}
```

极速版文档说明请求字段沿用标准版，只移除 callback、callback_data 及部分客服检测字段；其官方示例也列出 `enable_itn`、`enable_punc`、`enable_ddc`。标准版将三者分别定义为数字/书面形式规整、标点和语义顺滑。[极速版识别 API](https://www.volcengine.com/docs/6561/1631584?lang=zh)、[标准版识别 API](https://www.volcengine.com/docs/6561/1354868?lang=zh)

`enable_ddc` 的边界只是删除或修改停顿词、语气词和语义重复等 ASR 不流畅片段，不是根据任意提示词重写文本。完整边界见[豆包语音识别是否支持提示词驱动的文本整理](./doubao-speech-text-processing.md)。

### context 与词库

标准版 API 的 `corpus.context` 有两类用途，极速版公开声明沿用标准版字段：

1. 直传热词，最多 5000 个，用来提高指定词的识别率；
2. 传入对话历史、机器人信息、个性化信息或业务场景，帮助模型在语境中完成更准确的转录；2.0 还可用一张图片扩展上下文。

这些都是“识别干预”，不是 LLM 改写指令。[标准版识别 API](https://www.volcengine.com/docs/6561/1354868?lang=zh)

MVP 词库采用**请求级热词直传**，不先实现云端词表管理：把用户的本地词库转换成 `corpus.context` 的 `hotwords` JSON。这样词库仍可完全保存在本机，也不要求 App 操作火山控制台的词表资源。若真实调用发现极速版不接受该字段，再降级为平台词表：官方热词平台支持通过 `boosting_table_id` 或名称在识别请求中启用，一个请求只能生效一张词表。[热词说明](https://www.volcengine.com/docs/6561/155739?lang=zh)

平台词表的公开限制包括：中英文、每应用最多 500 张词表、每张最多 5000 个热词、每词少于 10 个字、可设置 1–10 权重，且不建议添加单字或无实体意义高频词。[热词说明](https://www.volcengine.com/docs/6561/155739?lang=zh)

## 已确认的响应与错误契约

成功时：

- 响应头 `X-Api-Status-Code: 20000000`；
- `X-Api-Message: OK`；
- `X-Tt-Logid` 应写入诊断日志，便于定位供应商请求；
- 正文读取 `result.text` 作为整段最终转录；`result.utterances` 只用于后续调试或逐句信息，不作为 MVP 必需输出。

官方列出的极速版错误码：

| 码 | 含义 | MVP 行为 |
| --- | --- | --- |
| `20000003` | 静音音频 | 显示“没有检测到语音”，不自动重试 |
| `45000001` | 请求参数无效/缺失 | 显示配置或格式错误，记录 log ID，不重试 |
| `45000002` | 空音频 | 本地错误，不重试 |
| `45000151` | 音频格式不正确 | 本地编码错误，不重试 |
| `55000031` | 服务繁忙/过载 | 可自动重试一次，随后保留文本等待态并允许用户重试 |
| `550XXXX` | 服务内部错误 | 可自动重试一次，随后进入可重试失败态 |

错误定义来源：[极速版识别 API](https://www.volcengine.com/docs/6561/1631584?lang=zh)。重试次数与 UI 行为是本报告给 MVP 的设计推论，不是火山引擎承诺。

## 取消语义

官方极速版文档没有公开“取消服务端识别任务”的端点或请求字段。由于它是一个同步 HTTP 请求，MVP 的可实现语义是：

- **录音中按 Esc**：本地停止录音、删除音频，不发请求；这是可靠取消。
- **已经提交后按 Esc**：调用 `URLSessionTask.cancel()`，停止客户端等待并忽略任何迟到结果；不能承诺已经发生的供应商计费或服务端计算会被撤销。
- 任何取消都不得把半成品写入聚焦输入框。

“没有公开服务端取消能力”是对已核对公开文档的结论，不是证明内部绝对不存在；需用真实账号或工单确认计费语义。

## 限额与计费

官方公开页确认：极速版需要单独开通 `volc.bigasr.auc_turbo`，单请求上限为 2 小时和 100 MB。官方产品页展示大模型录音文件识别按音频小时出售资源包，例如 30 小时包与 1000 小时包，但当前抓取到的公开页面没有给出极速版稳定的按量单价或明确 QPS，因此不能把价格数字和 QPS 写死进规格。[极速版识别 API](https://www.volcengine.com/docs/6561/1631584?lang=zh)、[语音识别产品页](https://www.volcengine.com/product/asr)

控制台可查看调用时长、次数和 QPS，并配置资源包/QPS 额度预警。[服务用量](https://www.volcengine.com/docs/6561/1359373?lang=zh)

因此 MVP 设置页只显示供应商用量入口，不展示自行估算的“本月费用”。正式发布前必须用目标账号核实：极速版计费项、免费额度、最小计费粒度、默认 QPS、欠费与额度耗尽错误。

## Swift 侧最小接口

```swift
protocol SpeechTranscribing {
    func transcribe(_ request: TranscriptionRequest) async throws -> Transcript
    func cancelCurrentRequest()
}

struct TranscriptionRequest {
    let wavData: Data
    let installationID: String
    let hotwords: [String]
    let context: String?
    let enablePunctuation: Bool
    let enableITN: Bool
    let enableDisfluencyRemoval: Bool
}

struct Transcript {
    let text: String
    let providerLogID: String?
    let audioDurationMilliseconds: Int?
}
```

实现约束：

- `DoubaoFlashASRClient` 只负责 HTTP/JSON、鉴权头、状态码映射和响应解析，不负责录音、粘贴或 LLM 整理。
- API Key 从 macOS Keychain 读取，不进入日志、崩溃报告或普通偏好文件。
- 每次请求生成 UUID；日志只记录 UUID、`X-Tt-Logid`、耗时、音频时长和错误分类，不记录音频、API Key 或转录正文。
- `result.text` 为空按可恢复失败处理，不直接写入输入框。
- ASR 成功后再进入可选文本模型处理；任何后处理失败都保留 ASR 原文供用户复制。

## 必须用真实账号验证的项目

以下信息不能仅凭公开文档锁死：

1. 新版控制台是否能给个人/当前账号开通 `volc.bigasr.auc_turbo`，以及是否确实只需一个 `X-Api-Key`。
2. 极速版在 1、5、15、60 秒中文音频上的 P50/P95“松开到结果”延迟。
3. `enable_ddc` 对真实口头禅、重复、犹豫的删除强度，是否会误改原意。
4. 极速版对 `corpus.context` 热词直传、对话 context 与平台词表 ID 的实际兼容性。
5. 当前账号的单价、免费额度、最小计费粒度、QPS、限流错误码、欠费错误码。
6. 客户端中途取消 HTTP 后，服务端是否继续计费。
7. API Key 是否允许直接从 macOS 客户端请求；若供应商条款或安全要求不允许，则 MVP 架构需要增加自有代理服务，这会改变“完全 BYOK、无后端”的范围。

## 最小验收用例

- 3 秒普通话、含数字：返回有标点且 ITN 生效的文本。
- 包含 3 个生僻人名/技术词：启用请求级热词后准确率优于未启用。
- 含“嗯、那个”和重复短语：分别对比 `enable_ddc=false/true`，确认只做轻量顺滑。
- 静音、空 WAV、错误格式、错误 Key、未开通资源、服务繁忙分别映射到稳定 UI 状态。
- 录音时 Esc 不产生请求；提交后取消不写入文本。
- 所有失败都保留可重试入口；如果已有 ASR 原文，则允许复制，且不因 LLM 失败丢失。

## 官方来源清单

- [大模型录音文件极速版识别 API](https://www.volcengine.com/docs/6561/1631584?lang=zh)
- [大模型录音文件标准版 API](https://www.volcengine.com/docs/6561/1354868?lang=zh)
- [语音识别大模型产品简介](https://www.volcengine.com/docs/6561/1354871?lang=zh)
- [豆包语音识别产品页](https://www.volcengine.com/product/asr)
- [热词说明](https://www.volcengine.com/docs/6561/155739?lang=zh)
- [豆包语音产品动态](https://www.volcengine.com/docs/6561/162929?lang=zh)
- [服务用量](https://www.volcengine.com/docs/6561/1359373?lang=zh)
