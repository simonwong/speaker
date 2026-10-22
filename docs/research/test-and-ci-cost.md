# 测试与 CI 成本调研

Last reviewed: 2026-10-15

这一步只做了调研，没有改 CI 配置、测试代码或脚本，也没有发出计费的 provider 请求。调研时下面的建议都还没有实施；之后实施的项在该项下标了状态。

## 来源标注

每条结论后面用方括号标出依据：

- **[API]**：GitHub REST API 数据，2026-10-15 读取。包括 runs、jobs、steps、attempts、branch protection、caches。
- **[日志]**：GitHub Actions job 日志，包括 Gate summary、`==>` 段落头和 cache 恢复行。
- **[文档]**：Apple 或 GitHub 的官方文档，链接列在文末。
- **[实测]**：本机测量。机器是 Apple M4（10 核），macOS 26.6.2，Swift 6.4，`.build` 从空开始。
- **[推断]**：由上面几类数据推出来的，没有直接测量过。

分位数用 nearest-rank。步骤和 job 的耗时统计只算成功的 job。

## 结论摘要

1. **能只跑相关测试。** 依赖图来自 `swift package describe`，脚本的输入来自读脚本本身，两者合成了一张"路径 → 步骤"映射表。路径不认识就全跑。
   - 回测最近 50 个合并的 PR：没有一次失败落在未被选中的步骤上，平均每个 PR 少跑约 207 秒（按 p50 模型估算）。[API][推断]
   - 15 处人为注入的故障里，选中的步骤抓到 13 处。漏掉的 2 处是现有测试本来就覆盖不到的地方，换成全量也一样抓不到。[实测]
2. **UI 规格不再在本地常规运行。** 按你的决定，静默方案不再研究，UI 规格只在大改 UI 设计时本地跑。
   - CI 每个 PR 都会跑 UI 规格（57 秒），而且不打扰你，所以本地跳过 UI 不会丢失覆盖。[API][日志]
   - 弹窗的直接原因是 `docs/agents/development.md` 的收尾规则。它要求"完整门禁通过"才算测完，而完整门禁就是 `--with-ui`。
3. **CI 收益最大的三处：**
   - verify 不再排在 specifications 后面串行跑：关键路径从约 10.4 分钟降到约 6.5 分钟。[推断]
   - 只改文档的 PR 跳过 macOS job：50 个 PR 里有 4 个属于这种情况。[API]
   - 修掉几条时序不稳的规格：42 次失败里有 22 次是 flaky。[日志]
4. **本地和 CI 的完整门禁是同一套命令，确实重复。** 本地全量的唯一价值是反馈更快：本机各步骤加起来约 1 分钟，CI 要 10 分钟。
   - 建议本地只跑映射表选中的步骤。
   - 完整门禁、UI、release 构建、打包和安装回滚交给 CI。

## 1. 基线

### 1.1 CI 运行时长

样本是最近 50 次已完成的 CI 运行：31 次 PR，19 次 push 到 main。时间范围是 2026-10-13 11:39Z 到 2026-10-14 08:25Z，只覆盖约 21 小时，数字代表的是最近这段的状态。[API]

| 指标 | PR p50 / p90 (n) | push main p50 / p90 (n) |
|---|---|---|
| 成功运行的墙钟时间 | 10.4m / 11.4m (26) | 9.8m / 13.0m (18) |
| 关键路径 changes → specifications → verify | 10.4m / 11.4m (25) | 9.8m / 13.0m (17) |
| specifications job 执行时间 | 6.2m / 7.6m | 6.0m / 6.9m |
| verify job 执行时间 | 3.7m / 4.2m | 3.5m / 4.4m |

- **排队时间很短。** `changes` 约 2 秒，macOS job 7–10 秒。[API]
- **执行时间占了大头。** specifications 占关键路径约 60%。[API]
- **concurrency group 的等待只体现在墙钟时间里：**
  - 连续合并到 main 时，后一次要等前一次 main 运行结束，等了 131–212 秒，因为 push 运行不会取消正在跑的那次。这就是 push main 的 p90 偏高的原因。
  - PR 的新推送要等被取代的那次取消完，等了 35–80 秒。[API]
- **运行结果构成：** PR 成功 26 次、失败 2 次、取消 3 次；main 成功 18 次、失败 1 次。[API]

### 1.2 job 内各步骤（PR，p50 / p90，秒）

[API]

| job | 步骤 | p50 | p90 |
|---|---|---|---|
| specifications | Set up / checkout / Record toolchain | 1 / 3 / 4 | 2 / 4 / 6 |
| specifications | Cache SwiftPM build products（恢复） | 8 | 11 |
| specifications | Check Swift formatting | 3 | 3 |
| specifications | Run deterministic specifications（`./scripts/test --with-ui`） | 276 | 334 |
| specifications | Verify resolved dependencies are pristine | 0 | 1 |
| specifications | Treat compiler warnings as errors（debug SpeakerApp） | 16 | 23 |
| specifications | Treat release compiler warnings as errors | 50 | 65 |
| specifications | Check scripts and patch hygiene | 0 | 1 |
| specifications | Post Cache（保存） | 8 | 11 |
| verify | Require the fast lane to pass | 0 | 0 |
| verify | checkout / Record toolchain | 3 / 4 | 4 / 5 |
| verify | Build and validate isolated release bundle | 120 | 143 |
| verify | Verify release identity and integrity | 0 | 1 |
| verify | Verify release evidence dSYM binding | 7 | 9 |
| verify | Verify install rollback | 61 | 74 |
| verify | Verify reviewed release identity guard | 15 | 19 |

