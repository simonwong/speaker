import Foundation

public enum PersonalDictionaryStoreError: Error, Equatable, Sendable {
    case readFailed
    case writeFailed
    case privacyProtectionFailed
    /// The file is corrupt and could not be moved aside; it stays in place and
    /// must not be overwritten.
    case corruptionPreservationFailed
}

/// A corrupt Personal Dictionary file that was moved aside before loading
/// continued from an empty dictionary.
public struct PersonalDictionaryRecovery: Equatable, Sendable {
    public let backupURL: URL
    public let reason: DocumentCorruption

    public init(backupURL: URL, reason: DocumentCorruption) {
        self.backupURL = backupURL
        self.reason = reason
    }
}

public struct PersonalDictionaryLoadResult: Equatable, Sendable {
    public let dictionary: PersonalDictionary
    /// Present when the stored file was corrupt and has been preserved.
    public let recovery: PersonalDictionaryRecovery?

    public init(
        dictionary: PersonalDictionary,
        recovery: PersonalDictionaryRecovery? = nil
    ) {
        self.dictionary = dictionary
        self.recovery = recovery
    }
}

public protocol PersonalDictionaryStoring: Sendable {
    func load() async throws -> PersonalDictionaryLoadResult
    func save(_ dictionary: PersonalDictionary) async throws
}

public enum PersonalDictionaryMigrationOutcome: Equatable, Sendable {
    case notNeeded
    case primaryAlreadyExists
    case migrated
    case migratedLegacyCleanupFailed
    case failed
}

public actor VersionedJSONPersonalDictionaryStore: PersonalDictionaryStoring {
    public static let currentVersion = 2
    private static let maximumDocumentByteCount = 8 * 1_024 * 1_024

    private struct Envelope: Codable {
        let version: Int
        let entries: [DictionaryEntry]
    }

    private struct LegacyEnvelopeV1: Decodable {
        let entries: [LegacyEntryV1]
    }

    private struct LegacyEntryV1: Decodable {
        let id: UUID
        let canonicalTerm: String
    }

    public nonisolated var fileURL: URL { documents.fileURL }
    private let documents: VersionedOwnerOnlyDocumentStore<PersonalDictionary>

    public init(fileURL: URL) {
        self.init(fileURL: fileURL, fileProtection: .ownerOnly)
    }

    package init(
        fileURL: URL,
        fileProtection: LocalFileProtection
    ) {
        documents = VersionedOwnerOnlyDocumentStore(
            fileURL: fileURL,
            schema: Self.schema,
            maximumByteCount: Self.maximumDocumentByteCount,
            backupInfix: "corrupt-",
            fileProtection: fileProtection
        )
    }

    /// Version dispatch is the migration seam. Version 1 stored canonical
    /// terms with aliases and an enabled flag; only the term survives.
    private static let schema = VersionedDocumentSchema<PersonalDictionary>(
        currentVersion: currentVersion,
        versionKey: .version,
        decoders: [
            2: { data in
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                return try PersonalDictionary(entries: envelope.entries)
            },
            1: { data in
                let envelope = try JSONDecoder().decode(LegacyEnvelopeV1.self, from: data)
                return try PersonalDictionary(
                    entries: envelope.entries.map {
                        DictionaryEntry(id: $0.id, word: $0.canonicalTerm)
                    })
            },
        ]
    )

    public static func defaultFileURL(
        fileManager: FileManager = .default,
        applicationDirectoryName: String = "Speaker"
    ) -> URL {
        let root =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
        return
            root
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent(
                "personal-dictionary.json",
                isDirectory: false
            )
    }

    /// Legacy development builds used the bundle identifier as their storage
    /// directory. Keep this locator only for one-way migration.
    public static func applicationSupportFileURL(
        bundleIdentifier: String = "com.local.speaker",
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return
            root
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("personal-dictionary.json", isDirectory: false)
    }

    public static func migrateLegacyFileIfNeeded(
        from legacyURL: URL,
        to primaryURL: URL
    ) async -> PersonalDictionaryMigrationOutcome {
        let legacyPath = legacyURL.standardizedFileURL.path
        let primaryPath = primaryURL.standardizedFileURL.path
        guard legacyPath != primaryPath,
            FileManager.default.fileExists(atPath: legacyPath)
        else {
            return .notNeeded
        }
        guard !FileManager.default.fileExists(atPath: primaryPath) else {
            return .primaryAlreadyExists
        }

        do {
            let legacyStore = VersionedJSONPersonalDictionaryStore(
                fileURL: legacyURL
            )
            let primaryStore = VersionedJSONPersonalDictionaryStore(
                fileURL: primaryURL
            )
            // A corrupt legacy file must stay where the user can find it, so
            // migration inspects it without preserving it as a sibling copy.
            guard let dictionary = try await legacyStore.decodeWithoutRecovery() else {
                return .failed
            }
            try await primaryStore.save(dictionary)
            guard try await primaryStore.load().dictionary == dictionary else {
                return .failed
            }
            do {
                try FileManager.default.removeItem(at: legacyURL)
                return .migrated
            } catch {
                return .migratedLegacyCleanupFailed
            }
        } catch {
            return .failed
        }
    }

    /// Loads the dictionary. A corrupt file is preserved as a timestamped
    /// sibling and the result carries that location together with an empty
    /// dictionary, so the user can keep working and still recover the file.
    /// A version 1 document is migrated and rewritten in the current version.
    public func load() async throws -> PersonalDictionaryLoadResult {
        switch documents.load().outcome {
        case .absent:
            return PersonalDictionaryLoadResult(dictionary: .empty)
        case .loaded(let dictionary, let version):
            if version != Self.currentVersion {
                try await save(dictionary)
            }
            return PersonalDictionaryLoadResult(dictionary: dictionary)
        case .corruptedPreserved(let backupURL, let corruption):
            return PersonalDictionaryLoadResult(
                dictionary: .empty,
                recovery: PersonalDictionaryRecovery(
                    backupURL: backupURL,
                    reason: corruption
                )
            )
        case .failed(let failure):
            throw Self.error(for: failure)
        }
    }

    /// Decodes the stored dictionary without moving a corrupt file aside.
    /// Returns nil when the file is corrupt.
    package func decodeWithoutRecovery() async throws -> PersonalDictionary? {
        switch documents.decode() {
        case .absent:
            return .empty
        case .decoded(let dictionary, _):
            return dictionary
        case .corrupted:
            return nil
        case .failed(let failure):
            throw Self.error(for: failure)
        }
    }

    public func save(_ dictionary: PersonalDictionary) async throws {
        let envelope = Envelope(version: Self.currentVersion, entries: dictionary.entries)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try documents.write(try encoder.encode(envelope))
        } catch {
            throw PersonalDictionaryStoreError.writeFailed
        }
    }

    private static func error(
        for failure: DocumentLoadFailure
    ) -> PersonalDictionaryStoreError {
        switch failure {
        case .protectionFailed: .privacyProtectionFailed
        case .readFailed: .readFailed
        case .preservationFailed: .corruptionPreservationFailed
        }
    }
}
