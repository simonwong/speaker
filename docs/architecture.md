# Speaker 架构方向

Speaker 采用渐进式深模块设计。目标不是把大文件平均切开，而是让调用者通过小 interface 获得完整行为，并让状态、错误和验证集中在同一个 seam。

## 目标形态

```text
SpeakerApp                 Scene 与 SwiftUI composition
  └─ SpeakerApplication   生命周期与 scene models
       ├─ VoiceInputExperience
       ├─ ShortcutFeature
       ├─ SettingsWorkspace
       ├─ HistoryFeature
       └─ Provider features

SpeakerCore               会话、转录、整理、送达和本地数据语义
Platform adapters         AppKit、AX、AVAudio、Carbon、Keychain、SMAppService

SpeakerAppFeatures        无窗口的 App 产品规则与可注入协调器
  ├─ DoubaoConnectionStatus
  ├─ OnboardingPresentation
  ├─ MenuBarPresentation
  └─ ShortcutAnnouncementCoordinator
```

- `SpeakerApp` 最终只声明菜单栏、设置和历史 Scene。
- `SpeakerApplication` 隐藏依赖组装、启动迁移顺序和终止顺序，向 Scene 提供稳定的 feature models。
- `VoiceInputExperience` 统一菜单、底部浮层、Esc、待复制、会话问题和 VoiceOver 的呈现事实源，但不吸收设置、历史和 provider 配置。
- 每个 feature 是深 module；删除它时，复杂度会重新散落到多个调用者。
- 只有确实存在 live 与 test 两个 adapter 的系统依赖才建立 seam，避免 pass-through protocol。

## 已落地的第一个 feature

`VoiceShortcutFeature` 的用户 interface 只有 `select`、`retryActivation` 和可观察状态；设置恢复、权限同步与终止 fence 属于 package lifecycle seam。它隐藏：

- Fn event tap 与自定义 Carbon hot key 的互斥启停。
- Accessibility 权限变化后的停止和恢复。
- Esc 保留、常用编辑快捷键冲突、系统占用时的 Fn 回退。
- 快速连续选择时严格按命令顺序持久化。
- 设置加载期间的用户选择优先级，迟到 restore 不得覆盖新选择。
- App 终止前建立不可逆 fence、停止 trigger intake，并等待最后一次设置写入。

生产使用 `FnEventMonitor` / `CustomHotKeyMonitor` adapters；规格使用 deterministic fake adapters。调用者和测试跨越同一 seam。

## VoiceInputExperience

`VoiceInputExperience` 已替换浅层 `VoiceInputSessionModel`。它只向调用者提供：

- 面向菜单栏和底部浮层的可观察语义 state。
- 与 session capability 绑定的不透明 action，以及结构化 route effect。
- 一个供快捷键 module 使用的 `VoiceTriggerTarget`。
- `start` / `shutdown` 生命周期。

implementation 隐藏 trigger dispatcher、长按/短按 gesture、Esc 同步 fence、session observation、菜单/浮层 projection、VoiceOver 的 `(sessionID, semantic phase)` 去重和终止 fence。旧浮层 action 无法取消、复制或关闭新会话；shutdown 后 trigger 也无法重新占有 Esc。

App 文案、SF Symbols 和无障碍 announcement 已从 `SpeakerCore` 移到 `SpeakerAppFeatures`，Core 不再公开具体语言和 UI presentation policy。

`PermissionRefreshCoordinator` 将 macOS 外部权限变化与快捷键恢复绑定为一个有序操作。它同时观察 Speaker 与任意 workspace App 的激活，因此用户在系统设置授权后可以直接切到目标 App，权限快照和快捷键 monitor 会自动恢复，不要求先把 Speaker 置于前台。

设置页选择与菜单命令也由 `SpeakerAppFeatures` 的共享 seam 持有。`SettingsNavigationModel` 是所有语音设置/关于入口的唯一页面状态，`MenuBarCommandRouter` 保证先更新目标页、再打开窗口并激活 App；普通“设置”保留用户当前页。首次引导的权限动作、连接检查可用性与完成条件集中在 `OnboardingPresentation`，生产窗口配置由 `OnboardingWindowFactory` 创建，场景规格和 AppKit 规格直接跨相同 interface 验证。

会话终态与历史持久化采用明确的提交边界：文字送达、待复制或失败会先发布给 Experience，历史记录随后按 session 顺序写入；持久化失败只追加 notice，不得阻塞或覆盖用户结果。送达 adapter 只有在 `DeliveryCommitGate` 成功取得 mutation commit 后才能修改目标。Esc 在 commit 前取消整个操作；commit 后仍会立即关闭 HUD 并释放快捷键，但已发生的 mutation 会在后台完成回执和真实历史结算，不得被改写成“已取消”，迟到终态也不得重新弹出 HUD。处理中和待复制期间的新快捷键 press 会被同步/actor 双层拒绝，并重置 gesture ownership，不能在旧会话结束后延迟启动录音。

