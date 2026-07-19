import Foundation

public enum PersonalDictionaryStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case corruptedData
    case readFailed
    case writeFailed
    case privacyProtectionFailed
}

extension PersonalDictionaryStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "个人词库文件版本 \(version) 暂不受支持。"
        case .corruptedData:
            "个人词库文件已损坏，请恢复或重建词库。"
        case .readFailed:
            "无法读取本机个人词库。"
        case .writeFailed:
            "无法保存本机个人词库。"
        case .privacyProtectionFailed:
            "无法把个人词库限制为仅当前用户可读，已停止加载。"
        }
    }
}

public protocol PersonalDictionaryStoring: Sendable {
    func load() async throws -> PersonalDictionary
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

    private struct VersionHeader: Decodable {
        let version: Int
    }

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

    public let fileURL: URL
    private let fileProtection: LocalFileProtection

    public init(fileURL: URL) {
        self.fileURL = fileURL
        fileProtection = .ownerOnly
    }

    package init(
        fileURL: URL,
        fileProtection: LocalFileProtection
    ) {
        self.fileURL = fileURL
        self.fileProtection = fileProtection
    }

    public static func defaultFileURL(
        fileManager: FileManager = .default,
        applicationDirectoryName: String = "Speaker"
    ) -> URL {
        let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return root
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
        return root
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
            let dictionary = try await legacyStore.load()
            try await primaryStore.save(dictionary)
            guard try await primaryStore.load() == dictionary else {
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

    public func load() async throws -> PersonalDictionary {
        do {
            try fileProtection.protect(fileURL)
        } catch {
            throw PersonalDictionaryStoreError.privacyProtectionFailed
        }
        let data: Data
        do {
            guard let storedData = try OwnerOnlyFilePersistence.read(
                from: fileURL,
                maximumByteCount: Self.maximumDocumentByteCount
            ) else {
                return .empty
            }
            data = storedData
        } catch {
            throw PersonalDictionaryStoreError.readFailed
        }

        let version: Int
        do {
            version = try JSONDecoder().decode(VersionHeader.self, from: data).version
        } catch {
            throw PersonalDictionaryStoreError.corruptedData
        }
        switch version {
        case Self.currentVersion:
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                return try PersonalDictionary(entries: envelope.entries)
            } catch {
                throw PersonalDictionaryStoreError.corruptedData
            }
        case 1:
            let dictionary: PersonalDictionary
            do {
                let envelope = try JSONDecoder().decode(LegacyEnvelopeV1.self, from: data)
                dictionary = try PersonalDictionary(entries: envelope.entries.map {
                    DictionaryEntry(id: $0.id, word: $0.canonicalTerm)
                })
            } catch {
                throw PersonalDictionaryStoreError.corruptedData
            }
            try await save(dictionary)
            return dictionary
        default:
            throw PersonalDictionaryStoreError.unsupportedVersion(version)
        }
    }

    public func save(_ dictionary: PersonalDictionary) async throws {
        let envelope = Envelope(version: Self.currentVersion, entries: dictionary.entries)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(envelope)
            guard data.count <= Self.maximumDocumentByteCount else {
                throw PersonalDictionaryStoreError.writeFailed
            }
        } catch {
            throw PersonalDictionaryStoreError.writeFailed
        }

        do {
            try OwnerOnlyFilePersistence.write(data, to: fileURL)
        } catch {
            throw PersonalDictionaryStoreError.writeFailed
        }
    }
}
