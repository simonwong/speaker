# Speaker 生产就绪清单

这份清单是发布门槛，不是功能愿望列表。只有 P0 全部完成并取得真实机器证据，才能称为面向用户的生产版本。

## 当前结论

Speaker 已可作为本机开发版持续试用，但还不能对外发布。主要阻断项是稳定代码签名与公证、凭据迁移到 Keychain、真实跨 App 兼容性验证和完整更新机制。

## P0 发布阻断

- [x] 未验证 App 禁止 PID Unicode 事件注入；统一保留文字等待复制。
- [x] 剪贴板写入必须在 `setString` 后精确读回确认；系统拒绝、被并发覆盖或内容不一致时保留结果供重试。
- [x] 跨 App 送达使用可注入 AX adapter seam；直接 AX 写入允许回执滞后，mutation 后瞬时 `.cannotComplete` 会轮询回执，mutation 前 `.cannotComplete` 则按 security/role/value/selection/focus 精确阶段记录为目标应用 AX 未响应，不伪报焦点变化或控件不支持。未知 App 的 PID Unicode 仅限前台精确目标并要求值回执；mutation 无法确认时提示先检查输入框，避免重复粘贴。
- [x] 自动送达降级保存内容无关的结构化边界，区分直接 AX 写入、回执确认、前台资格、并发编辑和 Unicode 投递；诊断可在历史、搜索及复制脱敏报告中使用，旧记录缺少字段时保持兼容。
- [x] Esc 只在 Speaker 会话活跃时消费完整 keyDown/repeat/keyUp 序列；空闲时透传给前台 App。
- [x] 首次启动先解释用途，再由用户主动请求权限、选择豆包资源并通过真实连接检查。
- [x] 音频流有明确的内存资源上限，耗尽时停止且报告事实，不静默丢帧。
- [x] 少于 300 ms 的录音与确定性数字静音在 release-time 本地终止，取消活跃 provider 请求且禁止文字送达；模糊低电平音频不使用启发式误杀。
- [x] 豆包 WebSocket 同时发送和接收；明确的服务端错误可提前终止录音。
- [x] App 退出等待取消记录和其他已排队历史写入完成。
- [ ] 确定正式 Bundle ID 与 Apple Developer Team。（仓库已增加不可由 CI 覆盖的 `Resources/ReleaseIdentity.plist` 门禁；当前保留占位值，正式分发会 fail-closed。）
- [ ] 使用 Developer ID Application 稳定签名并验证跨版本 TCC 权限保持。
- [x] 开发构建显式标记 ad-hoc 身份、在产品内解释麦克风与辅助功能授权失效边界，并支持可选具名本地签名。
- [ ] 开启 Hardened Runtime，通过 `notarytool` 公证并 staple。
- [ ] 将豆包与 DeepSeek Key 从 owner-only 本地文件迁移到稳定签名 App 的 Keychain；迁移会完整检查旧 Keychain/明文来源，只有全部可读且值一致才写入并回读 primary 后清理，冲突或部分不可读会保留所有来源并提示。代码门禁已完成，仍需 Developer ID 实机验证。
- [ ] 在干净 macOS 用户上走完首次安装、Gatekeeper、权限、升级和卸载/清理流程。

## P1 公测前

- [ ] 建立 TextEdit、Safari、Chrome/Electron、富文本和 Terminal 的真实兼容矩阵；每项覆盖中文、emoji、多行、选区、撤销、焦点变化和迟到 mutation。
  `./scripts/compatibility-smoke` 已将矩阵固化为可重复、失败即非零退出且
  生成脱敏证据的人工门禁；报告固定可执行文件 SHA-256，单项 partial PASS
  也返回非零，只有完整矩阵全 PASS 才返回 0。仍需在解锁且权限完整的真实机器上取得全 PASS 报告。
