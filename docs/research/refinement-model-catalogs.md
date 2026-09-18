# Refinement model catalogs

Last reviewed: 2026-09-18

## Decision and scope

Speaker maintains its recommended models and defaults in the App's `RefinementProviderCatalog`. Opening Settings never downloads a model directory. The picker keeps saved model IDs, every provider accepts a manual ID, and credentials remain scoped to the provider. Recommendations and defaults change with App updates without overwriting saved selections.

The public directories below are research sources for maintaining the bundled list, not runtime dependencies. Provider-specific defaults and request compatibility are documented in [refinement-default-models.md](refinement-default-models.md).

## Candidate sources

| Source | Authentication and cost evidence | Useful fields | Meaning and limitation |
| --- | --- | --- | --- |
| [Models.dev API](https://models.dev/api.json) | The project's published example uses a plain GET without a Key or account. Open-source database; no catalog charge is described. A local unauthenticated GET returned 200 and valid JSON. | Provider namespace; model ID/name; `release_date`, `last_updated`, `modalities`, `reasoning`, `reasoning_options`, `structured_output`, `status`, limits. | Community-maintained serving metadata, not account entitlement or a guarantee that a model accepts Speaker's exact request. |
| [OpenRouter models](https://openrouter.ai/api/v1/models) | Actual unauthenticated GET returned 200. The current API reference nevertheless marks Bearer authorization required. Treat unauthenticated access as observed behavior, not an unconditional contractual promise. | `id`, `created`, `architecture`, `supported_parameters`, `expiration_date`, pricing, pagination metadata. | OpenRouter route IDs and parameters. Does not establish availability or the same model ID on a vendor's direct endpoint. |
| [OpenAI models](https://developers.openai.com/api/reference/resources/models) | Official `GET https://api.openai.com/v1/models` examples use the current OpenAI Key. No explicit model-list billing guarantee found in the cited reference; do not call it a free public API. | `id`, `created`, `owned_by`, and current schema's optional shutdown date. | Current available model objects. Creation time is not a dedicated release date; the basic list lacks the request-capability detail needed for Speaker's filter. |
| [DeepSeek models](https://api-docs.deepseek.com/api/list-models/) | Official `GET https://api.deepseek.com/models`; use the provider's authentication contract. No model-list billing promise established here. | `id`, `object`, `owned_by`. | Official supported IDs. The documented list lacks release dates and JSON/thinking capabilities, so it cannot alone rank the newest compatible models. |
| [Kimi models](https://platform.kimi.com/docs/api/list-models) | Official `GET https://api.moonshot.cn/v1/models` explicitly requires a valid Kimi China Key. No model-list billing promise established here. | `id`, `created`, `context_length`, `supports_image_in`, `supports_video_in`, `supports_reasoning`. | Useful current availability/capability hints; a reasoning flag does not distinguish optional from mandatory thinking. Account tier and region still matter. |
| [BigModel model overview](https://docs.bigmodel.cn/cn/guide/start/model-overview) | Public documentation is readable. A supported generic `GET /models` endpoint was not found in the current [complete documentation index](https://docs.bigmodel.cn/llms.txt). | Documentation classifies text, vision, image, audio, video, and embedding products. | Do not invent `/api/paas/v4/models` because Chat Completions is OpenAI-shaped. Use a public catalog or maintained list until an official discovery contract is established. |

Models.dev's [README](https://github.com/anomalyco/models.dev/blob/285557390e8b62bf7a3e17ef50b7fd0374d0fd14/README.md) distinguishes model-only facts from provider serving details and documents the public API. The [schema](https://github.com/anomalyco/models.dev/blob/285557390e8b62bf7a3e17ef50b7fd0374d0fd14/packages/core/src/schema.ts) and [generator](https://github.com/anomalyco/models.dev/blob/285557390e8b62bf7a3e17ef50b7fd0374d0fd14/packages/core/src/generate.ts) establish how provider-specific overrides become catalog entries. Neither a JSON-mode flag nor a reasoning flag proves compatibility with a particular combination of parameters.

The OpenRouter [list reference](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties) documents filters, pagination, and its model schema. Keep its `created` field separate from a verified vendor release date. A model author prefix is not a direct endpoint identity: the observed `deepseek/deepseek-v4.1-flash` route must not be converted by stripping `deepseek/`; DeepSeek's direct [current documentation](https://api-docs.deepseek.com/) instead names `deepseek-flash`.

## What pi actually does

The official `badlogic/pi-mono` URL currently redirects to `earendil-works/pi`. Its [generation script](https://github.com/earendil-works/pi/blob/main/packages/ai/scripts/generate-models.ts) fetches Models.dev, OpenRouter, and other catalogs, applies provider/model corrections, and writes generated model data for the package. This is build-time catalog generation, not proof that every app using pi performs live discovery. Its OpenRouter fetch also preserves complete OpenRouter IDs. Speaker should borrow the provider/model separation and explicit compatibility handling; pi's tool-capability filter serves an agent workflow and is inappropriate for text refinement.

## Provider mapping

Only import model metadata from the exact serving namespace. Keep built-in endpoints in Speaker code, independent of every remote URL field.

| Speaker provider | Models.dev namespace | Speaker's fixed base URL |
| --- | --- | --- |
| DeepSeek | [`deepseek`](https://github.com/anomalyco/models.dev/blob/285557390e8b62bf7a3e17ef50b7fd0374d0fd14/providers/deepseek/provider.toml) | `https://api.deepseek.com` |
| OpenAI | [`openai`](https://github.com/anomalyco/models.dev/blob/285557390e8b62bf7a3e17ef50b7fd0374d0fd14/providers/openai/provider.toml) | `https://api.openai.com/v1` |
| Kimi, China | [`moonshotai-cn`](https://github.com/anomalyco/models.dev/blob/285557390e8b62bf7a3e17ef50b7fd0374d0fd14/providers/moonshotai-cn/provider.toml) | `https://api.moonshot.cn/v1` |
| GLM, BigModel | [`zhipuai`](https://github.com/anomalyco/models.dev/blob/285557390e8b62bf7a3e17ef50b7fd0374d0fd14/providers/zhipuai/provider.toml) | `https://open.bigmodel.cn/api/paas/v4` |

`moonshotai`, `zai`, and coding-plan namespaces are different services or billing products. Kimi's official model-list documentation explicitly states that China and international platform Keys cannot be mixed. Never infer credential ownership from a model's author, display name, or third-party catalog endpoint.

## Evidence recorded

Public metadata reads on 2026-09-18:

| Request | Result |
| --- | --- |
| `GET https://models.dev/api.json`, no authorization | Local curl at 06:07:11 UTC returned HTTP 200; 4,689,946 bytes of valid JSON; 221 provider namespaces. The four mapped namespaces contained 4 DeepSeek, 48 OpenAI, 4 Kimi China, and 15 Zhipu entries. `Server: cloudflare`, `CF-Cache-Status: HIT`, `Cache-Control: public, max-age=0, must-revalidate`, and ETag were present. These counts include entries not yet filtered for Speaker compatibility. |
| Same public endpoint using `curl --compressed` | HTTP 200 with `Content-Encoding: gzip`; curl `size_download` was 463,507 bytes. A subsequent compressed request with the returned weak ETag in `If-None-Match` returned HTTP 304 with `size_download = 0`. Headers and decoded JSON are in `/private/tmp/speaker-modelsdev-compressed-headers.txt` and `/private/tmp/speaker-modelsdev-compressed-body.json`. |
| `GET https://openrouter.ai/api/v1/models`, no authorization | HTTP 200; 739,579 bytes; JSON keys `data`, `total_count`, `links`; 446 model entries. `Cache-Control: public, max-age=120, stale-while-revalidate=3600, stale-if-error=3600`; no ETag or Last-Modified observed. |
| Official pi generation script, unauthenticated raw GitHub GET | HTTP 200; 112,781 bytes; observed public catalog fetches and generated file writes. |
| Models.dev GitHub tree and fixed source files | HTTP 200; tree revision `285557390e8b62bf7a3e17ef50b7fd0374d0fd14`, not truncated. Provider mappings, schema, and generator inspected at that revision. |
| BigModel `llms.txt` | HTTP 200; 48,107 bytes. Searched for model-list discovery; no documented generic list endpoint found. This does not prove that no private or undocumented endpoint exists. |

Temporary evidence files: `/private/tmp/speaker-openrouter.json`, `/private/tmp/speaker-pi-generate.ts`, `/private/tmp/speaker-modelsdev-tree.txt`, and `/private/tmp/speaker-glm-index.txt`. They contain public metadata or source only and are not release dependencies. HTTP reachability and schema inspection do not establish live inference quality, account permissions, provider billing, or production availability.

The initial Models.dev investigation reported 403, but its error headers and body were not retained, so the rejecting layer and cause cannot be established. The later local curl request succeeded without credentials or browser impersonation; the separate web retrieval tool still reported that the URL was inaccessible. The restricted shell also failed DNS resolution before the network-enabled request succeeded. These are distinct observations, not proof of a shared cause. In particular, a Cloudflare header on the successful response does not prove that Cloudflare caused the earlier 403. The successful response headers and JSON are retained in `/private/tmp/speaker-modelsdev-headers.txt` and `/private/tmp/speaker-modelsdev-body.txt`.

## Configuration and credential boundaries

`RefinementProviderCatalog.modelIDs(for:)` owns the built-in choices. The first model is the recommendation and default. Settings appends an existing saved ID when it is absent from that list; manual IDs survive provider switching and reloading. Each provider stores one selected model, and Custom stores one endpoint configuration. The App has no remote catalog service, cache, or refresh action.

`CredentialedTextRefiner` looks up the credential account from the session's provider profile, never from its model ID. Provider/model selection is blocked during credential writes. Switching providers clears only the secure input draft; saving, replacing, or deleting a Key changes the selected provider's credential. Custom additionally binds the Key to its normalized saved endpoint. Offline scenarios exercise these behaviors with synthetic credentials and temporary storage; live availability and quality require a separately authorized provider run.
