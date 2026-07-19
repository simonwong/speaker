# Doubao Streaming ASR Contract

Last reviewed: 2026-07-15

This page records the provider contract implemented by Speaker. It supersedes the initial recording-file HTTP proposal that existed before the streaming adapter landed.

## Decision summary

Speaker uses Doubao's optimized bidirectional `bigmodel_async` WebSocket. It sends audio while the user is speaking and marks the last frame when recording ends. The WebSocket starts with an HTTP upgrade, so authentication still occurs in HTTP request headers.

Speaker supports the current-console single API Key contract. It does not support the legacy APP ID plus Access Token credential pair.

## Credentials and identifiers

| Value | Role | Secret | Speaker behavior |
| --- | --- | ---: | --- |
| API Key / APP Key | Current-console credential sent as `X-Api-Key` | Yes | Stored in Keychain and sent during upgrade |
| APP ID | Legacy application identifier | No by itself | Unsupported |
| Access Token | Legacy credential paired with APP ID | Yes | Unsupported |
| Resource ID | Activated model and billing resource sent as `X-Api-Resource-Id` | No | User-selectable from supported resources |
| Request/Connect ID | Per-connection diagnostic UUID | No | Generated locally and retained only as safe metadata |

An API Key is not an IAM AK/SK, APP ID, Access Token, or Resource ID. The selected Resource ID must match a resource activated for the user's API Key.

## Endpoint and resource contract

Speaker connects to:

```text
wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async
```

The supported resource identifiers are:

- `volc.seedasr.sauc.duration` — streaming model 2.0, duration billing;
- `volc.seedasr.sauc.concurrent` — streaming model 2.0, concurrency billing;
- `volc.bigasr.sauc.duration` — streaming model 1.0, duration billing; and
- `volc.bigasr.sauc.concurrent` — streaming model 1.0, concurrency billing.

The upgrade carries the API Key, Resource ID, request/connect identifiers, and sequence metadata. After connection, the adapter sends the provider's binary protocol: one full client request followed by audio-only frames with explicit sequence and final-frame semantics.

## Audio and text behavior

- Microphone input is converted in memory to 16 kHz, 16-bit, mono PCM.
- Audio is placed in a bounded stream and sent in paced chunks; no normal audio file is created.
- ITN, punctuation, and semantic smoothing are enabled for Default Smoothing.
- Personal Dictionary Entries accompany the request as direct hotwords at `request.corpus.context`; the exact shape and current capacity are recorded in [Doubao Direct Hotword Contract](doubao-hotwords.md).
- Sender and receiver run concurrently so explicit provider errors can end recording early.
- User Cancellation closes the local task and suppresses late frames or results. It does not claim that remote work or billing stopped.

Doubao's ASR controls support transcription cleanup, punctuation, normalization, context, and hotwords. They are not a general natural-language rewrite interface. Stronger Refinement Modes use the separate DeepSeek text seam after a confirmed Doubao Stage Result.

## Diagnostics and acceptance

Runtime diagnostics retain only content-free transport phase, stable error class, request identifiers, HTTP status, and WebSocket close code. They exclude audio, transcript text, provider free-form messages, and credentials.

A successful connection probe proves credential and resource reachability only. Production acceptance requires the paid provider matrix defined in the [compatibility matrix](../compatibility.md).

## Primary sources

- [Doubao streaming speech recognition WebSocket](https://www.volcengine.com/docs/6561/1354869?lang=zh)
- [Doubao API Key usage](https://www.volcengine.com/docs/6561/1816214?lang=zh)
- [Doubao hotword guidance](https://www.volcengine.com/docs/6561/155739?lang=zh)
- [Doubao speech product overview](https://www.volcengine.com/docs/6561/1354871?lang=zh)
