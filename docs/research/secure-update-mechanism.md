# Speaker 的生产级安全更新方案

> 调研日期：2026-07-16
>
> 范围：Sparkle 官方文档/仓库与 Apple 官方文档；不包含第三方教程。
> 当前 Speaker 约束：SwiftPM、SwiftUI `MenuBarExtra`、`LSUIElement`、macOS 14+、非 App Sandbox、站外分发。

## 结论

Speaker 适合采用 **Sparkle 2.9.4 + 标准更新 UI + 程序化
`SPUStandardUpdaterController`**。生产更新链必须同时具备：

1. 固定且不可再改变的正式 Bundle ID。
2. Developer ID Application 签名、Hardened Runtime、公证与 stapling。
3. HTTPS appcast 和下载地址。
4. Sparkle EdDSA 签名的完整更新制品。
5. 签名 appcast 与签名 release notes。
6. 严格递增的数字 `CFBundleVersion`。
7. 发布前从真实旧版到新版的安装、失败和恢复测试。

Developer ID/公证与 Sparkle EdDSA 解决的是不同边界，不能互相替代：

- Apple 代码签名与公证让 Gatekeeper 验证开发者身份、代码完整性和 Apple
  的恶意软件扫描结果。
- Sparkle EdDSA 把下载到的更新制品绑定到 Speaker 自己持有的更新密钥。
- 签名 appcast 进一步保护版本、下载 URL、release notes 等更新元数据。

在正式 Bundle ID、Apple Team、Developer ID 证书、生产域名和 EdDSA
密钥尚未全部确定前，**正式构建不得启动 updater、不得发起更新网络请求，也不得展示一个实际不可用的“检查更新”入口**。

## 1. 版本与集成方式

### 选择 Sparkle 2.9.4

截至调研日期，Sparkle 的最新生产版本是 2.9.4。它包含 appcast/delta
安全修复，并修复了后台/dockless App 由用户主动触发时更新窗口可能无法进入前台的问题，
正好对应 Speaker 的 `LSUIElement` 菜单栏形态。

