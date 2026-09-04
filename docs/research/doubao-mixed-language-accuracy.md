# 豆包流式 ASR 中英混说准确率控制

最后核对：2026-09-01（仅查阅火山引擎第一方公开文档；未调用供应商接口）

## 结论

- **官方明确支持“中英文”及默认“中英文模型”，但没有明确写出“句内中英混说 / code-switch”或公布专项指标。** 因而普通话夹英文处于官方双语模型的合理目标范围，但公开合同不足以承诺任意切换位置、英文专名或缩写的效果。[产品简介](https://www.volcengine.com/docs/6561/1354871) [API 参数表](https://docs.volcengine.com/docs/6561/1354869?lang=zh)
- **两代双向流式资源都归入上述中英文能力；Speaker 应优先评估 ASR 2.0。** 2.0 时长版为 `volc.seedasr.sauc.duration`、并发版为 `volc.seedasr.sauc.concurrent`；1.0 对应 `volc.bigasr.sauc.duration` / `volc.bigasr.sauc.concurrent`。请求内 `model_name` 只有 `bigmodel`，没有另一个公开的 `model_version` 选择器；版本由 `X-Api-Resource-Id` 选择。官方没有声称 2.0 的“中英混说”一定优于 1.0，故优先 2.0 是采用新模型的工程建议，不是效果保证。[API 参数表](https://docs.volcengine.com/docs/6561/1354869?lang=zh)
- **`bigmodel_async` 不接受 `audio.language`。** 该字段属于其他接口模式；在双向流式上设置 `zh-CN`/`en-US` 不是合法的中英切换调优手段。默认双向流式本身就是中英文模型。[API 参数表](https://docs.volcengine.com/docs/6561/1354869?lang=zh)
- **Speaker 不发送应用或聊天前文。** Voice Input Session 在按下快捷键时已经开始向豆包发送完整请求，而 Input Target 到松开时才冻结；读取并发送目标应用文本既不符合现有时序，也扩大数据披露。当前优化不引入这项能力。

## `bigmodel_async` 相关参数与兼容性

下表中的默认值、限制和效果均来自当前官方 API 表；“建议”列是本仓库建议。

| 字段 | 官方事实（默认/限制） | 对中英混说的判断与建议 |
| --- | --- | --- |
| `X-Api-Resource-Id` | 1.0：`volc.bigasr.sauc.duration` / `.concurrent`；2.0：`volc.seedasr.sauc.duration` / `.concurrent`。 | **建议**优先 2.0；这是唯一公开的 ASR 大版本选择。 |
| `request.model_name` | 必填，当前只有 `bigmodel`。 | 不要虚构 `model_version`；`ssd_version` 也不是识别模型版本选择器。 |
| `audio.language` | `bigmodel_async` 不支持该字段；字段空时使用默认中英文模型。 | 应省略；不能用它控制句内语言切换。 |
| `enable_itn` | 默认 `true`；把口语数字等规整为书面形式。 | 改变书写形式，不是语义纠错；英文缩写/产品名错误通常不能靠 ITN 修复。 |
| `enable_punc` | 默认 `true`。 | 改善可读性，不修复错误词义。 |
| `enable_ddc` | 默认 `false`；会删除或修改停顿词、语气词、语义重复词等，使文本顺滑。产品表注明顺滑支持中文、英文。 | **建议**若目标是忠实听写默认关闭；若目标是可读输入再单独评估。它会改写/删除内容，不能当作可靠语义纠错器。 |
| `enable_accelerate_text` / `accelerate_score` | 前者默认 `false`，开启会降低首字准确率；后者默认 `0`，范围 0–20，越大越快。 | 准确率优先时保持关闭/0。 |
| `vad_segment_duration` | 默认 3000 ms；仅决定语义切句的最大静音阈值，不决定 `definite`。配置 `end_window_size` 后失效。 | 较长上下文可能有利于模型消歧；不要把它误当识别增强。 |
| `end_window_size` | 默认 800 ms，最小 200 ms；配置后停用语义分句，按静音强制判停并输出 `definite`。 | 过短会切碎跨语言短语，属于准确率风险；除低延迟要求外保留默认并以真实 code-switch 样本验证。 |
| `force_to_speech_time` | 最小 1 ms；须配合 `end_window_size`；文档推荐 1000 ms，并明确“可能影响识别准确率”。 | 不为准确率主动开启；只在短句过早判停问题明确时评估。 |
| `show_utterances` / `result_type` | `show_utterances` 返回停顿、分句、分词；`result_type` 默认 `full`，`single` 为不重复历史分句的增量结果。 | 只改变可观测/返回形态，不提升识别；但 A/B 时应打开分句信息以区分切句错误与词错误。 |
| `enable_lid` | 仅 nostream 和优化双向流式；默认 `false`；async 开启后会默认 VAD 800 ms。它给确定分句附语种标签。 | 这是检测/标注，不是切换识别模型的准确率开关；可能因强制 VAD 改变切句。 |

音频契约也会影响效果：`format` 必填，支持 pcm/wav/ogg/mp3；pcm/wav 内部须 pcm_s16le；`codec` 默认 `raw`（ogg 必须 opus）；`rate` 默认且仅支持 16000；`bits` 默认且仅支持 16；`channel` 默认 1。官方另建议双向流式按约 200 ms 分包，包过大或过小都会影响性能。[API 参数表](https://docs.volcengine.com/docs/6561/1354869?lang=zh)

## 热词与替换词

- `request.corpus.boosting_table_name` / `boosting_table_id`：引用平台热词表；`correct_table_name` / `correct_table_id`：引用替换词表。请求级 `context.hotwords` 的优先级高于热词表。直接热词的准确嵌套、JSON-string 形态、100-token 上限及文档示例歧义已在 [doubao-hotwords.md](doubao-hotwords.md) 记录，此处不重复。
- 官方热词平台仅支持中英文优化；一请求只生效一张词表。词表中每词少于 10 个字，权重 1–10、默认 4；数字/特殊符号应改写成对应汉字，避免单字、无实体意义常见词或高频口语词，否则可能负向影响整体效果。[热词指南](https://docs.volcengine.com/docs/6561/155739?lang=zh)

## 参数调不好的边界

1. **热词不是强制替换。** 官方 FAQ 说明它本质上是在解码后增强特定词概率，仍受基础模型能力、口音、噪声和训练数据场景覆盖影响；即使已加热词也可能不生效。官方只给出“非特别偏僻热词召回率绝对提升 5 点以上”的概括，并非逐词保证。[模型效果 FAQ](https://docs.volcengine.com/docs/6561/155743?lang=zh)
2. **ITN、标点、DDC 主要控制输出形式。** ITN 规整数字，标点补标点，DDC 删除/修改不流畅内容；三者都没有官方承诺可恢复声学上已识错、跨语言歧义选错或模型未知的英文实体。错误语义若不在热词可偏置范围内，只能依靠已知稳定映射的替换词或 Speaker 的后续文本精修，而不是继续调这些格式参数。
3. **过早判停会丢上下文。** `enable_accelerate_text` 官方明确降低首字准确率；`force_to_speech_time` 可能影响准确率；过小 `end_window_size` 会让分句更碎。它们是延迟—准确率权衡，不是修复错误语义的开关。[API 参数表](https://docs.volcengine.com/docs/6561/1354869?lang=zh)
4. **官方缺口。** 没有公开 Mandarin-English code-switch 专项 WER/CER、切换点基准、英文大小写/缩写保证，也没有承诺 2.0 相对 1.0 的混说增益。本次研究未发起任何供应商调用。 因此仓库提供离线评测工具 `SpeakerAccuracyEvaluator`（指标由 `SpeakerAccuracyMetricsSpecs` 确定性覆盖），用用户自备的 16 kHz 单声道样本与参考文本对 1.0/2.0、语义顺滑开/关、是否附带 Personal Dictionary Entry 逐变体计算 CER 与拉丁词元 WER；真实请求需显式付费确认，默认报告不含任何文本。用法与脱敏规则见 [development.md](../agents/development.md#offline-accuracy-evaluation)。

## 建议优先级（非官方事实）

1. 选择 `volc.seedasr.sauc.*`（2.0），保持 `model_name="bigmodel"`，省略 `language`。
2. 对可预知英文实体使用少量高优先级直接热词。
3. 保持 `enable_itn=true`、`enable_punc=true`；Default Smoothing 开启 `enable_ddc`，需要 DeepSeek 的 Refinement Mode 关闭 `enable_ddc`。
4. 同一份个人词库词条同时随需要 DeepSeek 的 Refinement Mode 进入精修提示词，作为纯文本数据要求按词条拼写纠正发音相近片段、并禁止翻译中英混说文本；这是热词概率偏置失效时的第二道纠错，契约见 [deepseek-text-refinement.md](deepseek-text-refinement.md)。
5. 判停先用默认 800 ms；若中英短语被切碎，优先延长窗口或不显式配置 `end_window_size` 以保留语义分句，再做延迟验收。

## 第一方来源

- [大模型流式语音识别 API / 参数表](https://docs.volcengine.com/docs/6561/1354869?lang=zh) — endpoint、资源、全部请求参数、默认值与兼容限制。
- [语音识别大模型产品简介](https://www.volcengine.com/docs/6561/1354871) — 双向流式语种与能力矩阵。
- [热词指南](https://docs.volcengine.com/docs/6561/155739?lang=zh) — 管理热词表的范围、格式与负向影响警告。
- [模型效果 FAQ](https://docs.volcengine.com/docs/6561/155743?lang=zh) — 热词增益与基础模型边界。
