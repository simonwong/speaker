# Deep-Module Review — 主窗口重设计涉及面

Last reviewed: 2026-08-14 · 镜头: codebase-design(depth / seam / deletion test / 接口即测试面)

## 已修复(本循环)

| 项 | 位置 | 处置 |
|---|---|---|
| `HistoryModel.store` 接口过宽 | `Sources/SpeakerApp/History/HistoryFeature.swift:26` | 收窄为 `private` |
| `usesScrollableSettingsNavigation` 生产零消费 | `Sources/SpeakerAppFeatures/Settings/MainWindowLayout.swift` | 删除 + 测试断言改到真实生产面(widthClass/padding) |
| `LocalSessionHistoryStoring.search(_:)` 生产死代码 | `Sources/SpeakerCore/History/VersionedLocalSessionHistory.swift`, `SQLiteSessionHistory.swift` | 协议+双实现删除；搜索投影保留为 `SessionHistoryRecordPolicy.searchableValues`，由表现层在内存中过滤留存文字与内容无关的送达诊断码 |
| History redelivery 的 AppKit 耦合 | `Sources/SpeakerApp/History/HistoryFeature.swift` | 随产品移除历史重送入口、状态与 `NSWorkspace`/`NSEvent` 接线 |
| Settings 表现层住错模块 | `Sources/SpeakerAppFeatures/Settings/SettingsViews.swift`, `SettingsModels.swift` | `SettingsViews`、`SettingsModels` 与带文案的 `RefinementChoice` 已迁入 `SpeakerAppFeatures`; App 只注入平台 route effect |

理由: 存储层查询接口没有生产消费者，占着核心 seam 的学习成本；但诊断码是用户可见、内容无关的故障检索键，应该留在明确的搜索投影中。App 身份与被整理结果取代的 provider 原文不参与搜索。

## 缓议(实现期处理, 附理由)

- **菜单文案仍在组合根**: `MenuBarContent` 的菜单文案仍位于 `SpeakerApp`; Settings 表现层已迁移。待菜单表面重做时把文案与 presentation policy 一并下沉，避免为未变化的薄 AppKit/SwiftUI 组合提前制造 seam。
- **UISpecs 渲染 fixture 而非真实视图**: MainWindowView/SettingsView/AboutView/HistoryView 无 spec 覆盖, Tab 结构漂移不会红测试。随 F1 解决(视图进 Features 后 spec 才能跨同一 seam)。
- **ShortcutRecorderModel 无 seam**: seam 规则 = live+fake 双全才存在; 现在只有 live, 加 fake 属假想 seam。重做录制 UX 时再议。

## 接受(经 deletion test)

- `SettingsWorkspace` 13 属性聚合: 删除则复杂度散回 SpeakerRuntime/MainWindowView → 是组合容器, 合格。
- `OverviewModel` 34 行: 接近 pass-through, 但承载 @Published 快照 + 刷新触发的 locality → 保留。
- `HistoryDashboard` seam(state+actions 进, 行/展开全 private): 深度合格, v2 的历史改动将在此 seam 内落地。
