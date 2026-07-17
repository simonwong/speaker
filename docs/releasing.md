# Speaker 发布流程

Speaker 的本机开发安装与正式对外发布使用不同入口，不能互相替代。

安装器在替换已有 Speaker 前会验证旧包身份：ad-hoc 更新只接受有效 ad-hoc
旧包；本机具名签名只接受同一 designated requirement（允许从有效 ad-hoc
首次迁移）；Developer ID 更新必须保持受审查的 Bundle ID、Team ID 与
entitlements。仅 Bundle ID 相同但签名损坏或身份不同的包会被 fail-closed 拒绝。

## 版本策略

- `SPEAKER_VERSION` 使用稳定 SemVer，例如 `1.2.0`，对应 `CFBundleShortVersionString`。当前正式 feed 尚未建立 prerelease channel，因此 `beta`、`rc` 等先行版本会 fail closed。
- `SPEAKER_BUILD_NUMBER` 是 CI 为每次正式候选构建注入的、全局单调递增的正整数，对应 `CFBundleVersion`。同一版本重新构建时也不得复用。
- Git tag 使用 `v<SemVer>`。只有通过签名、公证、制品复验和人工验收的构建才能创建正式 tag。
- 正式 Bundle ID 和 Apple Team ID 一经发布不得随版本改变，否则 macOS 会把新版本视作不同 App，Keychain 与 TCC 权限也无法稳定延续。

仓库不会根据日期、Git 提交数或本地环境猜测 build number。CI 必须提供唯一值；缺失或格式错误时发布脚本会直接失败。

## 本机开发安装

```bash
./scripts/release
```

该入口使用 `com.local.speaker` 和 ad-hoc 签名，只用于本机开发验证。它不生成可分发制品，也不能作为 TCC 权限跨版本保持的证据。

ad-hoc 签名的 designated requirement 会绑定单次构建的代码哈希。重新构建后，macOS
可能要求重新授予麦克风和辅助功能权限；这不是正式发布版本可接受的身份模型。

如果本机 Keychain 已有可信的代码签名 identity，可以让开发安装在多次构建间保持稳定身份：

```bash
SPEAKER_LOCAL_CODESIGN_IDENTITY="Apple Development: ..." ./scripts/release
```

`./scripts/release` 会自动选择唯一的 `Speaker Local Development` identity；
若不存在，则会自动选择唯一的 `Apple Development: ...` identity。存在多个
Apple Development identity 时必须显式指定，避免构建在不同证书之间漂移。

没有 Apple Development identity 时，可以按 Apple 推荐的图形界面流程创建仅供
本机使用的自签名 identity：

1. 打开“钥匙串访问”。
2. 选择“钥匙串访问 > 证书助理 > 创建证书”。
3. 名称填写 `Speaker Local Development`，证书类型选择“代码签名”，创建到
   当前用户的登录钥匙串。
4. 在证书的信任设置中只确认“代码签名”用途，并接受 macOS 的用户授权。
5. 运行 `security find-identity -v -p codesigning`，确认该名称显示为 valid。

不要使用允许所有应用访问私钥的导入选项。自签名 identity 只解决这台 Mac 上的
开发构建身份稳定性，不具备 Developer ID 的分发信任或公证能力。

本地具名签名仍使用 `com.local.speaker` 与 owner-only 本地凭据文件，不会被误认为正式制品。只有后续构建持续使用同一个 identity，TCC 权限身份才可能保持。
脚本会拒绝 ad-hoc 结果或仍然绑定单次 CDHash 的 identity。可用 identity 可通过
`security find-identity -v -p codesigning` 查看。

## 正式候选构建

首次正式发布前，必须把经过审查且后续保持不变的身份写入：