- [x] 监听 audio engine 配置变化与转换失败，实时停止录音并明确区分设备中断、音频处理和 provider 错误。
- [x] 历史使用带 schema/version 的 SQLite 增量事务、FULL synchronous、secure delete 和 WAL；默认由用户删除，也可明确选择 30/90/365 天策略，并有 10000 条安全上限。年龄/数量自动淘汰、显式删除和清空都要求非 busy 的 TRUNCATE checkpoint；busy 时保留已提交策略和清理 pending，后续写入重试，干净启动也会截断上次遗留 WAL。清空还会执行 VACUUM、再次 checkpoint 并删除旧恢复备份。设置、旧 JSON 历史和 SQLite 损坏集共享恢复档案预算：最多 3 份、30 天、128 MiB，并始终保留最新可用证据；软链接、未知类型或非当前用户候选不会被清理。旧 provider 原始文本以 fail-closed 迁移物理擦除，崩溃遗留非终态会话在启动时收敛为 `sessionInterrupted`。目标尚未分类时不写入转录正文；安全输入目标在处理中、取消和终态均保持正文与 provider request ID 为空，规格还会扫描 SQLite/WAL 字节确认 sentinel 未落盘。
- [x] 文件型历史、设置、个人词库和开发版凭据使用 descriptor-relative 的 no-follow 安全读写；只接受当前用户拥有的普通文件，读写均按数据类型限制大小，并以同目录 `0600` 临时文件、`fsync`、`renameat` 原子提交。符号链接目录/文件、非普通文件和超限文件会保留证据并停止加载/保存，加载失败后的设置更新和词库 UI 也不得覆盖原文件；旧历史不会以空数据迁移后删除原文件。
- [x] 提供“清除本地数据并退出”：先通过 no-follow owner-only 写入独立恢复标记并停止所有写入，再注销登录项、清除本地/Keychain 凭据、显式关闭 SQLite、删除当前与开发版遗留的 Application Support/缓存/saved state/偏好并逐项验证；恢复标记和凭据删除也使用 descriptor-relative `unlinkat`，父路径 symlink 逃逸会 fail closed，只有最终验证成功后才清除恢复标记并退出。
- [x] DeepSeek 连接检查仅更新诊断状态，不再覆盖用户持久化选择；无 Key 时依赖 DeepSeek 的已保存模式不会进入运行态，保存 Key 后才恢复。（Key 指纹随正式 Keychain/升级验证一并复核。）
- [x] 历史重新输入使用单一可取消状态；目标 App 激活后仍需用户再次明确点击输入位置，禁止把激活事件误当作送达确认。
- [x] 浮层优先按前台 App 的 AX focused window 所在显示器定位，鼠标仅作 fallback；切换布局、前台 App 或显示器配置时会重新定位，录音 telemetry 不会触发高频 AX 查询。
- [ ] UI 支持 Reduce Motion、Increase Contrast 和 VoiceOver 独立取消按钮/状态播报。（Reduce Motion、Increase Contrast palette、独立取消按钮与克制的状态 announcement 已完成，仍需 VoiceOver/Increase Contrast 实机 smoke。）
- [x] 权限菜单和错误恢复使用共享设置路由，直接落到语音识别页。
- [x] 建立 SwiftUI/AppKit UI 测试 target，覆盖首次引导、菜单命令、浮层不抢焦点和设置路由。（67 项 App scenario specs 已覆盖 onboarding 权限/连接动作、DeepSeek 可用性、菜单命令顺序与共享设置路由，以及数据清除恢复标记/遗留路径/symlink 防护、快捷键、全局交互、历史重送、HUD、Esc、VoiceOver、notice、辅助功能权限边界、开发 smoke 发布隔离、登录项、权限外部变更恢复和 shutdown 规则；5 项 AppKit UI specs 使用生产 panel/onboarding/HUD 视图验证 HUD non-activating、orderFront 不抢 key window、跨状态恢复紧凑尺寸、辅助功能按钮的标签/点击范围/真实 action，以及欢迎窗口在受限屏幕中的完整配置。）
- [x] 提供“关于、版本、隐私、打开数据目录、复制脱敏诊断”入口；诊断不包含转录文字、音频或 Key。
- [x] 活跃豆包请求提供内容无关的精确 transport 阶段、客户端/服务端请求标识和 HTTP 状态；阶段由实际协议边界推进，取消/结束立即清理。远端 close code、DNS、断网、连接丢失和 TLS 故障保留稳定子类；连接仍开放却没有最终帧时保持 `awaitingFinal`，不以本地经过时间推断 provider 故障。

## 发布与运维

