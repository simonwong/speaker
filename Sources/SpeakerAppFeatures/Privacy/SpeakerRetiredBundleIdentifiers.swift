import Foundation
import SpeakerCore

/// Bundle identifiers Speaker no longer ships under. Nothing new is written
/// under them; erasure still clears their preference domain, caches, and
/// saved state.
package enum SpeakerRetiredBundleIdentifiers {
    /// Development builds before ADR-0013.
    package static let development = "com.local.speaker"
    /// The release up to 0.8.0, before ADR-0014.
    package static let release = "cn.simonwong.speaker"

    /// The retired identifiers whose leftovers belong to the build that owns
    /// `dataDirectoryName`. A development build never claims the release's.
    package static func owned(
        byDataDirectory dataDirectoryName: String = SpeakerDataDirectory.name
    ) -> [String] {
        dataDirectoryName == SpeakerDataDirectory.releaseName
            ? [development, release] : [development]
    }

    /// The Keychain services those identifiers stored provider Keys under.
    /// Erasure clears them. Keys under the retired release service are not
    /// migrated: the new identity cannot read them without a Keychain
    /// password prompt, so onboarding asks for the Key again.
    package static func keychainServices(
        byDataDirectory dataDirectoryName: String = SpeakerDataDirectory.name
    ) -> [String] {
        owned(byDataDirectory: dataDirectoryName).map { "\($0).provider-api-keys" }
    }
}