```text
Resources/ReleaseIdentity.plist
  BundleIdentifier=<正式反向域名 Bundle ID>
  TeamIdentifier=<10 位 Apple Team ID>
  UpdateFeedURL=<正式 HTTPS appcast.xml>
  UpdateDownloadURLPrefix=<与 appcast 同目录且以 / 结尾>
  ProductURL=<正式 HTTPS 产品页>
  UpdatePublicEDKey=<Sparkle Ed25519 公钥>

Resources/ReleaseCandidate.plist
  PreviousPublishedBuildNumber=<上一个已公开 build；首次发布为 0>
  Version=<本次受审查的稳定 SemVer>
  BuildNumber=<本次受审查且严格递增的 build>
```

占位值会使正式分发直接失败。正式发布前先提交候选文件；发布成功并完成公开回读后，
下一次候选必须把本次 build 写入 `PreviousPublishedBuildNumber`。环境中的版本、build、
Bundle ID 与 Team ID 只能与这两份受审查文件完全相同，不能由 CI 临时替换。

CI 的受保护发布任务需要提供：

```text
SPEAKER_VERSION=1.0.0
SPEAKER_BUILD_NUMBER=<CI 注入的唯一正整数>
SPEAKER_CODESIGN_IDENTITY=Developer ID Application: ...
SPEAKER_NOTARY_PROFILE=<notarytool Keychain profile>
SPEAKER_SPARKLE_KEY_ACCOUNT=<Sparkle 私钥的 Keychain account>
SPEAKER_RELEASE_NOTES_FILE=<仓库内已提交、已审查的 .md/.txt/.html>
```

然后运行：

```bash
./scripts/test
./scripts/provider-smoke all
./scripts/build
./scripts/distribute
```

`scripts/distribute` 会按以下顺序 fail closed：

1. 读取受审查的 release identity 与 release candidate，拒绝占位值和环境覆盖；要求候选 build 严格大于仓库记录的上次公开 build，并验证 SemVer、正式 Bundle ID、Team ID 和签名 identity。Release notes 必须是当前干净 Git tree 内已提交的文件，外部临时文件和未跟踪文件会被拒绝。
2. 要求源码树和所有 SwiftPM dependency checkout 无本地修改；把固定的 `HEAD` commit 导出到 owner-only、只读的 source snapshot，后续 bundle、entitlements 和 release notes 全部从该快照读取。在本次发布专属的 pending SwiftPM scratch 中仅按快照里的 `Package.resolved` 解析公开依赖，不读取 Keychain/netrc，再分别构建 arm64/x86_64 并合成为 universal2 Release App。App 内会写入受代码签名保护的 `BuildManifest.plist`，精确记录 source commit、`Package.resolved` SHA-256 和 release-notes SHA-256。正式 App 不会覆盖开发用 `.build/Speaker.app`；随后要求 Developer ID Application、正确 Team/Identifier、Hardened Runtime、timestamp、受限 RPATH 和完全一致的 entitlements。
3. 删除非沙箱 App 不使用的 Sparkle XPC services，按 helper → framework → App 的顺序签名，并逐一验证 Team、Developer ID、Hardened Runtime、timestamp、RPATH 和私有 framework 路径。
4. 为最终可执行文件生成并核对 dSYM UUID；通过 pending ZIP 公证并 staple 内层 App，再生成 APFS+lzfse DMG，公证并 staple DMG。两次 `notarytool` 的 Accepted submission JSON 与 Apple log 都会按 submission ID、提交前 SHA-256 和 archive filename 交叉验证并留存，避免混入另一次已通过的公证记录。
5. 只读挂载最终 DMG，复验其中 App 的版本、签名、公证票据、Gatekeeper 与 Sparkle 布局。
6. 只从 SwiftPM 固定 artifact 的 canonical 路径加载 universal、code-integrity 完整且无 symlink 的 Sparkle 工具；确认 Keychain 私钥对应受审查公钥，使用 `generate_appcast` 生成 archive EdDSA、嵌入 release notes 和 signed feed，再用 `sign_update --verify` 复验 DMG 与 appcast。
7. 生成 release evidence archive，包含受签名 BuildManifest、DMG/appcast hash、两次公证 submission/log、dSYM、Swift/macOS 版本，以及实际编译 SDK 的 canonical name、路径和 `SDKSettings.plist` hash。Evidence 采用 exact allowlist，拒绝额外/空条目，重新验证 manifest、notary JSON/log、嵌套 dSYM ZIP，并从最终 ZIP 解出 dSYM 与发布 executable 再核 UUID；随后生成独立 SHA-256。DMG、两个 checksum、evidence archive 与 `appcast.xml` 由同一 promotion journal 原子晋升。

