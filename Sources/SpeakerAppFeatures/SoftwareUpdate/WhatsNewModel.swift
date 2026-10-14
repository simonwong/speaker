import Foundation

/// After an update, Overview offers the running version's release notes once.
///
/// The last version the user saw is a plain preference. A first install
/// records its version silently; an installation that finished setup before
/// this preference existed is treated as updated, so 0.8.0 users see the
/// notes of their first update too.
@MainActor
package final class WhatsNewModel: ObservableObject {
    package static let lastSeenVersionKey = "lastSeenVersion"

    /// The version whose notes are on offer, or nil once seen.
    @Published package private(set) var version: String?

    private let preferences: UserDefaults
    private let openURL: (URL) -> Void

    package init(
        preferences: UserDefaults,
        currentVersion: String?,
        hasCompletedSetup: Bool,
        openURL: @escaping (URL) -> Void
    ) {
        self.preferences = preferences
        self.openURL = openURL
        let pending = Self.pendingVersion(
            current: currentVersion,
            lastSeen: preferences.string(forKey: Self.lastSeenVersionKey),
            hasCompletedSetup: hasCompletedSetup
        )
        version = pending
        if pending == nil, let currentVersion = Self.normalized(currentVersion) {
            preferences.set(currentVersion, forKey: Self.lastSeenVersionKey)
        }
    }

    package static func pendingVersion(
        current: String?,
        lastSeen: String?,
        hasCompletedSetup: Bool
    ) -> String? {
        guard let current = normalized(current),
            ExternalLinks.releaseNotes(for: current) != nil
        else { return nil }
        guard let lastSeen = normalized(lastSeen) else {
            return hasCompletedSetup ? current : nil
        }
        return current.compare(lastSeen, options: .numeric) == .orderedDescending
            ? current : nil
    }

    package func open() {
        if let version, let url = ExternalLinks.releaseNotes(for: version) {
            openURL(url)
        }
        dismiss()
    }

    package func dismiss() {
        guard let version else { return }
        preferences.set(version, forKey: Self.lastSeenVersionKey)
        self.version = nil
    }

    private static func normalized(_ version: String?) -> String? {
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines),
            !version.isEmpty
        else { return nil }
        return version
    }
}