启动恢复先完成凭据、豆包资源、词库、整理模式、旧历史迁移、隐私清理和非终态历史收敛，最后才激活全局快捷键。上次进程遗留的 preparing/recording/processing 记录会成为结构化 `sessionInterrupted` 终态。历史保留设置是用户意图的唯一来源；年龄策略和数量上限在普通 save 中发生的自动淘汰也属于 destructive transaction，commit 后必须 TRUNCATE checkpoint。SQLite 事务一旦提交就不伪装回滚；checkpoint 受读事务占用时保留明确诊断和 pending 状态，在后续写入重试，下一次干净打开也会先截断遗留 WAL，从而收敛进程终止在 commit 与 checkpoint 之间的窗口。

活跃豆包请求另由 `VoiceProviderRuntimeDiagnostics` 持有只存在于内存的内容无关快照。阶段只在 Speaker 确认跨过 transport 边界时推进：连接、请求头发送、音频流发送、最终音频帧发送和等待最终结果；接收侧中间帧只能补充 HTTP/服务端请求标识，不能把仍在发送的请求提前标记为等待结果。成功、明确失败和取消都会删除快照。远端 WebSocket close code 与 URLSession 的 DNS、断网、连接丢失和 TLS 类别进入结构化终态诊断，但原始网络错误文本不作为状态码。它不设置业务超时，也不保存音频、文字、provider message 或凭据。

实时音频在录音期间进入有界流，因此 release-time 质量判断不能伪装成“从未请求 provider”。`AudioCaptureQualityPolicy` 只拒绝少于 300 ms 的录音和低于保守阈值的确定性数字静音；此时取消仍在进行的豆包任务、丢弃目标并记录本地 `audio.too_short` 或 `audio.silent`。轻声、环境噪声等模糊音频仍由 provider 判定，避免本地启发式误杀。

所有文件型敏感存储统一经过 `OwnerOnlyFilePersistence`：以 `O_NOFOLLOW` 打开数据目录和文件，用 `fstat` 确认当前用户拥有的普通文件，在同一个 descriptor 上收紧权限并执行有上限的读取；写入使用同一已打开目录中的 `0600` 临时文件、`fsync` 和 `renameat` 原子提交。符号链接目录/文件、非普通文件、所有者不符和超限文档全部 fail closed，不能在检查后重新按路径跟随，也不能把不安全对象当作损坏 JSON 移走。权限保护失败是读取边界失败：设置回到默认并发布恢复诊断，个人词库停止加载，旧 JSON 历史停止迁移且保留原文件；不能以 `try?` 忽略后继续读取。

正式签名版的凭据迁移把当前 Keychain service 作为 primary，并把旧 Keychain service 与开发版 owner-only 文件作为待清理来源。只有所有 legacy source 都可读取且非空值完全一致时，才允许把值写入 primary、回读确认并删除所有旧来源；部分来源不可访问或值冲突时会停止迁移、保留所有来源，并只发布 provider 名称级诊断，不记录 Key。

跨 App 送达由 `AccessibilityInputTargets` 的策略层和 `AccessibilityTargetSystem` 平台 adapter 分离。松开快捷键时会同步冻结精确 focused AX element，而不是只保存进程 PID；后续捕获必须消费同一个有界 token，并确认该 element 仍是同一进程的当前焦点，进程内切换到另一输入框也会 fail closed。策略层持有目标快照、并发修改防线、commit gate、能力阶梯与回执判断；live adapter 只封装 AX/CGEvent 调用。直接写入会在 mutation 前复核当前 selection/value，且不会在 commit 后恢复旧 selection 覆盖用户新的光标位置。AX `.cannotComplete` 是目标应用辅助功能接口未完成请求的事实，不是业务计时器：安全属性、role、value、selection 和 focus 分别保留 `securityRead`、`roleRead`、`valueRead`、`directSelection`/`fallbackSelection`、`focusRead` stage，并统一映射为 `targetApplicationUnresponsive`；不能伪装成用户改变输入位置或控件不支持。标准控件不再因为 SDK 规定 `AXSelectedText` 通常不可写而一律失败：目标仍为前台精确 focused element 时，可走 receipt-verified PID Unicode；任何 mutation 未取得期望值回执都不得标记 delivered。降级结果可附带内容无关的 `DeliveryDiagnostic(stage, cause)`，并贯穿会话历史、搜索、历史详情和复制脱敏诊断；例如区分 `directWrite.other`、`directReceipt.unconfirmed`、`fallbackEligibility.notFrontmost` 与 `unicodePost.rejected`，不保存 AX 对象或输入内容。

缺少 Accessibility 授权是独立的 `accessibilityPermissionMissing` 边界，不能伪装成目标控件不支持。仓库另提供显式的本机 `scripts/delivery-smoke`：由已安装的 Speaker 以固定 canary 驱动真实 capture、commit、mutation 与 receipt，只输出权限、精确 PID 和结构化送达结果，不记录目标原文。脚本会先正常退出已有 Speaker，结束后恢复原运行状态，避免两个实例同时打开本地数据库。该入口只接受本机开发签名，Developer ID 与未知签名构建在参数解析和脚本两层都拒绝，不属于正常运行路径，也不会替代发布前的人工兼容矩阵。

