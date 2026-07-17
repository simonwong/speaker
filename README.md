# Speaker

Speaker 是一个 macOS 14+ 菜单栏语音输入工具。默认使用 `Fn`：可以按住讲话、松开结束，也可以短按开始、再次短按结束。录音过程中通过豆包 `bigmodel_async` WebSocket 流式识别；结束时把最终结果安全送到当时聚焦的输入框。无法确认输入目标时，结果会留在浮层中等待你手动复制。

面向用户的数据说明见 [PRIVACY.md](PRIVACY.md)。
当前深模块设计与渐进迁移方向见 [architecture.md](docs/architecture.md)。

## 本地运行

运行 Speaker 需要 macOS 14 或更新版本；从源码构建需要 Swift 6 和 macOS 26 SDK。
项目脚本优先使用 Command Line Tools 的 `MacOSX26.sdk`，也可通过
`SPEAKER_SDKROOT` 显式选择其他 26 或更新版本的 SDK。

```bash
./scripts/release
```

脚本会完成 Release 构建、组装、本地 ad-hoc 签名、安装并启动：

```text
/Applications/Speaker.app
```

不需要再手动拖动 App；安装成功后，构建目录中的临时副本会被删除，避免 macOS 把两个 Speaker 识别成不同的权限主体。

首次启动会显示 Speaker 自己的引导窗口，不会在没有说明时连续弹系统授权：

1. 按引导逐项点击“麦克风”和“辅助功能”；只有点击后才会请求系统权限。
2. 在辅助功能系统列表中开启 `/Applications/Speaker.app`。
3. 在“豆包语音”中填入[新版豆包语音控制台](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default)生成的 API Key，选择与控制台已开通资源一致的流式资源，并通过“检查连接”。默认是模型 2.0 小时版 `volc.seedasr.sauc.duration`。
4. 长按 `Fn` 讲话并松开结束；或者短按一次开始录音，再短按一次结束。按 `Esc` 可随时取消。