### 1.3 门禁子步骤（PR，n=27，秒）

数据从日志里的 `==>` 段落头和 Gate summary 解析出来。[日志]

| 子步骤 | p50 | p90 | 占门禁 |
|---|---|---|---|
| SpeakerCoreSpecs | 60.4 | 69.1 | 22% |
| SpeakerAppUISpecs | 57.0 | 69.9 | 21% |
| SpeakerAppScenarioSpecs | 36.1 | 45.2 | 13% |
| test-package-dmg | 27.6 | 32.6 | 10% |
| test-compatibility-smoke | 13.5 | 20.6 | |
| test-brand-assets | 11.4 | 20.8 | |
| warnings-as-errors build: SpeakerProviderSmoke | 10.9 | 15.8 | |
| test-release-identity | 10.6 | 13.5 | |
| test-install-identity | 8.7 | 15.1 | |
| test-provider-smoke-contract | 6.4 | 10.6 | |
| test-release-evidence | 4.9 | 6.9 | |
| SpeakerAccuracyMetricsSpecs | 4.3 | 7.3 | |
| SpeakerProviderEvidenceSpecs | 3.4 | 4.9 | |
| warnings-as-errors build: SpeakerAccuracyEvaluator | 3.3 | 5.5 | |
| SpeakerUpdateSignatureVerifier --self-test | 2.8 | 3.8 | |
| 其余 4 个 warnings 构建和 1 个 self-test | 各 1.7–1.9 | | |

- **并发子步骤测不出时长。** test-workflow-security、test-development-build-identity、test-scripts-test-summary 和 test-skills-lock 与顺序段并发运行，CI 日志里拿不到各自的耗时。本机分别是 0.1、0.3、0.3 和 0.1 秒。[日志][实测]
- **第一个 spec 的时间里含公共编译。** 按顺序第一个跑的 spec 要先编出共享模块，所以 SpeakerCoreSpecs 的 60 秒里有一部分是 SpeakerCore 的编译。[推断]

### 1.4 本机编译和运行时间

[实测]

| 产物 | 冷编译（按顺序累计） | 无改动重编 | 改动后重编 | 只运行 |
|---|---|---|---|---|
| SpeakerCoreSpecs | 15.7s | 0.4s | 改 Core 一个文件 1.2s；只改它自己的测试 0.9s | 17.8s |
| SpeakerAppScenarioSpecs | 8.3s | 0.4s | 改 Features 一个文件 1.3s | 4.4s |
| SpeakerAppUISpecs | 2.7s | 0.4s | | 约 26s（会弹窗，之后不再本地跑） |
| SpeakerProviderEvidenceSpecs | 1.2s | 0.4s | | 0.5s |
| SpeakerAccuracyMetricsSpecs | 1.3s | 0.4s | | 1.4s |
| 各 Tools 产物 | 0.7–1.5s | 0.4s | | self-test 各 0.5s |
| SpeakerApp | 2.1s | 0.4s | | |

脚本的本机耗时（秒）：

| 脚本 | 耗时 |
|---|---|
| test-package-dmg | 8.4 |
| test-brand-assets | 7.1 |
| test-release-identity | 6.1 |
| test-install-identity | 5.9 |
| test-compatibility-smoke | 3.6 |
| test-provider-smoke-contract | 3.4 |
| test-release-evidence | 0.8 |
| 其余 4 个 | 各 ≤0.3 |
| `swift format lint` | 0.9 |

把这些步骤加起来，本机无 UI 门禁约 65 秒（增量编译）。这是逐项相加的估计，没有整体计时。同一批步骤在 CI 上约 220 秒，CI runner 比本机慢 3–4 倍。[实测][推断]

## 2. 失败历史

从 2026-07-17 第一次 CI 到 2026-10-14，281 次运行共 294 次 attempt，结论为 failure 的只有 42 次，所以全部列入，不足题目要的 50 次。另有 10 次 cancelled 和 3 次 startup_failure，没有逐一分析。[API]

| 分类 | 次数 | 判定规则 |
|---|---|---|
| flaky | 22 | 同一 SHA 重跑通过；或下一次运行通过，且中间的 diff 不涉及相关代码 |
| 真实缺陷 | 18 | 之后有提交改了相关代码或测试，然后通过 |
| 基础设施 | 2 | "The job was not acquired by Runner of type hosted"，macOS 容量不足 |

真实缺陷里，细分如下：

- 6 次是编译错误：
  - PR #140 连续 4 次 Swift 6 actor 隔离错误，由 15a0f1d 修复。
  - PR #181 两次 AVAudioPCMBuffer Sendable 错误，由 c7f113f 修复。
- 8 次靠改测试或测试工具修复：时序竞争、像素容差、超时预算和图标编码。
- 只有少数是产品代码本身的问题。[日志]

失败最多的用例：

| 用例 | 次数 | 所在 |
|---|---|---|
| hold and release delivers deterministic transcript | 7 | CoreSpecs |
| user cancellation and provider failure invalidate recording deadlines | 5 | CoreSpecs |
| audio device changes stop recording with a local diagnostic | 3 | CoreSpecs |
| every voice HUD presentation completes dismissal | 3 | UISpecs |
| stale cancel capability cannot cancel a newer recording | 2，都在 main 上 | ScenarioSpecs |

