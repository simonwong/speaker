import Foundation
import SpeakerCore

@MainActor
package final class SpeakerDataErasureIntentStore {
    package static let key = "speakerEraseAllPending"

    private let intentFileURL: URL
    private let preferences: UserDefaults
    private let preferenceDomainNames: [String]

    package init(
        intentFileURL: URL,
        preferences: UserDefaults,
        preferenceDomainNames: [String]
    ) {
        self.intentFileURL = intentFileURL
        self.preferences = preferences
        self.preferenceDomainNames = Array(Set(preferenceDomainNames))
    }

    package var isPending: Bool {
        do {
            return try OwnerOnlyFilePersistence.regularFileExists(
                at: intentFileURL
            ) || preferences.bool(forKey: Self.key)
        } catch {
            // An unsafe or unreadable marker path must keep erasure pending.
            return true
        }
    }

    package func persist() throws {
        do {
            try OwnerOnlyFilePersistence.write(
                Data("pending".utf8),
                to: intentFileURL
            )
        } catch let reason as SpeakerDataErasureReason {
            throw reason
        } catch {
            throw SpeakerDataErasureReason.io
        }
        guard isPending else { throw SpeakerDataErasureReason.io }
    }

    package func erasePreferences() throws {
        for domainName in preferenceDomainNames {
            preferences.removePersistentDomain(forName: domainName)
        }
        preferences.synchronize()
        guard preferenceDomainNames.allSatisfy({
            preferences.persistentDomain(forName: $0)?.isEmpty != false
        }) else {
            throw SpeakerDataErasureReason.verificationMismatch
        }
    }

    package func clearIntent() throws {
        do {
            _ = try OwnerOnlyFilePersistence.removeRegularFile(at: intentFileURL)
            _ = try OwnerOnlyFilePersistence.removeEmptyDirectory(
                at: intentFileURL.deletingLastPathComponent()
            )
            preferences.removeObject(forKey: Self.key)
            preferences.synchronize()
        } catch {
            throw SpeakerDataErasureReason.io
        }
        guard !isPending else {
            throw SpeakerDataErasureReason.verificationMismatch
        }
    }

    package static func defaultIntentFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Speaker", isDirectory: true)
            .appendingPathComponent("erase-all.pending", isDirectory: false)
    }
}
