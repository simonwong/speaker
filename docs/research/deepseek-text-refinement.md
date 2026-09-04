# DeepSeek Text Refinement Contract

Last reviewed: 2026-07-18

This page records the optional text-refinement contract implemented by Speaker. Provider model names and limits can drift; recheck the primary sources before changing the adapter.

## Decision summary

DeepSeek is an optional second stage. Default Smoothing never calls it. Concise cleanup, full rewrite, and Custom Modes send only the confirmed Doubao Stage Result, the selected rule, and the Entry words of the press-time Personal Dictionary snapshot. Audio, Input Target details, and history are excluded.

Speaker uses the OpenAI-compatible chat-completions endpoint with the current Flash model, explicitly disables thinking, requests non-streaming JSON, and bounds the output. The expected content is a single non-empty `text` field.

## Request contract

The implementation sends:

- `POST https://api.deepseek.com/chat/completions`;
- `Authorization: Bearer <user API key>`;
- model `deepseek-v4-flash`;
- system and user messages that treat the transcript, refinement rule, and Personal Dictionary Entry words as data;
- `thinking.type = disabled`;
- `response_format.type = json_object`;
- `temperature = 0`;
- a bounded `max_tokens`; and
- `stream = false`.

The user message is built from labeled blocks, each one JSON string that is declared to contain data only: the refinement rule, the transcript, and — only when the Personal Dictionary snapshot has at least one Entry — the Entry words as a JSON array string. An empty dictionary omits the third block, so a request without Entries keeps the previous user-message shape. The Entry list is the full press-time snapshot rather than the Doubao capacity-truncated hotword list, because DeepSeek has no provider token budget and the snapshot is already bounded by the local dictionary.

The fixed system prompt casts DeepSeek as a dictation editor whose output is pasted where the user is typing, then states the invariants that outrank any rule as short numbered items phrased as targets rather than prohibitions: every fact, name, number, promise, and conclusion traces to the source and questions stay questions for the recipient; the text keeps the speaker's person, tone, and intent rather than replying to them; mixed Mandarin-English text keeps each segment's spoken language; a self-correction keeps the corrected wording and drops the retracted one, and obvious homophone recognition errors are repaired from context; an Entry spelling replaces only a phonetically or visually close span that already exists; and the reply is the single JSON object. The built-in concise cleanup and full rewrite rules name the dictation artifacts they remove (fillers, stutter repeats, retracted wording) and end on a checkable bound: length and sentence structure unchanged for cleanup, information scope unchanged for rewrite.

## Acceptance and fallback

A DeepSeek Stage Result replaces the Doubao text only when all of these conditions hold:

1. the local task is active and receives a successful HTTP response;
2. the first completion ends with `finish_reason = stop`;
3. the content parses as a JSON object with exactly one non-empty string field named `text`;
4. the result remains within the configured token and character bounds; and
5. the session still owns the asynchronous result.

Authentication, balance, rate limit, network, system timeout, cancellation, server, service-unavailable, filtering, truncation, tool-call, empty-output, malformed-JSON, unexpected-shape, and abnormal-expansion outcomes all preserve the confirmed Doubao Stage Result. Speaker records a stable content-free classification and never delivers provider error text or partial JSON.

User Cancellation stops local waiting and suppresses late results. It does not claim that the provider cancelled remote inference or billing.

## Privacy and credentials

The user supplies the API Key, and Speaker stores it in Keychain. The Key never enters settings files, Session Records, diagnostics, source, or release evidence.

Speaker sends the minimum text required for the selected Refinement Mode: the transcript, the rule, and the Personal Dictionary Entry words. Product privacy copy must explain that DeepSeek-dependent modes disclose transcript text and Entry words to a second provider, while Default Smoothing and all audio remain outside that seam.

## Testing and live acceptance

Deterministic adapter specifications cover the exact request shape — including the presence, JSON-string wrapping, and empty-dictionary absence of the Entry block and the fixed system-prompt clauses — success validation, every stable failure class, output bounds, User Cancellation, and Doubao fallback. A live connection probe is insufficient for semantic acceptance.

The paid provider matrix covers concise cleanup, full rewrite, Custom Mode, cancellation, invalid credentials, malformed output, truncation, and abnormal expansion. Its evidence rules are defined in the [compatibility matrix](../compatibility.md).

## Primary sources

- [DeepSeek API: create chat completion](https://api-docs.deepseek.com/api/create-chat-completion/)
- [DeepSeek JSON output](https://api-docs.deepseek.com/guides/json_mode/)
- [DeepSeek thinking mode](https://api-docs.deepseek.com/guides/thinking_mode)
- [DeepSeek error codes](https://api-docs.deepseek.com/quick_start/error_codes/)
