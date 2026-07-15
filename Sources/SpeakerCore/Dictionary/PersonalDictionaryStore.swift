import Foundation

public enum PersonalDictionaryStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case corruptedData
    case readFailed
    case writeFailed
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
        }
    }
}

public protocol PersonalDictionaryStoring: Sendable {
    func load() async throws -> PersonalDictionary
    func save(_ dictionary: PersonalDictionary) async throws
}

public actor VersionedJSONPersonalDictionaryStore: PersonalDictionaryStoring {
    public static let currentVersion = 1

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private struct Envelope: Codable {
        let version: Int
        let entries: [DictionaryEntry]
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

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

    public func load() async throws -> PersonalDictionary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PersonalDictionaryStoreError.readFailed
        }

        let version: Int
        do {
            version = try JSONDecoder().decode(VersionHeader.self, from: data).version
        } catch {
            throw PersonalDictionaryStoreError.corruptedData
        }
        guard version == Self.currentVersion else {
            throw PersonalDictionaryStoreError.unsupportedVersion(version)
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw PersonalDictionaryStoreError.corruptedData
        }

        do {
            return try PersonalDictionary(entries: envelope.entries)
        } catch {
            throw PersonalDictionaryStoreError.corruptedData
        }
    }

    public func save(_ dictionary: PersonalDictionary) async throws {
        let envelope = Envelope(version: Self.currentVersion, entries: dictionary.entries)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(envelope)
        } catch {
            throw PersonalDictionaryStoreError.writeFailed
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw PersonalDictionaryStoreError.writeFailed
        }
    }
}