- [Sparkle 2.9.4 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4)
- [Sparkle security and reliability changes](https://sparkle-project.org/documentation/security-and-reliability/)

SwiftPM 应精确锁定一个已审核版本，不跟踪 `2.x` 分支或预发行版：

```swift
.package(
    url: "https://github.com/sparkle-project/Sparkle",
    exact: "2.9.4"
)
```

`Sparkle` 依赖只应加入 `SpeakerApp` target；`SpeakerCore` 和
`SpeakerAppFeatures` 不直接 import Sparkle。

### 最低要求

Sparkle 2.9.4 的官方 `Package.swift` 使用：

- `swift-tools-version: 5.3`
- `.macOS(.v12)`
- SwiftPM binary target

Speaker 自身是 Swift tools 6.0 / macOS 14，因此没有兼容性缺口。
不要依据 Sparkle 首页笼统的“Sparkle 2 支持 macOS 10.13+”降低判断：
当前 2.9.4 SwiftPM artifact 的实际 deployment target 是 macOS 12。

- [Sparkle 2.9.4 Package.swift](https://github.com/sparkle-project/Sparkle/blob/2.9.4/Package.swift)
- [Sparkle repository requirements](https://github.com/sparkle-project/Sparkle/tree/2.x#requirements)

### 推荐入口

SwiftUI App 使用 Sparkle 官方推荐的程序化方式：

```swift
SPUStandardUpdaterController(
    startingUpdater: false,
    updaterDelegate: updaterDelegate,
    userDriverDelegate: userDriverDelegate
)
```

必须先通过 Speaker 自己的生产配置校验，再调用 `startUpdater()`。选择
`startingUpdater: false` 是为了让配置错误真正 fail closed，避免 Sparkle
因缺少 feed/key 启动后向用户显示“应用配置错误”。

用户主动检查更新调用 `checkForUpdates(_:)`，菜单可用状态跟随
`updater.canCheckForUpdates`。不要自己按启动、网络、下载阶段拼装另一套安装流程。

- [Programmatic setup, including SwiftUI](https://sparkle-project.org/documentation/programmatic-setup/)
- [`SPUStandardUpdaterController`](https://sparkle-project.org/documentation/api-reference/Classes/SPUStandardUpdaterController.html)

## 2. EdDSA、appcast 与密钥管理

### 生产密钥

使用 Sparkle 发行包内的 `generate_keys` 只生成一次生产 Ed25519 密钥：

```sh
./bin/generate_keys
```

- 公钥以 `SUPublicEDKey` 固定嵌入 App。
- 私钥不得进入源码、仓库、appcast 主机或普通 CI 环境变量。
- 日常签名优先从专用发布 Mac 的 Keychain 读取。
- 必须做至少一份离线加密备份，并实际验证能够导入和签名。
- CI 如必须使用文件输入，只通过短生命周期 secret file 或标准输入；
  不使用已被 Sparkle 废弃的不安全命令行 `-s` 私钥参数。

Sparkle 官方明确要求把更新私钥与承载下载文件的服务器隔离。

- [Sparkle EdDSA setup and key rotation](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures)
- [Security change deprecating private key command arguments](https://sparkle-project.org/documentation/security-and-reliability/)

### 强制安全配置

生产 `Info.plist` 至少包含：

```xml
<key>SUFeedURL</key>
<string>https://updates.example.invalid/speaker/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>BASE64_PRODUCTION_PUBLIC_KEY</string>
<key>SUVerifyUpdateBeforeExtraction</key>
<true/>
<key>SURequireSignedFeed</key>
<true/>
<key>SUSignedFeedFailureExpirationInterval</key>
<integer>0</integer>
<key>SUEnableSystemProfiling</key>
<false/>
<key>SUEnableJavaScript</key>
<false/>
```

上面的域名与 key 只是结构示例，**不得原样进入制品**。

`SUVerifyUpdateBeforeExtraction=YES` 让 Sparkle 在解压前验证更新制品。
`SURequireSignedFeed=YES`（Sparkle 2.9+）要求验证 appcast 与外链 release
notes。`SUSignedFeedFailureExpirationInterval=0` 禁止签名失败在默认 20
天后过期，符合 Speaker 的严格 fail-closed 目标；代价是生产 EdDSA 私钥及其离线备份
必须得到长期可靠保管。

如团队不能承诺密钥恢复演练，不应假装拥有严格签名 feed；应先解决密钥托管，
而不是放宽客户端校验。

- [Sparkle security settings](https://sparkle-project.org/documentation/customization/#security-settings)

### 生成 appcast

首选 `generate_appcast`，不要手写 XML 或自行计算签名：

```sh
./bin/generate_appcast /path/to/published-updates
```

工具会生成 archive 签名、appcast 和 delta。启用 `SURequireSignedFeed`
后，它也会签名 appcast 和 release notes；任何后续修改都必须重新运行工具和重新签名。

发布前校验 appcast 至少包含：

- `sparkle:version`：与制品 `CFBundleVersion` 完全一致。
- `sparkle:shortVersionString`：与 `CFBundleShortVersionString` 一致。
- `sparkle:edSignature` 与精确 `length`。
- HTTPS `enclosure` URL。
- `sparkle:minimumSystemVersion`：Speaker 当前写 `14.0.0`。
- 正确 `pubDate`。
- 签名过的内嵌或外链 release notes。

- [Publishing an update](https://sparkle-project.org/documentation/publishing/)
- [Basic setup and `generate_appcast`](https://sparkle-project.org/documentation/#publish-your-appcast)

## 3. Developer ID、公证和 Sparkle 的关系

Apple 对站外分发的要求是：

1. 所有可执行代码使用 Developer ID Application 签名。
2. 启用 Hardened Runtime。
3. 使用 secure timestamp。
4. 将制品提交 Apple notary service。
5. 成功后 staple ticket，并在隔离环境中验证 Gatekeeper。

自签名、本地开发签名、ad-hoc 签名和 Mac App Distribution 签名都不能替代
Developer ID 进行公证。

- [Apple: Signing Mac software with Developer ID](https://developer.apple.com/developer-id/)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

Sparkle 官方同样推荐通过 Xcode Archive/Export 或等价的
`xcodebuild archive`、`xcodebuild -exportArchive` 流程导出 Developer ID
制品，以确保 Sparkle framework、Updater、Autoupdate 和 helper 被正确签名。
不能只对最外层 `.app` 做一次粗略 `codesign --deep` 来替代逐层正确签名。

- [Sparkle distributing your App](https://sparkle-project.org/documentation/#distributing-your-app)
- [Sparkle sandbox/code signing notes](https://sparkle-project.org/documentation/sandboxing/#code-signing)

Sparkle 会结合 Apple Code Signing 与自己的 EdDSA 验证更新，但 Apple
公证并不签署 appcast，EdDSA 也不产生 Gatekeeper notarization ticket。
两条链都必须通过。

## 4. 发布制品格式

### 推荐：公证并 staple 的 DMG

Speaker 的网站下载制品和 Sparkle enclosure 统一使用同一份 DMG：

1. DMG 内只放 `Speaker.app` 和指向 `/Applications` 的 symlink。
2. App 先完成 Developer ID 签名。
3. DMG 送公证并 staple。
4. 对最终字节完全确定的 DMG 再生成 Sparkle EdDSA/appcast 签名。
5. 上传后按公开 URL 下载一次，重新验证长度、EdDSA、codesign、stapler 和
   Gatekeeper。

启用 `SUVerifyUpdateBeforeExtraction` 后，如果未来需要轮换 EdDSA key，
Sparkle 官方指定 Developer ID code-signed DMG 作为可用回退，因此 DMG
比 ZIP 更适合 Speaker 的长期密钥恢复设计。

- [Sparkle key rotation](https://sparkle-project.org/documentation/#rotating-signing-keys)
- [Apple: Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

Sparkle 也支持 ZIP、tarball、Apple Archive 和 package installer，但：

- ZIP 必须用 `ditto -c -k --sequesterRsrc --keepParent` 创建并保留 symlink。
- `.aar` 要求 macOS 10.15+ 且必须启用解压前验证。
- `.pkg` 只适合真正需要定制安装的产品；它总可能要求授权、没有 delta、
  没有同等的 key rotation fallback，并增加恢复复杂度。

Speaker 目前是单一普通 App bundle，不应使用 `.pkg`。

- [Sparkle supported archive formats](https://sparkle-project.org/documentation/publishing/#archive-your-app)
- [Sparkle package update trade-offs](https://sparkle-project.org/documentation/package-updates/)

## 5. 防降级与版本比较

Sparkle 2 已移除自动 downgrade 支持。标准比较器针对 `x`、`x.y`、`x.y.z`
形式的数字版本；自定义 comparator 从 Sparkle 2.7 起已弃用，并且安装阶段仍可能使用
标准 comparator 防止降级。

Speaker 应采用两个分离字段：

```text
CFBundleVersion            = 严格单调递增的纯数字构建号，例如 120
CFBundleShortVersionString = 面向用户的语义版本，例如 1.3.0
```

appcast 中对应：

```xml
<sparkle:version>120</sparkle:version>
<sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>
```

发布系统必须拒绝：

- 构建号小于或等于已发布最大值。
- 同一构建号对应不同制品。
- 同一下载 URL 被原地覆盖。
- 用日期、Git hash、`beta` 文本等非标准值做 `CFBundleVersion`。
- 通过自定义 comparator 绕过顺序。

若新版存在严重缺陷，不能把旧构建重新发布成“降级”；应从旧源码制作一个
**更高 `CFBundleVersion` 的前向修复版本**。如无法安全自动安装，可发布
Sparkle informational update 指向人工恢复页面。

- [Sparkle upgrading guide: numeric versions and removed downgrade support](https://sparkle-project.org/documentation/upgrading/#upgrading-to-sparkle-27)
- [`SUStandardVersionComparator`](https://sparkle-project.org/documentation/api-reference/Classes/SUStandardVersionComparator.html)
- [`SPUNoUpdateFoundReason.onNewerThanLatestVersion`](https://sparkle-project.org/documentation/api-reference/Enums/SPUNoUpdateFoundReason.html)

签名 appcast 可以阻止攻击者修改下载地址和版本元数据；即使旧的已签名 feed
被重放，Sparkle 的版本比较仍不应把低版本安装到高版本之上。前提是发布方从不重用、
回退或歧义化构建号。

## 6. 自动检查、手动检查、权限和隐私

### 用户行为

建议保留 Sparkle 默认策略：

- 第一次启动不打扰用户。
- `SUEnableAutomaticChecks=NO`，不使用 Sparkle 第二次启动权限提示；只在 Speaker 设置中由用户明确开启自动检查。
- 菜单始终提供用户主动的“检查更新…”。
- 自动检查默认周期为 24 小时，不在每次启动手动强制调用后台检查。
- Settings 直接绑定 Sparkle 已由 `NSUserDefaults` 支持的
  `automaticallyChecksForUpdates` 和 `automaticallyDownloadsUpdates`；
  不再维护一份 Speaker 私有副本。

只有用户在 UI 中改变设置时才写这些 runtime properties。Sparkle 官方明确警告：
在启动时反复设置或晚些时候任意调用 `checkForUpdatesInBackground()` 会覆盖用户选择
或干扰 scheduler。

- [Sparkle update behavior settings](https://sparkle-project.org/documentation/customization/)
- [Sparkle SwiftUI settings UI](https://sparkle-project.org/documentation/preferences-ui/#adding-settings-in-swiftui)
- [Programmatic API expectations](https://sparkle-project.org/documentation/programmatic-setup/#api-expectations)

### 隐私

`SUEnableSystemProfiling` 保持 `NO`。启用后，Sparkle 可把系统版本、CPU、
Mac 型号、核心数、内存、App 版本和语言等作为 appcast GET query
发送；Speaker 的安全更新不需要这些数据。

不得向 appcast URL 添加：

- 用户 ID、安装 ID、设备序列信息。
- 豆包或 DeepSeek 配置状态。
- 转录历史、个人词库内容或任何语音输入数据。
- provider API key 或其他凭据。

Sparkle phased rollout 使用保存在本地 defaults 的随机组 ID，官方说明该 ID
不会发送到服务器；可在完成基础更新可靠性后再启用。

- [Sparkle system profiling data](https://sparkle-project.org/documentation/system-profiling/)
- [Sparkle phased rollouts](https://sparkle-project.org/documentation/publishing/#phased-group-rollouts)

### MenuBar/dockless 体验

Speaker 是 accessory/dockless App。自动检查发现更新时不应抢走用户当前输入焦点。
Sparkle 2.2+ 对后台 App 默认避免 scheduled alert 抢前台，但官方仍建议这类长期运行
App 实现 gentle reminder delegate。

建议：

- 用户主动点“检查更新…”时，允许标准更新窗口进入前台。
- 后台发现普通更新时，在菜单栏显示低干扰标记，等用户主动打开。
- critical update 才使用更明显提示。
- 更新会话期间如临时改为 `.regular` activation policy，结束后恢复
  `.accessory`；必须测试不会破坏 Speaker 的录音 HUD 和输入焦点规则。

- [Sparkle gentle update reminders](https://sparkle-project.org/documentation/gentle-reminders/)
- [Sparkle 2.9.4 dockless activation fix](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4)

## 7. 更新失败与恢复边界

Sparkle 提供签名校验、下载/解压错误、授权处理、可恢复的已下载状态，以及
atomic-safe App bundle 安装。失败应通过 `SPUUpdaterDelegate` 的
`didAbortWithError`、`didFinishUpdateCycle...`、`failedToDownloadUpdate`
等结构化回调进入 Speaker 诊断，而不是用固定超时或模糊的“更新失败”兜底。

- [Sparkle atomic-safe installs](https://github.com/sparkle-project/Sparkle#features)
- [`SPUUpdaterDelegate`](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
- [`SPUUserDriver` update states and recoverable errors](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html)

必须区分：

1. feed 下载失败；
2. feed 签名失败；
3. 没有兼容更新；
4. archive 下载失败；
5. EdDSA/Apple 签名验证失败；
6. 解压失败；
7. 安装目录不可写或用户取消授权；
8. App 无法退出；
9. 安装完成但新版业务启动失败。

Sparkle 的 atomic install 防止安装中断留下半个 bundle，但它不是新版业务健康检查系统。
如果新版成功安装后自身崩溃，Sparkle 不会自动把它降回旧版。因此发布侧还必须：

- 在真实、已公证的旧版上验证完整升级。
- 对数据 schema 采用前向兼容/可恢复迁移，迁移失败不删除旧数据。
- 保持旧版制品和符号文件可下载给支持人员，但不把它作为 Sparkle 降级项。
- 支持发布更高构建号的 hotfix。
- 需要暂停坏版本时，立即从 appcast 移除 enclosure 或发布 informational update，
  不覆盖已发布 archive。
- 保留 appcast、archive、签名、notary log、SHA-256、dSYM 与发布清单。

首次上线先只发布 full update，不生成 delta。待至少两次真实 full update
验证后，再启用 `generate_appcast` 的 delta，并分别测试 full fallback。

## 8. 正式身份未确定时的 fail-closed 条件

当前仓库仍使用开发 Bundle ID `com.local.speaker`。在以下任一条件不满足时，
`SoftwareUpdateFeature` 必须处于 `.unavailable(configurationReason)`，
live Sparkle adapter 不得构造或启动：

| 条件 | 发布 gate |
| --- | --- |
| Bundle ID | 非 `com.local.speaker`，与不可变发布清单精确相等 |
| Apple Team | 已固定，实际签名 TeamIdentifier 与发布清单相等 |
| 签名模式 | `SpeakerSigningMode == developer-id` |
| 代码签名 | `codesign --verify --strict` 通过，所有 nested code 正确签名 |
| Hardened Runtime | 已启用，且无 release `get-task-allow` |
| 公证 | `notarytool` Accepted；stapler validate 通过 |
| Feed | 最终 HTTPS URL；无 localhost、IP、example/invalid 域名、用户名或密码 |
| EdDSA | 合法生产公钥；不等于开发 key/placeholder |
| Feed security | `SUVerifyUpdateBeforeExtraction` 与 `SURequireSignedFeed` 均为 YES |
| Profiling | `SUEnableSystemProfiling` 为 NO |
| Version | `CFBundleVersion` 为数字且大于已发布最大值 |
| Artifact | 最终 DMG 与 appcast 的 length、signature、URL 一致且不可变 |

发布脚本应同时检查 Info.plist 中的预期值和签名制品的实际值，任何不一致都退出非零。
不能仅依赖运行时隐藏按钮；错误的 release artifact 必须在上传前被 CI/release gate
拒绝。

Bundle ID 对 Sparkle 和 macOS 都是长期身份。Sparkle 维护者明确说明它假设
Bundle ID 永不改变，并用它在更新制品中匹配 App；Apple 也把 Bundle ID
定义为系统识别 App 的唯一标识。

- [Sparkle maintainer: Bundle ID is permanent](https://github.com/sparkle-project/Sparkle/issues/1600)
- [Apple: Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)

## 9. Speaker 的 live/fake adapter seam

### 模块边界

```text
SpeakerAppFeatures
  SoftwareUpdateFeature
  SoftwareUpdateConfigurationValidator
  SoftwareUpdateClient protocol/value
  UpdateState / UpdateFailure / UpdateIntent
            ↑ 注入
SpeakerApp
  SparkleSoftwareUpdateAdapter
  SPUStandardUpdaterController
  SPUUpdaterDelegate
  SPUStandardUserDriverDelegate
```

`SpeakerAppFeatures` 不知道 Sparkle 类型。它只处理：

- 配置是否可用；
- 菜单/设置 presentation；
- `checkNow`、自动检查开关、自动下载开关等用户 intent；
- 结构化生命周期和失败分类；
- 诊断的脱敏投影。

建议最小接口：

```swift
@MainActor
package protocol SoftwareUpdateClient: AnyObject {
    var snapshot: SoftwareUpdateSnapshot { get }
    var snapshots: AsyncStream<SoftwareUpdateSnapshot> { get }

    func start() throws
    func checkForUpdates()
    func setAutomaticallyChecksForUpdates(_ enabled: Bool)
    func setAutomaticallyDownloadsUpdates(_ enabled: Bool)
}
```

`SoftwareUpdateSnapshot` 只保留产品需要的语义：

```swift
package struct SoftwareUpdateSnapshot: Equatable, Sendable {
    package var availability: Availability
    package var canCheckForUpdates: Bool
    package var automaticallyChecksForUpdates: Bool
    package var automaticallyDownloadsUpdates: Bool
    package var phase: Phase
    package var lastFailure: UpdateFailure?
}
```

不要把 `SUAppcastItem`、`NSError.userInfo`、下载 URL 或签名细节穿透到 SwiftUI。
live adapter 将 Sparkle KVO/delegate 回调映射成 snapshot；fake adapter
使用可控状态和已记录 intent。

### 组合方式

`SpeakerRuntime` 初始化时：

1. 从 Bundle、`SpeakerSigningMode` 和实际签名身份形成
   `SoftwareUpdateConfiguration`.
2. 用纯 `SoftwareUpdateConfigurationValidator` 校验。
3. 通过时注入 `SparkleSoftwareUpdateAdapter(startingUpdater: false)`。
4. 未通过时注入 `DisabledSoftwareUpdateClient(reason:)`。
5. `runtime.start()` 只对可用 client 调用 `start()`。

这样 Debug/ad-hoc 构建不访问生产 feed，也不会因为缺配置弹 Sparkle
错误框；AppFeatures 的所有状态均可无网络测试。

### 必测 fake 场景

- 配置完整时只 start 一次。
- 缺 Bundle ID/Team/feed/key/Developer ID 任一项时完全不 start。
- `canCheckForUpdates=false` 时菜单禁用。
- 用户主动检查只产生一次 `checkForUpdates` intent。
- 自动检查/自动下载设置只在用户操作时写 adapter。
- background failure 不抢焦点，只更新低干扰状态。
- user-initiated failure 显示可理解、可重试的错误。
- 签名失败与普通网络失败不可合并。
- 下载完成、等待退出、安装中、用户取消授权可恢复。
- data erasure/shutdown 期间不再启动新 update session。
- gentle reminder 结束后恢复 `.accessory` activation policy。

live integration 测试必须使用两份真实 Developer ID 签名、公证且构建号不同的
Speaker App，以及隔离的测试 appcast。普通 fake 或 ad-hoc 构建不能证明
Gatekeeper、key rotation、权限提升和实际替换行为。

## 10. 最小实施顺序

1. 确定并冻结正式 Bundle ID、Team ID、更新域名。
2. 建立 Developer ID、Hardened Runtime、公证、staple 的可重复 release。
3. 生成并备份生产 EdDSA key；把公钥加入发布清单。
4. 精确加入 Sparkle 2.9.4，只依赖 `SpeakerApp`。
5. 先实现纯配置 validator、disabled client 和 fake tests。
6. 实现 live adapter 与标准 Sparkle UI；加入菜单“检查更新…”和设置项。
7. 配置签名 feed 与解压前校验；system profiling/JavaScript 保持关闭。
8. 使用公证 DMG 建立 appcast，先只发布 full update。
9. 从真实旧版测试自动/手动检查、无更新、网络断开、签名损坏、授权取消、
   App 不退出、安装重启和 hotfix。
10. release gate 全通过后才允许上传 appcast；最后上传 appcast，避免客户端先看到
    尚未完全可用的 release。

## 官方资料索引

- [Sparkle basic documentation](https://sparkle-project.org/documentation/)
- [Sparkle programmatic/SwiftUI setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [Sparkle customization and security keys](https://sparkle-project.org/documentation/customization/)
- [Sparkle publishing](https://sparkle-project.org/documentation/publishing/)
- [Sparkle update security and reliability history](https://sparkle-project.org/documentation/security-and-reliability/)
- [Sparkle 2.9.4 source/release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4)
- [Apple Developer ID](https://developer.apple.com/developer-id/)
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple macOS distribution](https://developer.apple.com/macos/distribution/)
