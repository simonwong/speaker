# Development Workflow

Read this page before provider smoke or acceptance, building, testing, launching, bundling, installing, or releasing Speaker.

## Provider smoke and acceptance

`./scripts/provider-smoke doubao|deepseek` uses the key saved by Speaker. `./scripts/provider-smoke matrix --confirm-paid-requests ...` makes billed requests; obtain explicit approval before running it. Redact credentials, audio, transcript text, raw provider messages, and auth headers from captured evidence.

Setting `SPEAKER_PROVIDER_SMOKE_NO_NETWORK=1` makes the tool refuse every connection probe and matrix run right after argument parsing, before any provider client exists, printing one line naming the guard and exiting `78`. `scripts/test-provider-smoke-contract` exports it for every invocation it makes, so `./scripts/test` can never issue a billed request; leave it unset only for an approved real run.

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

Speaker requires Swift 6 and the macOS 26 SDK. Run build and test work through `scripts/*`; the wrappers take the active toolchain's macOS SDK from `xcrun`, refuse a major version below 26, announce the choice on stderr as `swiftw: using SDK <path>`, isolate the per-user module cache, and disable the nested SwiftPM sandbox. Override only the SDK with `SPEAKER_SDKROOT`, which CI sets to the same `xcrun` path. No versioned SDK path is hardcoded. Bare `swift build`, `swift run`, and `swift test` are not equivalent to CI.

Use the tightest relevant specification executable while iterating:

```bash
./scripts/swiftw run --disable-sandbox SpeakerCoreSpecs
./scripts/swiftw run --disable-sandbox SpeakerAppScenarioSpecs
./scripts/swiftw run --disable-sandbox SpeakerAppUISpecs
./scripts/swiftw run --disable-sandbox SpeakerProviderEvidenceSpecs
./scripts/swiftw run --disable-sandbox SpeakerAccuracyMetricsSpecs
```

These are sequential `@main` executables. They are `executableTarget`s only, not package products, so no product build links them — `./scripts/build`, the warnings gate, and CI all pass `--product SpeakerApp` — while `swift run <name>` still builds and runs them. A bare `swift build` compiles every target in the root package, spec executables included; that is SwiftPM behavior, not a product declaration. Their `run`/`runAsync`, `expect`, `expectThrows`, `eventually`, and end-of-run summary come from the shared `SpeakerSpecSupport` library target; do not redefine them per executable. A double that more than one specification executable needs belongs in the `SpeakerCoreSpecFakes` library target at `Tests/SpeakerCoreSpecFakes`, which depends on `SpeakerCore` and `SpeakerSpecSupport`; `SpeakerCoreSpecs` and `SpeakerAppScenarioSpecs` both link it. It owns the deterministic Voice Input Session collaborators — recorder, Input Target capture, transcriber, text processing, delivery, clipboard, and Session Record store — each defined once and varied by constructor parameter rather than copied under a new name. Add a parameter to the shared double instead of declaring a second one. Every executable accepts an optional case-name filter after the executable name: the words are joined and matched case-insensitively against case names, only matching cases run, and the summary reports how many were skipped. A filter that matches nothing exits with status 2.

`SpeakerCoreSpecs` is split by domain: `Tests/SpeakerCoreSpecs/SpeakerCoreSpecs.swift` is the `@main` driver, each `<Domain>Specs.swift` exposes `enum <Domain>Specs: CoreSpecDomain` with one `run(failures:)`, and the doubles only that executable needs live in its `Fakes+<Area>.swift`, `Fixtures.swift`, and `Helpers+SQLite.swift` files. Add a new case to the domain file it belongs to and register a new domain in the driver. When a run goes silent, rerun it with `SPEAKER_SPEC_TRACE=1`: the harness then writes each case name to stderr as it starts, so the last line names the case that hangs.

```bash
./scripts/swiftw run --disable-sandbox SpeakerCoreSpecs input target is frozen
```

Iterate with a filter, then run the whole executable, then the full deterministic gate:

```bash
./scripts/test
```

`./scripts/test` is the repository's full deterministic gate: all specification executables, its shell contract tests, and warnings-as-errors builds for tool executables. It is not the whole CI workflow. An ordinary code change is test-complete when its tightest relevant specification executable and `./scripts/test` both exit 0.

`skills-lock.json` is validated rather than deleted because every name it locks still resolves to a real `.agents/skills/<name>/SKILL.md` exposed through `.claude/skills/`, so `./scripts/test-skills-lock` turns silent drift between the lock file and those directories into a failing gate.

The gate runs every step even after one fails, then prints a PASS/FAIL summary with each step's exit status and exits non-zero if any step failed, so one run reports every broken gate. The contract tests that read the repository and write only inside their own `mktemp` directory run concurrently with the sequential lane; every step that reenters SwiftPM on the shared `.build` directory, bundles the App, or installs it stays sequential. The runner helpers live in `scripts/test-runner-common` and are covered by `./scripts/test-scripts-test-summary`.

For installer, release, or workflow changes, also inspect `.github/workflows/ci.yml` and run every directly relevant CI-only gate. `./scripts/test-install-rollback` is currently a CI-only gate and does not run inside `./scripts/test`. Such a change is test-complete only when the ordinary code gates and all directly relevant CI-only gates exit 0.

## Continuous integration

`.github/workflows/ci.yml` runs two gating jobs so a pull request gets its specification verdict without waiting for a release build.

