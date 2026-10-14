# ADR-0013: Keep development builds separate from the release on one Mac

Status: Accepted

Date: 2026-10-14

The developer uses the release every day and tests development builds on the same Mac. Before this decision both builds read and wrote `~/Library/Application Support/Speaker`, showed the same name in Privacy & Security, and a local install replaced `/Applications/Speaker.app`. A development build could therefore change settings, history, or the Personal Dictionary that the release then read, and testing meant losing the release.

A development build is now a separate app:

| | Release | Development |
| --- | --- | --- |
| Bundle ID | `ReleaseIdentity.plist` | `app.local.speaker` |
| Name | Speaker | Speaker Dev |
| Icon | `AppIcon.icns` | `AppIcon-Dev.icns`, with a DEV band |
| Signing | Developer ID, through `./scripts/distribute` | The Xcode team's Apple Development certificate |
| Installed at | `/Applications/Speaker.app`, from the DMG or Sparkle | `~/Applications/Speaker Dev.app` |
| Data | `~/Library/Application Support/Speaker` | `~/Library/Application Support/Speaker Dev` |
| Keys | Keychain | `credentials.json` in its own data directory |
| Updates | Sparkle | None |

`scripts/bundle` writes `CFBundleName`, `CFBundleDisplayName`, and `SpeakerDataDirectoryName` into every development bundle and swaps in the development icon. `SpeakerDataDirectory` reads `SpeakerDataDirectoryName` and falls back to `Speaker`, so the release needs no new key. Every store default, the erase intent file, the erasure locations, and the Settings folder link use that one name. Erasure in either build never touches the other build's directory.

Development signing prefers the single valid `Apple Development` identity in the login keychain, then a self-signed `Speaker Local Development`. `scripts/launch` and `scripts/release` skip identities that `security find-identity` marks as revoked or untrusted, and stop when none is left; they never fall back to ad-hoc signing. Gatekeeper treats an app signed with a revoked certificate as malware and moves it to the Trash, which is how this rule was found. A named identity keeps the designated requirement stable across rebuilds, so Microphone and Accessibility grants survive. `scripts/install` refuses to put a development build at `/Applications/Speaker.app`.

Both builds listen for the same global shortcut, so only one runs at a time. `scripts/launch` and `scripts/install` ask a running release to quit before they open a development build. Reopening the release afterwards is manual.

A development build starts with empty data and walks through onboarding once. Copying files from the release directory is a manual choice. Reading the release's settings is no longer an accidental compatibility test, so settings compatibility across versions stays with the settings specifications and `scripts/compatibility-smoke`.

Development bundles before this decision used `com.local.speaker`. Its preference domain, Keychain service, and legacy directories are still cleared by erasure and drained by credential migration; nothing new is written under that identifier.
