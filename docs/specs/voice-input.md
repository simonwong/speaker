# Voice Input Specification

Status: Implemented

This is the durable product contract for Speaker's macOS voice-input experience. Production release gates remain in the [production-readiness checklist](../production-readiness.md).

## Problem Statement

People want to speak from any macOS work context and receive usable text at the position they selected when they finished speaking. Built-in dictation does not combine user-owned providers, a Personal Dictionary, optional refinement, inspectable Stage Results, and conservative cross-application delivery.

Speaker must make the entire Voice Input Session legible without turning an uncertain target or provider outcome into apparent success. A successful transcript must remain recoverable even when automatic delivery is unsafe.

## Solution

Speaker is a menu-bar macOS application. Holding or short-pressing the configured shortcut starts recording; releasing it freezes the Input Target. Audio streams to Doubao ASR while recording. Default Smoothing uses Doubao only. A Refinement Mode that explicitly requires DeepSeek sends the confirmed Doubao text, never the audio, for optional further refinement.

Delivery mutates the frozen Input Target only after it remains safe, current, and verifiable. Every unsupported, secure, changed, closed, or otherwise uncertain target produces a Pending Copy Result. The user can copy that result explicitly without Speaker stealing focus or overwriting the clipboard in advance.

## User Stories

1. As a user, I want Speaker to live in the menu bar, so that voice input stays available without occupying the Dock.
2. As a first-time user, I want Microphone and Accessibility onboarding, so that I understand each permission before granting it.
3. As a user, I want missing or revoked permissions reported explicitly, so that platform failures are not confused with provider failures.
4. As a user, I want `Fn` as the default voice shortcut, so that recording requires minimal hand movement.
5. As a user, I want to select a custom modifier-and-key shortcut, so that I can avoid hardware or system conflicts.
6. As a user, I want real shortcut registration to reject conflicts, so that a saved shortcut is actually usable.
7. As a user, I want press/release and short-press interactions to create at most one Voice Input Session, so that repeated events cannot race.
8. As a user, I want `Esc` to cancel an active session, so that accidental audio or text is not delivered.
9. As a user, I want clear recording and processing status without focus activation, so that Speaker never changes the intended Input Target.
10. As a user, I want short recordings and definite digital silence rejected locally, so that meaningless input is never delivered.
11. As a user, I want the Input Target frozen when recording ends, so that later window changes never retarget my result.
12. As a user, I want password fields and other secure targets excluded from automatic delivery and text history, so that sensitive work stays protected.
13. As a user, I want unsupported, changed, closed, or unverifiable targets to produce a Pending Copy Result, so that usable text is never lost or inserted into the wrong place.
14. As a user, I want copying a Pending Copy Result to be explicit and verified, so that Speaker never silently replaces my clipboard.
15. As a user, I want Default Smoothing to use Doubao only, so that the normal path avoids a second provider.
16. As a user, I want punctuation, written-form number normalization, and light disfluency removal, so that ordinary dictation is immediately usable.
17. As a user, I want concise cleanup, full rewrite, and Custom Modes, so that I can choose how strongly a transcript is refined.
18. As a user, I want every Refinement Mode to preserve the source language, facts, names, numbers, and intent, so that refinement cannot invent content.
19. As a user, I want DeepSeek used only by modes that require it, so that audio and Default Smoothing never reach DeepSeek.
20. As a user, I want every DeepSeek failure to fall back to the confirmed Doubao Stage Result, so that optional refinement cannot lose a transcript.
21. As a user, I want to supply my own provider credentials and keep them in Keychain, so that Speaker has no shared provider backend or embedded secret.
22. As a user, I want content-free provider diagnostics and connection checks, so that configuration and transport problems are actionable without exposing audio or text.
23. As a user, I want a local Personal Dictionary of canonical spellings, spoken aliases, and enabled states, so that specialist terms are recognized consistently.
24. As a user, I want ambiguous Entries rejected and each session to use a stable dictionary snapshot, so that edits and aliases remain deterministic.
25. As a user, I want Session Records with Stage Results, Refinement Mode, target application, timing, delivery status, and sanitized diagnostics, so that the pipeline is inspectable.
26. As a user, I want to search, inspect, copy, redeliver, delete, and clear Session Records, so that local history remains useful and controllable.
27. As a user, I want history retention to follow an explicit policy with a safety cap, so that storage behavior reflects my intent.
28. As a user, I want raw audio, credentials, AX objects, captured source text, and clipboard contents excluded from persistence, so that local diagnostics remain minimal.
29. As a user, I want login launch to be optional and disabled by default, so that Speaker changes startup behavior only with consent.
30. As a user, I want User Cancellation and late provider results handled deterministically, so that stale text can never be delivered.
31. As a user, I want Waiting For Result to remain honest until the provider or system reports an outcome, so that elapsed time is not misreported as a failure.
32. As a user, I want a reproducible build, test, installation, and release path, so that the application can be verified from source and safely distributed.

