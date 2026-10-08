# Admin 获取与使用 Developer ID Application

调研日期：2026-10-06。实测日期：2026-10-07 至 2026-10-08。范围：Apple 官方文档、Speaker 当前发布脚本，以及已授权 Admin 的 Xcode 云端 Developer ID 签名和公证流程。

## 结论

Admin 可以使用 Developer ID 签名，但须区分云端签名权限与本地签名身份。Apple 把传统 Developer ID 证书的创建权限限定给 Account Holder，同时允许获特别授权的 Admin 使用云端托管 Developer ID。不能把“Admin 不能自行创建本地证书”理解为“Admin 不能发布站外 App”。[Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)

Speaker 现有流程直接调用本机 `codesign`，建议在实际签名的 Mac 生成 CSR，由 Account Holder 在自己的账号上传申请，然后把 `.cer` 返回原 Mac。这不需要 Account Holder 登录该 Mac，也不需要传递私钥。这是依据 Apple 的 CSR 机制和角色权限组合出的实施方案，尚未在本团队执行。[证书申请](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)、[CSR 与签名身份机制](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)

## 路径一：授权 Admin 使用云端 Developer ID

官方 `UserRole` 文档明确规定：

- Account Holder 默认拥有 `CLOUD_MANAGED_DEVELOPER_ID`。
- Account Holder 可以授予 Admin；已获授权的 Admin 可以再授予其他 Admin。
- 使用者必须有 Certificates, Identifiers & Profiles 权限。
- 签名请求需要证书而团队尚无对应云端证书时，系统自动创建。

