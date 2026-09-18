# Low-cost Refinement Provider defaults

Last reviewed: 2026-09-18

## Decision

Use `deepseek-v4-flash`, `gpt-5.6-luna`, `kimi-k2.6`, and `glm-5.3-flash` as the built-in defaults. DeepSeek keeps its compatibility ID, which currently routes to the latest Flash backend. These choices preserve Speaker's final JSON Chat Completions contract; GLM 5.3 Flash uses mandatory low-effort thinking. Preserve saved model IDs and the legacy DeepSeek profile. A newer flagship is not automatically a suitable default for short text refinement.

| Provider | Recommended default | Current price per million tokens | Optional choices |
| --- | --- | --- | --- |
| DeepSeek | `deepseek-v4-flash` | CNY 1 input / 4 output off-peak; CNY 2 / 8 peak. Cached input CNY 0.02 / 0.04 respectively. | `deepseek-flash` is the current provider alias. |
| OpenAI | `gpt-5.6-luna` | USD 0.20 input / 1.20 output / 0.02 cached input for ordinary context sizes. | `gpt-5.6-terra` for deliberate higher-cost use. |
| Kimi China | `kimi-k2.6` | Exact current price not verified: the official pricing page's extracted content omitted its price table. | No additional default recommended without a verified cost advantage and matching request contract. |
| GLM China | `glm-5.3-flash` | CNY 0.8 input / 2.8 output / 0.23 cached input. | `glm-4.7-flash` remains a free alternative; `glm-4.7-flashx`: CNY 0.5 input / 3 output / 0.1 cached input; `glm-5.2`: CNY 8 / 28 / 2. |

Prices above come from the [OpenAI Luna model page](https://developers.openai.com/api/docs/models/gpt-5.6-luna), current [DeepSeek China pricing table](https://api-docs.deepseek.com/zh-cn/quick_start/pricing/), [Kimi pricing page](https://platform.kimi.com/docs/pricing/chat), and [BigModel pricing table](https://docs.bigmodel.cn/cn/guide/start/pricing). BigModel describes cache storage separately as temporarily free; that does not make paid model input/output free. These are published prices, not measured bills or a promise of unlimited access.

## DeepSeek

`deepseek-flash` currently serves DeepSeek-V4.1-Flash. The retired V4 Flash model IDs remain accepted and route to it at Flash pricing. Preserve the legacy ID as the default without a settings migration; offer the current alias as an explicit alternative. The current pricing page explicitly retains V4 Pro service after September 14, overriding the earlier retirement plan in the September 10 announcement. Peak periods are Beijing weekdays 09:00–12:00 and 14:00–18:00. [Models and pricing](https://api-docs.deepseek.com/zh-cn/quick_start/pricing/)

The current API documents `POST /chat/completions`, `thinking.type=disabled`, `response_format.type=json_object`, `max_tokens`, and temperature 0 in non-thinking mode. Speaker's fixed prompt already specifies JSON and its required text field. No request-shape change is needed for this default. [Chat Completions reference](https://api-docs.deepseek.com/api/create-chat-completion/)

## OpenAI

The public model ID is `gpt-5.6-luna`. OpenAI positions it for cost-sensitive workloads and documents Chat Completions, structured output, and `none` reasoning. Its ordinary text rates are USD 0.20 input, 0.02 cached input, and 1.20 output per million tokens. [Model and pricing](https://developers.openai.com/api/docs/models/gpt-5.6-luna)

Speaker keeps its JSON Chat Completions endpoint and explicitly sends `reasoning_effort: none` with `max_completion_tokens`. It omits temperature. This preserves the low-latency, non-thinking role instead of inheriting the family's medium reasoning default. Only reviewed GPT-5.6 aliases receive this setting; older or unknown manual IDs and Custom endpoints retain their existing profile. [GPT-5.6 migration guidance](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.6), [Chat Completions parameters](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)

## Kimi China

Keep `kimi-k2.6`: it explicitly supports `thinking.type=disabled` and the China endpoint `https://api.moonshot.cn/v1/chat/completions`. Keep temperature omitted: its non-thinking temperature is fixed at 0.6 and other supplied values are rejected. `max_tokens` is supported. [K2.6 guide](https://platform.kimi.com/docs/guide/kimi-k2-6-quickstart)

The official API demonstrates K2.6 with `response_format.type=json_object`; Speaker's system/user JSON instructions satisfy the documented requirement. [Chat Completions reference](https://platform.kimi.com/docs/api/chat)

Kimi K3 is newer but always reasons; it cannot satisfy the current non-thinking profile. [K3 guide](https://platform.kimi.com/docs/guide/kimi-k3-quickstart) The current catalog lists K3, K2.7 Code, K2.7 Code Highspeed, and K2.6. K2.5 and moonshot-v1 retired on August 31, 2026; K2, including Turbo variants, retired on May 25, 2026. Do not restore those older cheap-looking IDs or invent a Kimi Flash model. [Current model list](https://platform.kimi.com/docs/models)

## GLM China

The selected default `glm-5.3-flash` supports structured JSON output at the existing China endpoint. [GLM-5.3-Flash model guide](https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash)

`glm-4.7-flash` is a documented text model with JSON output at Speaker's existing `https://open.bigmodel.cn/api/paas/v4/chat/completions` endpoint. Its current guide specifies 200K context and 128K maximum output. [Model guide](https://docs.bigmodel.cn/cn/guide/models/free/glm-4.7-flash) The China API lists both `glm-4.7-flash` and `glm-4.7-flashx`, accepts `max_tokens`, and documents `response_format.type=json_object`. [Chat Completions reference](https://docs.bigmodel.cn/api-reference/模型-api/对话补全)

The China thinking contract supports disabling thinking for GLM-4.5-and-later models except the new mandatory-thinking models; it explicitly demonstrates `glm-5.2` with `thinking.type=disabled`. [China thinking guide](https://docs.bigmodel.cn/cn/guide/capabilities/thinking) The same vendor's GLM-4.7 series guide groups Flash and FlashX with 4.7, and its thinking-mode guide explicitly documents disabling thinking for that series. These corroborate the 4.7 Flash request profile; no China inference was executed. [4.7 series](https://docs.z.ai/guides/llm/glm-4.7), [thinking modes](https://docs.z.ai/guides/capabilities/thinking-mode)

GLM-5.3-Flash is newer and inexpensive at CNY 0.8 input / 2.8 output / 0.23 cache hit per million tokens, but `thinking.type=disabled` is explicitly rejected. Speaker selects it as the GLM default with `thinking.type=enabled`, `reasoning_effort=low`, and an 8,192-token completion budget to leave room for reasoning and the final answer. The adapter reads only `message.content`; `reasoning_content` is ignored, and truncation or a missing final answer remains a failure. Do not infer `glm-5-flash` or `glm-5.2-flash` from naming patterns; neither is established by the inspected official catalog/reference. [Current prices](https://docs.bigmodel.cn/cn/guide/start/pricing), [mandatory-thinking restriction](https://docs.bigmodel.cn/cn/guide/capabilities/thinking)

## Evidence boundary

Official pages were retrieved on September 18, 2026 and contain current September model changes. Most pages expose no revision timestamp, so retrieval date does not establish their exact last-update date. The recommendations follow their published API contracts and prices; they do not establish account entitlement, latency, semantic refinement quality, or live inference success. No credentials were read and no inference requests were sent. Existing saved selections remain governed by [ADR-0009](../adr/0009-select-text-refinement-providers.md).
