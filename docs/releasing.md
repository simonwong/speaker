# Speaker 发布流程

Speaker 的本机开发安装与正式对外发布使用不同入口，不能互相替代。

安装器在替换已有 Speaker 前会验证旧包身份：ad-hoc 更新只接受有效 ad-hoc
旧包；本机具名签名只接受同一 designated requirement（允许从有效 ad-hoc
首次迁移）；Developer ID 更新必须保持受审查的 Bundle ID、Team ID 与
entitlements。仅 Bundle ID 相同但签名损坏或身份不同的包会被 fail-closed 拒绝。

## 版本策略

- `SPEAKER_VERSION` 使用稳定 SemVer，例如 `1.2.0`，对应 `CFBundleShortVersionString`。当前正式 feed 尚未建立 prerelease channel，因此 `beta`、`rc` 等先行版本会 fail closed。
- `SPEAKER_BUILD_NUMBER` 是 CI 为每次正式候选构建注入的、全局单调递增的正整数，对应 `CFBundleVersion`。同一版本重新构建时也不得复用。
- Git tag 使用 `v<SemVer>`。候选签名、公证和制品复验通过后，staging 可创建该 tag 及 prerelease；只有人工验收通过，才能把同一 tag 提升为 stable latest。
- 正式 Bundle ID 和 Apple Team ID 一经发布不得随版本改变，否则 macOS 会把新版本视作不同 App，Keychain 与 TCC 权限也无法稳定延续。

Formal releases never derive a build number from dates, Git history, or the local environment. CI must provide the unique value; a missing or malformed value fails closed.

## 本机开发安装

```bash
./scripts/release
```

该入口使用 `com.local.speaker` 和 ad-hoc 签名，只用于本机开发验证。它不生成可分发制品，也不能作为 TCC 权限跨版本保持的证据。

Without explicit development metadata, `CFBundleVersion` is the current
`HEAD` commit count and `SpeakerSourceRevision` is the 12-character commit SHA.
An uncommitted worktree appends `-dirty`. Each committed development install
therefore gets a new numeric build, while About and redacted diagnostics can
identify its source. This identity is for development traceability only; it
does not participate in Sparkle ordering or formal release numbering.

Specialized installs and black-box tests may set `SPEAKER_VERSION`,
`SPEAKER_BUILD_NUMBER`, and `SPEAKER_SOURCE_REVISION` explicitly. Source outside
resolvable Git history must provide at least the build and source revision;
the scripts never silently fall back to build 1.

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

## GitHub development prereleases

After CI succeeds for a push to `main`, it reads the explicit SemVer from
`Resources/Info.plist`. If `v<SemVer>-dev` does not exist, CI creates a GitHub
Prerelease containing the already validated ad-hoc ZIP and its SHA-256 file.
Later commits using the same SemVer do not replace or republish that release;
creating another development release requires a reviewed version change.

Development prereleases use `com.local.speaker`, are not notarized, and are not
part of the Sparkle update channel. They may require renewed Microphone and
Accessibility permissions after installation. This path remains separate from
the protected production workflow below.

## 正式候选构建

首次正式发布前，必须把经过审查且后续保持不变的身份写入：

```text
Resources/ReleaseIdentity.plist
  BundleIdentifier=<正式反向域名 Bundle ID>
  TeamIdentifier=<10 位 Apple Team ID>
  UpdateFeedURL=https://github.com/simonwong/speaker/releases/latest/download/appcast.xml
  UpdateDownloadURLPrefix=https://github.com/simonwong/speaker/releases/download/
  ProductURL=https://github.com/simonwong/speaker
  UpdatePublicEDKey=<Sparkle Ed25519 公钥>

Resources/ReleaseCandidate.plist
  PreviousPublishedBuildNumber=<上一个已公开 build；首次发布为 0>
  Version=<本次受审查的稳定 SemVer>
  BuildNumber=<本次受审查且严格递增的 build>
```

占位值会使正式分发直接失败。正式发布前先提交候选文件；发布成功并完成公开回读后，
下一次候选必须把本次 build 写入 `PreviousPublishedBuildNumber`。环境中的版本、build、
Bundle ID 与 Team ID 只能与这两份受审查文件完全相同，不能由 CI 临时替换。

