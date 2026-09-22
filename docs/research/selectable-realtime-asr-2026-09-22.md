# Selectable streaming and complete-audio recognition

Research date: 2026-09-22. Sources below were opened or fetched from the provider's official documentation and source repositories. No credentials, recordings, paid requests, or provider acceptance were used. The wire contracts establish implementation scope; they do not establish accuracy, account availability, latency, or billing results.

## Product boundary

Both OpenAI and Qwen support streaming audio. The initial complete-audio implementation was a scope choice in [ADR-0010](../adr/0010-select-speech-recognition-providers.md), not a provider limitation. A recognition-method choice can retain the complete-audio adapters and add WebSocket adapters. Streaming upload and incremental transcript display are separate capabilities. Speaker can stream audio while recording and still deliver only one confirmed Stage Result after shortcut release.

For OpenAI, `gpt-live-transcribe` produces partial text while audio arrives; `gpt-transcribe` over WebSocket starts transcription after a committed turn. A complete-file response streamed over HTTP is a third workflow. These modes must not share an accuracy claim. Higher live-model delay can provide more context, but requires representative evaluation. [OpenAI transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)

Qwen's `qwen3-asr-flash-realtime` supports both server VAD and manual utterance boundaries. Manual mode fits push-to-talk: stream chunks during capture, then commit at release. Do not promise pre-release partial text in manual mode: the documented interaction sequence triggers recognition at commit. [Qwen interaction flow](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-realtime-interaction-process)

## Connections and model selection

| Provider | Connection | Authentication | Input |
| --- | --- | --- | --- |
| OpenAI | `wss://api.openai.com/v1/realtime?intent=transcription` | `Authorization: Bearer <key>` | Raw PCM16, mono, 24 kHz |
| Qwen Beijing | `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime` | `Authorization: Bearer <Beijing key>` | Raw PCM16LE, mono, 16 kHz |
| Qwen Singapore | `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime` | `Authorization: Bearer <Singapore key>` | Raw PCM16LE, mono, 16 kHz |

