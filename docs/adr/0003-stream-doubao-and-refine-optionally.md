# ADR-0003: Stream Doubao ASR and Refine Text Optionally

Status: Accepted

Date: 2026-07-18

## Context

Submitting a complete recording after release creates avoidable tail latency. Doubao provides a bidirectional streaming ASR interface intended for voice-input workloads. Speaker also needs stronger user-selected rewriting than ASR punctuation, normalization, and smoothing provide.

Sending every transcript to a second provider would increase latency, cost, and data exposure. Sending audio to a general text model would violate the intended provider split.

## Decision

Speaker streams bounded in-memory PCM audio to Doubao's `bigmodel_async` WebSocket while recording. Release sends the final audio frame and waits for the final Stage Result. The user selects a provider resource that matches the resource activated in the Doubao console.

Default Smoothing ends with the confirmed Doubao Stage Result. Concise cleanup, full rewrite, and Custom Modes may send that text and the selected refinement rule to DeepSeek. DeepSeek never receives audio.

DeepSeek refinement is non-thinking, non-streaming, bounded JSON. Only an expected non-empty shape with a normal completion may replace the Doubao text. Every explicit failure preserves the Doubao Stage Result; User Cancellation discards late results.

Both providers use user-owned credentials stored in Keychain. Speaker has no shared provider backend.

## Consequences

- The audio and text provider adapters remain separate seams with different data contracts.
- Doubao connection begins before the Input Target is frozen; target selection still occurs only at release.
- Provider resource selection and paid acceptance evidence are production configuration concerns, not hidden defaults.
- Default Smoothing has lower latency and narrower disclosure than DeepSeek-dependent modes.
- Replacing either provider adapter does not change session, delivery, or persistence interfaces as long as the established Stage Result contract remains intact.
