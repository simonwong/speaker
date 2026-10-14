# ADR-0014: Move the release to `app.moonunder.speaker`

Status: Accepted

Date: 2026-10-14

Releases up to 0.8.0 ship as `cn.simonwong.speaker`. The product now lives at `speaker.moonunder.app`, and development builds already moved to `app.local.speaker` ([ADR-0013](0013-separate-development-and-release-builds.md)). The release moves to `app.moonunder.speaker` while it has few users. The Team (`D7QJXSW5GJ`), the Developer ID signing, the update feed, and the Ed25519 key do not change.

`Resources/ReleaseIdentity.plist` records the new identifier as `BundleIdentifier` and the old one as `RetiredBundleIdentifier`. The release scripts accept exactly one retired identifier, and it must differ from the current one.

## Updating across the change

Sparkle 2 installs a full update when the archive's Ed25519 signature verifies and the new app has a valid code signature. A different bundle identifier does not block this. Sparkle finds the new app in the DMG by name (`Speaker.app`), so 0.8.0 updates in place at `/Applications/Speaker.app`.

macOS treats the updated app as a new app:

| | After the update |
| --- | --- |
| Settings, history, Personal Dictionary | Kept. They live in `Application Support/Speaker`, which is chosen by name, not by bundle identifier. |
| Launch at login | Kept. The preference is in `settings.json`, and startup registers the new identifier. |
| Onboarding | Runs again. Its completion flag is in the preference domain, which is new. |
| Microphone and Accessibility | Granted again in onboarding. The old entries stay in System Settings until the user removes them. |
| Provider Keys | Entered again in onboarding. |
| What's New notice | Not shown; onboarding takes its place. |

Keys are not migrated. The old Keychain items trust only the old identity's designated requirement, so reading them from the new app shows a Keychain password prompt for each provider at startup, before any window explains why. Typing the Key once in onboarding is clearer than a series of unexplained password prompts. A user who never re-enters a Key keeps the old item until they erase data.

## Leftovers

"Clear local data and quit" in the release also removes the retired identifier's preference domain, caches, saved state, and Keychain service `cn.simonwong.speaker.provider-api-keys`. A development build never touches them. `SpeakerRetiredBundleIdentifiers` is the single list. Deleting another identity's Keychain item may show a Keychain prompt; erasure is user-initiated, so the prompt has context.

`scripts/launch` and `scripts/release` quit a release running under either identifier before they open a development build.

## Release gate

The first release under `app.moonunder.speaker` must update from the published 0.8.0 through its prerelease appcast before it becomes Latest. `scripts/compatibility-smoke` accepts an upgrade source under `RetiredBundleIdentifier`, writes `Identity Transition: cn.simonwong.speaker -> app.moonunder.speaker` into the report, and switches the TCC and Keychain cases to the transition's pass criteria: no Keychain prompt, onboarding opens, permissions and Keys work after granting them again, and data is kept. The evidence check rejects a changed identifier unless it matches `RetiredBundleIdentifier` and the report records the transition. If the update fails, the prerelease is not promoted.

The release notes for that version must tell users that onboarding will ask for permissions and Keys again, and that they can remove the old Speaker entries from Privacy & Security.

The Sparkle private key's Keychain account is still named `cn.simonwong.speaker`. It is a label for the signing key, not the app identity, and renaming it would change nothing for users.
