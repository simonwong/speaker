# 个人 macOS 语音输入 MVP

> 历史 MVP 设计记录。当前生产门槛与实现状态以
> [`docs/production-readiness.md`](../../docs/production-readiness.md) 和源码为准；
> 本文件中的 watchdog、临时 WAV、固定 provider budget 与发布范围不再代表现状。

Status: ready-for-agent

## Problem Statement

用户希望在 macOS 的任意工作场景中按住一个全局快捷键讲话，松开后获得经过轻量顺滑或明确规则整理的文本，并尽可能写入结束录音时聚焦的输入位置。现有系统听写难以同时满足自定义模型、个人词库、可追溯的多阶段结果、保守可靠的跨 App 送达和失败后不丢文本。

用户只需要一个在自己 Mac 上运行的个人工具，不希望首版承担账号、云同步、订阅或发布体系，但必须能够看清录音、转录、进一步整理、送达和失败降级的全过程。

## Solution

构建一个 Swift 编写的非沙盒 macOS 菜单栏 App。默认按住 `Fn` 录音，松开时立即捕获输入目标并把短音频提交给豆包语音识别大模型。默认整理模式只使用豆包语义顺滑；用户主动选择精简清理、完整重写或自定义模式时，才把豆包结果发送给 DeepSeek 进一步整理。

App 只在能够保守确认目标安全且支持送达时自动写入。没有输入目标、目标失效、目标内容发生并发变化、安全输入或送达无法确认时，保留为待复制结果并显示不抢焦点的浮层，由用户主动复制。所有阶段文本与元数据进入本地会话历史，原始音频和凭证不进入历史。

## User Stories