失败按步骤分布：[日志]

- **约四分之三落在门禁的 spec 子步骤里。**
  - CoreSpecs 18 次，大多数是时序 flaky。
  - UISpecs 9 次。
  - ScenarioSpecs 2 次。
  - brand-assets 3 次。
  - 2026-08-22 之前的日志没有 Gate summary，那段时间的子步骤是按"出错前最后链接的产物"推断的。
- **verify job 本身几乎没抓到过东西。**
  - 只有一次 2026-07 的 CI 脚本问题（29594479929，dSYM 绑定步骤）。
  - 还有两次是容量问题。
  - 打包和安装回滚步骤没有抓到过产品缺陷。

**UI 规格的失败记录：**9 次失败里有 2 次是产品缺陷，都在 2026-07/08 的 PR 分支上，合并前就抓住了。

- 菜单栏图标尺寸：30989230156，由 bbf8edc 修复。
- HUD 消失流程：31301845904。

其余 7 次是测试一侧的时序或预算问题。[日志]

**一次漏网：**2026-09-05，PR #104（Sparkle 升级）的 specifications 失败了，但 verify 被跳过，而跳过的必需检查算通过，结果这个 PR 26 秒后就合并了。13 分钟后 PR #106 加上了 `Require the fast lane to pass`。改 CI 结构时必须保住这个防线（见第 5 节）。[API][日志]

**flaky 的代价：**每次 flaky 至少要重跑一轮，约 10 分钟。最近 50 次运行里，main 上那 1 次失败也是 flaky（38502337336）。[API]

## 3. 只跑相关测试

### 3.1 映射表怎么来的

- **Swift 部分：**用 `swift package describe --type json` 读出 target 依赖图。[实测]
  - SpeakerCore 不依赖任何 target。
  - SpeakerAppFeatures 依赖 Core。
  - SpeakerApp 依赖 Core、Features 和 Sparkle。
  - CoreSpecs 依赖 Core、CoreSpecFakes 和 SpecSupport。
  - Scenario 和 UI 规格依赖 Core、Features、Fakes 和 Support。
  - EvidenceSpecs 依赖 Evidence；MetricsSpecs 依赖 Metrics。
  - ProviderSmoke 依赖 Core 和 Evidence；AccuracyEvaluator 依赖 Core 和 Metrics；BrandAssetGenerator 依赖 Features。
  - **没有任何规格依赖 SpeakerApp**，所以只改 `Sources/SpeakerApp/` 的行为不受 spec 保护，只有编译和 warnings 检查。
- **脚本部分：**逐个读 `scripts/test-*`，记下它们实际读取的文件。[实测]
  - test-package-dmg 和 test-release-evidence 用一个 C 语言写的假 App。
  - test-install-identity 和 test-compatibility-smoke 会真的打包 SpeakerApp。
  - test-release-identity 读 fixture 和 bundle、distribute、release-common 三个脚本。
  - test-workflow-security 读 `.github/workflows/` 和 verify-published-update。
  - test-skills-lock 读 `.agents/`、`.claude/skills/` 和 `skills-lock.json`。
- **规则：**
  - 改了 Package.swift、Package.resolved、scripts/swiftw 或 `.github/workflows/ci.yml`，就全跑。
  - 已知无测试的路径什么都不跑：docs/、site/、README、AGENTS.md、CLAUDE.md、CONTEXT.md、LICENSE，以及 launch、run、release、各类 delivery smoke 等只有 `zsh -n` 覆盖的脚本。
  - 其他不认识的路径，全跑。
- **实现：**原型在会话的 scratchpad 里（`select/selector.py`），没有进仓库。

映射表摘要：

| 改动路径 | 选中的步骤 |
|---|---|
| `Sources/SpeakerCore/` | CoreSpecs、ScenarioSpecs、UISpecs、compat-smoke、install-identity、provider-smoke-contract、brand-assets，以及 ProviderSmoke 和 AccuracyEvaluator 的 warnings 构建、SpeakerApp 的 debug 和 release warnings、verify job、格式检查 |
| `Sources/SpeakerAppFeatures/` | ScenarioSpecs、UISpecs、brand-assets、compat-smoke、install-identity、SpeakerApp warnings、verify job、格式检查 |
| `Sources/SpeakerApp/` | compat-smoke、install-identity、SpeakerApp warnings、verify job、格式检查 |
| `Sources/SpeakerProviderEvidence/` | EvidenceSpecs、provider-smoke-contract，以及 ProviderSmoke 和 EvidenceVerifier 的 warnings 构建 |
| `Sources/SpeakerAccuracyMetrics/` | MetricsSpecs、AccuracyEvaluator warnings |
| `Tests/SpeakerSpecSupport/`、`Tests/SpeakerCoreSpecFakes/` | 所有依赖它的 spec |
| `Tests/<某个 spec>/` | 只跑那个 spec |
| `Resources/` | compat-smoke、install-identity、release-identity、verify job；改到 AppIcon 和 Installer 还会加跑 brand-assets 和 package-dmg |
| `scripts/<x>` | 读它的 test-* 脚本；属于打包链的脚本还会加跑 verify job |
| `.github/workflows/release.yml` | test-workflow-security、test-scripts-test-summary |
| `.agents/`、`.claude/skills/`、`skills-lock.json` | test-skills-lock |
| docs/、site/、README 等 | 不跑（site/ 由已有的 site job 负责） |