版本单一来源：`ReleaseCandidate.plist` 的 `Version` 必须与 `Resources/Info.plist` 的
`CFBundleShortVersionString` 完全相同，`BuildNumber` 必须是严格大于
`PreviousPublishedBuildNumber` 的正整数，否则 `scripts/distribute` 在读取候选清单时立即
fail closed。

`scripts/distribute` 的本地正式参数：

```text
SPEAKER_VERSION=1.0.0
SPEAKER_BUILD_NUMBER=<CI 注入的唯一正整数>
SPEAKER_CODESIGN_IDENTITY=Developer ID Application: ...
SPEAKER_NOTARY_PROFILE=<notarytool Keychain profile>
SPEAKER_SPARKLE_KEY_ACCOUNT=<Sparkle 私钥的 Keychain account>
SPEAKER_RELEASE_NOTES_FILE=<仓库内已提交、已审查的 .md/.txt/.html>
SPEAKER_UPGRADE_EVIDENCE_FILE=<仓库内已提交、由 compatibility-smoke 生成的完整报告>
```

GitHub workflow 从 `ReleaseCandidate.plist` 读取 version/build；首次输入 release notes，
promotion 再输入 upgrade evidence 路径与首次 candidate run ID。

仓库提供 `.github/workflows/release.yml` 作为唯一的 GitHub Actions 正式发布入口。
它只允许从默认分支手动触发。签名 job 绑定 `production` Environment；建议开启
required reviewers、禁止发起者自批，并只允许受保护的 `main` 部署。只在
`production` 配置以下 Environment secrets：

```text
SPEAKER_DEVELOPER_ID_P12_BASE64
SPEAKER_DEVELOPER_ID_P12_PASSWORD
SPEAKER_NOTARY_API_KEY_P8_BASE64
SPEAKER_NOTARY_KEY_ID
SPEAKER_NOTARY_ISSUER_ID
SPEAKER_SPARKLE_PRIVATE_KEY
SPEAKER_DOUBAO_API_KEY
SPEAKER_DEEPSEEK_API_KEY
SPEAKER_EVIDENCE_ARCHIVE_PASSWORD
```

P12 与 App Store Connect API `.p8` 以完整文件的 base64 保存；Sparkle secret
保存 `generate_keys -x` 导出的文件内容。Workflow 在临时 Keychain 中导入签名、
公证、Sparkle 和两家 provider 凭据，先验证 Developer ID 唯一性、公证 API Key
和 Sparkle 公私钥绑定，再用固定非敏感 TTS 样本执行完整 provider matrix。Matrix
必须在本次 run 内生成，并与当前 commit、`Package.resolved` hash、version、build
及四小时内的执行时间窗完全一致；任何 FAIL/SKIP 或开发文件凭据都会阻止
`scripts/distribute`。任务结束后删除临时 Keychain 和 secret files。DMG、checksum 与
appcast 作为 90 天 Actions artifact 留存，并同时附加到公开 prerelease。Evidence archive
先用至少 32 字符的随机 production secret 经 ChaCha20-Poly1305 加密；Actions 只保留
密文及其 checksum。仓库公开，因此 artifact 与 prerelease 都按公开数据处理；明文
notarization/provider evidence 不离开 ephemeral runner。

受审查人恢复 evidence 时，在受控机器下载 `.zip.enc` 并运行：

```bash
SPEAKER_EVIDENCE_ARCHIVE_PASSWORD='<production secret>' \
./scripts/swiftw run --disable-sandbox \
  SpeakerReleaseEvidenceProtector decrypt \
  Speaker-<version>-<build>-evidence.zip.enc \
  Speaker-<version>-<build>-evidence.zip
```

错误 secret、损坏或篡改密文都会认证失败，不产生可接受 evidence。

`production-staging` job 以 `v<SemVer>` 创建公开 GitHub prerelease，只附加 DMG、checksum
和签名 appcast，并从公开地址逐字节回读。稳定 feed 使用 `releases/latest`，不会选择
prerelease。`production-publication` job 不读取 Developer ID、公证、provider、Sparkle
私钥或 evidence 解密 secret；它凭受审查报告和 candidate run ID 下载首次 run 的同一
artifact，核对公开 prerelease、完整 executable SHA-256、两架构 CodeDirectory CDHash
和 Ed25519 签名，再把同一个 Release 原地改为 non-prerelease/latest。任何第二次构建都
不能进入 promotion。

