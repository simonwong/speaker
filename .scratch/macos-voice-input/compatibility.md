# Speaker 本机兼容性矩阵

更新日期：2026-07-16

## 自动验证

| 场景 | 状态 | 证据 |
| --- | --- | --- |
| 无目标输入框 | 通过 | 最终文本进入待复制，不自动改剪贴板 |
| 安全输入框 | 通过 | AX 捕获拒绝 `AXSecureTextField` |
| 目标关闭或失效 | 通过 | 送达映射为待复制 |
| 等待期间目标内容变化 | 通过 | 原始值证据不一致时 fail closed |
| 重复按下/松开 | 通过 | 同一会话只提交一次 |
| 快速按下/松开顺序 | 通过 | 全局事件经单一有序 dispatcher 进入会话 actor |
| 转录期间取消/迟到结果 | 通过 | provider task 被取消，迟到结果不送达 |
| 送达 commit 后取消 | 通过 | mutation commit 前 Esc 取消整个操作；commit 后立即隐藏 HUD，后台只完成真实回执与历史结算，迟到终态不会重新显示 |
| 退出期间活动请求 | 通过 | dispatcher 停止接收并先取消会话，再等待消费者结束 |
| 录音停止迟到错误 | 通过 | 取消终态不会被迟到的 recorder 错误覆盖 |
| Unicode、emoji、多行文本保存 | 通过 | Swift `String`、JSON UTF-8 与 AX selected-text 路径不做降级转换 |
| 选择替换 | 通过（实现级） | mutation 前复核当前选区并只设置 `AXSelectedText`；commit 后不恢复旧选区覆盖用户新的光标位置 |
| 同一 App 内切换输入框 | 通过 | 松开快捷键时冻结精确 AX element；后续焦点移到同 PID 的另一输入框也会使原目标失效 |
| 安全目标历史隐私 | 通过 | 目标分类前不持久化转录正文；安全目标的处理中、取消和终态记录均无正文/request ID，SQLite/WAL sentinel 扫描通过 |
| 本地敏感文件路径 | 通过 | 设置、词库、旧历史和开发凭据不跟随目录/文件 symlink，只读当前用户普通文件并限制大小；写入为 descriptor-relative 原子替换 |
| 多来源凭据迁移 | 通过 | 旧 Keychain/明文必须全部可读且值一致才自动迁移；冲突或部分不可读时保留全部来源并发布脱敏诊断 |
| AX 写入回执滞后 | 通过 | 最多等待 1 秒取得期望值回执；瞬时旧值不会误判失败 |
| AX mutation 无法确认 | 通过 | 显示“请先检查输入框”，避免用户手动粘贴造成重复文字 |
| AX range IPC 瞬时失败 | 通过 | `.cannotComplete` 重试；range setter 不支持但当前选区未变时仍可继续 |
| AX 目标应用未响应 | 通过 | mutation 前 `.cannotComplete` 按 security/role/value/selection/focus 阶段记录为 `targetApplicationUnresponsive`，不伪报焦点变化或业务超时 |
| 不自动覆盖剪贴板 | 通过 | 只有用户点击“复制”才写剪贴板；`setString` 后必须精确读回，失败或被并发覆盖会保留结果重试 |
| Fn event tap timeout | 通过（实现级） | tap 被系统禁用后取消悬挂按压、重置状态、重新启用并上报 recovered 事件 |
| Secure Event Input 在录音中开启 | 通过（实现级） | Fn/自定义快捷键轮询安全输入并取消活动会话 |
| App 退出清理 | 通过（实现级） | App 停止快捷键 intake、取消活动 provider/内存音频流，并等待历史与设置写入收敛；不产生临时音频文件 |
| 中文词库边界 | 通过 | 连续中文可替换，普通词内部子串不替换 |
| 详细历史快照 | 通过 | 保存整理提示词、完整词库/context、provider 诊断及阶段耗时，不保存音频/Key |
| 崩溃历史恢复 | 通过 | 上次进程遗留的准备/录音/处理记录收敛为明确中断终态 |
| 保留策略提交边界 | 通过 | SQLite 已提交删除后即使 checkpoint busy 也不伪装回滚策略 |
| 数量上限物理清理 | 通过 | save 自动淘汰旧记录后截断 WAL；busy 时保留诊断并由后续 save/启动重试，旧正文 sentinel 不残留 |
| 豆包取消尾帧 | 通过 | Task 取消后不会再发送 `isFinal=true` 音频帧 |
| 豆包错误优先级 | 通过 | 已收到的服务端鉴权/资源错误不会被 socket close 引发的发送错误覆盖 |
| DeepSeek HTTP 取消 | 通过 | 生产 URLSession transport 取消会触发 `URLProtocol.stopLoading()` |
| 保守第二送达路径 | 通过（实现级） | 已验证 App 可使用 PID Unicode；未知 App 仅在仍为前台、focused element/value/selection 与快照完全一致时尝试，并以 AXValue 回执确认 |
| 送达降级诊断 | 通过 | 新会话区分 direct AX write/receipt、前台资格、并发编辑与 Unicode post，结构化代码写入历史且不包含输入内容 |

## 需要解锁 Mac、授予权限后人工 smoke

当前自动化环境处于锁屏，以下项目没有伪称通过。所有未确认目标仍统一降级为待复制，不使用模拟粘贴、强制焦点或整段 `AXValue` 回写。

