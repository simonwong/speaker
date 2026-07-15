# 定义个人 macOS 语音输入 MVP

Label: wayfinder:map

## Destination

形成一份完整、可直接进入 Swift 开发并能在用户本机运行的 macOS 语音输入 MVP 产品与技术规格。规格覆盖交互、系统权限、模型接入、本地数据、安全降级与可验证的验收标准，但本次 wayfinding 不实现正式 App。

## Notes

- 全程使用 `grilling`、`domain-modeling`；外部 API 与 Apple 平台事实使用 `research`，交互不确定性使用 `prototype`。
- 产品为单用户、本地优先工具；用户自行配置豆包凭证，只有启用需要进一步整理的整理模式时才配置并调用 DeepSeek。
- 全局快捷键默认 `Fn` 且可自定义：按住录音、松开提交、`Esc` 取消。
- 结束录音时捕获输入目标；录音期间允许任意切换聚焦位置。无法送达时产生待复制结果，不自动覆盖剪贴板。
- 默认顺滑只使用豆包 ASR；精简清理、完整重写与自定义模式才调用 DeepSeek，失败时降级到豆包结果。
- 个人词库仅保存在本地，包含标准写法、可选口语别名和启用状态。
- 会话历史永久保存在本地，详细记录各阶段文本与元数据，支持用户手动删除；原始音频不进入历史并在处理后删除。
- MVP 采用菜单栏工具、设置窗口、悬浮状态层和会话历史窗口；不做账号、同步、订阅或团队能力。
- MVP 只保证在用户自己的 Mac 上从源码构建安装，不包含 App Store、签名、公证、DMG、自动更新或崩溃上报。
- 当前本机为 macOS 26.5 / Apple Silicon，Swift 6.2.4 可用；完整 Xcode 尚未安装，正式 UI 开发前需安装。
- 本目录当前不是 Git 仓库；研究资产直接保存在本地 `.scratch/macos-voice-input/research/`，无法使用研究分支。

## Decisions so far

<!-- resolved tickets are indexed here; the detailed answer lives in each ticket -->

- [验证 macOS 全局按键与文本送达边界](./issues/01-verify-macos-system-integration.md) — `Fn` 用 event tap 边沿检测，自定义组合键用 Carbon hotkey；AX 送达只承诺能力探测后的已验证适配器，其他情况进入待复制结果。
- [验证豆包 ASR 的 MVP 接入契约](./issues/02-verify-doubao-asr-integration.md) — 采用录音文件极速版 HTTP，松开后单次提交；请求级词库优先使用 `corpus.context`，服务端取消与价格/QPS 留待真实账号验证。
- [验证 DeepSeek 文本整理的 MVP 接入契约](./issues/03-verify-deepseek-integration.md) — 可选整理采用 `deepseek-v4-flash` 非思考、非流式 JSON Output；任何失败都无损回退豆包顺滑结果。

## Not yet specified

- 历史窗口、设置窗口与悬浮层的最终信息架构，在状态机确定后通过原型澄清。
- 验收测试矩阵需要覆盖哪些原生、Web、Electron 和安全输入场景，将由文本送达能力边界决定。
- 网络中断、超时、取消、重复触发和 App 退出时的恢复细节，在会话状态机中澄清。

## Out of scope

- Mac App Store 上架、开发者签名、公证、DMG、自动更新与崩溃上报。
- 账号系统、云同步、订阅计费、团队词库与多设备同步。
- 原始音频历史、云端历史和完整转录文档管理。
- 正式 Swift App 的编码与交付；wayfinder 的终点是实现就绪规格。