### 3.2 回测：50 个合并 PR（#135–#185）

做法如下：[API][推断]

1. 对每个 PR 的文件列表跑一遍映射表，得到选中的步骤。
2. 把该 PR 所有失败 attempt（包括合并后 main 上那次）的失败步骤和选中集合比对，看有没有漏选。
3. 节省时间用模型估算，没有真实跑过。模型如下：
   - specifications job 的固定开销取 27 秒（setup、checkout、toolchain、cache 恢复和保存）。
   - 加上选中子步骤和步骤的 p50。
   - verify job 被选中时加 214 秒，即各步骤 p50 之和。
   - 全量约 581 秒。

| 结果 | 数量 |
|---|---|
| 全跑（命中 GLOBAL 路径：ci.yml 6 次，Package.resolved 1 次，swiftw 1 次） | 8 |
| 选出子集 | 36 |
| 什么都不跑 | 6，其中 #155 和 #178 只改 site/，现在已经跳过 macOS |
| 失败步骤在选中集合里 | 12 / 12 |
| 漏选 | 0 |
| 每 PR 节省（模型） | 平均 207 秒，中位数 144 秒 |

- **回测的局限：**样本里的失败只有 12 次，覆盖 PR #137、#139、#140、#172 和 #181，而且回测用的是 PR 最终的文件列表，不是每次失败时那一版。所以"0 漏选"只说明没有反例，证据有限。第 3.3 节的故障注入是补充。
- **如果去掉 UI 规格：**同样的回测在映射表里去掉 UI 规格后，会"漏掉" PR #139 的两次 UI 失败。这两次一次是超时预算，一次是 flaky，都不是产品缺陷。[日志]
- **节省的上限：**模型没算编译。少跑一个 spec 时，它那部分编译也省了，但共享模块总要编，所以实际节省可能比模型小。[推断]

### 3.3 故障注入

在一个基于 main 528e77f 的独立 worktree 里，每个区域注入一处故障，按映射表选出步骤，在本机逐个运行，然后还原。UI 规格、release warnings 和 verify job 没有在本机跑。[实测]

| 区域 | 注入的故障 | 抓到它的步骤 |
|---|---|---|
| SpeakerCore | 调换默认模型顺序 | CoreSpecs、ScenarioSpecs |
| SpeakerAppFeatures | 去掉"（推荐）"后缀 | ScenarioSpecs |
| SpeakerApp | 加一个未使用的变量 | 只有 CI 的 SpeakerApp debug warnings |
| SpeakerProviderEvidence | 改错 DeepSeek 模型名比较 | EvidenceSpecs |
| SpeakerAccuracyMetrics | CER 分母用错长度 | MetricsSpecs |
| Tools/SpeakerProviderSmoke | 未使用变量 | ProviderSmoke warnings 构建 |
| Tools/SpeakerUpdateSignatureVerifier | 签名校验取反 | self-test |
| Tests/SpeakerSpecSupport | 通过时直接 exit(3) | 所有 spec |
| scripts/package-dmg | `/Applications` 链接写错 | test-package-dmg |
| scripts/development-build-identity | 丢掉 `-dirty` 后缀 | test-development-build-identity |
| skills-lock.json | 改错一个 skill 名 | test-skills-lock |
| release.yml | action 不用 SHA 固定版本 | test-workflow-security |
| Resources/AppIcon.png | 水平翻转 | test-brand-assets |
| **scripts/install** | **跳过对暂存 App 的 `codesign --verify`** | **没抓到** |
| **scripts/release-common** | **`verify_dsym_matches_executable` 直接 return 0** | **没抓到** |

最后两处是测试覆盖的缺口，不是映射表选漏了：

- **scripts/install：**test-install-identity 只测了"目标 App 身份不对时拒绝"，没测"暂存 App 签名坏了时拒绝"。
- **scripts/release-common：**test-release-evidence 没有"dSYM UUID 不匹配"的反例。

CI 的 verify job 用的是正常打包、签名有效、UUID 匹配的 App，所以这两处故障在 verify 里大概率也不会触发失败。这一点没有在 CI 上验证。[推断]

另外，SpeakerApp 那一行说明，只改 `Sources/SpeakerApp/` 时，本地 spec 什么也抓不到，唯一的保护是 warnings 构建和 CI 的打包。[实测]

## 4. UI 规格

你的决定：本地不再常规跑 UI 规格，也不再研究静默方案，只在大改 UI 设计时跑。下面只记录已经做过的部分，供以后参考。

### 4.1 为什么会弹窗

- **规格本身会把窗口带到前台。**
  - 约 22 处 `orderFrontRegardless`，2 处 `makeKeyAndOrderFront`。
  - 1 处 `NSApp.activate`，只在设置了 `SPEAKER_REFINEMENT_PROVIDER_UI_ARTIFACTS` 时执行。
  - 进程启动后会设为 `.accessory` 激活策略。[实测：读源码]
- **Apple 文档：**
  - `orderFrontRegardless()` 在 App 未激活时也会把窗口放到前面。
  - macOS 14 起激活是"协作式"的，`ignoringOtherApps` 被忽略，激活只是一个请求。[文档]