The OpenAI transcription-specific query is implemented by `_prepare_websocket_url` in the [official Agents SDK source](https://github.com/openai/openai-agents-python/blob/main/src/agents/voice/models/openai_stt.py). It waits for session creation, sends `session.update`, and waits for configuration acknowledgement. The current SDK accepts both GA `session.*` and older `transcription_session.*` acknowledgement names. Use the GA request schema below. The [current Realtime SDK](https://github.com/openai/openai-python/blob/main/src/openai/resources/realtime/realtime.py) and [WebSocket guide](https://developers.openai.com/api/docs/guides/voice-websockets?api=realtime) use Bearer authentication without requiring the old `OpenAI-Beta` header. Do not confuse the separate GPT-Live `/v1/live/sessions` protocol with Realtime transcription.

Qwen recommends workspace-specific domains but explicitly retains the classic domains above. Beijing and Singapore keys differ. Both regions list `qwen3-asr-flash-realtime`; the stable alias currently points to the 2025-10-27 snapshot, while 2026-02-10 is a separate newer snapshot. `qwen-audio-3.1-asr-flash-streaming` uses a different protocol and cannot be added by changing only this adapter's model string. [Qwen endpoints](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-realtime-interaction-process), [models and raw PCM examples](https://www.alibabacloud.com/help/en/model-studio/real-time-speech-recognition-user-guide)

## OpenAI wire contract

After session creation, send this application-specific configuration and wait for `session.updated` before uploading:

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": {"type": "audio/pcm", "rate": 24000},
        "transcription": {
          "model": "gpt-live-transcribe",
          "prompt": "Technical dictation. Preserve the spoken terms.",
          "keywords": ["Speaker", "SwiftUI"]
        },
        "turn_detection": null
      }
    }
  }
}
```

Omit optional context when empty. `keywords` entries must exclude angle brackets and line breaks. The live model accepts plural `languages`; do not send singular `language` alongside it. Unspecified language is appropriate when Speaker has no explicit language preference. These fields and the example structure follow the [model-specific guide](https://developers.openai.com/api/docs/guides/realtime-transcription).

Send raw audio, not a WAV header. Speaker's existing 16 kHz stream must be resampled; changing the rate label corrupts playback speed and recognition. The protocol accepts only 24 kHz for `audio/pcm`. Chunks are JSON text messages with `type: "input_audio_buffer.append"` and `audio` containing Base64 bytes. Each append is bounded by 15 MiB and has no acknowledgement. After successful local capture validation, send `{"type":"input_audio_buffer.commit"}` once. Empty commits are errors. Do not send `response.create`: transcription commit does not require an assistant response. `session.updated` contains effective configuration but does not echo the client's `event_id`. [Client events reference](https://developers.openai.com/api/reference/resources/realtime/client-events)

The final event is `conversation.item.input_audio_transcription.completed`, with `item_id`, `content_index`, and `transcript`. Match it to the committed item; use the final transcript instead of concatenating final text onto partial text. Different turns can finish out of order. Live deltas carry `delta` rather than Qwen's `text`/`stash`. [Transcription events](https://developers.openai.com/api/docs/guides/realtime-transcription)

Documentation discrepancy: the live guide explicitly documents five `delay` levels for `gpt-live-transcribe`, while the generic reference's delay description still names only `gpt-realtime-whisper`. [ADR-0011](../adr/0011-select-the-speech-recognition-method.md) follows the model-specific guide and selects `high` to favor additional audio context. The implementation therefore adds `delay: "high"` to the minimal configuration above. Its actual latency and quality remain subject to approved live validation.

## Qwen wire contract

After connection, send a unique `event_id` with each client event. Configure manual boundaries, then wait for `session.updated`:

```json
{
  "event_id": "speaker-configuration-1",
  "type": "session.update",
  "session": {
    "input_audio_format": "pcm",
    "sample_rate": 16000,
    "input_audio_transcription": {
      "corpus": {"text": "Technical vocabulary: Speaker, SwiftUI."}
    },
    "turn_detection": null
  }
}
```

`input_audio_transcription.corpus.text` accepts context up to 10,000 tokens. Omit a forced language for automatic recognition. Append Base64 PCM chunks with `input_audio_buffer.append`; no append ACK is returned. Manual append events have a 15 MiB limit. At validated release, send `input_audio_buffer.commit`, followed by `session.finish`. Both carry unique event IDs. These fields are from the English [client-events reference](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-realtime-client-events), including its directly fetched HTML; translated copies may omit newer context fields.

Track `input_audio_buffer.committed.item_id`. Intermediate `conversation.item.input_audio_transcription.text` events carry a cumulative confirmed `text` prefix and revisable `stash` suffix. A preview replaces the current item's text with `text + stash`; it does not append repeated prefixes. Only `.completed.transcript` is final for that item. `.failed` is an explicit recognition failure with nested `error`. `session.finished` means all recognition is complete. Preserve only safe identifiers and codes, never raw error messages. [Server-events reference](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-realtime-server-events)

Success requires the expected final item and the session completion signal. `session.finished` can arrive without transcript when no speech is detected; do not convert an earlier partial into a final result. Closing before proper finish can discard pending audio. Qwen3's session connection is not reusable after completion. [Interaction flow](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-realtime-interaction-process), [connection lifecycle](https://www.alibabacloud.com/help/en/model-studio/real-time-speech-recognition-user-guide)

## Speaker implementation and acceptance constraints

These are application requirements, not additional provider claims:

- Freeze provider, model, region, recognition method, dictionary, and credential namespace at Voice Input Session start. A settings change affects the next session.
- Use one remote session per Voice Input Session. Keep refinement text-only and commit delivery once to the Input Target captured at release.
- Streaming uploads audio before stop; it cannot promise complete-audio mode's pre-upload local validation. Gate the final commit and accepted result on successful local capture completion. On capture failure or User Cancellation, close the connection and discard late events.
- Bound queued PCM, encoded chunks, individual received messages, cumulative text, and item count. Preserve sample continuity across resampling chunk boundaries. Do not truncate oversized input or reconnect and replay implicitly.
- Keep existing conservative application recording limits until measured long-turn acceptance supports changing them. The consulted references do not establish an exact maximum manual-turn duration for these two selected models; do not label Speaker's limit as the provider's maximum.
- Saving a key or switching methods makes no provider request. Verify selection persistence, correct credential ownership, upload before release, ACK rejection, failed capture, cancellation, wrong-item results, missing final results, and graceful completion using deterministic transport specifications.
- Before claiming real support is accepted, separately test authorized accounts in each region with approved audio: Chinese/English switching, names, numerals, silence, pauses, recording limits, connection loss, and cancellation. Compare final character/word errors and entity errors against the complete-audio baseline on the same recordings. Partial latency is not final accuracy.