- [x] 本地安装采用干净 bundle、canonical Applications 路径、symlink/`..` 拒绝、候选先验证、旧包签名身份验证、标准 App termination 等待异步 shutdown，以及交换失败回滚；同 Bundle ID 但签名损坏的包不会被替换或进入回滚链，不会用强杀覆盖仍在写历史/设置的进程。
- [x] 正式发布脚本缺少或不匹配 Developer ID、受审查固定 Team/Bundle/更新身份、公证 profile、Sparkle 私钥 account、release notes、SemVer 或构建号时 fail closed；CI 环境变量不能替换 release identity。Release notes 必须来自仓库内已提交文件；正式 App 从固定 `HEAD` 的 owner-only 只读 source snapshot 构建，在独立 SwiftPM scratch 中仅按快照的 `Package.resolved` 获取公开依赖，分别构建 arm64/x86_64 并合成为 universal2，不覆盖开发 `.build/Speaker.app`。受签名保护的 BuildManifest 固定 source commit、依赖锁文件 hash 与 release-notes hash；同时清除构建机 RPATH，验证 timestamp、架构和允许的 RPATH，源码树与 SwiftPM checkout 只要存在本地改动就拒绝发布。脚本逐层验证 Sparkle helper，生成并公证 APFS+lzfse DMG、archive EdDSA、signed appcast 与 SHA-256；公开地址回读同时把验证 account 和 App 内更新策略绑定到受审查 EdDSA 公钥。正式发布使用全局锁和持久 promotion journal，可在下一次运行恢复 `SIGKILL`/断电留下的 prepared 晋升，尚未建立 channel 前拒绝 prerelease 混入稳定 feed。
- [x] 确定 SemVer 与单调递增 build number 策略；仓库内 `ReleaseCandidate.plist` 固定上一个公开 build 与当前受审查候选，正式构建和公开回读的环境值必须精确匹配，且候选必须严格递增。appcast 比较使用任意长度十进制字符串，避免整数溢出；正式参数和两阶段流程见 `docs/releasing.md`。
- [ ] 建立可复现 CI 构建、自动测试、签名、公证、校验和及制品留存。（未签名的测试/严格编译/Release bundle CI 已落地；CI 会把通过完整性门禁的候选 App 归档为带 SHA-256 的 immutable artifact 并留存 30 天。正式流程已生成 hash-bound evidence archive，包含 dSYM、BuildManifest、两次公证 submission/log 与 toolchain 信息；真实签名与公证执行仍待 Developer ID/发布环境配置。）
- [ ] 接入安全更新机制，并验证降级、更新失败恢复和签名轮换策略。（Sparkle 2.9.4 feature/live adapter、正式 DMG/appcast 生成和公开地址回读门禁已完成；仍缺真实 Developer ID 旧版→新版安装、篡改/断网/回滚及密钥轮换实机证据。）
- [x] 编写对外隐私说明：`PRIVACY.md` 覆盖音频/文本去向、本地历史、Key 存储、诊断和删除边界。

## 当前自动证据