- **触发路径：**`docs/agents/development.md` 写着"普通改动在最紧的 spec 和完整门禁通过后才算测完"，完整门禁就是 `./scripts/test --with-ui`。所以每次收尾，不管是人还是 agent，都会在本机把 UI 规格跑一遍。

### 4.2 已经测到的数据

每种方式只跑了一次，运行时用户正在用电脑，所以只能当参考。[实测]

| 方式 | 有窗口可见的时间 | 53 条 UI 规格 |
|---|---|---|
| 现状 | 26 秒里约 17 秒，峰值约 1.23M 像素，最多 5 个窗口同时出现 | 全部通过 |
| 运行时把窗口透明度置 0（实验 hook） | 约 4 秒 | 全部通过 |
| 运行时把窗口挪到屏幕外 +100,000（实验 hook） | 约 5.7 秒 | 全部通过 |

两种方式都没能做到完全不可见。

- **透明度为 0：**Apple 文档说"a completely transparent window may also be considered visible"，所以透明窗口仍然可能抢焦点、挡鼠标。[文档]
- **挪到屏幕外：**系统会约束窗口位置，坐标上限是 ±16,000，挪不出去。[文档]
- **前台切换的来源没有确认。**现状那次运行里，UI 规格进程约有 22 秒处于前台；但在另一次带追踪的运行里没有。前台切换可能是用户点击造成的。

### 4.3 建议

- **CI 照常每个 PR 跑 UI 规格。**
  - 它在 macOS runner 上跑，不打扰任何人，只多 57 秒。
  - 历史上抓到过 2 次产品缺陷。[日志]
- **可选：在 CI 里给 UI 规格加路径条件。**只在改了 `Sources/SpeakerCore/`、`Sources/SpeakerAppFeatures/`、`Tests/SpeakerAppUISpecs/`、`Tests/SpeakerSpecSupport/` 或 `Tests/SpeakerCoreSpecFakes/` 时跑。收益只有几十秒，优先级低。
- **本地规则：**默认 `./scripts/test` 不带 UI（现在已经是这样）。收尾规则改成"最紧的 spec 加上本地选中的步骤"，不再要求 `--with-ui`。大改 UI 设计时，在你不用电脑的时候专门跑一次 `./scripts/test --ui-only`。见第 7 节。
- **发布不受影响。**`release.yml` 自己执行 `./scripts/test --with-ui`，UI 覆盖在发布时仍然完整。

## 5. CI 建议

### 5.1 当前的保护设置

[API]

- **必需检查：**`main` 只有一个必需检查，`Test, build, and bundle`（也就是 verify job，app 15368）。
  - `strict: true`：合并前分支必须和 main 同步。
  - 需要 PR，但 0 个 approval。
  - `enforce_admins: true`，`required_linear_history: true`。
  - 没有 rulesets。
- **仓库：**公开仓库。标准 GitHub-hosted runner 不计费；Free 计划的 macOS 并发上限是 5。[API][文档]

### 5.2 GitHub 的几条语义

[文档]

- **job 级 `if:` 跳过：**job 报 Success，满足必需检查。
- **workflow 级 `paths` 过滤：**workflow 根本不运行，必需检查一直 Pending，PR 合并不了。所以按路径跳过只能在 job 级做，不能用 workflow 的 `paths`。
- **依赖失败：**被 `needs` 的 job 失败后，下游 job 会被跳过，而跳过算通过（PR #104 的漏网就是这样）。汇总 job 要用 `if: ${{ !cancelled() }}` 并自己检查 `needs.*.result`。
- **缓存作用域：**
  - PR 保存的缓存只属于它的 merge ref，只有同一个 PR 的后续运行能用。
  - 只有 push、workflow_dispatch、schedule 等事件能写 main 作用域的缓存。
  - 7 天没访问的缓存会被删；仓库总上限 10 GB，超了按最近最少使用淘汰。

### 5.3 缓存现状

[API][日志]

- **规模：**43 条，共 10.77 GB，已经超过 10 GB，正在被淘汰。每条约 250 MB。main 上有 16 条（4.0 GB），但恢复时只用最新那条。
- **命中率：**PR 运行 93%（115/123），其中 66 次恢复自 main push 保存的缓存，49 次恢复自同一 PR 之前的运行。push 运行 94%（60/64）。
- **未命中的原因：**集中在 Package.resolved 改动时（09-05、09-21、09-30 三次 Sparkle 升级），以及 10-08 那次 CI 停了 8 天之后，这和 7 天淘汰规则吻合。
- **结论：**main 的缓存来自 push 到 main 时 specifications job 的保存。任何不再在 push main 上跑 specifications 的改动，都会让 PR 失去主要的缓存来源。

### 5.4 逐项建议

每一项都说明对以下四个方面的影响：

- 必需检查
- "跳过算通过"
- release.yml 的完整门禁
- main 缓存的来源

**A. verify 不再等 specifications，两者并行，再加一个汇总 job 承接必需检查的名字。**

- 收益：
  - 关键路径从 changes + 6.2m + 3.7m 降到约 changes + max(6.2m, 3.7m) + 汇总约 10 秒，p50 约 6.5 分钟，比现在少约 3.7 分钟。[推断]
  - verify 历史上几乎没失败过（见第 2 节），提前跑它几乎不会白跑。
