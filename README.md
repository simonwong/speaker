# Speaker

Speaker 是一个 macOS 14+ 菜单栏语音输入工具。默认按住 `Fn` 讲话，松开后使用豆包极速版语音识别，并把结果安全送到松开时聚焦的输入框。无法确认输入目标时，结果会留在浮层中等待你手动复制。

## 本地运行

需要 macOS 14 或更新版本，以及能使用 Swift 6 的 Xcode Command Line Tools。

```bash
./scripts/release
```

脚本会完成 Release 构建、组装和 ad-hoc 签名，然后生成并启动：

```text
.build/Speaker.app
```

首次启动后，在菜单栏点击 Speaker：

1. 打开“设置”。
2. 授予“辅助功能”和“麦克风”权限。
3. 在“豆包语音”中填入你自己的 API Key，保存后点击“检查连接”。该 Key 需要已开通极速版语音识别资源 `volc.bigasr.auc_turbo`。
4. 按住 `Fn` 讲话，松开后等待结果进入当前输入框。

如果系统没有立即刷新权限，退出后重新运行 `./scripts/release`。设置页也可以切换为包含修饰键的自定义快捷键。

## 文本整理

- 默认顺滑：只使用豆包返回的语义顺滑结果，不调用 DeepSeek。
- 精简清理、完整重写、自定义模式：需要在设置中额外保存你自己的 DeepSeek API Key；音频不会发送给 DeepSeek。
- 个人词库：标准词及别名保存在本机，新会话会使用按下快捷键时取得的词库快照。

## 隐私和本地数据

- API Key 只保存在 macOS Keychain。
- 会话历史包含豆包结果、可选 DeepSeek 结果、最终文本、阶段、目标应用和最小诊断信息。
- 原始音频只存在于一次会话的临时 WAV 中，停止、取消或下次启动清理后删除，不进入历史。
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
