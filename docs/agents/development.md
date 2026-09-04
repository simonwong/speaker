# Development Workflow

Read this page before provider smoke or acceptance, building, testing, launching, bundling, installing, or releasing Speaker.

## Provider smoke and acceptance

`./scripts/provider-smoke doubao|deepseek` uses the key saved by Speaker. `./scripts/provider-smoke matrix --confirm-paid-requests ...` makes billed requests; obtain explicit approval before running it. Redact credentials, audio, transcript text, raw provider messages, and auth headers from captured evidence.

A provider check is complete only when the requested provider and scenario report a terminal verdict; a connection-only probe is not transcription or refinement acceptance evidence.

## Offline accuracy evaluation

`SpeakerAccuracyEvaluator` measures Doubao recognition accuracy on user-supplied samples and compares request variants. It never runs inside `./scripts/test` beyond a warnings-as-errors build; `SpeakerAccuracyMetricsSpecs` covers its deterministic metrics.

```bash
./scripts/swiftw run --disable-sandbox SpeakerAccuracyEvaluator -- \
    --manifest ~/eval/manifest.json --resources 1.0,2.0 --smoothing on,off \
    --dictionary-file ~/eval/entries.json --dictionary with,without
```

The manifest is `{"samples":[{"id","wav","reference","tags"?}]}`; relative `wav` paths resolve against the manifest directory and must be 16 kHz, 16-bit, mono PCM WAV, or the sample is rejected by name before anything is sent. The optional dictionary file is a JSON array of Entry strings; it is validated like the Personal Dictionary and sent through the same `DictionaryRequestContextBuilder` capacity rule. Resource `1.0`/`2.0` follow the hour or concurrent tier of the activated resource in `settings.json`.

Without `--confirm-paid-requests` the tool validates every input and prints the plan only; no network request is made. Adding `--confirm-paid-requests --output <fresh report.json>` streams each sample in real-time 200 ms packets, once per variant, and bills the user's Doubao account; obtain explicit approval first. The default report is owner-only and text-free: manifest SHA-256, variant definitions, per-sample and aggregate CER (with substitution, deletion, and insertion counts) and Latin-token WER, durations, and provider request IDs. `--include-text` also writes `<output>.with-text.json` with transcript, reference, and Entry text; keep that file local and never commit it or attach it to an issue. Audio samples never enter the repository.

## Build and test

Speaker requires Swift 6 and the macOS 26 SDK. Run build and test work through `scripts/*`; the wrappers select `MacOSX26.sdk`, isolate the per-user module cache, and disable the nested SwiftPM sandbox. Override only the SDK with `SPEAKER_SDKROOT`. Bare `swift build`, `swift run`, and `swift test` are not equivalent to CI.

Use the tightest relevant specification executable while iterating:

```bash
./scripts/swiftw run --disable-sandbox SpeakerCoreSpecs
./scripts/swiftw run --disable-sandbox SpeakerAppScenarioSpecs
./scripts/swiftw run --disable-sandbox SpeakerAppUISpecs
./scripts/swiftw run --disable-sandbox SpeakerProviderEvidenceSpecs
./scripts/swiftw run --disable-sandbox SpeakerAccuracyMetricsSpecs
```

These are sequential `@main` executables. Their `run`/`runAsync`, `expect`, `expectThrows`, `eventually`, and end-of-run summary come from the shared `SpeakerSpecSupport` library target; do not redefine them per executable. Every executable accepts an optional case-name filter after the product name: the words are joined and matched case-insensitively against case names, only matching cases run, and the summary reports how many were skipped. A filter that matches nothing exits with status 2.

```bash
./scripts/swiftw run --disable-sandbox SpeakerCoreSpecs input target is frozen
```

Iterate with a filter, then run the whole executable, then the full deterministic gate:

```bash
./scripts/test
```

`./scripts/test` is the repository's full deterministic gate: all specification executables, its shell contract tests, and warnings-as-errors builds for tool executables. It is not the whole CI workflow. An ordinary code change is test-complete when its tightest relevant specification executable and `./scripts/test` both exit 0.

For installer, release, or workflow changes, also inspect `.github/workflows/ci.yml` and run every directly relevant CI-only gate. `./scripts/test-install-rollback` is currently a CI-only gate and does not run inside `./scripts/test`. Such a change is test-complete only when the ordinary code gates and all directly relevant CI-only gates exit 0.

Use `./scripts/build` for the ordinary debug App build. For a focused warnings gate, use:

```bash
./scripts/swiftw build --disable-sandbox --configuration <debug|release> --product SpeakerApp -Xswiftc -warnings-as-errors
```

A build check is complete only when the relevant configuration exits 0 without warnings.

## Audio capture environment acceptance

Use a real Mac for capture-environment acceptance. Start and end one Voice Input Session so the live recorder refreshes its snapshot, then use About to copy diagnostics. Confirm `audioCaptureVoiceProcessingRequested` is `false` and `audioCaptureVoiceProcessingActive` is `false`; Speaker records on the raw input path and does not request Apple voice processing. Compare `audioCapturePreferredMicrophoneMode` with the mode selected in Control Center and `audioCaptureActiveMicrophoneMode` with the mode actually active for the current route. Record `audioCaptureAGCEnabled` as observed evidence only; Speaker does not change AGC. Values are `unknown` until live capture has supplied them.

## Launch, bundle, and local install

Every command that bundles or launches Speaker must keep one stable local code identity:

```bash
SPEAKER_LOCAL_CODESIGN_IDENTITY="Speaker Local Development" ./scripts/launch
SPEAKER_LOCAL_CODESIGN_IDENTITY="Speaker Local Development" ./scripts/bundle
```

The certificate lives in the login keychain. Ad-hoc signing changes code identity after rebuilds, so macOS can silently discard Accessibility and Microphone grants.

Run `./scripts/release` without an identity override when the keychain contains exactly one `Speaker Local Development` identity. The script selects it automatically; if absent, it selects exactly one `Apple Development: ...` identity. Multiple matching identities require an explicit `SPEAKER_LOCAL_CODESIGN_IDENTITY`. This is the development “try my change” loop: release build, bundle, install to `/Applications/Speaker.app`, and launch. It is not a production release.

Local App verification is complete when the launched bundle uses the selected stable identity and the expected TCC grants remain effective.

## Production release

Read [`../releasing.md`](../releasing.md) and [`../production-readiness.md`](../production-readiness.md) before production work. `./scripts/distribute` is the only production entrypoint. It must fail closed for placeholder release identity, missing Developer ID/notary/Sparkle inputs, dirty source or dependency checkouts, and incomplete provider evidence.

Production work is complete only after signed and notarized artifacts, signed appcast, public readback, retained evidence, and required clean-machine/old-version acceptance all pass. A successful local bundle is not production evidence.