- 必需检查：把现在的 verify job 改名（比如 "Release bundle and install"），新的汇总 job 叫 `Test, build, and bundle`，`needs: [changes, specifications, verify]`。名字不变，branch protection 不用改。
- 跳过算通过：汇总 job 必须 `if: ${{ !cancelled() && needs.changes.outputs.app != 'false' }}`，并在步骤里检查 specifications 和 verify 的 result 都是 success，否则 exit 1。这样就保住了现在 `Require the fast lane to pass` 的作用，不会退回 PR #104 那种漏网。
- release.yml：无影响，它自己跑 `./scripts/test --with-ui`。
- main 缓存：无影响，verify 本来就不用缓存，只有 specifications 保存缓存。
- 代价：
  - 每次运行同时占 2 个 macOS runner。PR 和 main 运行重叠时最多占 4 个，接近 Free 计划的上限 5。
  - specifications 失败时 verify 也会跑完，但公开仓库不计费。[文档][推断]

**B. 只改文档的 PR 跳过 macOS job。**

- 做法：扩展现有 `changes` job 的分类。现在只把 `site/*` 当作非 app 文件；改成把 NO_TEST 列表（docs/、README、AGENTS.md 等）也当非 app 文件，不认识的路径照旧当 app。
- 收益：50 个 PR 里有 4 个（#147、#156、#157、#166）能省掉整整 10 分钟，约 8%。[API]
- 必需检查：verify 由 job 级 `if:` 跳过，报 Success，满足必需检查。这正是 #155 和 #178 现在的行为。
- 跳过算通过：这里的跳过是有意的，靠分类正确来保证。风险在于把有测试的路径误分进 NO_TEST，所以列表只放明确无测试的路径。
- release.yml：无影响。
- main 缓存：纯文档的 push 不再保存新缓存。PR 仍能用前缀匹配到上一条 main 缓存；但如果 main 连续 7 天以上只有文档提交，旧缓存会过期，下一个代码 PR 就是冷编译。[推断]

**C. 修掉 3 条时序不稳的 CoreSpecs 规格，加上 main 上的 stale cancel 规格。**

- 范围：涉及的是测试代码，按约束这一步不动，单独开任务。
- 收益：42 次失败里有 22 次 flaky，集中在 hold and release、recording deadlines、audio device changes 和 stale cancel 四个用例。每次 flaky 至少多一轮约 10 分钟。
- 对四个方面都没有影响。

**D. 把 "Treat release compiler warnings as errors"（50 秒）并入 verify 的 release 打包。**

- 状态：已实施（2026-10-22）。`scripts/bundle` 读 `SPEAKER_BUNDLE_WARNINGS_AS_ERRORS=1`，在 ad-hoc 路径上给 `scripts/build` 加 `-Xswiftc -warnings-as-errors`；只有 ci.yml 的 verify 打包设置它。specifications 里的 release warnings 步骤已删除。两者编译的是同一个 `SpeakerApp` 产品、release 配置、同一个 SDK 和构建系统，区别只是打包用隔离的空 scratch 路径（全量编译）和只读 `Package.resolved` 的解析参数。

- 现状：
  - release warnings 步骤把 SpeakerApp 按 release 配置编了一遍。
  - verify 的打包也是 release 配置，又编了一遍。但 CI 走的是 ad-hoc 签名路径，`scripts/bundle` 只在正式签名路径上加 `-warnings-as-errors`。
  - 历史上没有一次失败只出现在 release warnings 步骤。[日志]
- 做法：让 CI 的打包也带 `-warnings-as-errors`，然后删掉单独的步骤。这需要改 `scripts/bundle` 和 ci.yml。
- 收益：specifications 少 50 秒。在 A 实施之后，specifications 就是关键路径，这 50 秒会直接体现在关键路径上。
- 必需检查：warnings 问题会改成在 verify（或 A 方案里的 bundle job）里失败，必需检查照样变红。
- release.yml：正式签名路径本来就带这个参数，不受影响。
- main 缓存：无影响。
- 风险：打包用的是隔离的 scratch 路径，要确认它编的产物和原来的 release warnings 步骤一致。

**E. 去掉 verify 里重复的 `test-release-identity`（15 秒）。**

- 状态：已实施（2026-10-22）。verify 不再单独跑它，specifications 的 `./scripts/test --with-ui` 照常跑。

- 现状：门禁子步骤里已经跑过同一个脚本，读的是同样的 fixture。
- `test-release-evidence` 不是重复：verify 那次用的是真打包的 App（`SPEAKER_EVIDENCE_TEST_APP`），门禁里那次用的是 C 写的假 App。
- 收益小，风险低。四个方面都没有影响。

**F. 在 CI 里也按路径选测试。**

- 现在不建议做。
- 收益：按模型每 PR 平均省 207 秒；A、B、D 做完后，剩下能省的会更少。
- 风险：
  - 选漏一个就是漏网。
  - 部分 spec 被跳过后，保存的 `.build` 缺少它的编译产物，下一次运行要补编。
- 如果要做：
  - 只对 PR 选择，push 到 main 永远全跑，以保证 main 缓存完整。
  - 跳过的步骤要在 Gate summary 里明确写出 SKIPPED。
- release.yml 必须继续跑全量：如果选择逻辑加进 `scripts/test`，默认模式要保持全量，release.yml 不传选择参数。

**G. push 到 main 时只跑 specifications，不跑 verify。**