| Job | Name | Contents |
| --- | --- | --- |
| `specifications` | `Specifications, warnings, and formatting` | The SwiftPM build-product cache, the swift-format check, `./scripts/test` (every specification executable and shell contract test), the pristine dependency checkout gate, the debug and release warnings-as-errors builds, and script/patch hygiene. |
| `verify` | `Test, build, and bundle` | `needs: specifications`. The isolated release bundle, release identity and integrity, the dSYM evidence binding, the retained release candidate, install rollback, and the reviewed release identity guard. |

`Test, build, and bundle` is the required status check on `main`; renaming the `verify` job breaks branch protection until the required check is renamed to match. `development-prerelease` still `needs: verify`, so it runs only after both gating jobs pass.

The `specifications` job caches `.build` through `actions/cache` under a key containing the `Package.resolved` hash, so a resolved dependency graph is compiled once and later runs restore it through the prefix restore key. The `verify` job does not restore that cache: `./scripts/bundle` builds the release into an isolated scratch path under `RUNNER_TEMP` on purpose. Every action in every workflow stays pinned to a full commit SHA, which `./scripts/test-workflow-security` enforces.

Formatting is checked with the `swift-format` shipped with the toolchain against the repository-root `.swift-format` configuration:

```bash
swift format lint --strict --parallel --recursive Sources Tests
```

The tree is not formatted to that configuration yet, so the CI step carries `continue-on-error: true` and only reports findings. Reformatting the sources and making the step blocking is separate work; do not reformat unrelated files to silence it.

Use `./scripts/build` for the ordinary debug App build. For a focused warnings gate, use:

```bash
./scripts/swiftw build --disable-sandbox --configuration <debug|release> --product SpeakerApp -Xswiftc -warnings-as-errors
```

A build check is complete only when the relevant configuration exits 0 without warnings.

## Scripts

Every file in `scripts/` is listed here; `ls scripts | wc -l` must equal the number of rows. `./scripts/swiftw` is the only Swift entrypoint the others use, and `scripts/release-common` is sourced, never executed.

| Script | Purpose | Called by |
| --- | --- | --- |
| `build` | Builds the `SpeakerApp` product in `SPEAKER_CONFIGURATION` (default debug). | developer |
| `bundle` | Assembles, versions, signs, and validates `Speaker.app` from the built executable. | developer, `launch`, `install`, `distribute`, `./scripts/test`, CI |
| `compatibility-smoke` | Runs the manual cross-application delivery matrix and writes a redacted owner-only report. | developer (manual gate) |
| `delivery-e2e-smoke` | Drives an end-to-end delivery run against the `SpeakerDeliverySmokeTarget` fixture app. | developer |
| `delivery-smoke` | Delivers one fixed string into TextEdit or Terminal and checks the receipt. | developer |
| `development-build-identity` | Derives the development build number and source revision from committed Git history. | `bundle`, `./scripts/test` |
| `distribute` | The only production entrypoint: Developer ID signing, notarization, DMG, signed appcast, evidence, and promotion. | release |
| `frontmost-delivery-smoke` | Checks delivery into whatever app is frontmost, without a scripted target. | developer |
| `generate-brand-assets` | Regenerates `Resources/AppIcon.png` and `AppIcon.icns` through `SpeakerBrandAssetGenerator`. | developer, `./scripts/test` |
| `install` | Replaces `/Applications/Speaker.app` with a verified swap, identity checks, and rollback. | developer, `release`, `./scripts/test`, CI |
| `launch` | Bundles the development App and opens it. | developer |
| `provider-smoke` | Doubao/DeepSeek connection probes and the paid evidence matrix. | developer (explicit approval), release |
| `release` | Development “try my change” loop: release build, bundle, install, launch under a stable local identity. | developer |
| `release-common` | Sourced library of fail-closed release validation helpers; it is never run directly. | `bundle`, `install`, `distribute`, `verify-published-update`, `test-release-*`, CI |
| `run` | Runs `SpeakerApp` straight from SwiftPM without bundling. | developer |
| `swiftw` | SwiftPM wrapper that pins the macOS 26 SDK, isolates module caches, and guards isolated scratch paths. | every other script, developer |
| `target-capture-smoke` | Verifies Input Target freezing against a real machine. | developer |
| `test` | The repository's full deterministic gate. | developer, CI |
| `test-brand-assets` | Regenerates brand assets into a temporary directory and compares them pixel by pixel. | `./scripts/test` |
| `test-compatibility-smoke` | Contract test for the compatibility report: partial PASS returns non-zero and the report stays `0600`. | `./scripts/test` |
| `test-development-build-identity` | Exercises development build metadata derivation and its failure modes. | `./scripts/test` |
| `test-install-identity` | Proves the installer refuses a same-Bundle-ID app with a broken signature. | `./scripts/test` |
| `test-install-rollback` | Injects a post-swap failure and confirms the old bundle is restored. | CI only |
| `test-provider-smoke-contract` | Asserts `provider-smoke` argument validation under the offline guard so the gate can never bill. | `./scripts/test` |
| `test-release-evidence` | Checks dSYM binding and evidence ZIP integrity with a real executable. | `./scripts/test`, CI |
| `test-release-identity` | Release identity, lock, promotion journal, and rollback counterexamples. | `./scripts/test` |
| `test-skills-lock` | Checks `skills-lock.json` is valid JSON and that every locked skill directory exists. | `./scripts/test` |
| `test-workflow-security` | GitHub workflow permission, pinning, and trigger counterexamples. | `./scripts/test` |
| `verify-provider-evidence` | Runs `SpeakerProviderEvidenceVerifier` over a provider matrix report. | developer, release |
| `verify-published-update` | Reads back the public appcast and archive and verifies EdDSA signature and release identity. | release |
| `verify-update-signature` | Runs `SpeakerUpdateSignatureVerifier` over an archive and its signature. | developer, release |

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