1. As a user, I want the App to live in the menu bar, so that voice input is available without occupying the Dock.
2. As a first-time user, I want clear Microphone and Accessibility onboarding, so that I understand why each permission is required.
3. As a user, I want the App to report when a permission is missing or revoked, so that silent failures do not look like model failures.
4. As a user, I want `Fn` to be the default hold-to-talk trigger, so that speaking requires minimal hand movement.
5. As a user, I want to configure a modifier-plus-key shortcut, so that I can avoid hardware or system conflicts with `Fn`.
6. As a user, I want shortcut conflicts to be detected before saving, so that I never select a shortcut that cannot work.
7. As a user, I want holding the shortcut to start recording and releasing it to submit, so that the interaction feels immediate.
8. As a user, I want pressing `Esc` during an active session to cancel it, so that accidental speech is not sent.
9. As a user, I want repeated key events and very short taps to be handled safely, so that one gesture never creates multiple sessions.
10. As a user, I want only one active voice input session at a time, so that results cannot race into the wrong place.
11. As a user, I want a visible recording indicator with elapsed time and input level, so that I know the microphone is active.
12. As a user, I want a 60-second maximum recording watchdog, so that a lost key-up event cannot record forever.
13. As a user, I want sub-300 ms recordings and definite digital silence terminated locally. The current streaming transport may already have opened a request while recording; release-time local rejection cancels it and never delivers text.
14. As a user, I want the App to capture the input target at the moment recording ends, so that moving focus during recording is allowed.
15. As a user, I want model processing to continue after I switch Apps, so that I can keep working while waiting.
16. As a user, I want the App to avoid writing into password or otherwise secure fields, so that sensitive inputs are protected.
17. As a user, I want unsupported, changed, closed, or unverifiable targets to produce a待复制结果, so that text is never written into an uncertain location.
18. As a user, I want a待复制结果 panel that does not steal focus, so that the fallback does not disrupt my current work.
19. As a user, I want copying a待复制结果 to require an explicit action, so that the App never overwrites my clipboard automatically.
20. As a user, I want successful insertion to replace the selection or insert at the captured cursor, so that the result lands where intended.
21. As a user, I want the default整理模式 to use only豆包语义顺滑, so that the normal path has lower cost and latency.
22. As a user, I want the default result to include punctuation and written-form number normalization, so that it can be used immediately.
23. As a user, I want a精简清理整理模式, so that filler, repetition, self-correction, and obvious redundancy are removed without changing meaning.
24. As a user, I want a完整重写整理模式, so that my ideas can be reorganized into clear prose without adding facts.
25. As a user, I want to create and name a自定义模式 with my own prompt, so that the output matches a recurring writing need.
26. As a user, I want every整理模式 to remain constrained to the source language, meaning, facts, names, numbers, and intent, so that rewriting cannot invent content.
27. As a user, I want DeepSeek to be called only for a整理模式 that explicitly requires it, so that the default path never sends text to a second provider.
28. As a user, I want DeepSeek-dependent modes disabled until a valid DeepSeek Key is configured, so that configuration errors are explicit.
29. As a user, I want any DeepSeek timeout, network error, malformed output, filtering, or abnormal expansion to fall back to the豆包 result, so that optional refinement cannot lose a successful transcription.
30. As a user, I want the fallback to be visible in the session status and history, so that I know which text was delivered.
31. As a user, I want to enter my own豆包 API Key, so that the App does not depend on a shared backend.
32. As a user, I want model credentials stored in macOS Keychain, so that they are absent from source, files, history, and logs.
33. As a user, I want a connection check for configured providers, so that authorization, balance, or service activation problems can be diagnosed before dictation.
34. As a user, I want a local个人词库, so that names, products, and technical terms are recognized consistently.
35. As a user, I want each词条 to contain a standard spelling, optional spoken aliases, and an enabled state, so that recognition preferences remain explicit and reversible.
36. As a user, I want enabled词条 supplied to豆包 as request context where supported, so that recognition improves before local correction.
37. As a user, I want deterministic alias normalization only when an unambiguous configured alias matches, so that the词库 does not rewrite ordinary language.
38. As a user, I want conflicting词条 rejected or surfaced, so that two standard spellings cannot claim the same spoken alias silently.
39. As a user, I want all个人词库 data to remain on my Mac except the enabled context sent with the current豆包 request, so that there is no independent cloud dictionary.
40. As a user, I want a local会话历史 window, so that I can inspect prior voice inputs.
41. As a user, I want each会话记录 to include time, duration, target App,整理模式 snapshot,豆包 result, optional DeepSeek result, final text, delivery status, stage timing, provider request identifiers, and sanitized errors, so that the complete pipeline is auditable.
42. As a user, I want会话历史 to distinguish transcription, refinement, delivery, cancellation, and待复制结果, so that different failures are not collapsed into one message.
43. As a user, I want to search history across final,豆包, and DeepSeek text, so that previous wording can be found quickly.
44. As a user, I want to copy or re-attempt delivery of a historical final text, so that a useful result can be reused.
45. As a user, I want to delete one会话记录 or clear all history, so that I control local retention.
46. As a user, I want history retained until I delete it, so that the App does not discard useful text automatically.
47. As a user, I want the raw audio removed after success, failure, or cancellation, so that recordings do not accumulate.
48. As a user, I want target AX objects, selected source text, clipboard content, and credential values excluded from history, so that debugging data stays minimal.
49. As a user, I want menu bar access to current整理模式, provider status,会话历史, settings, and quit, so that common actions remain close.
50. As a user, I want settings for the shortcut, credentials,整理模式,个人词库, permissions, and login launch, so that configuration has one home.
51. As a user, I want login launch to be optional and off by default, so that the App does not change startup behavior without consent.
52. As a user, I want recording and processing overlays to be non-activating, so that displaying status never changes the captured target.
53. As a user, I want provider and network errors expressed as actionable local messages, so that I can distinguish bad credentials, missing activation, no balance, throttling, timeout, and service failure.
54. As a user, I want late responses from cancelled or superseded sessions ignored, so that stale text can never be delivered.
55. As a user, I want the App to build and run from source on my current Apple Silicon Mac, so that the MVP is usable without distribution infrastructure.

## Implementation Decisions