- 理由：`strict: true` 加上只能 squash/rebase，合并后 main 的树和 PR 测过的 merge 提交的树相同，push main 时的 verify 是在重复验证同一棵树。[API][推断]
- 收益：
  - 每次合并少占一个 macOS runner 约 3.7 分钟。
  - 连续合并时 main 上 131–212 秒的排队会变短。
  - 不影响 PR 的关键路径。
- 必需检查：必需检查只对 PR 有意义，push 事件不受影响。
- 跳过算通过：只影响 main 上的显示。
- release.yml：不受影响，发布有自己的门禁。
- main 缓存：仍由 specifications 保存，不变。
- 代价：main 上就不再有"打包加安装回滚"的独立信号。这类问题在 PR 阶段已经测过同一棵树。

**H. 补两处测试覆盖缺口。**

- 内容：
  - `scripts/install`：暂存 App 签名无效时必须拒绝。
  - `scripts/release-common`：dSYM UUID 不匹配时必须失败。
- 这两项是测试代码，单独开任务。
- 收益是安全性，不是速度。四个方面都没有影响。

**I. SessionHistorySpecs 里 busy reader 用例不再等满 3 秒。**

- 状态：已实施（2026-10-22）。这一项不在最初的调研里。
- 原状：`SQLiteConnection` 写死 `PRAGMA busy_timeout=3000`。4 条用例（privacy scrub 重试、busy checkpoint 的 clear、retention、cap pruning）各自开着一个读事务，等 SQLite 报 busy，每条在 CI 上要 4–6 秒。
- 做法：busy timeout 改成 `SQLiteSessionHistory` 的构造参数，生产默认仍是 3 秒（`defaultBusyTimeout`），这 4 条用例传 50 毫秒。读事务在整个调用期间都不释放，所以超时长短不改变结果：仍然报 busy，释放后重试成功。本机每条从约 3.2 秒降到约 0.1 秒（privacy scrub 那条约 0.8 秒）。
- 四个方面都没有影响。

## 6. 步骤一览

| 步骤 | p50 / p90 | 防的是什么 | 建议 |
|---|---|---|---|
| changes（ubuntu） | 约 5s | 分出 site/ 和 app 改动 | 扩展到 NO_TEST 路径（B） |
| Cache 恢复和保存 | 8s + 8s | 冷编译；PR 93% 命中 | 保留 |
| Check Swift formatting | 3s | 格式漂移 | 保留；本地也跑（0.9s） |
| SpeakerCoreSpecs | 60s / 69s | Core 领域行为：会话、provider、持久化、取消 | 保留；修 flaky（C） |
| SpeakerAppUISpecs | 57s / 70s | 真实窗口的焦点、HUD、布局、可访问性；抓到过 2 次产品缺陷 | CI 保留；本地只在大改 UI 时跑 |
| SpeakerAppScenarioSpecs | 36s / 45s | App 层流程（用 fake） | 保留 |
| test-package-dmg | 28s / 33s | DMG 结构 | 保留；本地按路径选 |
| test-compatibility-smoke | 13s / 21s | 真打包 SpeakerApp 后的兼容性冒烟 | 保留 |
| test-brand-assets | 11s / 21s | 生成的图标和仓库里的资源一致 | 保留 |
| ProviderSmoke warnings 构建 | 11s / 16s | 冒烟工具能编译且无警告；抓到过 2 次（#181） | 保留 |
| test-release-identity（门禁内） | 11s / 13s | 发布身份守卫 | 保留 |
| test-install-identity | 9s / 15s | 安装时拒绝身份错误的目标 | 保留；补签名反例（H） |
| test-provider-smoke-contract | 6s / 11s | 冒烟 CLI 的契约（不联网） | 保留 |
| test-release-evidence（门禁内） | 5s / 7s | 证据和 dSYM 绑定（假 App） | 保留；补 UUID 反例（H） |
| Metrics、Evidence spec 和其余工具步骤 | 各 2–4s | 各自模块 | 保留 |
| 并发的 4 个脚本测试 | 各 ≤0.3s（本机） | workflow 安全、构建身份、门禁汇总、skills 锁 | 保留 |
| Debug SpeakerApp warnings | 16s / 23s | Swift 6 并发错误；抓到过 4 次（#140） | 保留 |
| Release SpeakerApp warnings | 50s / 65s | release 配置的警告；从未单独抓到过东西 | 已并入打包（D，已实施） |
| pristine deps、脚本和补丁卫生 | 约 1s | 依赖被改动、`zsh -n`、空白错误 | 保留 |
| Build isolated release bundle | 120s / 143s | release 打包能成功 | 保留；与 specifications 并行（A） |
| Verify release identity and integrity | <1s | Info.plist 身份、签名 | 保留 |
| Verify release evidence dSYM binding | 7s / 9s | 真 App 的 dSYM 绑定 | 保留 |
| Verify install rollback | 61s / 74s | 安装失败时回滚 | 保留；push main 时可跳过（G） |
| Verify reviewed release identity guard | 15s / 19s | 和门禁内的同一个脚本 | 已去掉（E，已实施） |

## 7. 建议的本地测试规则

**本地负责：**改动当场的快速反馈。

