# Speaker Architecture

Speaker uses deep modules: callers learn small interfaces while session ordering, platform behavior, recovery, and verification stay local to the implementation. A seam exists only when production and deterministic adapters both cross it.

The [voice-input specification](specs/voice-input.md) owns product behavior. The [ADRs](adr/README.md) own the rationale for load-bearing decisions. This page describes the current implementation shape.

## System shape

```text
SpeakerApp                  Scene and SwiftUI composition
  └─ SpeakerRuntime         Lifecycle, dependency assembly, startup, shutdown
       ├─ VoiceInputExperience
       ├─ VoiceShortcutFeature
       ├─ Settings workspace
       ├─ History feature
       └─ Provider features

SpeakerAppFeatures          Windowless product rules and injectable coordinators
SpeakerCore                 Session, transcription, refinement, delivery, local data
SpeakerProviderEvidence     Provider acceptance evidence shared by app and tools
Platform adapters           AppKit, AX, AVAudio, Carbon, Keychain, SMAppService
```

`SpeakerApp` declares the menu-bar, settings, onboarding, and history scenes. `SpeakerRuntime` hides dependency assembly, startup migration order, shortcut activation, and shutdown convergence. SwiftUI views observe one feature state and send semantic intents; they do not coordinate several platform adapters.

`SpeakerAppFeatures` owns product copy, SF Symbols, accessibility announcements, windowless presentation policy, and route effects. `SpeakerCore` does not expose concrete UI language or presentation policy.

## Deep product modules

### VoiceShortcutFeature

The user interface is `select`, `retryActivation`, and observable state. The implementation hides:

- mutual exclusion among the `Fn` event tap, side-specific modifier event tap, and custom Carbon key chord;
- stop and recovery after Accessibility permission changes;
- `Esc` reservation, common editing conflicts, and fallback when the system owns `Fn`;
- ordered persistence when shortcut selections change quickly;
- precedence of a new user selection over a late settings restore; and
- the irreversible shutdown fence that stops trigger intake and waits for the last settings write.

Production uses live event-monitor adapters; specifications use deterministic adapters. Callers and tests cross the same seam.

### VoiceInputExperience

`VoiceInputExperience` is the application-facing voice-input module. Its interface exposes:

- observable semantic state for the menu bar and HUD;
- session-capability actions and structured route effects;
- a `VoiceTriggerTarget` for the shortcut module; and
- `start` and `shutdown` lifecycle operations.

The implementation owns the trigger dispatcher, hold/short-press gesture, synchronous `Esc` fence, session observation, menu/HUD projections, VoiceOver phase deduplication, notices, and shutdown fencing. Actions are bound to the originating session, so a stale HUD cannot cancel, copy, or dismiss a newer session.

### Application feature modules

`SettingsNavigationModel` is the single page-selection source for the six settings sections. It separates ordinary top-of-page presentation from one-shot requests to reveal a specific section. About is a separate top-level main-window tab. `MenuBarCommandRouter` selects the intended destination before activating Speaker; the ordinary Settings command returns to the page top.

`OnboardingPresentation` owns permission actions, provider-check availability, resource selection, and completion rules. The onboarding view, its copy, and its SF Symbols live in the application feature module; the App scene keeps only the window controller. Production window configuration comes from a dedicated factory that the AppKit specifications exercise through the same interface.

`AccessibilityAnnounce` names the single accessibility announcement seam. Voice Input, the shortcut coordinator, and onboarding hand messages to an injected closure; the App scene owns the one `NSAccessibility` announcement post behind it.

`PermissionRefreshCoordinator` turns an external macOS permission change and shortcut recovery into one ordered operation. It observes Speaker and workspace-application activation so returning from System Settings can restore the shortcut without first activating Speaker.

## Voice Input Session

`VoiceInputSessions` is the core deep module. Semantic commands enter one ordered actor and publish a revisioned presentation. At most one Voice Input Session is active. Duplicate edges are idempotent, release during recorder startup is remembered, asynchronous results carry session identity, and stale results are discarded.

Recording, target capture, transcription, optional refinement, delivery, cancellation, persistence, and cleanup remain behind this interface. Terminal presentation is published before its Session Record settles; a history failure adds a notice but cannot delay or replace the user's result.

User Cancellation is distinct from a Session Problem. Cancellation suppresses late provider results. Once `DeliveryCommitGate` commits a mutation, cancellation may close the HUD and release the shortcut, while receipt and Session Record settlement continue with the real mutation outcome.

New shortcut presses are rejected while processing or while a Pending Copy Result owns the interaction. Gesture ownership is reset synchronously and in the actor so a rejected press cannot start a delayed recording after the old session finishes.

## Provider processing and audio