然后运行：

```bash
./scripts/test
./scripts/provider-smoke all
./scripts/build
./scripts/distribute
```

仅为生成待实测候选时，可不设置 upgrade evidence，并显式使用
`SPEAKER_PREPARE_UPGRADE_CANDIDATE=1 ./scripts/distribute`。GitHub workflow 的首次 run
固定使用该模式，并把验证后的产物发布为不进入 stable latest feed 的 prerelease。

`scripts/distribute` 会按以下顺序 fail closed：

1. 读取受审查的 release identity 与 release candidate，拒绝占位值和环境覆盖；要求候选 build 严格大于仓库记录的上次公开 build，并验证 SemVer、正式 Bundle ID、Team ID 和签名 identity。Release notes 必须是当前干净 Git tree 内已提交的文件，外部临时文件和未跟踪文件会被拒绝。Provider matrix 必须来自本次 release run 的正式 Keychain，且精确绑定 commit、依赖锁 hash、version、build 与生成时间窗；旧报告、开发凭据、FAIL 或 SKIP 均 fail closed。
2. 要求源码树和所有 SwiftPM dependency checkout 无本地修改；把固定的 `HEAD` commit 导出到 owner-only、只读的 source snapshot，后续 bundle、entitlements 和 release notes 全部从该快照读取。在本次发布专属的 pending SwiftPM scratch 中仅按快照里的 `Package.resolved` 解析公开依赖，不读取 Keychain/netrc，再分别构建 arm64/x86_64 并合成为 universal2 Release App。App 内会写入受代码签名保护的 `BuildManifest.plist`，精确记录 source commit、`Package.resolved` SHA-256 和 release-notes SHA-256。正式 App 不会覆盖开发用 `.build/Speaker.app`；随后要求 Developer ID Application、正确 Team/Identifier、Hardened Runtime、timestamp、受限 RPATH 和完全一致的 entitlements。
3. 删除非沙箱 App 不使用的 Sparkle XPC services，按 helper → framework → App 的顺序签名，并逐一验证 Team、Developer ID、Hardened Runtime、timestamp、RPATH 和私有 framework 路径。
4. 为最终可执行文件生成并核对 dSYM UUID；通过 pending ZIP 公证并 staple 内层 App，再生成 APFS+lzfse DMG，公证并 staple DMG。两次 `notarytool` 的 Accepted submission JSON 与 Apple log 都会按 submission ID、提交前 SHA-256 和 archive filename 交叉验证并留存，避免混入另一次已通过的公证记录。
5. 只读挂载最终 DMG，复验其中 App 的版本、签名、公证票据、Gatekeeper 与 Sparkle 布局。
6. 只从 SwiftPM 固定 artifact 的 canonical 路径加载 universal、code-integrity 完整且无 symlink 的 Sparkle 工具；确认 Keychain 私钥对应受审查公钥，使用 `generate_appcast` 生成 archive EdDSA、嵌入 release notes 和 signed feed，再用 `sign_update --verify` 复验 DMG 与 appcast。
7. 生成 release evidence archive，包含受签名 BuildManifest、已绑定的 provider matrix 及其 hash、DMG/appcast hash、两次公证 submission/log、dSYM、Swift/macOS 版本，以及实际编译 SDK 的 canonical name、路径和 `SDKSettings.plist` hash。Evidence 采用 exact allowlist，拒绝额外/空条目，重新验证 manifest、provider report hash、notary JSON/log、嵌套 dSYM ZIP，并从最终 ZIP 解出 dSYM 与发布 executable 再核 UUID；随后生成独立 SHA-256。DMG、两个 checksum、evidence archive 与 `appcast.xml` 由同一 promotion journal 原子晋升。

