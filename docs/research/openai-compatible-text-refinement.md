# OpenAI-compatible text refinement

Last reviewed: 2026-09-18

## Scope and evidence

Support manually selected text refinement providers while Doubao retains all audio processing. This note recommends an initial compatibility profile; documentation review does not establish live availability, account entitlement, latency, or semantic quality. No authenticated or billed requests were made.

[ADR-0003](../adr/0003-stream-doubao-and-refine-optionally.md) names DeepSeek as the optional text provider. [ADR-0009](../adr/0009-select-text-refinement-providers.md) extends that choice while preserving its text-only, bounded-output, normal-completion, Doubao-preservation, and User Cancellation invariants. [ADR-0004](../adr/0004-protect-local-sensitive-data.md) continues to own credentials and persistence.

## Registry design from pi

The primary upstream is `badlogic/pi-mono`. Its generated model registry separates provider catalogs; the public model configuration distinguishes provider endpoint/API/authentication from model ID and model capabilities. Compatibility fields include `maxTokensField`, developer-role support, and thinking format. These are concrete evidence that an OpenAI-shaped endpoint is not one universal request contract. See [generated registry](https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/ai/src/models.generated.ts), [model configuration](https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/docs/models.md), and [compatibility types](https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/ai/src/types.ts).

Recommendation: use a small local provider/model catalog with explicit request profiles, plus a documented Custom profile. Do not import pi's agent runtime, tool support, OAuth flows, discovery, or fallback behavior. Vendor documentation takes precedence over catalog model names.

## Initial provider choices

These are conservative non-thinking candidates, not a list of each vendor's newest models. Model selection can initially contain one eligible model where the current documentation establishes only one.

| Provider | Full Chat Completions endpoint | Suggested initial model IDs | Request differences |
| --- | --- | --- | --- |
| DeepSeek | `https://api.deepseek.com/chat/completions` | `deepseek-flash`, `deepseek-v4-pro` | `thinking.type = disabled`; `max_tokens`; preserve existing temperature `0` |
| OpenAI | `https://api.openai.com/v1/chat/completions` | `gpt-4.1-mini`, `gpt-4.1` | `max_completion_tokens`; omit `thinking` and `reasoning_effort`; omit temperature unless a model profile needs it |
| Kimi, China API | `https://api.moonshot.cn/v1/chat/completions` | `kimi-k2.6` | `thinking.type = disabled`; `max_tokens`; omit fixed sampling fields |
| GLM, BigModel API | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | `glm-5.2` | `thinking.type = disabled`; `max_tokens`; omit `reasoning_effort` |
| Custom | User-entered HTTPS base URL | User-entered model ID | A limited legacy Chat Completions profile using `max_tokens`; no vendor-specific thinking field or temperature |

DeepSeek's current [model table](https://api-docs.deepseek.com/quick_start/pricing/) lists `deepseek-flash` and `deepseek-v4-pro`. The existing `deepseek-v4-flash` name remains accepted but routes to DeepSeek-V4.1-Flash. Its [Chat Completions contract](https://api-docs.deepseek.com/api/create-chat-completion/) exposes `thinking`, `max_tokens`, JSON mode, and non-streaming requests. Existing settings should retain their supported identity unless an explicit migration is implemented.