整个正式流程由当前 shell 的文件描述符持有 macOS `lockf` 单一发布锁，不信任可伪造的环境标记；每次正式 build 使用独立 scratch，两个发布也不能并发晋升 feed，进程崩溃后内核会自动释放锁。晋升前会把制品名、DMG/checksum/新旧 appcast 的 SHA-256 和 `prepared` 状态持久写入 promotion journal；DMG、校验和与 appcast 全部落位并同步后才持久切换为 `committed`。普通失败或可处理信号会立即按 journal 恢复；若遭遇 `SIGKILL` 或断电，下一次拿到锁时会先清理带 owner-only Speaker marker 的遗留 pending（包括尝试卸载其固定 mountpoint），再恢复 `prepared` 状态，或校验并完成 `committed` 状态的清理。恢复对象 hash 不符、旧 feed 损坏、未知 pending 或 journal 被篡改时 fail closed 并保留证据，不会删除外来同名制品或猜测成功。任一步失败都会清理可证明属于本事务的 pending 制品；不会退回 ad-hoc 签名，也不会把未验证的 DMG 或 appcast 留在正式制品目录。同一个版本号和构建号的 DMG 或 checksum 一旦存在，脚本会直接拒绝覆盖；任何重发都必须增加 build number。

对外上传时先发布 DMG 和 checksum，最后原子替换 `appcast.xml`，避免客户端先看到尚不可下载的版本。`Speaker-<version>-<build>-evidence.zip` 及其 checksum 以 `0600` 生成，应作为受保护 CI artifact 显式留存，不得使用 `distribution/*` 之类的 glob 默认公开，因为 Apple notarization log 可能包含团队和构建环境元数据。上传完成后在同一受保护发布环境执行：

```bash
SPEAKER_VERSION=1.0.0 \
SPEAKER_BUILD_NUMBER=<同一 build> \
SPEAKER_SPARKLE_KEY_ACCOUNT=<同一 account> \
./scripts/verify-published-update
```

该门禁从正式 HTTPS 地址回读 signed feed、DMG 和 checksum，复验 EdDSA、长度、SHA-256、公证、Gatekeeper、Developer ID/Team、版本号与 Sparkle 嵌套结构。

## 对外发布前的人工门槛

自动化通过后，仍需在干净 macOS 用户上完成并留存证据：

- 首次安装、Gatekeeper、麦克风和辅助功能授权。
- 从上一个公开版本覆盖升级，确认 Keychain API Key 与 TCC 权限保持。
- 豆包真实转录、可选 DeepSeek 整理、Esc 取消和无网络/鉴权错误恢复。
- TextEdit、Safari、Chrome/Electron、富文本和 Terminal 的输入与安全降级。
- 使用 `./scripts/compatibility-smoke` 逐项执行并保留脱敏报告；任何 FAIL
  返回 1，存在 SKIP 返回 2，只有全部通过返回 0。可用
  `./scripts/compatibility-smoke --list` 查看用例，或用 `--case ID`
  聚焦复测失败项。
- VoiceOver、Reduce Motion、Increase Contrast 和多显示器浮层定位。
- 历史查看、保留策略、清空、损坏恢复与卸载后本地数据边界。

仓库已接入更新 feature、Sparkle live adapter 和发布/回读门禁；但在真实正式身份、更新域名以及“旧版 → 新版”实机更新矩阵完成前，不应把当前开发制品描述为已经具备可用的生产更新通道。