整个正式流程由当前 shell 的文件描述符持有 macOS `lockf` 单一发布锁，不信任可伪造的环境标记；每次正式 build 使用独立 scratch，两个发布也不能并发晋升 feed，进程崩溃后内核会自动释放锁。晋升前会把制品名、DMG/checksum/新旧 appcast 的 SHA-256 和 `prepared` 状态持久写入 promotion journal；DMG、校验和与 appcast 全部落位并同步后才持久切换为 `committed`。普通失败或可处理信号会立即按 journal 恢复；若遭遇 `SIGKILL` 或断电，下一次拿到锁时会先清理带 owner-only Speaker marker 的遗留 pending（包括尝试卸载其固定 mountpoint），再恢复 `prepared` 状态，或校验并完成 `committed` 状态的清理。恢复对象 hash 不符、旧 feed 损坏、未知 pending 或 journal 被篡改时 fail closed 并保留证据，不会删除外来同名制品或猜测成功。任一步失败都会清理可证明属于本事务的 pending 制品；不会退回 ad-hoc 签名，也不会把未验证的 DMG 或 appcast 留在正式制品目录。同一个版本号和构建号的 DMG 或 checksum 一旦存在，脚本会直接拒绝覆盖；任何重发都必须增加 build number。

GitHub prerelease 是候选事务边界：DMG、checksum 与 `appcast.xml` 同时上传并从公开
immutable tag URL 复验；它不进入 `releases/latest`。`Speaker-<version>-<build>-evidence.zip`
只在签名 runner 上短暂存在，随后变成认证加密的 `.zip.enc` 和 checksum；只有密文进入
Actions artifact，不附加到 GitHub Release。旧版实测绑定该 prerelease 后，publication
job 只允许提升同一 tag、同一 public assets 和同一 candidate-run artifact。发布后执行：

```bash
SPEAKER_VERSION=1.0.0 \
SPEAKER_BUILD_NUMBER=<同一 build> \
./scripts/verify-published-update
```

该门禁从正式 HTTPS 地址回读 signed feed、DMG 和 checksum，只用受审查公钥复验 archive EdDSA，并核对 appcast 原始字节、长度、SHA-256、公证、Gatekeeper、Developer ID/Team、版本号与 Sparkle 嵌套结构。

先在 `main` 手动运行 production workflow；把 `upgrade_evidence_file` 与
`candidate_run_id` 都留空。该 run 完成签名、公证、密文 evidence 留存，并创建公开
`v<SemVer>` prerelease。记录 workflow run ID。下载候选，用两份真实 Developer ID App
生成完整旧版本升级报告：

```bash
./scripts/compatibility-smoke \
  --app /path/to/candidate/Speaker.app \
  --upgrade-from /path/to/previous/Speaker.app \
  --staging-feed https://github.com/simonwong/speaker/releases/download/v1.0.0/appcast.xml \
  --output docs/release-evidence
```

`sparkle-update` 用例会要求退出候选，并通过 `open -n <旧版> --args
--speaker-update-feed <staging-feed>` 启动旧版。参数只接受当前 GitHub 仓库与候选 SemVer
完全匹配的 immutable prerelease appcast；普通启动不读取该 override，继续使用 stable feed。

候选必须来自首次 workflow 固定的 commit。完成实机矩阵后，只提交生成的报告；从
候选 commit 到发布 commit 只能变更该报告。再次运行 production workflow，同时传入报告
路径 `upgrade_evidence_file` 和首次 `candidate_run_id`。门禁验证 run 成功且 source commit
等于报告候选，再验证生成器 schema、七天时间窗、macOS/架构、两版
Developer ID/Bundle ID/Team ID、候选 source commit、审计用 executable SHA-256 与稳定的
两个架构各自的 CodeDirectory CDHash，并要求
Sparkle 更新、Developer ID、TCC、Keychain 连续性四项 `PASS`。Promotion 重新下载首次
artifact，并要求 DMG、checksum、appcast、完整 executable SHA-256 与 universal2 的
arm64/x86_64 CodeDirectory CDHash 都等于实测候选；不会重新构建或重签。非首次发布时旧 build 必须等于上一公开 build；
首次发布的上一公开 build 为 `0`，但仍要求一个小于候选 build 的真实开发版作为升级
源。`production-publication` reviewer 只在复核报告、candidate run 与 prerelease 后批准。

## Stable promotion 前的人工门槛

公开 prerelease staging 后、stable promotion 前，需在干净 macOS 用户上完成并留存证据：

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

仓库已接入更新 feature、Sparkle live adapter、GitHub Releases 发布和公开回读门禁；但在真实正式身份以及“旧版 → 新版”实机更新矩阵完成前，不应把当前开发制品描述为已经具备可用的生产更新通道。
