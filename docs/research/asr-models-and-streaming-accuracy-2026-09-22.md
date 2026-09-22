# ASR 候选、流式识别与听写准确性

调研日期：2026-09-22。对象：Speaker 的中文及中英混输、短句桌面听写、个人 BYOK。证据来自当日读取的官方文档、模型作者仓库及论文；没有调用付费 API、上传录音或执行模型。这是待测建议，不是准确率验收，也不修改现行 ADR。


后续接入决策见 [ADR-0010](../adr/0010-select-speech-recognition-providers.md)。首版选择已核实 Base64 同步契约的 `qwen3-asr-flash`；本报告中的 Qwen-Audio-3.1 推荐仍是进一步评测候选，不代表已接入。

## 结论与候选顺序

建议保留当前 Doubao 为对照，第一批只比较 **OpenAI 与阿里两家 ASR**。先用同一批音频测原始识别，再决定默认模型与传输方式。ElevenLabs 作为第三候选；本地 Whisper 是离线方向；Deepgram、Google 暂放第二批。这个顺序针对 Speaker 的需求与接入成本，不是厂商准确率排名。

这里的 ASR 接收音频，和现有只接收文本的 Refinement Provider 是两个选择。Speaker 已有 OpenAI 文本润色，不代表已能用 OpenAI 识别语音。现行 [ADR-0009](../adr/0009-select-text-refinement-providers.md) 仍规定 Doubao 是唯一音频服务；正式增加 ASR 选项需要另立或修订决策，保持文本与音频边界分离。

