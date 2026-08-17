# Deep-Module Review — 主窗口重设计涉及面

Last reviewed: 2026-08-14 · 镜头: codebase-design(depth / seam / deletion test / 接口即测试面)

## 已修复(本循环)

| 项 | 位置 | 处置 |
|---|---|---|
| `HistoryModel.store` 接口过宽 | `Sources/SpeakerApp/History/HistoryFeature.swift:26` | 收窄为 `private` |
| `usesScrollableSettingsNavigation` 生产零消费 | `Sources/SpeakerAppFeatures/Settings/MainWindowLayout.swift` | 删除 + 测试断言改到真实生产面(widthClass/padding) |
| `LocalSessionHistoryStoring.search(_:)` 生产死代码 | `Sources/SpeakerCore/History/VersionedLocalSessionHistory.swift`, `SQLiteSessionHistory.swift` | 协议+双实现删除; 连带的 `SessionHistoryRecordPolicy.searchableValues` 一并删除; 3 处 spec 改为直读属性断言(原有 pin 全部保留: 留存丢弃由 `allRecords==[firstID]` 承载, 诊断字段由 `deliveryDiagnosticCode` 直读承载) |

理由: 该查询路径比 UI 故意暴露的搜索更宽(含诊断码), 与 UISpec"搜索只匹配展示文本"的产品决定相悖; 死接口占着核心 seam 的学习成本。

## 缓议(实现期处理, 附理由)

- **表现层住错模块 (F1, 最大项)**: `SettingsViews.swift`(1546 行/25 structs)、`SettingsModels.swift`(RefinementSettingsModel/DictionarySettingsModel/ShortcutRecorderModel)、`RefinementChoice`(带文案)、`MenuBarContent` 菜单文案 —— 全在 SpeakerApp 组合根, 违反"UI copy/SF Symbols/presentation policy 住 SpeakerAppFeatures"。**缓办理由**: v2 重设计将重写其中约一半(设置/关于/历史), 现在搬运 = 双重工作; 实现期把新 UI 直接落进 SpeakerAppFeatures, 旧文件随重写删除。
- **UISpecs 渲染 fixture 而非真实视图**: MainWindowView/SettingsView/AboutView/HistoryView 无 spec 覆盖, Tab 结构漂移不会红测试。随 F1 解决(视图进 Features 后 spec 才能跨同一 seam)。
- **Redelivery 接线无 seam 无测试**(HistoryModel 内 NSWorkspace/NSEvent 直连): v2 决策已把"重新输入"移出历史 UI → 实现期整体删除 `HistoryRedeliveryTargetState`+`toggleRedelivery`, 现在补 seam 是浪费。
- **ShortcutRecorderModel 无 seam**: seam 规则 = live+fake 双全才存在; 现在只有 live, 加 fake 属假想 seam。重做录制 UX 时再议。

## 接受(经 deletion test)

- `SettingsWorkspace` 13 属性聚合: 删除则复杂度散回 SpeakerRuntime/MainWindowView → 是组合容器, 合格。
- `OverviewModel` 34 行: 接近 pass-through, 但承载 @Published 快照 + 刷新触发的 locality → 保留。
- `HistoryDashboard` seam(state+actions 进, 行/展开全 private): 深度合格, v2 的历史改动将在此 seam 内落地。
