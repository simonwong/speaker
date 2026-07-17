# Speaker 隐私说明

更新日期：2026-07-16

Speaker 是一个由用户自行配置服务凭据的 macOS 语音输入工具。它不包含广告、行为分析或自动上传的崩溃报告。

## 音频

- 只有在用户主动开始录音后，Speaker 才访问麦克风。
- 音频在内存中转换为 16 kHz 单声道 PCM，并通过用户配置的豆包语音账号发送给火山引擎完成转录。
- Speaker 不把原始音频写入磁盘、会话历史或剪贴板；取消录音会终止本次发送并释放内存缓冲。
- 少于 300 ms 的录音和近乎数字静音会在结束录音时由本机终止，不会进入文字送达。由于识别是实时流式的，判定前的音频分片可能已经发送给火山引擎，Speaker 会取消仍在进行的请求。
- 音频到达火山引擎后的处理适用用户与该服务商之间的账号、套餐和数据处理条款。

## 转录与文本整理

- Speaker 会把已启用的个人词库词条作为热词随音频请求发送给豆包，以提高专有名词识别率。
- 默认“语义顺滑”使用豆包返回的文字和本地词库别名替换，不调用 DeepSeek。
- 只有用户明确选择“精简清理”“完整重写”或自定义模式时，Speaker 才把经过本地词库替换后的豆包文字和所选整理规则发送到用户配置的 DeepSeek 账号。
- Speaker 不单独向 DeepSeek 发送个人词库、目标应用信息或会话历史。
- Speaker 不把音频发送给 DeepSeek。
- 豆包与 DeepSeek 请求使用临时网络会话，不持久化 Cookie、HTTP 缓存或系统 URL 凭据。

## 本地保存的数据

会话历史保存在当前 macOS 用户的 `~/Library/Application Support/Speaker/history.sqlite3`，可能包含：

- 豆包转录、可选的 DeepSeek 结果和最终文字；
- 目标应用名称、处理阶段、耗时和服务请求 ID；
- 当次整理规则及个人词库快照；
- 结构化且限制范围的错误代码，不保存服务商返回的自由文本错误消息。

历史不包含原始音频、API Key、辅助功能对象、目标输入框原内容或剪贴板历史。安全输入框中的结果不会写入会话历史。

新安装默认不按日期自动清理，直到用户明确选择保留最近 30 天、90 天或一年。任何设置都最多保留 10000 条，防止常驻 App 无限占用本地空间。用户可以删除单条记录或清空全部历史。

设置和个人词库同样只保存在当前用户的 Application Support 目录。目录权限为 `0700`，敏感本地文件及 SQLite sidecar 权限为 `0600`。Speaker 会在解码前重新验证并收紧这些权限；若系统拒绝修改权限，则停止加载对应文件并显示诊断。

旧版本曾创建用于豆包请求的本机安装标识；当前版本改为每次请求生成临时标识，并在启动时删除旧值。

## API Key

- 本机 ad-hoc 开发构建没有稳定签名身份，因此把 Key 保存在仅当前用户可读写的 `credentials.json`；这种构建不用于对外分发。
- 稳定 Developer ID 发布构建使用 macOS Keychain，访问级别为 `AfterFirstUnlockThisDeviceOnly`。
- 从开发构建升级到正式构建时，Speaker 只有在 Keychain 写入后读回一致，才删除旧凭据。清理失败会保留诊断并重试，不会把失败伪装成迁移成功。

## 系统权限与文字送达

- 麦克风权限仅用于录音。
- 辅助功能权限用于监听用户设置的全局快捷键、识别当前输入位置，并在可以验证完整结果时送达文字。
- Speaker 不会自动覆盖剪贴板。只有用户点击“复制”时才写入剪贴板，并在系统确认写入成功后关闭待复制结果。
- 无法证明安全送达、输入位置发生变化或目标是安全输入框时，Speaker 会保留结果等待用户复制，不模拟粘贴或强制修改目标应用。

## 诊断信息

“复制脱敏诊断信息”只包含 App/系统版本、权限状态、快捷键、处理状态、provider 是否已配置、资源类型和历史存储状态。它不包含转录文字、音频、API Key 或完整本地文件内容。用户决定是否把诊断信息提供给支持方。

## 删除与卸载

用户可以在 App 内删除 API Key、词库条目和会话历史。彻底移除本地数据时，退出 Speaker 后删除：

```text
~/Library/Application Support/Speaker
~/Library/Application Support/com.local.speaker
~/Library/Caches/Speaker
~/Library/Caches/<Speaker 的正式 Bundle ID>
~/Library/Caches/com.local.speaker
~/Library/Saved Application State/<Speaker 的正式 Bundle ID>.savedState
~/Library/Saved Application State/com.local.speaker.savedState
~/Library/Preferences/<Speaker 的正式 Bundle ID>.plist
~/Library/Preferences/com.local.speaker.plist
```

App 内的“清除本地数据并退出”会按上述范围清理并逐项验证，同时注销登录项及删除当前/旧版 Keychain 凭据；任何步骤失败都不会报告成功。手动卸载时，还应在“系统设置 → 通用 → 登录项”中移除 Speaker，并按需在“隐私与安全性”中移除麦克风和辅助功能授权。仅删除 App 本身不会自动删除用户明确保留的历史、偏好或 Keychain 凭据。

## 变更与反馈

若数据流、第三方服务或默认保留策略发生实质变化，本说明应随 App 版本一并更新。问题反馈请使用获得 Speaker 的分发渠道，并且不要发送 API Key。
