# 验证 macOS 全局按键与文本送达边界

Type: research
Status: resolved

## Question

基于 Apple 官方资料与可核验的一手技术资料，Swift macOS App 怎样可靠监听按住/松开 `Fn` 及自定义全局快捷键、在松开时捕获聚焦的可编辑对象、稍后向该对象的光标或选区送达文本，并识别安全输入框或失效目标？需要哪些权限，App Sandbox、系统保留快捷键和不同类型应用分别有什么限制；这些事实对 MVP 的最低系统版本和降级策略意味着什么？

## Answer

MVP 采用两类热键路径：默认 `Fn` 用 session 级、listen-only `CGEventTap` 监听 `flagsChanged` 并比较 `maskSecondaryFn` 的状态边沿；普通自定义组合键用 `RegisterEventHotKey` 接收 pressed/released，并以真实注册结果处理冲突。Fn 本身不能作为普通 hotkey 独占，系统的 Fn/Globe 动作与第三方键盘支持都需要实测和用户降级选项。

松开后立即通过 Accessibility 捕获 focused application、focused UI element、选择范围和短生命周期内容版本证据。Apple 没有提供适用于所有 App 的“稍后向旧编辑位置原子插入文本”API，因此送达必须按属性可写性和已验证适配器尝试；目标失效、发生并发编辑、控件不完整实现 AX、富文本/Web/Electron 行为未验证或安全输入时，一律产生待复制结果，不抢焦点、不模拟粘贴、不自动改剪贴板。

当前 MVP 需要 Accessibility 与 Microphone 权限；Accessibility 已覆盖事件 listen/post，不再额外请求 Input Monitoring。App Sandbox 必须关闭，因为 Apple 明确将 assistive app 的 Accessibility API 列为不兼容活动。系统集成 API 的现代权限下限是 macOS 10.15；为个人 Swift 6/现代 SwiftUI MVP 缩小测试矩阵，建议暂定 deployment target 为 macOS 14.0，最终可由数据与 UI 方案调整。

完整证据、送达阶梯、安全边界、兼容性矩阵和必须原型验证的项目见 [macOS 全局按键与文本送达边界](../research/macos-system-integration.md)。
