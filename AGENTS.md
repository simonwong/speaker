# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Speaker is a macOS 14+ menu-bar voice input tool: hold (or short-press) `Fn` to record, audio streams to Doubao's `bigmodel_async` WebSocket ASR in real time, and the final text is delivered to the input field that was focused when the shortcut was released — or held in a HUD for manual copy when the target can't be confirmed. DeepSeek refinement modes run only when the user has saved a DeepSeek key; audio never goes to DeepSeek.

Building needs Swift 6 and the macOS 26 SDK. `scripts/swiftw` pins `SDKROOT` to the Command Line Tools' `MacOSX26.sdk`; override with `SPEAKER_SDKROOT`.

## Commands

Always build and test through `scripts/*` — the wrappers set `SDKROOT`, a per-UID module cache, and `--disable-sandbox` (SwiftPM can't nest `sandbox-exec` here). Bare `swift build`/`swift run`/`swift test` diverges from CI.

- `./scripts/test` — full deterministic suite: the four spec executables, the `test-*` scripts, then warnings-as-errors builds of both `Tools/` executables.
- `./scripts/build` — debug build of `SpeakerApp` (`SPEAKER_CONFIGURATION=release` for release).
- `./scripts/launch` — build and open the debug `.build/Speaker.app`.
- `./scripts/release` — the "try my change" loop: release build, bundle, ad-hoc sign, install to `/Applications/Speaker.app`, launch.
- `./scripts/provider-smoke doubao|deepseek` — live BYOK connection check using the key saved in the app.
- `./scripts/provider-smoke matrix --confirm-paid-requests ...` — pre-release acceptance matrix; makes billed requests.
- `./scripts/distribute` — the only production release entrypoint; rejects the placeholder `Resources/ReleaseIdentity.plist`.

Lint is the warnings-as-errors build: `./scripts/swiftw build --disable-sandbox --configuration <debug|release> --product SpeakerApp -Xswiftc -warnings-as-errors` (CI runs both configurations).

### Tests are hand-rolled executables

The four `Tests/` targets are `@main` executables using local `run`/`runAsync` + `expect` helpers — run one with `./scripts/swiftw run --disable-sandbox <TargetName>`, never `swift test`. There is no per-case filter: each `main.swift` is one sequential list of named cases (`SpeakerCoreSpecs/main.swift` is ~6,800 lines); grep for a case name to iterate, then finish with the full `./scripts/test`. `Tests/SpeakerCoreTests/` is an empty leftover, absent from `Package.swift`.

## Architecture

Read `docs/architecture.md` before restructuring — it holds the full narrative, migration checklist, and complete invariant list.

```text
SpeakerApp                 Scene/SwiftUI composition (~50 lines of wiring)
  └─ SpeakerRuntime        lifecycle, dependency assembly, startup/shutdown order
SpeakerAppFeatures         windowless app product rules + injectable coordinators
SpeakerCore                session, transcription, refinement, delivery, local-data semantics
SpeakerProviderEvidence    evidence schema shared by app, smoke tool, and verifier
Platform adapters          AppKit / AX / AVAudio / Carbon / Keychain / SMAppService
```

Each feature is a deep module with a small interface (`VoiceShortcutFeature` exposes `select`, `retryActivation`, and observable state; hotkey exclusivity, permission recovery, and shutdown fencing stay hidden). UI copy, SF Symbols, and presentation policy live in `SpeakerAppFeatures`, not `SpeakerCore`. A seam exists only where a live adapter and a deterministic fake both exist; specs and production code cross the same seam.

Invariants for voice-input/delivery work:

- The input target frozen at shortcut release is the session's only target; window switches never retarget it.
- User cancellation is not a session problem; late provider results after it are never delivered.
- Delivery adapters mutate the target only after `DeliveryCommitGate` commits; a committed mutation is never reported as cancelled.
- History persists transcript text only after the target's security class is confirmed; secure fields never get text in any state.
- Sensitive local files (`history.sqlite3`, `settings.json`, `personal-dictionary.json`, dev `credentials.json`) go through `OwnerOnlyFilePersistence` — route new file I/O for this data through it.

Domain vocabulary lives in `CONTEXT.md`; each term lists the synonyms to avoid. Use those terms in code, tests, and commit messages.

## Agent skills

### Issue tracker

Issues live as GitHub Issues (`simonwong/speaker`), managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles map 1:1 to label strings: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` at the repo root, `docs/adr/` for ADRs (create lazily). See `docs/agents/domain.md`.
