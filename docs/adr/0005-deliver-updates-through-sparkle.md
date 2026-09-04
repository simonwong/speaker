# ADR-0005: Deliver Updates Through Sparkle With Three Independent Verifications

Status: Accepted

Date: 2026-09-04

## Context

Speaker is distributed outside the Mac App Store ([ADR-0001](0001-run-outside-app-sandbox.md)), so no store review, no store transport, and no store installer stands between a published build and a user's Mac. Speaker also holds Accessibility and Microphone grants and reads the user's focused editable text, which makes a hijacked update a total compromise rather than an inconvenience.

Writing a custom updater would mean re-implementing signature verification, atomic bundle replacement, privileged installation, and resumable downloads, and every mistake would be invisible until abused. Returning to the Mac App Store would remove the assistive-application capability the product exists for. Sparkle is the established macOS out-of-store updater with published security history, appcast signing, verify-before-extraction, and atomic-safe installs; [`docs/research/secure-update-mechanism.md`](../research/secure-update-mechanism.md) records the version, configuration, and failure-mode survey behind this choice.

## Decision

Speaker updates through Sparkle, pinned in `Package.swift` as `exact: "2.9.4"`. The dependency is attached only to the `SpeakerApp` target; `SpeakerCore` and `SpeakerAppFeatures` never import Sparkle. A newer Sparkle arrives only through a reviewed dependency-update pull request that moves the pin to another exact version; Speaker never tracks `2.x`, a branch, or a prerelease.

The update chain has three independent verifications, and each one answers a different question:

- **Developer ID signing, Hardened Runtime, and notarization** prove to macOS and Gatekeeper who built the code and that Apple has scanned it. This covers first install and every launch.
- **The HTTPS appcast** protects the transport and, with `SURequireSignedFeed`, the update metadata itself: version, enclosure URL, length, and release notes.
- **The Ed25519 (EdDSA) signature** binds the downloaded artifact to Speaker's own update key, checked before extraction, independently of Apple's trust chain.

Apple notarization does not sign the appcast, and an Ed25519 signature produces no Gatekeeper ticket. Neither substitutes for the other, and the transport check substitutes for neither.

Update code lives behind a driver seam. `SoftwareUpdateFeature` in `SpeakerAppFeatures` owns availability, product state, and user intent. `SoftwareUpdateConfiguration` decides availability from the signing mode, an HTTPS feed URL, and a 32-byte non-placeholder public key; anything short of that is `unavailable`, and the live driver is never constructed. `SoftwareUpdateDriving` is the seam; `SparkleSoftwareUpdateDriver` in `SpeakerApp` is its only live implementation and the only place Sparkle types, KVO, and update UI exist. Development builds are `update.development-build` and never reach the production feed.

Production acceptance may inject one immutable `v<SemVer>` prerelease appcast through a launch argument. `SoftwareUpdateFeedOverridePolicy` accepts it only when the host, path shape, and repository match the stable feed and the version is a bare numeric SemVer; ordinary launches always use the stable `releases/latest` feed.

Two release gates bound publication, both described in [`docs/releasing.md`](../releasing.md). The **public readback gate** re-downloads the signed feed, DMG, and checksum from their production HTTPS addresses and re-verifies the Ed25519 signature, byte length, SHA-256, notarization, Gatekeeper, Developer ID, Team, and version against the reviewed public key. The **old-version upgrade gate** installs the candidate from a real, notarized previous release through the candidate-bound staging appcast and requires Sparkle update, Developer ID, TCC, and Keychain continuity to pass. Promotion then re-labels the same tag, DMG, checksum, and appcast; it never rebuilds or re-signs.

## Consequences

- None of the three verifications may be weakened, made optional, or traded against another. Removing signed-feed enforcement, verify-before-extraction, or notarization is a new decision, not a configuration tweak.
- A Sparkle version change is a reviewed dependency-update pull request with a new exact pin; the pin is never relaxed to a range to pick up fixes automatically.
- Update presentation stays in `SpeakerAppFeatures` and is testable with a deterministic driver and no network. Sparkle appcast items, error user info, download URLs, and signature details never reach SwiftUI.
- A configuration that cannot satisfy the production identity fails closed to an explicit status code rather than starting an updater that would show Sparkle's own configuration error.
- Because Sparkle 2 has no downgrade path, a bad release is answered by a higher build number, never by republishing an older artifact.
- Publication depends on evidence produced outside the application, so release gates, not application scenes, own distribution correctness.