Microphone capture uses the raw input path and does not request Apple voice processing. The result is converted to 16 kHz, 16-bit, mono PCM and enters a bounded in-memory stream. Doubao transmission and reception run concurrently over the bidirectional `bigmodel_async` WebSocket. Release marks the final audio frame; cancellation never sends a final frame after the task has been cancelled.

`AVAudioCapture` records a content-free `AudioCaptureEnvironmentSnapshot` while configuring the engine and refreshes it after recording starts. The snapshot contains only booleans and stable enums for the voice-processing request and active state, enable-failure class, AGC state, and preferred and active system microphone modes. It contains no device name, path, or raw error. The diagnostic report renders every field; before the first recording, unavailable values are `unknown`. On a real Mac, start one recording before copying diagnostics, then compare `audioCaptureVoiceProcessingRequested` and `audioCaptureVoiceProcessingActive` and verify that `audioCapturePreferredMicrophoneMode` and `audioCaptureActiveMicrophoneMode` match the Control Center selection and active route.

`AudioCaptureQualityPolicy` rejects recordings shorter than 300 ms and definite digital silence. Because streaming may already have crossed the provider seam, local rejection cancels the active request and records an explicit local outcome. Ambiguous quiet audio and environmental noise continue to the provider rather than being rejected by a speculative heuristic.

Default Smoothing enables Doubao semantic smoothing and uses its confirmed Stage Result. A Refinement Mode that requires DeepSeek disables Doubao semantic smoothing while retaining punctuation and written-form number normalization, then sends only that more faithful Stage Result, its rule, and the Entry words of the press-time Personal Dictionary snapshot. `TextRefinementContext` is the seam that carries the Refinement Mode and those Entry words; Default Smoothing never constructs one because it never crosses the DeepSeek seam. The Entry words travel as one labeled data-only JSON string block that is absent when the dictionary is empty, and the fixed system instructions forbid translating mixed Mandarin-English text and forbid inserting an Entry where the source has no phonetically or visually close span. The DeepSeek adapter accepts a bounded, non-thinking, non-streaming JSON completion; every explicit error preserves the Doubao text. Audio never crosses the DeepSeek seam.

`VoiceProviderRuntimeDiagnostics` holds a content-free, in-memory snapshot for the active Doubao request. Its phase advances only when Speaker crosses a transport event: connected, request header sent, audio streaming, final audio sent, and waiting for the final result. Intermediate receive frames may add safe request metadata but cannot advance a sender that is still streaming. Success, explicit failure, and cancellation remove the snapshot.

Provider state records stable HTTP, close-code, DNS, connectivity, connection-loss, and TLS classifications. Raw network messages, audio, text, provider messages, and credentials never enter the snapshot. An open connection with no final result remains Waiting For Result; local elapsed time does not invent a provider failure.

## Input Target and delivery

The global release callback snapshots only the frontmost PID, so it never blocks the event tap on target-application AX IPC. Immediately after the callback returns, the platform adapter reads the current focused element in that exact process, falling back to its focused window when no element is exposed. This avoids making delayed or missing `AXObserver` notifications a correctness dependency while keeping a process fence around the small post-callback capture window. The policy layer owns the resulting one-session target token, concurrent-change evidence, commit gate, and receipt judgment; the live adapter wraps AX, pasteboard, and CGEvent operations.

Every delivery attempt consumes the original bounded token and confirms the same process and strongest available focus identity. Element-scoped targets require the exact element; applications that expose no usable focused element require the exact focused window. A window-scoped target cannot prove movement between fields inside that window, so it is permitted only for the transactional paste path and remains protected by frontmost-process and Secure Input checks. Application identity remains transient adapter diagnostics and is neither displayed nor persisted in Session Records.

There is one application-independent mutation path. While the frozen element or window remains current in the exact frontmost process and Secure Input is off, the live adapter preflights event-post access, snapshots every readable pasteboard representation, writes a private transaction marker, and posts one physical Command-V from `.combinedSessionState`. It restores only when both marker and change count still prove ownership. Exact AX value/range evidence may confirm the resulting edit, but it never selects another write API. A posted paste is a committed one-shot action even when no receipt is available because retrying it could duplicate text.

AX `.cannotComplete` retains the precise operation stage: security read, role read, value read, selection read, focus read, or receipt. This maps to a target-application-unresponsive fact rather than a guessed timeout, focus change, or unsupported-control diagnosis.

Delivery degradation carries a content-free `DeliveryDiagnostic` through the Session Record, search, history details, and copied diagnostics. Accessibility permission absence is a separate platform state, not an unsupported-target result.

The full decision is recorded in [ADR-0002](adr/0002-freeze-the-input-target.md). Real target-family evidence is governed by the [compatibility matrix](compatibility.md).

## Persistence and startup recovery

