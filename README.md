<div align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Speaker app icon">
  <h1>Speaker</h1>
  <p>A privacy-conscious macOS voice-input tool that turns speech into text wherever you are typing.</p>

  <p><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

  <p>
    <a href="https://github.com/simonwong/speaker/actions/workflows/ci.yml"><img src="https://github.com/simonwong/speaker/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
    <a href="https://github.com/simonwong/speaker/releases"><img src="https://img.shields.io/badge/Download-development%20build-2F81F7?logo=github" alt="Download the latest development build"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 or later">
    <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT License"></a>
  </p>
</div>

Speaker lives in the menu bar and uses `Fn` as its default shortcut. Hold the key while speaking and release it to finish, or short-press once to start and again to stop. Speaker streams audio to Doubao for real-time transcription, optionally refines the confirmed text with DeepSeek, and delivers the result to the input position that was focused when recording ended.

If Speaker cannot prove that the original input target is still safe and current, it keeps the result in a HUD for explicit copying instead of risking delivery to the wrong place.

> [!IMPORTANT]
> Speaker development builds are ad-hoc signed and are not Apple-notarized. macOS will block the first launch until you explicitly remove the quarantine attribute from the downloaded `Speaker.app`. Only download builds from this repository's official [Releases](https://github.com/simonwong/speaker/releases) page.

## Highlights

- **Natural voice shortcut** — hold or short-press `Fn`, choose a custom shortcut, and press `Esc` to cancel at any time.
- **Target-safe delivery** — the input target is frozen when recording ends; later window or focus changes never retarget the result.
- **Real-time transcription** — audio streams to Doubao's `bigmodel_async` WebSocket ASR while you speak.
- **Optional text refinement** — Default Smoothing uses Doubao only. Concise Cleanup, Full Rewrite, and Custom Modes use your DeepSeek key and send text only, never audio.
- **Local controls** — Personal Dictionary, searchable Session Records, retention settings, and redacted diagnostics remain under the current macOS user account.
- **Conservative privacy boundaries** — raw audio is never written to disk, secure input text is never stored in history, and Speaker changes the clipboard only after an explicit Copy action.

## Requirements

| Requirement | Details |
| --- | --- |
| Operating system | macOS 14 or later |
| Transcription | A user-supplied Doubao API key and an activated streaming ASR resource |
| Refinement | A DeepSeek API key is optional and is required only for non-default Refinement Modes |

## Download and run

1. Open [GitHub Releases](https://github.com/simonwong/speaker/releases) and download the newest `Speaker-<version>-development.zip` and its `.sha256` file.
2. Verify the downloaded archive against the published checksum, then unzip it and move `Speaker.app` into `/Applications`.
3. Remove the quarantine attribute from this app only, then launch it:

```bash
cd ~/Downloads
shasum -a 256 -c Speaker-*-development.zip.sha256
```

```bash
xattr -dr com.apple.quarantine /Applications/Speaker.app
open /Applications/Speaker.app
```

Keep the downloaded ZIP and checksum file in the same directory. The checksum command must report `OK` before you continue.

The `xattr` command removes Gatekeeper's quarantine marker only from `/Applications/Speaker.app`; it does not disable Gatekeeper system-wide. Because each development build has an ad-hoc identity, updating Speaker can require macOS to approve Microphone and Accessibility access again.

### First run

1. Follow Speaker's onboarding to request Microphone and Accessibility access.
2. Enable `/Applications/Speaker.app` in **System Settings → Privacy & Security → Accessibility** when macOS opens that page.
3. In **Doubao Speech**, enter an API key from the [Doubao Speech console](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default), select a streaming resource enabled for that account, and run **Check Connection**.
4. Focus an input field in any app, then hold `Fn` while speaking and release it to finish. A short press followed by another short press also starts and stops recording.

If an update leaves stale permission entries, reset only Speaker's local bundle identity:

```bash
tccutil reset Accessibility com.local.speaker
tccutil reset Microphone com.local.speaker
open /Applications/Speaker.app
```

Then enable Speaker again in System Settings. These commands do not reset permissions for other applications.

## How it works

1. Speaker captures microphone input in memory as 16 kHz, 16-bit mono PCM and streams it to Doubao in short chunks.
2. Releasing the shortcut freezes the current Input Target and asks Doubao for the final Stage Result.
3. Default Smoothing uses that Doubao result directly. Other Refinement Modes may send the confirmed text and selected instruction to DeepSeek.
4. Speaker revalidates the original Input Target before committing delivery. An uncertain, changed, closed, or secure target becomes a Pending Copy Result instead.

Audio is sent only to Doubao. It is never sent to DeepSeek or persisted as a normal application artifact.

## Privacy

Speaker has no hosted account service or shared provider credentials. You supply your own provider keys. Local ad-hoc builds store credentials in an owner-only application data file; a production Developer ID build uses macOS Keychain. Settings, Personal Dictionary entries, and Session Records are stored locally with owner-only persistence.

See [Privacy](PRIVACY.md) for the complete data-handling contract, local storage paths, provider boundaries, retention behavior, and diagnostic redaction rules.

## Development

Building Speaker requires Swift 6 and the macOS 26 SDK, normally provided by Xcode 26 or compatible Command Line Tools. The wrappers prefer `/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk`; set `SPEAKER_SDKROOT` to use another macOS 26-or-later SDK.

Use the repository wrappers so local builds match CI:

```bash
./scripts/test
./scripts/build
```

| Command | Purpose |
| --- | --- |
| `./scripts/test` | Run the deterministic specification executables and script checks |
| `./scripts/build` | Build the debug `SpeakerApp` product |
| `./scripts/provider-smoke doubao\|deepseek` | Check a configured provider connection using locally saved credentials |

Bare `swift build`, `swift run`, and `swift test` do not use the repository's pinned SDK and cache configuration and therefore do not represent the supported build path.

## Documentation

- [Voice input specification](docs/specs/voice-input.md) — product behavior, boundaries, and acceptance decisions
- [Architecture](docs/architecture.md) — modules, seams, adapters, and system invariants
- [Compatibility matrix](docs/compatibility.md) — real-application delivery evidence
- [Release process](docs/releasing.md) — local installation and production distribution
- [Production readiness](docs/production-readiness.md) — remaining gates for a signed public release

## Contributing

Focused issues and pull requests are welcome. For substantial behavior or architecture changes, open a [GitHub Issue](https://github.com/simonwong/speaker/issues) first so the product contract and verification approach can be agreed before implementation. Keep changes scoped, use the repository scripts, and include deterministic specifications for changed behavior.

## License

Speaker is available under the [MIT License](LICENSE).