1. 迭代时跑最紧的 spec，带用例名过滤。
2. 提交或推送前，按改动路径跑第 3.1 节映射表选中的本地步骤，并跑 `swift format lint`：
   - 改 `Sources/SpeakerCore/`：CoreSpecs 加 ScenarioSpecs，本机约 25 秒。
   - 改 `Sources/SpeakerAppFeatures/`：ScenarioSpecs，约 6 秒。
   - 改 `Sources/SpeakerApp/`：debug SpeakerApp warnings 构建，约 10 秒。
   - 改 `scripts/<x>`：对应的 `test-<x>`。
   - 只改文档：不跑。
3. 跨多个区域、或改了共享的 Fakes/Support 时，跑一次 `./scripts/test`（无 UI，本机约 1 分钟）。
4. 大改 UI 设计时，在你不用电脑的时候跑一次 `./scripts/test --ui-only`。其他时候本地不跑 UI 规格。
5. 有 provider、发布、安装或 workflow 改动时，照现在 development.md 的要求跑对应的专项检查。

**CI 负责：**

- 完整门禁 `--with-ui`
- release 配置构建
- 打包、安装回滚和发布身份守卫
- 发布时的完整门禁（release.yml）

本地通过只代表"选中的部分没坏"，"可以合并"要以 CI 的结果为准。

实施这条规则要改 `docs/agents/development.md` 里"普通改动在最紧的 spec 和完整门禁通过后才算测完"那一句。这一步只是调研，没有改。

## 8. 改动清单

按收益和风险排序。每项都写了实施后怎么验证。

| # | 改动 | 收益 | 风险 | 怎么验证 |
|---|---|---|---|---|
| 1 | 改 development.md 的收尾规则（第 7 节），本地不再跑 `--with-ui` | 不再弹窗；本地每次省 30–60 秒 | 低：CI 每个 PR 仍跑 UI | 之后 10 个 PR 统计：本地按新规则通过、CI 却失败的次数，以及失败的是哪一步 |
| 2 | A：verify 与 specifications 并行，新汇总 job 承接 `Test, build, and bundle` | 关键路径约 −3.7 分钟 | 中：汇总 job 写错会重现 PR #104 的漏网 | 开 3 个 draft PR：(a) 正常改动，看必需检查是否为 success、墙钟时间多少；(b) 故意弄坏一个 spec，必需检查必须是 failure，合并按钮必须不可用；(c) 故意弄坏打包，同上。拿 (a) 和同一提交在旧 workflow 下的耗时对比 |
| 3 | C：修 4 条 flaky 规格 | 减少约一半的失败重跑 | 低 | 本机对同一提交用 `SPEAKER_SPEC_TRACE=1` 循环跑 50 次，修前修后比较失败次数；之后 50 次 CI 运行统计 flaky 次数 |
| 4 | B：纯文档 PR 跳过 macOS | 约 8% 的 PR 省 10 分钟 | 低到中：分类写错会漏测 | 开 2 个 draft PR：只改 docs/ 时，必需检查应为 success 且 specifications 被跳过；同时改 docs/ 和 Sources/ 时，应该全跑 |
| 5 | D：release warnings 并入打包（已实施） | specifications −50 秒 | 中 | 在同一提交上，加一个只在 release 下出现的警告（`#if !DEBUG` 里的未使用变量）：改前应在 release warnings 步骤失败，改后应在打包步骤失败；对比两边的总耗时 |
| 6 | H：补安装签名和 dSYM UUID 两个反例 | 堵住故障注入发现的两个缺口 | 低 | 重跑第 3.3 节对应的两处注入，应当被抓到 |
| 7 | G：push main 不跑 verify | 每次合并少占约 3.7 分钟 runner | 低 | 看之后 main push 的 cache 保存是否照常（`cache_restores` 里来自 main 的命中率不下降），以及连续合并时的排队时间 |
| 8 | E：去掉重复的 release identity（已实施） | −15 秒 | 低 | 同一提交前后对比 verify 的耗时 |
| 9 | F：CI 内按路径选测试 | 模型上每 PR 省 207 秒，做完 1–8 后会更少 | 中到高 | 先在本地用一个月，统计 CI 失败是否都落在本地选中的步骤里，再决定要不要做 |

1 只改文档，可以马上做。2、4、5、7、8 要改 ci.yml，3、6 要改测试代码，都需要你点头后单独开分支。

## 附：一手文档

- 必需检查的通过状态包括 success、skipped 和 neutral：https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches#require-status-checks-before-merging
- job 被 `if:` 跳过时报 Success：https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-jobs-with-conditions
- workflow 被 `paths` 跳过时检查保持 Pending：https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore
- 跳过的必需检查和 `always()` 的用法：https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks#handling-skipped-but-required-checks
- `needs`：https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds
- 状态函数和 `!cancelled()`：https://docs.github.com/en/actions/reference/workflows-and-actions/expressions#status-check-functions
- concurrency：https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency
- 缓存作用域、写权限和淘汰规则：https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching
- runner 并发上限：https://docs.github.com/en/actions/reference/limits#job-concurrency-limits-for-github-hosted-runners
- 公开仓库计费：https://docs.github.com/en/billing/concepts/product-billing/github-actions
- `orderFrontRegardless()`：https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless()
- 透明窗口也可能算可见：https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.struct/visible
- 窗口遮挡与屏幕外窗口（OS X 10.9 说明）：https://developer.apple.com/library/archive/releasenotes/AppKit/RN-AppKitOlderNotes/