- The deployment target is macOS 14. The App uses Swift 6 with SwiftUI for scenes and AppKit/ApplicationServices/Carbon/AVFoundation for menu bar behavior, non-activating panels, global input, Accessibility, audio, and platform integration.
- The App is a non-sandboxed menu bar application with no Dock icon. App Sandbox is intentionally disabled because cross-App Accessibility control is a core requirement. The App requests only Accessibility and Microphone permissions; it does not separately request Input Monitoring.
- `Fn` is a special default trigger implemented as session-level listen-only event-tap edge detection over the secondary-Fn flag. It cannot be exclusively registered, so onboarding explains the system Fn/Globe conflict and external-keyboard limitation. User-defined modifier-plus-key triggers use the platform hotkey registration path and must pass a real registration check before saving.
- The central `VoiceInputSessions` module is a deep module. Its external interface accepts semantic commands such as pressed, released, cancel, copy pending result, retry, and dismiss; callers observe a revisioned presentation stream. It owns the single-session invariant and hides all pipeline ordering, errors, cancellation, retries, cleanup, history updates, and provider fallback.
- A press snapshots the active整理模式 and enabled个人词库. A release stops recording and immediately starts the first Accessibility target query. The resulting输入目标 is a short-lived in-memory snapshot of the target element, process identity, role/subrole, selected range, and non-persisted content version evidence.
- Presentation states cover idle, preparing, recording, target capture, transcribing, refining, delivering, delivered,待复制结果, cancelled, and failed. DeepSeek failure is a degraded success when a豆包 result exists, not a failed session.
- Commands are serialized. Duplicate press/release events are idempotent, a release arriving during recorder startup is remembered, each asynchronous result carries the session identity and generation, and stale results are discarded.
- The current audio adapter converts to 16 kHz, 16-bit, mono PCM in memory and streams bounded chunks without creating a temporary WAV. Recordings shorter than 300 ms or below the conservative definite-silence boundary are rejected locally on release; ambiguous low-level audio is left to the provider rather than risking false rejection.
- The豆包 adapter calls the large-model recording-file flash HTTP endpoint after release, using the user Key, a per-request UUID, the flash resource identifier, base64 WAV data, punctuation, written-number normalization, and semantic smoothing. The first implementation uses non-streaming HTTP; streaming remains an internal-adapter replacement if measured latency is unacceptable.
- Enabled个人词库 terms are sent using request-level context when the provider accepts it. Local alias normalization occurs only for exact configured aliases with a unique enabled owner; ambiguous aliases are rejected during editing.
- The DeepSeek adapter uses the current V4 Flash model in explicitly non-thinking, non-streaming JSON mode. It sends only the豆包 text and selected整理模式 rule, expects exactly one non-empty `text` field, uses a 20-second total budget, and accepts only a normal stop with bounded output. Transient errors may retry once within the same budget; every unsuccessful path falls back to豆包.
- Fixed prompt invariants override custom整理模式: treat the transcript as data, retain source language and intent, add no facts/names/numbers/promises/conclusions, do not answer transcript questions, and return only the required JSON shape. A custom rule is limited to 4,000 characters.
- Provider credentials are stored only in macOS Keychain. Settings,整理模式,个人词库, and会话历史 are stored by a local persistence module under Application Support using an atomic, versioned representation. The external persistence interface is independent of its representation so migration to SQLite does not affect callers.
- A会话记录 is created when a session starts and updated at meaningful stages. History persistence failure emits a user-visible notice but does not block delivery. Records never contain audio, API Keys, AX element references, captured source content, or clipboard contents.
- Delivery uses a conservative ordered set of internally verified adapters. Direct Accessibility insertion is attempted only when required text attributes are writable, the target remains valid and non-secure, and the captured version evidence has not detected concurrent change. A PID-targeted Unicode event path may be attempted only for bundle IDs explicitly verified by the local compatibility matrix, while the same element is still focused and its value and selection evidence remain unchanged; the shipping allow-list stays empty until that smoke exists because macOS provides no delivery receipt. The App never restores focus, simulates Command-V, rewrites an entire rich document value, or optimistically reports success.
- Missing, unsupported, secure, changed, invalidated, or unverifiable targets produce a待复制结果. The panel is non-activating and exposes an explicit copy action; the clipboard is not changed before that action.
- Secure Event Input prevents starting a new session and cancels an active recording if detected. Secure-subrole targets never receive automatic text and their transcript is not persisted by default, following fail-closed behavior.
- The UI consists of a menu bar extra, non-activating recording/processing/result panels, a settings scene, and a会话历史 scene. The menu bar switches整理模式 and opens settings/history. The history scene supports search, detail, copy, re-attempt delivery, single deletion, and clear all.
- Login launch uses the system login-item mechanism and is off by default.
- The source distribution includes a reproducible command-line build and test workflow. On the current machine it pins the macOS 26 SDK (`MacOSX26.sdk`) with a writable module cache; `SPEAKER_SDKROOT` can still override the SDK explicitly (used by CI). Full Xcode is recommended for interactive UI debugging but is not a prerequisite for command-line verification.