| 候选 | 本次核实的能力 | 对 Speaker 的建议与未证实之处 |
| --- | --- | --- |
| OpenAI `gpt-transcribe` | 官方当前文件转写推荐；支持完整录音、流式返回文字，以及 Realtime 中已提交音频段的转写；支持上下文、关键词和多语言提示。[模型页](https://developers.openai.com/api/docs/models/gpt-transcribe) | 第一批准确性候选。中文与英文同时提示适合混输评测；尚无 Speaker 音频证据证明优于 Doubao。 |
| OpenAI `gpt-live-transcribe` | 面向实时音频增量文字；可调延迟，支持上下文、关键词、多语言提示。[模型页](https://developers.openai.com/api/docs/models/gpt-live-transcribe) | 只有需要边说边展示时才优先比较；不要把实时性当作更准确。 |
| OpenAI `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` | 仍受支持；4o 模型官方描述为相对原版 Whisper 改善语言识别与转写；支持 prompt，兼容文件文字流式返回。[4o 模型页](https://developers.openai.com/api/docs/models/gpt-4o-transcribe)、[API 参数](https://developers.openai.com/api/reference/cli/resources/audio/subresources/transcriptions/methods/create) | 可作为既有生态及成本对照；不再把它们写成官方当前默认。比较时记录完整模型 ID，mini 和 4o 不能共用准确性结论。 |
| 阿里 `qwen-audio-3.1-asr-flash` / `qwen-audio-3.1-asr-flash-streaming` | 官方当前列出短音频 HTTP 与实时 WebSocket 型号，含中文、英文及方言，上下文与词表增强。[ASR 总览](https://www.alibabacloud.com/help/en/model-studio/asr-model/) | 第一批国内 BYOK 候选。短听写优先同步 Flash；实时型号单独比较，不能仅因同系列就假设同质量。 |
| 阿里 `qwen3-asr-flash` | 仍列为可用型号；完整短音频输入；API 可用 system 内容传背景/词表，并支持返回文字流。[API](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-api-reference) | 若新型号地域或账号未开放，用它做明确版本的对照。这里的 system 是识别背景，不是通用聊天角色指令。 |
| ElevenLabs `scribe_v2` / `scribe_v2_realtime` | 官方区分文件与实时型号，列出普通话、粤语；两者支持 keyterm，词表容量与计费不同。[官方能力](https://elevenlabs.io/docs/overview/capabilities/speech-to-text) | 第三候选，值得测专有名词与自然口语。广泛语言支持不等于中文混英领先。 |
| Deepgram `nova-3` | 当前支持普通话简繁体及粤语，提供文件与流式路径；`language=multi` 的列举语言未含中文。[模型与语言](https://developers.deepgram.com/docs/models-languages-overview) | 英语/实时扩展的第二批候选。不能从“支持中文”推导“multi 模式支持中英切换”。 |
| Google `chirp_3` | Speech-to-Text V2 支持中文、文件与流式方法、短语 adaptation；能力受地域/语言组合约束。[Chirp 3](https://docs.cloud.google.com/speech-to-text/docs/models/chirp-3) | 已有 Google Cloud 项目的人可测；文档接入涉及项目、region、recognizer，对个人 BYOK 不如单 Key 路径直接，这是集成判断。 |
| 本地 Whisper / `whisper.cpp` | 本地运行，Apple Silicon 有 Metal、Core ML 等路径。[作者仓库](https://github.com/ggml-org/whisper.cpp) | 离线和隐私方向独立候选。需实测目标 Mac 的内存、耗电、首轮加载、延迟与中文质量，不承诺本地必然更准。 |

## OpenAI 接入时容易混淆的边界

截至本次调研，OpenAI Docs 已推荐 `gpt-transcribe`，并非只剩 Whisper 与 4o 两代可选。其多语言提示接受 `cmn`、`yue`、区域 `zh` 代码等；中文混英应记录明确提示策略，再与自动识别对照。文件接口当前限制 25 MB；短句通常无需分段。[文件转写](https://developers.openai.com/api/docs/guides/speech-to-text)

`gpt-transcribe` 当日模型页价格为 $0.0045/音频分钟，`gpt-live-transcribe` 为 $0.017/音频分钟；它们的任务定位与计费不同。此处仅帮助排候选，不是最终成本预算，正式接入时应重查模型权限、价格与速率限制。[文件模型](https://developers.openai.com/api/docs/models/gpt-transcribe)、[实时模型](https://developers.openai.com/api/docs/models/gpt-live-transcribe)

`whisper-1` 文件接口不支持 `stream=true`；可用于时间戳/字幕等特定需求，不是本轮准确性优先的首选。`gpt-4o-transcribe-diarize` 是多人说话分离型号，不能为单人听写机械套用，且没有普通转写模型的 prompt 能力。[API 参数](https://developers.openai.com/api/reference/cli/resources/audio/subresources/transcriptions/methods/create)

个人 BYOK 仍受官方地区支持限制；当日支持地区表未列中国大陆。不要把“用户已有一个 Key”当作地域、模型权限和网络可用性都成立，也不要静默改第三方代理目的地。[支持地区](https://developers.openai.com/api/docs/supported-countries)

## 阿里型号、地域与词表

当日官方推荐已推进到 Qwen-Audio-3.1 系列。`qwen3-asr-flash`、开源 `Qwen3-ASR-1.7B/0.6B`、`qwen-audio-3.1-asr-flash` 不是同一部署，名字和证据不能互换。Paraformer 在当前总览中已标为旧代，首次扩展不建议优先新增它。[ASR 总览](https://www.alibabacloud.com/help/en/model-studio/asr-model/)

对桌面短听写，同步 Flash 可接受 Base64/URL；长音频 Filetrans 要提交可访问 URL、轮询任务。后者会额外引入文件托管、生命周期与访问控制问题，因此不建议只为几十秒听写引入。北京、新加坡等地域 Key 与端点应明确绑定，不自动跨区。[非实时识别](https://www.alibabacloud.com/help/en/model-studio/non-realtime-speech-recognition-user-guide)

Qwen3-ASR API 明确说：混合多语言时不设置只能填一个值的 `language`。它的 system 字段可传背景与实体词表，但总览的增强能力列较粗，不能据此把该能力推及每个 realtime/filetrans 型号。实现时应按确切模型与 API 核对字段。[Qwen-ASR 参数](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-api-reference)

开源 Qwen3-ASR 也值得离线实验：作者公布 0.6B/1.7B 多语言模型，含中文方言；仓库现有 streaming 路径依赖 vLLM。它不是现成的 Swift/Apple Silicon 原生适配，不能仅凭参数量承诺 Mac 可用性。[Qwen3-ASR 作者仓库](https://github.com/QwenLM/Qwen3-ASR)

## 不能从公开材料直接得出的结论

“支持中文”“厂商自己的 WER 降低”“榜单领先”都不足以证明 Speaker 用户的中英技术混输更准。Qwen3-ASR 作者报告覆盖多语言、方言与多种测试集，能说明评测范围；其结果也不能与另一厂商不同数据集的 WER 拼成名次。[Qwen3-ASR 技术报告](https://arxiv.org/abs/2601.21337)

候选阶段应分别保留以下未知项：实际账号可用型号、目标地区往返延迟、中文混英实体正确率、静音幻觉、断网收尾、词表误插入，以及统一音频前处理后的公平比较。API 能力已核实，不等于这些验收已完成。

## 流式与整段：先分清三个维度

“流式”可能指音频边录边上传、识别时只看有限上下文，或把已经算出的文字逐步返回。这三个维度不同。完整文件也能 SSE 返回文字；音频也能先流式上传，再等松键后统一识别。因此，不能用 HTTP/WebSocket 或 `stream=true` 单独判断准确性。

| 方案 | 工作方式 | 准确性与延迟取舍 | Speaker 适用性 |
| --- | --- | --- | --- |
| 实时双向识别 | 边传音频，边产出可修订文字，最后终结 | 初字快；分句、有限右侧上下文、过早定稿可能影响结果；最终准确率仍取决于实现 | 若要实时字幕再重点做；当前只交付最终结果，不必为初字速度牺牲质量 |
| 边上传，提交后识别 | 录音期间传音频，松键 commit 后开始转写 | 上传与录音重叠，识别可利用已提交整段；并不保证与文件模式完全一致 | 优先验证，契合按键听写 |
| 录完后提交完整文件 | 松键后上传完整音频，文字可一次返回或 SSE 返回 | 服务端有完整请求，但上传耗时留在松键后；短句接入简单 | 作为准确性与集成成本基线 |
| 流式首遍加音频级二遍 | 首遍出候选，结束后结合音频/声学表示重评分 | 常见的质量与延迟折中；增加处理和可能的计费 | 优先查现有 Doubao 能力，不能假设只是打开某个通用开关 |

OpenAI 的 `gpt-transcribe` WebSocket committed-turn 路径明确等 commit 后识别，并自动利用该远端 session 之前已转写段作上下文。建议 Speaker 每个 Voice Input Session 建独立远端 session，避免跨次隐含上下文。实时模型的较高 delay 可增加上下文、可能改善 WER；实际毫秒数和收益须测。[Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)

Google 的流式结果中 `isFinal` 只表示该音频片段不会再修订，不代表整个录音结束；`stability` 估计结果是否还会变化，不是文字正确概率。接入应分别处理临时片段、片段终态与整次结束。[StreamingRecognitionResult](https://docs.cloud.google.com/speech-to-text/docs/reference/rest/v2/StreamingRecognitionResult)

二遍识别有明确的一手工程先例：Google 的 2019 年工作给流式 RNN-T 加 LAS 二遍；WeNet U2 用流式 CTC 产生候选，再用 attention decoder 重评分。它们支持“低延迟首遍 + 更完整上下文修订”的设计思路，不证明今天任何云模型在 Speaker 上能取得论文中的收益。[Google 论文](https://research.google/pubs/two-pass-end-to-end-speech-recognition/)、[WeNet U2](https://arxiv.org/abs/2012.05481)

FunASR 的服务端 SDK 也提供 `online`、`offline` 和 `2pass` 三种模式；`2pass` 先实时识别，再在句末用非流式模型修订。这是可核查的开源实现例子。它依据音频重新识别，与把首遍文字交给普通 LLM 润色不同。[FunASR 服务端文档](https://github.com/modelscope/FunASR/blob/main/runtime/docs/SDK_tutorial_online.md)

## 当前 Speaker 与 Doubao 的关系

当前 [DoubaoStreamingASRClient](../../Sources/SpeakerCore/VoiceInput/DoubaoStreamingASRClient.swift) 默认使用 `bigmodel_async`；[DoubaoStreamingExchange](../../Sources/SpeakerCore/VoiceInput/DoubaoStreamingExchange.swift) 录音中发送，结束发送最后音频帧，收到最终结果才返回。因此当前已是边录边传、最终交付，不是逐字粘贴。当前请求没有显式 `enable_nonstream`，但这不足以推断服务端默认是否做二遍。

火山官方产品介绍将流式音频输入、分句返回列为语音输入法场景；产品动态记录 `bigmodel_async` 支持非流式二遍能力。值得先查现有能力，再增加外部供应商。本轮直接 API 文档未取得正文，实施前必须重新核实资源权限、参数、默认值及结果终态；不把其他 RTC 产品的参数移植为当前 ASR 契约。[产品介绍](https://www.volcengine.com/docs/6561/1354871?lang=zh)、[产品动态](https://www.volcengine.com/docs/6561/162929?lang=en)

新增 ASR 的设计仍需维持最终结果单次交付、松键冻结 Input Target、User Cancellation 丢弃晚到结果，以及原始音频只在有界内存中存在。完整音频模式不是把录音写到磁盘的理由。输入格式需按供应商适配；OpenAI 当前 WebSocket 文档示例为 24 kHz PCM，不能将 Speaker 的 16 kHz 音频只改标签发送。[ADR-0004](../adr/0004-protect-local-sensitive-data.md)、[现行架构](../architecture.md)、[OpenAI 音频会话](https://developers.openai.com/api/docs/guides/realtime-transcription)

## 准确性优先的落地顺序

以下是针对 Speaker 的试验设计，不是已经采纳的发布门槛。

1. **先保证音频输入。** 近距离、不过载、避免削波，尽量使用无损音频和正确采样率。不要盲目叠加降噪或 AGC；Google 官方明确提醒预处理可能降低其识别精度，这不意味着所有服务都不应降噪，应按目标供应商做对照。[Google 最佳实践](https://docs.cloud.google.com/speech-to-text/docs/best-practices?hl=en)
2. **先测原始 ASR，再测整理后的可读性。** 第一轮关闭额外 LLM 润色和可关闭的语义整理，保持同一音频与统一输出约定。只看文字的 LLM 没有原始声学证据，不能可靠补回缺失音素；把错误改成通顺句不等于识别变准。这是数据边界推论，符合现有文本限定接口。
3. **按供应商内对照，再横向对照。** Doubao 当前路径对比官方整段/二遍；OpenAI 同一 `gpt-transcribe` 比较文件与 WebSocket commit；阿里比较明确版本的同步与实时型号。不同模型之间的变化不能全部归因于流式。
4. **用真实代表样本。** 建议首轮 100–200 句、每句 5–60 秒，涵盖安静/噪声、内置/外接麦、普通话口音、中英切换、缩写、数字日期、否定词、产品人名、长停顿与自我纠正。这个数量仅是试验起点。样本必须获得授权；词表调试集与保留测试集分离，避免把答案塞进提示。
5. **同时计量正确性和失败。** 中文 CER、英文 WER、混输 MER 用固定归一化规则；混输可按中文字符、英文单词计量，统一大小写、标点与数字写法，另列数字、否定、专名的正确率及静音幻觉。所有尝试进入覆盖率与失败率分母；成功样本的识别错误率需明确其条件范围，失败、空结果、漏句、截断独立报告，不只统计成功样本。[中英混输评测实例](https://www.isca-archive.org/interspeech_2024/hussein24_interspeech.pdf)
6. **用松键到最终结果衡量等待。** 记录 p50/p95、总耗时、失败率及单次费用，并做成对复验。首字更快不代表最后交付更快，也不代表更准。

当前仓库评测器面向 Doubao，已有耗时包含按音频节奏发送的等待，不能直接用作松键后延迟；尚未具备多供应商与混输 MER 的完整对照。这是实施前需要补齐的测量边界，不是本轮已完成的评测。

建议下一步先做可替换 ASR 的离线评测接口和同源音频对照，再选择是否新增用户设置。先验证 Doubao 可用二遍和 OpenAI committed-turn，随后比较阿里；在数据证明收益之前，不默认双供应商重跑所有录音，也不宣称整段识别必然更准。
