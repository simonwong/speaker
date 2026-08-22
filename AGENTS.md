# Speaker Agent Guide

Speaker is a macOS 14+ menu-bar voice input tool. A Voice Input Session records through a global shortcut, streams audio to Doubao, optionally refines text with DeepSeek, then delivers to the Input Target frozen when recording ends. Audio never crosses the DeepSeek seam.

## Read by task

- **Provider smoke or acceptance:** read [`docs/agents/development.md`](docs/agents/development.md) first. Obtain explicit approval before billed requests; redact credentials, audio, transcript text, provider messages, and auth headers from evidence.
- **Build, test, launch, bundle, install, or release:** read [`docs/agents/development.md`](docs/agents/development.md) before running a command. It owns the Swift/SDK wrappers, test topology, local signing/TCC rule, and production entrypoint.
- **Explore, change, or name domain behavior, including terms in code, tests, specs, or issues:** read [`docs/agents/domain.md`](docs/agents/domain.md).
- **Design or change a module, interface, seam, adapter, or invariant:** read [`docs/architecture.md`](docs/architecture.md) and relevant ADRs first. Finish when callers and specs cross the same named interface and the relevant highest specification executable plus full gate pass; commands live in [`docs/agents/development.md`](docs/agents/development.md).
- **Change user-visible Voice Input behavior:** read [`docs/specs/voice-input.md`](docs/specs/voice-input.md). Finish when implementation and the highest existing specification seam agree.
- **Change software updates, the update channel, or publication:** read [`docs/architecture.md`](docs/architecture.md), [`docs/research/secure-update-mechanism.md`](docs/research/secure-update-mechanism.md), and [`docs/releasing.md`](docs/releasing.md). Preserve Developer ID, HTTPS, and Ed25519 verification; finish only after public readback and old-version upgrade gates pass.
- **Create, triage, or publish work:** read [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) and [`docs/agents/triage-labels.md`](docs/agents/triage-labels.md).

## Load-bearing rules

- The Input Target frozen at shortcut release is the session's only target; focus changes never retarget it.
- User Cancellation is not a Session Problem. Late provider results after cancellation are never delivered.
- Delivery adapters mutate only after `DeliveryCommitGate` commits. A committed mutation is never reported as cancelled.
- Persist transcript text only after the Input Target security class is confirmed. Secure fields remain text-free in every state.
- Route sensitive local files (`history.sqlite3`, `settings.json`, `personal-dictionary.json`, development `credentials.json`) through `OwnerOnlyFilePersistence`.
- Keep product copy, SF Symbols, accessibility announcements, and presentation policy in `SpeakerAppFeatures`, not `SpeakerCore`.
