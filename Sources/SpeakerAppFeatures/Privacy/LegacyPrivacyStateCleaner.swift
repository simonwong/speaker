import Foundation

/// Removes privacy-sensitive state used by older builds once the production
/// request contract no longer depends on it.
package enum LegacyPrivacyStateCleaner {
    package static let installationIdentifierKey = "localInstallationID"

    package static func removeObsoleteIdentifiers(
        from defaults: UserDefaults,
        legacyDefaults: UserDefaults? = UserDefaults(
            suiteName: SpeakerRetiredBundleIdentifiers.development
        )
    ) {
        defaults.removeObject(forKey: installationIdentifierKey)
        legacyDefaults?.removeObject(forKey: installationIdentifierKey)
    }
}