使用 `./scripts/compatibility-smoke` 执行完整矩阵；它会在
`.build/compatibility-smoke/` 生成不包含转录文字、Key 或请求正文的报告。
报告会固定 App 版本、签名模式和可执行文件 SHA-256，且不记录绝对 App 路径。
FAIL 返回 1，SKIP 返回 2，单项 `--case` 即使通过也返回 3；只有完整矩阵全 PASS
返回 0，避免 partial run 被误当作发布证据。

| 目标/场景 | 待执行步骤 | 期望 |
| --- | --- | --- |
| 内建键盘 Fn / 外接键盘 Fn | 按住讲话、松开 | 单次录音与提交；系统 Fn/Globe 行为不被吞掉 |
| 自定义组合键 | 在设置中录制未占用组合键；再录制冲突组合键 | 前者生效；冲突项回退 Fn 并提示 |
| TextEdit 纯文本 | 光标插入、选择替换、撤销 | 自动送达且系统撤销可用 |
| Safari 可编辑控件 | 普通输入框与安全字段 | 普通控件自动送达；安全字段待复制 |
| Chrome / Electron | 普通输入框、富文本 | 可验证目标自动送达，否则稳定待复制 |
| 富文本编辑器 | emoji、多行、选择替换 | 不破坏周边格式；不确定时待复制 |
| Terminal | 光标位置输入 | 可写时送达；否则待复制，不模拟按键粘贴 |
| 焦点切换 | 录音中任意切换，松开时聚焦目标 | 只使用松开后的第一次目标快照 |
| 目标关闭/并发编辑 | 模型等待时关闭或修改目标 | 待复制，不覆盖变化 |
| 登录时启动 | 开启/关闭并重新登录 | 系统状态与设置页一致；默认关闭 |
| 权限撤销与恢复 | 运行中撤销辅助功能/麦克风再恢复 | 失败可解释，重新授权后无需重装 |

## 需要用户 BYOK 的 provider smoke

- 豆包：1、5、15、60 秒中文音频；数字 ITN、标点、语义顺滑、静音、错误 Key、未开通资源、限流。
- DeepSeek：精简清理、完整重写、自定义模式；错误 Key、余额不足、等待中取消、截断、空 JSON 与异常扩写回退。
- `./scripts/provider-smoke [doubao|deepseek|all]` 只执行无 UI 连接探针，不能作为真实模型矩阵证据。开发预检可显式运行 `./scripts/provider-smoke matrix --confirm-paid-requests --evidence-directory <全新目录> --candidate-version <版本> --candidate-build <构建号> --doubao-sample <至少 60 秒的 16kHz 单声道 PCM WAV>`；它执行实时 paced 的豆包 1/5/15/60 秒非空转录、等待中取消、错误 Key，以及 DeepSeek 精简/重写/自定义语义断言、等待中取消与错误 Key。任何 SKIP 都返回 2。
- Matrix 只输出固定 case、PASS/FAIL、固定错误分类和严格 allowlist 后的 request ID/status，不输出 Key、音频、转录文本、DeepSeek 输出或服务商自由文本。它在付费请求前固定 source commit/clean 状态、`Package.resolved` SHA-256、候选 version/build、macOS/架构、凭据来源、资源与模型，逐级 no-follow 校验父目录后向全新 `0700` 目录原子写入 `0600` 的严格 13-case JSON 报告。`verify-provider-evidence` 对未知字段、缺失/重复、FAIL/SKIP、dirty source 与非正式 Keychain 凭据 fail closed；`--allow-development-credentials` 只用于开发结构预检。Verifier 只验证结构、绑定字段与完成性，release run 还必须校验 `generatedAt` 属于本次执行，旧报告不可复用。豆包样本使用 no-follow 文件描述符一次性读取到内存，拒绝 symlink、非普通文件、不足 60 秒、非 16kHz/单声道/16-bit PCM WAV 和超过 64 MiB 的文件；工具不会写出或复制音频，并禁用 core dump，调用方负责测试后删除原样本。该 CLI 仍使用开发版本地凭据，不能单独作为 Developer ID 候选的发布证据。
- 这些调用不使用项目内置密钥；真实测试结果应记录请求 ID，不记录 Key 或音频。

## 当前构建证据

- `./scripts/test`：`PASS: 162 core specs`、`PASS: 67 app scenario specs` 与 `PASS: 5 AppKit UI specs`。
- `./scripts/provider-smoke doubao`（2026-07-17）：豆包
  `volc.seedasr.sauc.duration` PASS，服务端请求 ID
  `20260717125537286AF74BAC3BF6B4ED6B`；DeepSeek 仍未配置。探针未输出 Key、音频、文本或 provider 自由文本。
- 2026-07-17 旧版开发 matrix（结构化报告门禁落地前）：使用非敏感系统 TTS，豆包 1/5/15/60 秒实时 paced 非空转录、流式取消、错误 Key全部 PASS，临时音频已删除；DeepSeek 连接、三模式与取消因未配置而 SKIP，错误 Key PASS。该历史运行按契约为 INCOMPLETE，未记录为 FULL PASS，也不冒充当前 schema 的报告。
- `./scripts/build`：Debug `SpeakerApp` 构建通过。
- `./scripts/release`：Release App bundle 组装、ad-hoc 签名、安装到唯一的 `/Applications/Speaker.app` 路径与本机进程启动通过；`codesign --verify --deep --strict` 与 `plutil -lint` 通过。ad-hoc 身份按构建版本隔离，更新代码后按需重新授权。
- ad-hoc 构建每次重签后都必须重新确认麦克风与辅助功能状态；当前文档不把历史 TCC 条目当作最新构建的通过证据。
