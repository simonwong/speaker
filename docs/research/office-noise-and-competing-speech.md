# 办公噪声与竞争人声

最后核对：2026-09-02（仅查阅第一方公开资料与本仓库文档；未调用供应商接口，也未读取凭据、音频、转写文本、供应商消息或本地敏感文件）

## 结论

Speaker 在录音引擎启动前默认尝试启用 Apple Voice Processing；无法启用时回退原始采集。处理后的音频转成 16 kHz、16-bit、单声道 PCM，实时送入豆包 `bigmodel_async`。这条系统路径适合稳态噪声、键盘瞬态和本机扬声器回声，但 Apple 没有承诺按身份排除旁人，因此不能把 Voice Isolation 当作“只听机主”。[当前架构](../architecture.md) [Voice Input 规范](../specs/voice-input.md) [Apple WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/)

**VAD、普通降噪和说话人分离都不能可靠阻止同事的话进入转写。** VAD 只判断“有没有语音”；普通降噪通常保留任何清晰语音；说话人分离是在识别后标注/聚类，至多让 Speaker 丢弃某个聚类，仍会受首段归属、短句和重叠说话错误影响。真正以身份保留目标说话人的能力是目标说话人提取／声纹降噪；目前公开的豆包大模型 ASR 接口没有这项合同，火山公开能力位于另一套 RTC Conversational AI 产品，不能当作现有 ASR 参数直接打开。[豆包 ASR API](https://docs.volcengine.com/docs/6561/1354869?lang=zh) [RTC 声纹能力](https://www.volcengine.com/docs/6348/1807452?lang=zh)

## 先区分四种干扰

| 干扰 | 本质 | 最匹配手段 | 明确边界 |
| --- | --- | --- | --- |
| 空调、风扇等稳态噪声 | 非语音、统计较稳定 | Voice Processing／Voice Isolation、WebRTC APM、RNNoise、DeepFilterNet | 过强抑制会损伤轻声、辅音和专名；不能据此排除人声。 |
| 本机扬声器回声 | 已知播放信号经声学路径返回麦克风 | Apple Voice Processing I/O 或 WebRTC AEC，并提供/拥有播放参考 | AEC 消除的是与参考信号相关的回声；同事说话没有参考，不是 echo。耳机通常比算法更确定。 |
| 房间混响 | 自己声音的多径拖尾 | 近讲、吸声、换麦克风；再评估专门去混响 | 普通 AEC 与普通噪声抑制都不等价于去混响；Apple 未公开承诺其 Voice Processing 的去混响指标，DeepFilterNet 论文也主要评价降噪而非专用去混响。 |
| 同事说话 | 另一段合法语音，可与用户顺序或重叠 | 声学隔离；其次 Voice Isolation；若仍不够才考虑目标声纹/目标说话人提取 | 单通道 VAD、普通降噪、ASR 鲁棒性和 diarization 均无“只保留机主”的身份保证。 |

## 各能力能做什么、不能做什么

### 1. Apple Voice Processing I/O 与麦克风模式

- `AVAudioEngine` 可在 I/O node 上调用 `setVoiceProcessingEnabled(true)`；Apple 将它与 `AUVoiceProcessingIO`（AUVoiceIO）描述为相同的语音处理能力入口，包含回声消除、噪声处理和默认开启的 AGC。切换 voice processing 必须在 engine 停止时完成，并可能改变 I/O 图与格式，故应作为录音适配器启动配置而非录音中开关。[API](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)) [Using voice processing](https://developer.apple.com/documentation/avfaudio/using-voice-processing) [AGC](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/isvoiceprocessingagcenabled)
- 采用 AUVoiceIO／AVAudioEngine voice processing 后，系统可向用户提供 Standard、Voice Isolation、Wide Spectrum；**应用不能强制选择 Voice Isolation**，应读取 `preferredMicrophoneMode` 与实际 `activeMicrophoneMode`。可用模式还取决于 Mac 年代、输入路由和设备；Apple WWDC21 给出的门槛是 2018 年及之后设备。`NSAlwaysAllowMicrophoneModeControl` 只扩展用户在麦克风尚未活动时的系统控制机会，不把模式选择权交给应用。[WWDC21](https://developer.apple.com/videos/play/wwdc2021/10047/) [WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/) [activeMicrophoneMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemicrophonemode) [Info.plist key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsalwaysallowmicrophonemodecontrol)
- Apple 对 Voice Isolation 的公开表述是增强主要语音并移除不需要的背景噪声，示例为键盘、鼠标和吹叶机；没有给出竞争人声拒绝率、身份注册或“旁人绝不进入”的保证。因此它值得第一优先级实测，但只能是概率性衰减，不是安全边界。[Voice Isolation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/microphonemode/voiceisolation)
- Apple 没有公开固定算法延迟或 CPU 指标；必须在 Speaker 支持的 Intel/Apple Silicon、内置麦克风/耳机/USB 麦克风及不同输出路由上测量。系统实现无需新增网络边界，隐私最佳、集成和许可风险最低，但行为是黑盒且会随 OS、硬件和用户模式变化。

### 2. 豆包 ASR 与说话人分离边界

- 豆包宣称大模型使噪声与背景人声影响下降 30%–50%，这是整体识别鲁棒性表述，不是“删除旁人文本”的合同。[产品简介](https://www.volcengine.com/docs/6561/1354871?lang=zh)
- **VAD 会把同事的声音也判为 speech**，所以不能作为目标说话人门禁。
- 豆包公开的说话人信息能力用于把已收到、已识别的语音聚类并标注，不是在麦克风或解码前消除旁人。Speaker 当前产品合同不启用该能力。若事后只保留一个 speaker ID，仍不知道哪个 ID 是用户，并可能在短 Voice Input Session、首次出声、音色相近、远近变化或重叠说话时误删用户或保留同事。该能力还会让产品从单人输入走向当前规范明确排除的 diarization，需先改产品合同而非偷偷加参数。[ASR API 参数表](https://docs.volcengine.com/docs/6561/1354869?lang=zh) [产品能力矩阵](https://www.volcengine.com/docs/6561/1354871?lang=zh) [Voice Input 规范：Out of Scope](../specs/voice-input.md#out-of-scope)
- ASR 文档没有给 Speaker 当前接口提供独立的环境降噪强度或目标声纹字段。火山另有音频技术“降噪/去混响”和 RTC `AnsMode`，但属于不同产品/SDK，不能据此假定 `bigmodel_async` 已含可调前处理。[音频技术：降噪/去混响 V2](https://www.volcengine.com/docs/6489/192743) [RTC API](https://www.volcengine.com/docs/6348/1807452?lang=zh)

### 3. 声纹/目标说话人

- 火山 RTC Conversational AI 的 `VoicePrint.Mode=1` 是声纹降噪：预注册模式只允许 1 个声纹 ID，并保留匹配目标人声；无 `IdList` 时可学习 `TargetUserID`，但累计约 30 秒目标语音后才生效。`Mode=2` 是在 1–3 个预注册声纹间识别说话人，不等于从混音中清除旁人。[RTC 声纹能力](https://www.volcengine.com/docs/6348/1807452?lang=zh)
- 因此，**只有 Mode 1 这类目标说话人提取在设计目标上能阻止同事语音进入后续 ASR**；它仍不是绝对保证，需测假接受（同事被保留）与假拒绝（用户被删除）。实时学习的 30 秒冷启动不适合 Speaker 常见短句；预注册则引入声纹模板的知情同意、撤销/删除、防冒用、跨设备/感冒漂移和生物特征数据治理。
- 该能力不在当前 `bigmodel_async` 合同中。接入意味着新增 RTC 产品、协议、计费与供应商数据用途，改变“音频只流向豆包 ASR”的既有适配器形状，并可能触发架构/规格与隐私评审；在供应商书面确认 macOS/服务端接入、数据保留和删除合同前，不建议立项为小功能。

### 4. 本地实时前处理候选

| 候选 | 适合场景 | 延迟/CPU | 隐私、许可与集成风险 | 竞争人声边界 |
| --- | --- | --- | --- | --- |
| WebRTC Audio Processing Module | AEC + NS + AGC + 瞬态抑制的完整通信链 | API 按 10 ms capture/render 帧工作；端到端延迟和 CPU 无通用保证。AEC 必须喂 render/reverse stream。 | 本地处理；BSD 风格许可并有专利授权。上游体量大、C++/GN 构建复杂，Swift/C++ ABI、裁剪、更新和双流时钟对齐风险最高。[APM](https://chromium.googlesource.com/external/webrtc/+/master/modules/audio_processing/g3doc/audio_processing_module.md) [API](https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h) [PATENTS](https://webrtc.googlesource.com/src/+/refs/heads/main/PATENTS) | NS 不按身份区分人声；AEC 只消已知播放参考。 |
| RNNoise | 轻量单麦克风噪声抑制 | 48 kHz、480 samples，即 10 ms/帧；上游未给 macOS CPU 保证。Speaker 需在降噪前后做 48↔16 kHz 转换或调整采集管线。 | 本地；BSD-3-Clause，C 接口较易封装。默认模型下载/打包、架构优化和模型版本复现需纳入供应链。[仓库](https://github.com/xiph/rnnoise) [示例](https://github.com/xiph/rnnoise/blob/main/examples/rnnoise_demo.c) | 目标是 noise suppression，不是声纹提取；清晰同事语音通常会被保留。 |
| DeepFilterNet | 更强的 48 kHz 全频带神经语音增强 | 上游实时插件称最低算法延迟约 20 ms；论文配置为 40 ms、单线程 notebook CPU RTF 0.19。版本、host buffering 和 Mac 芯片会改变结果。 | 本地；MIT/Apache-2.0 双许可。Rust/C ABI/ONNX 模型、模型体积、签名/打包、Swift 集成复杂；上游没有生产级 macOS 实时采集宿主示例。[仓库](https://github.com/Rikorose/DeepFilterNet) [论文](https://www.isca-archive.org/interspeech_2023/schroter23b_interspeech.html) | 单通道语音增强，不提供用户身份保证；论文指标不能证明去混响或拒绝旁人。 |

三者都能在音频跨豆包边界前本地处理，因而不增加第三方音频披露；但处理后的音频仍按当前合同发给豆包。不要串联多个强降噪器作为默认方案：失真会累积，ASR CER/WER 可能反而变差。

## 建议的实现与测试顺序

1. **先建内容合规的离线基准，不改产品。** 使用获准的非敏感、可公开测试句和合成/许可噪声；测试矩阵必须分别覆盖：(a) 风扇稳态噪声，(b) 键盘瞬态，(c) 已知本机播放回声，(d) 房间脉冲响应卷积混响，(e) 同事顺序说话，(f) 同时重叠说话；再按近/远、SIR/SNR、内置麦克风/耳麦/USB 和支持/不支持 Voice Isolation 的 Mac 分层。核心指标为目标说话人 CER/WER、**干扰词插入率**、用户词删除率、首字/最终延迟 p50/p95、实时线程 underrun、CPU/能耗和热稳定性。严禁把测试音频作为普通 Session Record 持久化。
2. **测物理与系统基线。** 同一句矩阵依次比较近讲耳麦、关闭系统处理的 raw capture、Apple voice processing Standard、用户选择 Voice Isolation；记录 `preferred` 与 `active` mode，不能把“用户选了但路由未生效”误判为算法结果。若耳麦已把旁人插入率降到门槛内，避免新增 DSP。
3. **验证默认 Apple voice processing 与回退。** 保持产出仍为 16 kHz mono PCM、bounded in-memory stream，不改变 Doubao/DeepSeek seam。确认 voice processing 无法启用时回退 raw capture，录音期间的设备配置变化仍报告明确问题；对 AGC 影响分别测轻声、削波和数字静音策略，验证 `AudioCaptureQualityPolicy` 不被新噪声底误导。Apple 未给时延上界，需在支持矩阵中持续实测。
4. **只有 Apple 路径未达标才评估一个本地库。** 有真实本机播放回声时先 WebRTC APM；主要是非语音噪声且重视体积/CPU 时先 RNNoise；质量收益足以覆盖 20–40 ms 与打包复杂度时才试 DeepFilterNet。每个候选必须独立与 raw/Apple 对照，不先串联。
5. **竞争人声仍不达标时再做产品决策。** 优先提供“建议使用耳麦/Voice Isolation”的诚实能力说明。若业务必须保证只听机主，先为目标声纹建立单独威胁模型、同意/删除流程、假接受阈值和 ADR；随后向火山确认该 RTC 能力能否以 Speaker 的短时 macOS 流接入。不要用 VAD、普通降噪或 diarization 冒充身份门禁。

## 主要风险与未决证据

- **高：竞争人声误收。** 现有公开 ASR/Apple 合同均无身份保证；在实机目标说话人插入率验收前，不能宣称“屏蔽同事”。
- **高：声纹产品与隐私边界。** RTC 声纹不是现有 ASR 参数，且涉及生物特征模板、另一产品合同及潜在新增计费；需要架构、法务/隐私和供应商书面确认。
- **中：Apple 可用性与黑盒漂移。** 用户而非应用选模式，实际模式受硬件/路由影响，公开资料没有延迟、CPU、重叠语音指标。
- **中：diarization 后过滤误删。** 短句和重叠说话缺乏公开准确率；Speaker 也没有跨 Session 的可靠 speaker-ID 身份绑定。
- **中：本地 DSP 供应链与实时性。** WebRTC 构建体量、RNNoise 48 kHz 模型、DeepFilterNet Rust/ONNX 均需锁版本、许可证归档、Universal Binary/签名验证及 M 系列和 Intel 性能门槛。
- **证据缺口：** 豆包公开文档未给 `ssd_version=200` 的短句/重叠说话 DER、额外终局延迟，也未给 ASR 端目标声纹接口；Apple 未给 Voice Isolation 的竞争人声拒绝率；三个本地项目均无 Speaker 硬件矩阵上的 ASR 指标。下一步只能靠获批、非敏感的确定性离线样本与实机 acceptance 补齐。

## 第一方来源

- [Apple：What’s new in voice processing（WWDC23）](https://developer.apple.com/videos/play/wwdc2023/10235/) — AVAudioEngine/AUVoiceIO、macOS voice processing 与麦克风模式。
- [Apple：What’s new in camera capture（WWDC21）](https://developer.apple.com/videos/play/wwdc2021/10047/) — Voice Isolation 定位、用户控制和设备条件。
- [Apple：Using voice processing](https://developer.apple.com/documentation/avfaudio/using-voice-processing) — AVAudioEngine voice-processing 集成。
- [火山引擎：大模型流式语音识别 API](https://docs.volcengine.com/docs/6561/1354869?lang=zh) — VAD 与 speaker 参数合同。
- [火山引擎：语音识别大模型产品简介](https://www.volcengine.com/docs/6561/1354871?lang=zh) — 噪声/背景人声与说话人分离能力表述。
- [火山引擎 RTC：Conversational AI API](https://www.volcengine.com/docs/6348/1807452?lang=zh) — `AnsMode`、VoicePrint 模式、ID 数量与 30 秒学习限制。
- [WebRTC APM 上游文档](https://chromium.googlesource.com/external/webrtc/+/master/modules/audio_processing/g3doc/audio_processing_module.md)、[RNNoise 上游仓库](https://github.com/xiph/rnnoise)、[DeepFilterNet 上游仓库](https://github.com/Rikorose/DeepFilterNet) — 本地候选的范围、接口与许可。