Debug 构建提供 `--speaker-visual-scenario` 视觉验收入口，可重复展示
`recording`、`processing`、`pending-copy` 和 `problem` HUD。该入口通过
`#if DEBUG` 隔离，不加载语音运行时，也不得出现在 Release 二进制中。
HUD 的窗口分类与尺寸由 `VoiceInputPanelLayout` 统一定义并由场景规格锁定，
避免 AppKit/SwiftUI 状态切换重新引入大尺寸空窗或长条。处理中使用独立的
小型 spinner 与常驻低强调取消按钮；录音只显示红点、音量波形和同一取消按钮，
不显示虚假进度或时长。所有四种 layout 的两两切换都由 AppKit 规格验证目标窗口
与 hosting content 同步收敛到新尺寸。

首次引导另提供 `--speaker-onboarding-capture` 与仅 Debug 可用的尺寸覆盖，
由真实 `NSWindow`、`NSHostingView` 和生产 View 生成可重复截图。窗口初始尺寸
受当前屏幕可视区域约束，但不会永久设置最大尺寸；内容可滚动，完成区固定在
底部，权限、Key 与资源控件在窄窗口中保持可达。

本地数据清除由 `SpeakerDataErasureCoordinator` 定义唯一的外部操作。它隐藏
停写、登录项、凭据、SQLite close、owned path、preferences、验证和退出顺序；
并发调用合并为同一任务，调用方取消不能中断已开始的销毁。路径删除必须位于
已验证且解析过 symlink 的用户 Library 根目录内。清除意图使用独立的
owner-only 恢复标记，不与待删除的 preferences 共用持久化域；只有所有数据
验证成功后才删除标记并退出。任何 partial failure 都保留标记供下次启动恢复，
且禁止普通 termination handler 在删除后重新写入设置。正式 Bundle 也必须清理
开发版 `com.local.speaker` 的 Application Support、cache、saved state 与偏好域。

## 不变量

- 录音结束时的输入目标是本次会话唯一目标；后续切换窗口不改变它。
- 用户取消不是会话问题，迟到结果不得送达。
- 未确认输入目标类型前，历史不得持久化转录正文；安全输入目标的非终态、取消和终态记录始终不包含正文或 provider request ID。
- 等待结果不因本地经过一段时间而被推断为失败。
- App 退出先停止新的 trigger，再关闭会话调度，最后等待本地持久化。
- settings/history/provider raw IDs、schema、本地路径和 onboarding key 在迁移期间保持兼容。
- SwiftUI View 只观察对应 feature state 并发送语义 intent，不直接协调多个系统 adapter。

## 渐进迁移顺序

- [x] 把已有的快捷键行为深化为 `VoiceShortcutFeature`，以 interface specs 固定行为。
- [x] 集中 `VoiceInputActivity`、处理阶段和待复制原因的 presentation mapping，让菜单、浮层、历史与 VoiceOver 共用文案事实源。
- [x] 将 onboarding、overlay、history 和 settings 按 feature 移出 `SpeakerApp.swift`，不改变运行顺序。
- [x] 将 composition/lifecycle 移入 `Application/SpeakerRuntime.swift`；`SpeakerApp.swift` 只保留约 50 行 Scene wiring。
- [x] 建立 `SpeakerAppFeatures` 和 67 项可注入 App scenario specs，固定豆包刷新、DeepSeek 可用性、onboarding 权限/连接动作与屏幕约束、数据清除意图/顺序/并发/遗留路径/symlink 安全边界、菜单栏命令/设置路由、全局交互路由、历史重送精确 PID 与鼠标手势状态、HUD 尺寸、快捷键播报、权限外部变更恢复、登录项状态转换和 VoiceInputExperience 规则。
- [x] Settings 与 Onboarding 不再反向持有整个 `SpeakerRuntime`，只接收 workspace、模型与语义动作。
- [x] 用 `VoiceInputExperience` 吸收 menu/overlay 的会话观察、session capability action、route effect、Esc fence 与 VoiceOver phase。
- [x] 在 scenario specs 之上建立 AppKit UI target，并用生产 panel factory 固定 non-activating 配置、不成为 key window，以及跨状态精确恢复 HUD 尺寸的行为。
- [x] 扩展 AppKit/SwiftUI UI specs，以生产欢迎窗口工厂、菜单命令路由和共享设置导航覆盖首次引导、菜单命令与设置路由。
- [x] 以 `SoftwareUpdateFeature` 隔离产品状态和 intent，Developer ID + HTTPS feed + 32-byte Ed25519 公钥全部有效时才创建 Sparkle live adapter；开发构建完全禁用更新。正式 DMG/appcast 与公开地址回读门禁已加入发布脚本，真实旧版升级证据仍属于发布验收。

每一步都必须通过核心规格、`warnings-as-errors` 构建、Release bundle 验证和相应的真实机器 smoke；单纯减少文件行数不算完成。