因此，不能笼统断言“只有 Account Holder 能修改这项权限”。[UserRole](https://developer.apple.com/documentation/appstoreconnectapi/userrole?changes=_2)

操作入口：App Store Connect → Users and Access → People → 选择该 Admin → 配置云端 Developer ID 访问权限 → Save。执行者使用 Account Holder 或已有该项授权的 Admin。Apple 官方帮助确认用户编辑路径和保存方式；本次未登录团队页面核验复选框的现行名称或所在分组。[Add and edit users](https://developer.apple.com/help/app-store-connect/manage-your-team/add-and-edit-users/)、[Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates)

授权后使用 Xcode Organizer 的 Archive / Distribute 自动签名流程。云端托管证书不是下载到钥匙串的本地身份：Apple 明确说明云端私钥不能传输或存储到 Mac，手动分发签名不支持云端签名。因此不能把云端证书导出为带私钥的 `.p12`，再直接交给现有 `codesign --sign` 流程。[Xcode 13 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-13-release-notes)、[Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates)

## 路径二：本机 CSR，由 Account Holder 申请证书

1. 在最终签名的 Mac 打开 Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority，保存 CSR 到磁盘。密钥对生成于该 Mac 的 login keychain，CSR 包含公钥和申请信息，不包含私钥。[Create a certificate signing request](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request/)、[TN3161](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)
2. 将 `.certSigningRequest` 交给 Account Holder。对方在 Apple Developer → Certificates, Identifiers & Profiles → Certificates → `+` → Developer ID 中选择 Developer ID Application，上传 CSR，下载 `.cer`。[Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
3. 将 `.cer` 返回生成 CSR 的 Mac，双击导入。证书中的公钥与原私钥配对后形成完整签名身份；无需转移原私钥。[TN3161](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)

这里 Account Holder 负责团队证书的签发权限；本机持有对应私钥并执行签名。只下载某张已有 `.cer`，没有匹配私钥，不能签名。[Synchronizing code signing identities](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)

## 路径三：导入团队已有本地签名身份

如果团队已持有有效的本地 Developer ID Application 身份，可以由持有人在 Keychain Access 中选中证书及匹配私钥，使用 File → Export Items 导出有密码的 `.p12`。接收者将该文件导入本机 login keychain。该方式同时转移证书和私钥；文件和密码应分渠道交付。云端托管身份不适用此路径。[钥匙串项目导入与导出](https://support.apple.com/en-ca/guide/keychain-access/kyca35961/mac)、[Synchronizing code signing identities](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)、[Xcode 13 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-13-release-notes)

## Speaker 适用性与验证边界

仓库已核验：`scripts/bundle` 的生产分支执行 `codesign --options runtime --timestamp --sign`；`scripts/distribute` 读取 `SPEAKER_CODESIGN_IDENTITY` 和 `SPEAKER_NOTARY_PROFILE`。发布文档也要求 CI 提供本地 Developer ID `.p12`。因此路径二或三直接符合现有工具链；云端路径需要另行设计并验证 Archive / Export 集成，不能仅增加账号权限就宣称兼容。[bundle](../../scripts/bundle)、[distribute](../../scripts/distribute)、[发布流程](../releasing.md)

采用现有本地私钥发布流程时，应确认本机存在有效 Developer ID Application 签名身份，再独立配置公证认证并运行正式发布门禁。证书可用不等于公证已通过，也不等于生产发布条件全部满足。[发布流程](../releasing.md)

上述团队授权路径以组织会员为前提；个人会员添加的 App Store Connect 用户不属于 Apple Developer Program 团队。[Overview of accounts and roles](https://developer.apple.com/help/app-store-connect/manage-your-team/overview-of-accounts-and-roles)

## 本团队实测

已确认发布 Bundle ID 为 `cn.simonwong.speaker`，签名 Team 为 `D7QJXSW5GJ`。两者写入 `Resources/ReleaseIdentity.plist`；`scripts/test-release-identity` 通过。

Xcode 27.0 可识别由 SwiftPM Release 产物组装、使用 Apple Development 签名的 macOS `.xcarchive`。使用以下 ExportOptions，通过当前登录 Admin 的云端权限成功导出 Developer ID 签名 App：

```xml
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>export</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>D7QJXSW5GJ</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
```

`xcodebuild -exportArchive -archivePath <archive> -exportOptionsPlist <options> -exportPath <output> -allowProvisioningUpdates` 返回 `EXPORT SUCCEEDED`。导出 App 的签名身份为 `Developer ID Application: Ningbo Weixu Space Design Co., Ltd. (D7QJXSW5GJ)`，具有可信时间戳和 Hardened Runtime；`codesign --verify --deep --strict` 通过，包含 Sparkle 嵌套代码。

将 `destination` 改为 `upload` 后，同一命令成功提交 Apple 公证。上传成功不等于公证通过；须等 Apple 处理完成，再运行 `xcodebuild -exportNotarizedApp -archivePath <archive> -exportPath <output>`，并验证票据与 Gatekeeper。

2026-10-07 01:00（Asia/Shanghai）上传成功。2026-10-08 实测 `xcodebuild -exportNotarizedApp` 返回 `EXPORT SUCCEEDED`，导出至 `.scratch/cloud-signing/notarized/Speaker.app`。该 App 为 `cn.simonwong.speaker`、版本 `0.7.0 (187)`；`codesign --verify --deep --strict` 通过，`xcrun stapler validate` 返回 `The validate action worked!`，`spctl --assess --type execute --verbose=4` 返回 `accepted`、`source=Notarized Developer ID`。公证票据及本机 Gatekeeper 验证已通过。Archive 的本地 `processingEvent` 字段仍保留旧值 `Processing`，不能仅凭该缓存字段判断当前公证结果。

在仓库根目录复核该产物：

```sh
codesign --verify --deep --strict .scratch/cloud-signing/notarized/Speaker.app
xcrun stapler validate .scratch/cloud-signing/notarized/Speaker.app
spctl --assess --type execute --verbose=4 .scratch/cloud-signing/notarized/Speaker.app
```

本次产物位于本地忽略目录 `.scratch/cloud-signing/`，仅用于验证云签名链路。它仍使用开发构建元数据；正式发布的 Sparkle 公钥、审核版本、CI 产物及验收证据尚未齐备。现有 `scripts/distribute` 仍采用本地私钥流程，尚未集成云端 Archive / Export。不能把此次导出作为正式生产发布门禁的替代。
