<div align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Speaker 应用图标">
  <h1>Speaker</h1>
  <p>一款注重隐私的 macOS 菜单栏语音输入工具，让你在任何输入位置直接把语音变成文字。</p>

  <p><a href="README.md">English</a> · <strong>简体中文</strong></p>

  <p>
    <a href="https://github.com/simonwong/speaker/actions/workflows/ci.yml"><img src="https://github.com/simonwong/speaker/actions/workflows/ci.yml/badge.svg" alt="CI 状态"></a>
    <a href="https://github.com/simonwong/speaker/releases"><img src="https://img.shields.io/badge/下载-开发版本-2F81F7?logo=github" alt="下载最新开发版本"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="需要 macOS 14 或更高版本">
    <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  </p>
</div>

Speaker 常驻菜单栏，默认使用 `Fn` 快捷键。你可以按住说话、松开结束，也可以短按一次开始、再次短按结束。Speaker 会通过豆包实时转写语音，可以选择使用 DeepSeek 整理已确认的文本，并把最终结果送到录音结束时聚焦的输入位置。

如果 Speaker 无法确认原输入位置仍然安全有效，它会把结果保留在浮层中，等待你主动复制，而不会冒险把文字输入到错误的位置。

> [!IMPORTANT]
> Speaker 的开发版本使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 会阻止首次启动，直到你明确移除所下载 `Speaker.app` 的隔离属性。请只从本仓库的官方 [Releases](https://github.com/simonwong/speaker/releases) 页面下载。

## 主要功能

- **自然的语音快捷键** — 按住或短按 `Fn`，支持自定义快捷键，随时可以按 `Esc` 取消。
- **安全的目标送达** — 录音结束时冻结输入目标，之后切换窗口或焦点不会改变送达位置。
- **实时语音识别** — 讲话时通过豆包 `bigmodel_async` WebSocket ASR 持续流式转写。
- **可选文本整理** — 默认顺滑只使用豆包；精简清理、完整重写和自定义模式使用你的 DeepSeek Key，并且只发送文字，不发送音频。
- **本地管理** — 个人词库、可搜索的会话记录、保留策略和脱敏诊断都保存在当前 macOS 用户下。
- **保守的隐私边界** — 原始音频不写入磁盘，安全输入框文字不进入历史，只有主动点击复制时才会修改剪贴板。

## 使用要求

| 要求 | 说明 |
| --- | --- |
| 操作系统 | macOS 14 或更高版本 |
| 语音识别 | 用户自己的豆包 API Key，以及已开通的流式语音识别资源 |
| 文本整理 | DeepSeek API Key 为可选项，仅非默认整理模式需要 |

## 下载并运行

1. 打开 [GitHub Releases](https://github.com/simonwong/speaker/releases)，下载最新的 `Speaker-<版本>-development.zip` 及对应的 `.sha256` 文件。
2. 校验下载文件，通过后解压，并把 `Speaker.app` 移动到 `/Applications`。
3. 只移除这个 App 的隔离属性，然后启动：

```bash
cd ~/Downloads
shasum -a 256 -c Speaker-*-development.zip.sha256
```

```bash
xattr -dr com.apple.quarantine /Applications/Speaker.app
open /Applications/Speaker.app
```

请把下载的 ZIP 和 checksum 文件放在同一目录。校验命令必须显示 `OK`，再继续安装。

`xattr` 命令只移除 `/Applications/Speaker.app` 的 Gatekeeper 隔离标记，不会关闭系统全局的 Gatekeeper。由于每个开发版本使用 ad-hoc 身份，更新 Speaker 后，macOS 可能要求重新授予麦克风和辅助功能权限。

### 首次使用

1. 按照 Speaker 的引导申请麦克风和辅助功能权限。
2. 当 macOS 打开设置页时，在 **系统设置 → 隐私与安全性 → 辅助功能** 中启用 `/Applications/Speaker.app`。
3. 在 **豆包语音** 中填写从[豆包语音控制台](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default)获取的 API Key，选择当前账号已开通的流式资源，然后执行 **检查连接**。
4. 在任意 App 中聚焦输入框，按住 `Fn` 说话并松开结束；也可以短按一次开始，再短按一次结束。

如果更新后出现旧权限条目，可以只重置 Speaker 的本地 Bundle 身份：

```bash
tccutil reset Accessibility com.local.speaker
tccutil reset Microphone com.local.speaker
open /Applications/Speaker.app
```

然后重新在系统设置中启用 Speaker。这些命令不会重置其他 App 的权限。

## 工作原理

1. Speaker 在内存中把麦克风输入转换为 16 kHz、16-bit、单声道 PCM，并分片发送给豆包。
2. 松开快捷键时，Speaker 冻结当前输入目标，并等待豆包返回最终阶段结果。
3. 默认顺滑直接使用豆包结果；其他整理模式可以把已确认文字和所选指令发送给 DeepSeek。
4. 真正送达前，Speaker 会再次验证原输入目标。无法确认、已经变化、已经关闭或属于安全输入框时，结果会转为待复制状态。

音频只会发送给豆包，不会发送给 DeepSeek，也不会作为普通应用数据持久化保存。

## 隐私

Speaker 没有托管账号服务，也不提供共享的服务商凭据。你需要使用自己的 API Key。当前 ad-hoc 开发版本把凭据保存在仅当前用户可访问的应用数据文件中；正式 Developer ID 构建会使用 macOS Keychain。设置、个人词库和会话记录都通过仅当前用户可访问的本地持久化保存。

完整的数据处理约定、本地存储位置、服务商边界、保留策略和诊断脱敏规则请参阅 [隐私说明](PRIVACY.md)。

## 开发

构建 Speaker 需要 Swift 6 和 macOS 26 SDK，通常由 Xcode 26 或兼容的 Command Line Tools 提供。项目脚本优先使用 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk`；也可以通过 `SPEAKER_SDKROOT` 选择其他 macOS 26 或更高版本 SDK。

请使用仓库脚本，让本地构建与 CI 保持一致：

```bash
./scripts/test
./scripts/build
```

| 命令 | 用途 |
| --- | --- |
| `./scripts/test` | 运行确定性的规格可执行文件和脚本检查 |
| `./scripts/build` | 构建 Debug 版本的 `SpeakerApp` |
| `./scripts/provider-smoke doubao\|deepseek` | 使用本机已保存凭据检查服务商连接 |

直接运行 `swift build`、`swift run` 或 `swift test` 不会使用仓库固定的 SDK 和缓存配置，因此不属于受支持的构建路径。

## 项目文档

- [语音输入规格](docs/specs/voice-input.md) — 产品行为、边界和验收决策
- [架构说明](docs/architecture.md) — 模块、接缝、适配器和系统不变量
- [兼容性矩阵](docs/compatibility.md) — 不同真实应用的送达证据
- [发布流程](docs/releasing.md) — 本地安装与正式分发
- [生产就绪清单](docs/production-readiness.md) — 签名公开发布仍需完成的门槛

## 参与贡献

欢迎提交聚焦的问题和 Pull Request。涉及重要产品行为或架构变化时，请先创建 [GitHub Issue](https://github.com/simonwong/speaker/issues)，先对产品约定和验证方法达成一致。请保持改动范围明确，使用仓库脚本，并为行为变化补充确定性规格。

## 许可证

Speaker 当前尚未包含开源许可证。在许可证发布之前，源码可供查看，但尚未授予复制、修改或再分发的许可。