Startup finishes credential migration, provider-resource restore, Personal Dictionary and Refinement Mode loading, legacy history migration, privacy cleanup, and non-terminal Session Record convergence before activating the global shortcut. Records left in preparing, recording, or processing become an explicit interrupted terminal state.

History retention settings are the sole source of user intent. Automatic age and count eviction is a destructive transaction. A committed deletion is never presented as rolled back because WAL checkpointing is busy; pending checkpoint work is retried on later writes and the next clean open.

File-backed sensitive data cross `OwnerOnlyFilePersistence`. The implementation opens directories and files without following symbolic links, confirms a regular file owned by the current user, bounds reads, and performs atomic same-directory owner-only writes with descriptor-relative operations. Unsafe objects fail closed and remain available for diagnosis.

Credential migration treats the current Keychain service as primary and old Keychain or development files as legacy sources. Migration proceeds only when every legacy source is readable and all non-empty values agree. It writes and reads back the primary value before removing legacy sources. A conflict or inaccessible source preserves all data and emits only provider-level diagnostics.

The persistence decision is recorded in [ADR-0004](adr/0004-protect-local-sensitive-data.md), and the Session Record store's WAL, secure-delete, and checkpoint-convergence rationale in [ADR-0006](adr/0006-store-session-records-in-sqlite.md).

## Local data erasure

`SpeakerDataErasureCoordinator` is the only external erasure operation. It hides write fencing, login-item removal, credential deletion, SQLite close, owned-path validation, preferences removal, verification, recovery marking, and exit order.

Concurrent requests share one task, and caller cancellation cannot interrupt destruction already in progress. Deletion targets must remain within verified, symlink-resolved user Library roots. A separate owner-only recovery marker survives preferences removal; partial failure preserves it for the next startup. Normal termination cannot write settings after erasure.

Both the main window and the system Settings scene replace writable controls while erasure is running. A failed erasure routes to a guarded recovery destination that replaces ordinary settings so its reason and retry action remain reachable without reopening writable controls.

## UI verification seams

Debug builds provide a visual-scenario entry point for the recording, processing, Pending Copy Result, and problem HUD states. It does not load the voice runtime and is absent from Release binaries. `VoiceInputPanelLayout` is the single source for panel classification and size; AppKit specifications cover every state transition and require the window and hosting content to converge together. Those specifications, like every other suite, are sequential `@main` executables sharing the `SpeakerSpecSupport` harness rather than XCTest bundles; see [ADR-0007](adr/0007-specify-behavior-through-sequential-executables.md).

The HUD exposes real state rather than fabricated progress. Recording shows a red indicator, audio level, and explicit cancel action. Preparing shows a compact wave and the same cancel action. Waiting For Result widens the same pill to show the stage title; Esc and the cancel control keep their User Cancellation meaning. Reduce Motion, Increase Contrast, VoiceOver labels, and announcements are product behavior owned by the application feature module.

Onboarding has a separate debug capture entry point that renders the production view and window. Content scrolls within constrained screens while the completion region remains reachable.

## Software updates and release

`SoftwareUpdateFeature` isolates update state and intents. A live Sparkle adapter exists only when the Developer ID identity, GitHub Releases HTTPS feed, and Ed25519 public key are all valid. Development builds disable updates. Production acceptance may inject only this repository's immutable `v<SemVer>` prerelease appcast through a launch argument; normal launches always use the stable latest feed. The production workflow signs once, publishes that exact DMG as a prerelease candidate, binds old-version evidence to it, then promotes the same release as latest and reads the signed channel back. The signing job owns private keys but no repository write permission; staging and publication jobs own scoped repository write permission and verify with only the reviewed public key. Distribution, notarization, appcast signing, exact-artifact promotion, public readback, and candidate-bound old-version upgrade evidence are release gates rather than application-scene responsibilities. The update-channel decision, including why Developer ID signing, the HTTPS appcast, and Ed25519 verification are three independent checks, is recorded in [ADR-0005](adr/0005-deliver-updates-through-sparkle.md).

## Invariants

- The Input Target frozen when recording ends is the session's only target; later focus changes never retarget it.
- User Cancellation is not a Session Problem, and late Stage Results after cancellation are never delivered.
- A delivery adapter mutates only after the commit gate succeeds; a committed mutation is settled from its real receipt.
- Transcript text is persisted only after the Input Target's security class is known; secure targets remain text-free in every state.
- Waiting For Result never becomes failure from local elapsed time alone.
- Shutdown stops trigger intake, closes session dispatch, and then waits for required local persistence.
- SwiftUI views observe one feature state and emit semantic intents; they do not coordinate multiple platform adapters.
- A seam has both a live adapter and a deterministic adapter. Pass-through protocols without real variation are removed by the deletion test.