- `./scripts/test`：164 项核心规格、67 项 App scenario specs 与 5 项 AppKit UI specs 通过。
- `./scripts/test-compatibility-smoke`：使用本地构建候选验证人工兼容报告契约；partial PASS 返回 3、报告权限为 `0600`、记录可执行文件 SHA-256 且不包含绝对 Bundle 路径。
- `./scripts/provider-smoke doubao`：2026-07-17 使用当前 BYOK 再次完成 `volc.seedasr.sauc.duration` 静音连接探针，服务端请求 ID `20260717125537286AF74BAC3BF6B4ED6B`。该结果只证明连接，不证明模型矩阵；DeepSeek 仍未配置。当前 matrix 要求显式付费确认、全新 evidence 目录及候选 version/build；报告以固定 13-case schema 绑定 source commit/clean 状态、`Package.resolved` SHA-256、macOS/架构、凭据来源、资源与模型，逐级 no-follow 校验父目录后原子写入 `0700/0600`，且 verifier 对未知字段、缺失/重复、FAIL/SKIP、dirty source 与非正式 Keychain 凭据 fail closed。Verifier 只验证结构、绑定字段和完成性；正式 release run 还必须把 `generatedAt` 绑定到本次执行，不能复用旧报告。它仍使用开发版本地凭据，完整 BYOK 与正式 Keychain 候选结果仍待执行。工具与 verifier 由 `./scripts/test` 以 warnings-as-errors 编译，并有离线隐私/权限/原子写反例规格。
- 2026-07-17 旧版开发 matrix（严格报告 schema 落地前）：使用 226 秒非敏感系统 TTS 的前 60 秒完成开发预检。豆包 1/5/15/60 秒实时 paced 转录、流式取消和错误 Key全部 PASS；request ID 分别为 `20260717130020408124A2C1B9F0D44A84`、`20260717130022E8FA7E55CDA7BBB97D7F`、`2026071713002723F393A0B537B2B4AF8B`、`20260717130043BFCC2F1416BF87BBE9C0`、取消 `7669280B-705D-4856-B275-12280D970DFC`、错误 Key `20260717130146B7236D4D34EEBDC471A4`。临时 AIFF/WAV 已删除。DeepSeek 未配置，连接、三模式和取消均 SKIP；错误 Key边界 PASS。因此这只是历史 PARTIAL 日志，不是当前 schema 报告、完整 provider 或正式 Keychain 候选证据。
- `./scripts/test-release-identity`：受审查 Bundle/Team 身份不可由环境变量覆盖，占位身份无法进入正式发布；覆盖不可伪造的 FD 发布锁、自定义 bundle 输出防覆盖、源码快照与 BuildManifest、公证 JSON/log、evidence ZIP 完整性、handled rollback、包含 evidence 的 hash-bound prepared/committed journal、外来同名制品保留和 stale pending 清理。
- `./scripts/test-release-evidence`：使用真实 Speaker executable 生成 dSYM，把它装入完整 evidence ZIP 后重新解包核对 UUID 和 DWARF 完整性；篡改嵌套 DWARF 必须失败。CI 对隔离 Release bundle 执行同一门禁。
- `./scripts/test-install-rollback`：隔离安装中注入交换后失败，旧 bundle、签名完整性和运行状态均恢复。
- `./scripts/test-install-identity`：隔离安装中构造同 Bundle ID 但签名损坏的旧 App，安装器在停止进程或交换 bundle 前拒绝替换，原版本保持不变；安装测试使用临时 App 输出，不再覆盖共享 `.build/Speaker.app`。
- `./scripts/build`：Debug App 构建通过。
- `./scripts/swiftw build --disable-sandbox --configuration debug --product SpeakerApp -Xswiftc -warnings-as-errors`：严格警告构建通过。
- `SPEAKER_CONFIGURATION=release ./scripts/bundle`：Release bundle、Info.plist、签名完整性验证通过。
- `.github/workflows/ci.yml`：在 GitHub `macos-26` runner 上校验活动 SDK 不低于 26，并通过 `SPEAKER_SDKROOT` 固定本次 job 的 SDK；随后执行规格、Debug/Release warnings-as-errors、独立 SwiftPM scratch 的 Release bundle、Info.plist/签名、SwiftPM checkout 干净度和脚本校验。Release bundle 不复用或改写开发 `.build/Speaker.app`。正式签名与公证仍由 fail-closed 发布流程单独负责。
- App composition 已按 Application、Settings、Onboarding、History、VoiceInput module 拆分；`SpeakerApp.swift` 只保留 49 行 Scene wiring。`VoiceInputExperience` 已删除浅层 session model，集中 dispatcher、Esc、session capability action、notice、menu/overlay projection、VoiceOver 和 shutdown；Settings/Onboarding 也不再反向持有整个 Runtime。终态先向用户发布，历史持久化随后排队，磁盘写入不会卡住转录结果。
- `/Applications/Speaker.app`：保留用于 TCC/权限复测的本机开发安装；它可能刻意落后于当前源码，未经显式重新安装不得作为当前构建或 UI 的证据，且 ad-hoc 身份始终不是发布签名证据。
- 本机从旧历史升级后 SQLite `quick_check=ok`、`user_version=1`，现有记录的 payload schema 均为 v1；数据库目录为 `0700`，数据库及 WAL sidecar 为 `0600`。
- 首次引导已用生产窗口在 640×620 与 420×400 两种内容尺寸真实渲染复核；小窗口保持固定底部完成区、滚动内容和一致的权限操作布局。