OpenAI documents [GPT-4.1 Mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini) as operating without a reasoning step; [GPT-4.1](https://developers.openai.com/api/docs/models/gpt-4.1) is also a non-reasoning model. The [request reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) deprecates `max_tokens` in favor of `max_completion_tokens`; the former is incompatible with o-series models. The latter includes reasoning tokens where applicable. This is why token-field selection belongs in the model profile.

Kimi's [current model list](https://platform.kimi.com/docs/models) marks K2.5 and moonshot-v1 retired on 2026-08-31 and K2 retired on 2026-05-25. Its [parameter reference](https://platform.kimi.com/docs/api/models-overview) permits thinking to be disabled for K2.6; its non-thinking temperature is fixed at `0.6`, and the docs recommend omitting fixed sampling fields. K3 and K2.7 Code always think, so they do not meet this initial profile. The [China quickstart](https://platform.kimi.com/docs/get-api-key) uses `.cn`; the [international quickstart](https://platform.kimi.ai/docs/overview) uses `.ai`. Never silently change regions or try another region after authentication failure.

BigModel's [Chat Completions reference](https://docs.bigmodel.cn/api-reference/%E6%A8%A1%E5%9E%8B-api/%E5%AF%B9%E8%AF%9D%E8%A1%A5%E5%85%A8) lists the endpoint, `glm-5.2`, `max_tokens`, and `json_object` output. Its [thinking guide](https://docs.bigmodel.cn/cn/guide/capabilities/thinking) explicitly demonstrates disabling thinking on GLM-5.2 and states GLM-5.3/5.3-FLASH reject that setting. Other listed model IDs need individual profile validation before inclusion; a generic model enum is not proof of every parameter combination. BigModel's standard API is distinct from coding-plan or international Z.AI endpoints.

## Shared text request and acceptance

Recommendation: send only `model`, two string-content messages (`system`, `user`), `stream = false`, `response_format.type = json_object`, a bounded token field, and the selected model's required controls. The system prompt must explicitly require JSON. Send the confirmed Doubao Stage Result, Refinement Mode instruction, and Personal Dictionary Entry words; exclude audio, images, tools, Input Target details, and history. Send no stop sequence or automatic repair request.

JSON mode guarantees neither Speaker's schema nor completion. OpenAI distinguishes JSON syntax from strict schema adherence and requires handling refusals and truncation; see [structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs). Kimi likewise documents `json_object`, prompt instructions, and `length` truncation in its [JSON guide](https://platform.kimi.com/docs/guide/use-json-mode-feature-of-kimi-api).

Recommendation: accept a result only after successful HTTP status, `finish_reason = stop`, no explicit refusal/tool call, and exactly one non-empty `text` string in the parsed content object. OpenAI's [response contract](https://developers.openai.com/api/reference/resources/chat) distinguishes normal stop, length, filtering, and tool/function calls. Unknown finish reasons fail closed. Preserve the Doubao Stage Result for every explicit failure; never deliver explanatory provider text, reasoning text, partial JSON, or late results after User Cancellation.

## Local bounds and endpoint security

Provider token limits are not transport memory bounds. The inspected existing client uses a 2,048-token request limit and a result expansion check of `max(4096, sourceText.count * 4)`, but `URLSession.data(for:)` collects the response before those checks. Recommendation: bound the encoded request and accumulated response in bytes before JSON decoding, including non-success bodies, and retain the semantic expansion limit. A 256 KiB request and 1 MiB response are reasonable initial application limits to evaluate against existing dictionary and transcript fixtures; these are proposed Speaker limits, not vendor guarantees. Do not silently truncate input.

Recommendation: require an HTTPS base URL (append `/chat/completions`) with host, no embedded username/password, query, or fragment. Bind each Keychain credential to its provider or exact Custom endpoint identity; changing the endpoint invalidates verification and must not silently reuse a credential saved for another destination. Snapshot provider, model, endpoint, and credential ownership for each Voice Input Session. No automatic cross-provider failover.

Apple's [redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)) can refuse a redirect by returning `nil` in default or ephemeral sessions. Recommendation: reject every redirect for this text transport, including same-host redirects, so neither transcript body nor credential leaves the configured endpoint through redirect behavior. Use an ephemeral session with caching/cookies disabled; retain normal TLS verification. Background sessions are unsuitable for this rule because Apple documents that they always follow redirects.

## Compatibility and acceptance limits

The Custom profile covers servers accepting bearer authentication, string `system`/`user` messages, non-streaming Chat Completions, `max_tokens`, and JSON object responses. It does not imply support for all OpenAI models, Responses-only models, always-thinking models, Anthropic-native APIs, coding subscriptions, Azure deployment/query conventions, local HTTP servers, or arbitrary extra parameters. Do not retry with changed fields or route to another provider after rejection.

Offline specifications should verify each catalog request, credential isolation, endpoint changes, redirect refusal, bounded response accumulation, model-switch verification invalidation, failure preservation, and cancellation ownership. Live connection checks need explicit user action and may incur cost; a successful synthetic check verifies the profile, not dictation quality. Semantic acceptance still requires approved provider samples for concise cleanup, full rewrite, Custom Mode, mixed languages, and Personal Dictionary preservation.