## Implementation Decisions

- Speaker targets macOS 14 or later and uses Swift 6. It is a menu-bar application outside App Sandbox because global shortcut monitoring and cross-application Accessibility delivery are core behavior.
- Accessibility and Microphone are the only runtime permissions required for voice input. Shortcut activation and permission recovery are coordinated as one ordered feature lifecycle.
- The Voice Input Session module is the primary deep module. Its interface accepts semantic intents and publishes observable session behavior; it hides event ordering, recording, target capture, provider processing, delivery, cancellation, cleanup, and history settlement.
- Commands are serialized. Duplicate edges are idempotent, asynchronous work carries session identity, and late results from cancelled or superseded sessions are discarded.
- Audio is converted to 16 kHz, 16-bit, mono PCM in memory and placed in a bounded stream. It is never persisted as a normal application artifact.
- Audio streams over Doubao's bidirectional `bigmodel_async` WebSocket while recording. Release sends the final audio frame and begins final-result settlement; the selected resource must match the user's activated provider resource.
- A press snapshots the Refinement Mode and enabled Personal Dictionary. A release freezes the precise focused Accessibility element as the Input Target. Later capture and delivery must consume that same bounded target token.
- The Personal Dictionary is local. Enabled Entries influence request context, and local alias normalization applies only to an exact, unambiguous configured match.
- Default Smoothing does not call DeepSeek. Other Refinement Modes send only the confirmed Doubao text and the selected rule through a non-thinking, non-streaming JSON request. Only a bounded, non-empty normal completion with the expected shape may replace the Doubao Stage Result.
- Provider credentials live in Keychain. Settings, the Personal Dictionary, Session Records, and development credentials use owner-only persistence appropriate to their data type.
- Session Records use versioned SQLite transactions. Secure targets never persist transcript text or provider request identifiers, including non-terminal and cancelled records.
- Delivery is conservative. Direct Accessibility mutation and the receipt-verified PID Unicode fallback share one commit gate. Speaker does not restore focus, simulate paste, rewrite an entire rich document, or report an unconfirmed mutation as delivered.
- A Pending Copy Result is a successful recovery surface, not a generic failure. Its non-activating presentation exposes explicit copy, retry, and dismiss actions tied to the originating session.
- User Cancellation is distinct from a Session Problem. Cancellation closes the user-facing session immediately; a mutation that already committed may finish its receipt and history settlement but cannot be rewritten as cancelled.
- Application shutdown fences new shortcut intake, stops session dispatch, cancels external work, and waits for required local persistence in that order.

## Testing Decisions

- Good tests cross the same interface as production callers and assert externally observable behavior rather than private method calls, internal state layout, or framework call counts.
- The highest test seam is the Voice Input Session interface. Deterministic adapters replace recording, target capture, Doubao, DeepSeek, delivery, time, clipboard, and persistence behind that seam.
- Session specifications cover shortcut ordering, duplicate edges, short recordings, definite silence, snapshots, target timing, provider outcomes, optional refinement, fallback, User Cancellation, stale results, secure and changed targets, Pending Copy Results, explicit copy, history, and shutdown.
- Provider adapter specifications verify request framing, credential placement, resource/model selection, response decoding, cancellation, stable error classification, content bounds, and secret exclusion without contacting paid endpoints.
- Persistence specifications exercise in-memory and temporary-disk adapters through the same interfaces. They cover schema migration, retention, search, deletion, secure-target redaction, corruption recovery, owner-only file handling, and sensitive-content exclusion.
- App scenario specifications verify product rules without a window server. AppKit UI specifications verify production window configuration, non-activation, geometry, accessibility, and layout transitions.
- Platform behavior without a cross-application Apple contract is accepted through the [real-machine compatibility matrix](../compatibility.md), not through a fake that claims universal support.

## Out of Scope

- Accounts, a hosted Speaker backend, cloud history, cloud settings, multi-device sync, subscriptions, teams, or shared dictionaries.
- Offline transcription, additional ASR or refinement providers, translation, text-to-speech, meeting transcription, diarization, or long-form audio management.
- Saving or replaying raw audio.
- Automatic clipboard replacement, forced focus restoration, simulated paste, or guaranteed delivery into every macOS input control.
- Per-application Refinement Modes or Personal Dictionaries, dictionary synchronization, and cloud history backup.
- iPhone or iPad application targets.

## Further Notes

- The [architecture](../architecture.md) is the current implementation map; ADRs preserve the rationale behind its load-bearing choices.
- Provider and platform details can drift. The dated pages under [`docs/research`](../research/) must be rechecked before changing an adapter contract.
- Production identity, notarization, provider evidence, and real-machine acceptance remain governed by the [production-readiness checklist](../production-readiness.md), not by this feature specification.