可选流式资源为模型 2.0/1.0 的小时版或并发版。Resource ID 不是密钥；若选择的资源没有在控制台开通，“检查连接”会返回鉴权或资源错误。实现使用官方推荐的 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`，详见[流式语音识别文档](https://docs.volcengine.com/docs/6561/1354869?lang=zh)。

在系统设置中修改权限后，切换到任意 App 都会触发 Speaker 刷新权限并重新同步快捷键，不要求先点回 Speaker。设置页也可以切换为包含修饰键的自定义快捷键。

`./scripts/release` 面向本机开发，使用 ad-hoc 签名。它没有稳定 Team ID，修改代码并重新构建后 macOS 可能要求重新授权；这不是面向用户发布的签名方式。若本机开发遇到旧条目，可执行：

```bash
tccutil reset Accessibility com.local.speaker
tccutil reset Microphone com.local.speaker
./scripts/release
```

然后在系统设置中重新开启 `Speaker.app`，不会影响其他 App 的权限。正式发布必须使用稳定的 Developer ID、Hardened Runtime 和 Apple 公证；发布清单见 [production-readiness.md](docs/production-readiness.md)，版本号、构建号、签名、公证和人工验收步骤见 [releasing.md](docs/releasing.md)。

若钥匙串中存在唯一的 `Speaker Local Development` 或 `Apple Development: ...`
代码签名 identity，`./scripts/release` 会自动使用它，让本机多次构建保持同一个
权限身份。一次性的安全配置步骤见 [releasing.md](docs/releasing.md#本机开发安装)。

## 文本整理

- 默认顺滑：只使用豆包返回的语义顺滑结果，不调用 DeepSeek。
- 精简清理、完整重写、自定义模式：需要在设置中额外保存你自己的 DeepSeek API Key；无 Key 时这些模式不会进入运行态，音频也永远不会发送给 DeepSeek。
- 个人词库：标准词及别名保存在本机，新会话会使用按下快捷键时取得的词库快照。

## 隐私和本地数据

- API Key 只保存在当前 Mac 用户的 Speaker 本地配置中，文件权限为仅当前用户可读写。
- 会话历史包含豆包结果、可选 DeepSeek 结果、最终文本、阶段、目标应用和结构化诊断信息。自动送达降级会区分 AX 直接写入、回执确认、前台目标资格、Unicode 事件投递等内容无关边界。
- 原始音频不会写入磁盘或历史；录音时只在内存中转换为 16 kHz 单声道 PCM，并以约 200 ms 的分片发送给豆包。
- 少于 300 ms 的录音与近乎数字静音会在本机结束，不会进入文字送达；由于使用实时流式识别，结束前的音频分片可能已经发送给豆包，Speaker 会取消仍在进行的请求。
- App 不会自动覆盖剪贴板；只有点击“复制”时才写入。
- 安全输入框的文本不写入历史。

本地数据位置：

```text
~/Library/Application Support/Speaker/history.sqlite3
~/Library/Application Support/Speaker/settings.json
~/Library/Application Support/Speaker/credentials.json   # 仅 ad-hoc 本机开发版
~/Library/Application Support/Speaker/personal-dictionary.json
```

稳定 Developer ID 构建会使用 macOS Keychain；启动时会主动迁移所有已配置 provider。旧 Keychain service 与开发版文件必须全部可读且非空值完全一致，才会写入新 service，读回一致后再删除旧来源；任一来源不可访问或值冲突都会保留全部原数据并显示不含 Key 的诊断。清理失败不会遮蔽已经验证可用的新凭据；发布脚本也不会允许正式签名版本继续使用本地明文凭据。

本地历史、设置、个人词库和开发版凭据通过不跟随符号链接的文件描述符读取：只接受当前用户拥有的普通文件，读取有明确大小上限，并在解码前收紧为仅当前用户可读。写入使用同目录 owner-only 临时文件和原子替换；数据目录、文件类型、所有者或权限不符合边界时，Speaker 会停止加载/保存并显示诊断。

旧版词库位于 `~/Library/Application Support/com.local.speaker/personal-dictionary.json`；新版本只在校验迁移后的词库与原内容一致后删除旧文件。

旧版 `history.json` 会在首次启动时按当前保留策略合并导入 SQLite，校验最终 payload 后删除。历史页可选择保留最近 30 天、90 天、一年或不按日期清理；所有策略都有 10000 条安全上限。清空历史只有在 WAL 已实际截断并完成数据库整理后才报告成功；占用中的读事务会得到明确失败状态，可释放后重试。

如果 Speaker 上次运行时被系统或崩溃中断，启动时会把遗留的“准备中、录音中、处理中”记录收敛为“上次语音输入被中断”，并保留已经确认的豆包文字和结构化请求标识，不会永久显示仍在处理。保留策略以设置文件中的用户选择为准；若数据库清理暂时受占用，界面会明确显示待重试，后续写入或下次启动继续执行。

“关于”中的“复制脱敏诊断”会在豆包请求仍进行时记录实际跨过的连接、请求、音频发送和等待最终结果阶段，并附带客户端/服务端请求标识及 HTTP 状态。远端关闭、DNS、断网和 TLS 故障会记录稳定的结构化子类；连接仍开放但没有最终帧时只报告 `awaitingFinal`。它不会根据经过时间猜测故障，也不包含音频、转录文字、提示词、词库内容、目标 App 名称或 API Key。

## 开发验证

```bash
./scripts/test
./scripts/build
./scripts/launch
```

`./scripts/test` 运行纯 Swift 核心规格与无窗口 App 场景规格；`./scripts/launch` 构建并启动 Debug App bundle。真实豆包和 DeepSeek 请求只会使用你在 App 中保存的 Key。

本机开发版可以运行 `./scripts/provider-smoke doubao` 或
`./scripts/provider-smoke deepseek` 验证当前 BYOK 连接。命令只输出结构化结果、
资源和请求 ID，不打印 Key、音频、转录内容或服务商自由文本。

连接探针不等于模型验收。发布前使用
`./scripts/provider-smoke matrix --confirm-paid-requests --evidence-directory <全新目录> --candidate-version <版本> --candidate-build <构建号> --doubao-sample <至少 60 秒的 16kHz 单声道 16-bit PCM WAV>`
执行实时 paced 的豆包 1/5/15/60 秒、取消和错误 Key，以及 DeepSeek 三种规则、取消和错误 Key的开发预检。
工具只把样本读入内存，不复制或写出音频；任一 provider 未配置、缺少样本或 case
被跳过都会使矩阵返回 SKIP。该命令会产生付费 BYOK 请求，必须显式确认；它使用开发版本地凭据，不能替代正式签名 App 的 Keychain 矩阵证据。

Matrix 在发出请求前固定源码 commit、源码树 clean/dirty、`Package.resolved` SHA-256、候选 version/build、macOS/架构、凭据来源、资源和模型；逐级 no-follow 校验目录后，只向一个全新 `0700` 目录原子写入 `0600` 的 `speaker-provider-matrix.json`。报告使用固定 13-case Codable schema，不包含 Key、音频、提示词、转录/整理正文或服务商自由消息；不安全的 request ID/status 会直接丢弃。`./scripts/verify-provider-evidence <报告>` 对未知字段、缺失/重复 case、FAIL/SKIP、dirty source 或非正式 Keychain 凭据 fail closed；开发预检只能显式加 `--allow-development-credentials` 做结构验收，不能冒充正式候选证据。Production workflow 会在同一 run 的临时 Keychain 中生成全新报告，随后按 commit、依赖锁 hash、version、build 和不超过四小时的起止时间窗二次验证，并把报告及其 hash 收入 release evidence ZIP；旧报告无法放行。

当前本机验证环境不允许 SwiftPM 再启动一层 `sandbox-exec`，因此项目脚本显式使用 `--disable-sandbox`。Package 只在 App target 中固定依赖 Sparkle 2.9.4，不使用 build plugin；`SpeakerCore` 和 `SpeakerAppFeatures` 不依赖 Sparkle。CI 固定使用 GitHub `macos-26` runner，并把该 runner 的活动 macOS SDK 通过 `SPEAKER_SDKROOT` 传给所有构建步骤。Swift/Clang module cache 默认位于当前用户的 `TMPDIR` 下、带 UID 且权限为 `0700`，不会复用公共可写缓存目录。

`./scripts/distribute` 是 fail-closed 的正式发布入口。正式 Bundle ID、Team ID、产品地址、更新目录和 Sparkle 公钥必须先写入并审查 `Resources/ReleaseIdentity.plist`，CI 无权用环境变量替换；当前占位配置会直接拒绝分发。发布任务注入版本、构建号、Developer ID identity、`notarytool` profile、Sparkle 私钥的 Keychain account、仓库内已提交的 release notes，以及本次 run 新生成并完成候选绑定的正式 Keychain provider matrix。脚本从固定 `HEAD` 的只读 source snapshot 开始，在本次发布专属的 SwiftPM scratch 中按 `Package.resolved` 构建，不覆盖开发 `.build/Speaker.app`；随后逐层验证 App/Sparkle 签名，生成并公证 APFS+lzfse DMG，再由 Sparkle 生成 archive EdDSA 与 signed appcast。DMG、SHA-256、包含 provider matrix、dSYM/BuildManifest/公证日志/toolchain 的 evidence archive 和 `appcast.xml` 由同一个 hash-bound journal 晋升；普通失败即时回滚，`SIGKILL`/断电由下一次运行先清理可证明属于 Speaker 的遗留 pending，再恢复或完成晋升。Evidence 默认只作为受保护 CI artifact 留存，不公开公证环境元数据。上传后必须运行 `./scripts/verify-published-update` 从正式 HTTPS 地址回读复验；缺少或不匹配任一发布凭据都会清理 pending 制品并退出，不会退回 ad-hoc。

## 当前人工校准项

不同 App 的 Accessibility 文本控件实现并不一致。TextEdit、浏览器普通输入框、Electron、富文本和 Terminal 应在你的 Mac 解锁并授予权限后分别 smoke；无法证明安全送达的目标会稳定降级为待复制，不会模拟粘贴、强制焦点或整段覆盖控件值。详见 [本机兼容性矩阵](.scratch/macos-voice-input/compatibility.md)。
