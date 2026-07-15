# Speaker

Speaker 是一个 macOS 14+ 菜单栏语音输入工具。默认使用 `Fn`：可以按住讲话、松开结束，也可以短按开始、再次短按结束。录音过程中通过豆包 `bigmodel_async` WebSocket 流式识别；结束时把最终结果安全送到当时聚焦的输入框。无法确认输入目标时，结果会留在浮层中等待你手动复制。

## 本地运行

需要 macOS 14 或更新版本，以及能使用 Swift 6 的 Xcode Command Line Tools。

```bash
./scripts/release
```

脚本会完成 Release 构建、组装、本地 ad-hoc 签名、安装并启动：

```text
/Applications/Speaker.app
```

不需要再手动拖动 App；安装成功后，构建目录中的临时副本会被删除，避免 macOS 把两个 Speaker 识别成不同的权限主体。

首次启动后，在菜单栏点击 Speaker：

1. 打开“设置”。
2. 首次启动会主动登记“辅助功能”和“麦克风”权限。麦克风在系统弹窗中允许；辅助功能在打开的系统列表中开启 `Speaker.app`。
3. 在“豆包语音”中填入[新版豆包语音控制台](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default)生成的 API Key，并选择与控制台已开通资源一致的流式资源。默认是模型 2.0 小时版 `volc.seedasr.sauc.duration`。
4. 长按 `Fn` 讲话并松开结束；或者短按一次开始录音，再短按一次结束。按 `Esc` 可随时取消。

可选流式资源为模型 2.0/1.0 的小时版或并发版。Resource ID 不是密钥；若选择的资源没有在控制台开通，“检查连接”会返回鉴权或资源错误。实现使用官方推荐的 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`，详见[流式语音识别文档](https://docs.volcengine.com/docs/6561/1354869?lang=zh)。

从系统设置返回 Speaker 后，权限状态会自动刷新。设置页也可以切换为包含修饰键的自定义快捷键。

本地 ad-hoc 签名会安全地绑定当前构建版本。因此修改代码并重新构建后，macOS 可能要求重新授权；日常直接打开 `/Applications/Speaker.app` 不受影响。若遇到旧条目，只需执行：

```bash
tccutil reset Accessibility com.local.speaker
./scripts/release
```

然后在系统设置中重新开启 `Speaker.app`，不会影响其他 App 的权限。若需要开发版本跨构建保留权限，应改用 Apple Development 或 Developer ID 证书，不要使用弱化的 identifier-only requirement。

## 文本整理

- 默认顺滑：只使用豆包返回的语义顺滑结果，不调用 DeepSeek。
- 精简清理、完整重写、自定义模式：需要在设置中额外保存你自己的 DeepSeek API Key；音频不会发送给 DeepSeek。
- 个人词库：标准词及别名保存在本机，新会话会使用按下快捷键时取得的词库快照。

## 隐私和本地数据

- API Key 只保存在 macOS Keychain。
- 会话历史包含豆包结果、可选 DeepSeek 结果、最终文本、阶段、目标应用和最小诊断信息。
- 原始音频不会写入磁盘或历史；录音时只在内存中转换为 16 kHz 单声道 PCM，并以约 200 ms 的分片发送给豆包。
- App 不会自动覆盖剪贴板；只有点击“复制”时才写入。
- 安全输入框的文本不写入历史。

本地数据位置：

```text
~/Library/Application Support/Speaker/history.json
~/Library/Application Support/Speaker/settings.json
~/Library/Application Support/com.local.speaker/personal-dictionary.json
```

## 开发验证

```bash
./scripts/test
./scripts/build
./scripts/launch
```

`./scripts/test` 运行纯 Swift 核心规格；`./scripts/launch` 构建并启动 Debug App bundle。真实豆包和 DeepSeek 请求只会使用你在 App 中保存的 Key。

## 当前人工校准项

不同 App 的 Accessibility 文本控件实现并不一致。TextEdit、浏览器普通输入框、Electron、富文本和 Terminal 应在你的 Mac 解锁并授予权限后分别 smoke；无法证明安全送达的目标会稳定降级为待复制，不会模拟粘贴、强制焦点或整段覆盖控件值。详见 [本机兼容性矩阵](.scratch/macos-voice-input/compatibility.md)。