## Testing Decisions

- Tests describe observable product behavior through public interfaces and do not assert private method calls, internal state layout, concrete file paths, or framework call counts.
- The primary seam is the `VoiceInputSessions` interface. Integration-style tests drive semantic commands and observe revisioned presentations and persisted会话记录 while using deterministic adapters for audio, target capture,豆包, optional DeepSeek, delivery, time, and persistence.
- The primary seam covers press/release ordering, short-tap races, duplicate events, 60-second watchdog, mode and词库 snapshots, target capture timing, successful豆包 delivery, optional refinement, all DeepSeek fallback classes, cancellation, stale response suppression, secure/no/changed targets,待复制结果, explicit copy, audio cleanup, and history behavior.
- The provider-adapter seam uses URL loading test adapters to verify exact endpoint, authentication headers, resource/model selection, JSON encoding, provider response decoding, error classification, output validation, timeout and bounded retry. Tests never contact paid provider endpoints.
- The persistence seam is tested against a temporary on-disk adapter and an in-memory adapter through the same interface. Tests cover atomic save/load, schema version handling, append/update, search, deletion, clear, credential exclusion, corrupted-data recovery, and deterministic词条 conflict handling.
- Keychain logic is tested at its narrow interface with an in-memory adapter; one manual local smoke test verifies real Keychain round-tripping without printing secrets.
- Platform behavior that Apple does not contract across Apps is verified by a manual local support matrix rather than mocked into a false guarantee. The matrix covers internal/external keyboard `Fn`, custom shortcut conflicts, TextEdit text field/view, Safari input/textarea/contenteditable, Chrome or an Electron editor, Notes/rich text, Terminal, target closure, concurrent edits, focus changes, secure fields, permission revoke, Unicode, emoji, multiline text, selection replacement, and undo.
- UI verification covers scene launch, menu commands, non-activating panel behavior, mode selection, settings validation, history search/detail/delete, and visible degraded-success messaging. Business-state assertions remain at the `VoiceInputSessions` seam.
- Since the repository begins without prior application tests, there is no existing test prior art. The test suite establishes the above high-level seams and avoids per-view or per-helper unit-test sprawl.
- Run focused tests throughout each red-green cycle, run the full test suite at the end of every implementation ticket, and run a command-line build plus local smoke launch before delivery.

## Out of Scope

- Mac App Store submission, App Sandbox compatibility, Developer ID signing, notarization, DMG packaging, auto-update, telemetry, analytics, or crash reporting.
- Accounts, a hosted backend, cloud history, cloud settings, multi-device sync, subscriptions, teams, shared dictionaries, or organization administration.
- Offline speech recognition, additional ASR or refinement providers, streaming partial transcription in the UI, translation, text-to-speech, meeting transcription, speaker diarization, or long-form document management.
- Saving or replaying original audio.
- Automatic clipboard replacement, forced focus restoration, simulated paste, or a promise to write into every macOS input control.
- Per-App整理模式 or per-App个人词库, dictionary import/export, dictionary groups, automatic history expiry, or history cloud backup.
- iPhone/iPad App targets and guaranteed delivery into iOS Apps running on Apple Silicon.

## Further Notes

- The official API research is stored beside this spec and remains the source for provider details that may drift. Model names, pricing, limits, privacy controls, account activation, real latency, cancellation behavior, and request-level context support must be smoke-tested with the user's own non-sensitive provider accounts before the MVP is considered production-calibrated.
- The Apple research proves that target capture and conservative delivery are feasible but does not prove cross-App compatibility. The implementation must preserve the待复制结果 fallback even if the local support matrix performs well.
- The current machine has macOS 26.5, Apple Silicon, Swift 6.2.4, and Command Line Tools. The pinned macOS 26 SDK (`MacOSX26.sdk` → 26.2) now compiles and tests the full project with this compiler; the earlier 15.4 pin worked around a since-resolved SDK/compiler incompatibility. Note the 26 SDK marks AVAudioConverter's input block `@Sendable`, which required one targeted `nonisolated(unsafe)` exemption in `LiveVoiceInputAdapters`.
