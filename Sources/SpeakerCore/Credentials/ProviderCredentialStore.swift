import Foundation
import Security

public enum ProviderID: String, CaseIterable, Sendable {
    case doubao
    case deepSeek = "deepseek"
}

public enum ProviderCredentialStoreError: Error, Equatable, Sendable {
    case emptyAPIKey
    case apiKeyTooLarge
    case accessDenied
    case interactionUnavailable
    case malformedStoredValue
    case conflictingStoredValues
    case storageUnavailable
}

extension ProviderCredentialStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            "API Key 不能为空。"
        case .apiKeyTooLarge:
            "API Key 超出本机凭据存储允许的大小。"
        case .accessDenied:
            "无法访问本机凭据存储。"
        case .interactionUnavailable:
            "本机凭据存储当前不可用，请解锁 Mac 后重试。"
        case .malformedStoredValue:
            "已保存的 API Key 无法读取，请删除后重新保存。"
        case .conflictingStoredValues:
            "检测到多个旧凭据来源保存了不同的 API Key，已停止自动迁移并保留原数据。"
        case .storageUnavailable:
            "保存 API Key 失败，请稍后重试。"
        }
    }
}

public protocol ProviderCredentialStoring: Sendable {
    func save(apiKey: String, for provider: ProviderID) async throws
    func apiKey(for provider: ProviderID) async throws -> String?
    func deleteAPIKey(for provider: ProviderID) async throws
}

/// Stores BYOK credentials in Speaker's Application Support directory.
///
/// Local development builds are ad-hoc signed, so their Keychain identity can
/// change after every release build. An owner-only file gives those builds a
/// stable, non-interactive credential store while keeping the values local to
/// the current macOS account.
public actor LocalFileProviderCredentialStore: ProviderCredentialStoring {
    public static let currentSchemaVersion = 1
    private static let maximumDocumentByteCount = 256 * 1_024
    private static let maximumAPIKeyByteCount = 64 * 1_024

    private struct Document: Codable {
        let schemaVersion: Int
        var apiKeys: [String: String]
    }

    private let fileURL: URL

    public init(fileURL: URL = LocalFileProviderCredentialStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        fileManager: FileManager = .default,
        applicationDirectoryName: String = "Speaker"
    ) -> URL {
        let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser

        return baseDirectory
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
    }

    public func save(apiKey: String, for provider: ProviderID) async throws {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else {
            throw ProviderCredentialStoreError.emptyAPIKey
        }
        guard normalizedAPIKey.utf8.count <= Self.maximumAPIKeyByteCount else {
            throw ProviderCredentialStoreError.apiKeyTooLarge
        }

        var document = try loadDocument()
        document.apiKeys[provider.rawValue] = normalizedAPIKey
        try persist(document)
    }

    public func apiKey(for provider: ProviderID) async throws -> String? {
        let value = try loadDocument().apiKeys[provider.rawValue]
        guard let value else { return nil }
        guard !value.isEmpty else {
            throw ProviderCredentialStoreError.malformedStoredValue
        }
        return value
    }

    public func deleteAPIKey(for provider: ProviderID) async throws {
        var document = try loadDocument()
        guard document.apiKeys.removeValue(forKey: provider.rawValue) != nil else {
            return
        }
        if document.apiKeys.isEmpty {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            } catch {
                throw ProviderCredentialStoreError.storageUnavailable
            }
            return
        }
        try persist(document)
    }

    private func loadDocument() throws -> Document {
        do {
            try OwnerOnlyFilePersistence.protectExistingFile(at: fileURL)
        } catch {
            throw ProviderCredentialStoreError.storageUnavailable
        }
        do {
            guard let data = try OwnerOnlyFilePersistence.read(
                from: fileURL,
                maximumByteCount: Self.maximumDocumentByteCount
            ) else {
                return Document(schemaVersion: Self.currentSchemaVersion, apiKeys: [:])
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schemaVersion == Self.currentSchemaVersion else {
                throw ProviderCredentialStoreError.malformedStoredValue
            }
            return document
        } catch let error as ProviderCredentialStoreError {
            throw error
        } catch is DecodingError {
            throw ProviderCredentialStoreError.malformedStoredValue
        } catch {
            throw ProviderCredentialStoreError.storageUnavailable
        }
    }

    private func persist(_ document: Document) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            guard data.count <= Self.maximumDocumentByteCount else {
                throw ProviderCredentialStoreError.storageUnavailable
            }
            try OwnerOnlyFilePersistence.write(data, to: fileURL)
        } catch {
            throw ProviderCredentialStoreError.storageUnavailable
        }
    }
}

public actor KeychainProviderCredentialStore: ProviderCredentialStoring {
    public static let defaultService = "com.local.speaker.provider-api-keys"
    private static let maximumAPIKeyByteCount = 64 * 1_024

    private let service: String

    public init(service: String = KeychainProviderCredentialStore.defaultService) {
        self.service = service
    }

    public func save(apiKey: String, for provider: ProviderID) async throws {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else {
            throw ProviderCredentialStoreError.emptyAPIKey
        }
        guard normalizedAPIKey.utf8.count <= Self.maximumAPIKeyByteCount else {
            throw ProviderCredentialStoreError.apiKeyTooLarge
        }

        let valueData = Data(normalizedAPIKey.utf8)
        let query = itemQuery(for: provider)
        let attributes: [CFString: Any] = [
            kSecValueData: valueData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            attributes.forEach { item[$0] = $1 }
            try validate(SecItemAdd(item as CFDictionary, nil))
        default:
            try validate(updateStatus)
        }
    }

    public func apiKey(for provider: ProviderID) async throws -> String? {
        var query = itemQuery(for: provider)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try validate(status)

        guard
            let data = result as? Data,
            let apiKey = String(data: data, encoding: .utf8),
            !apiKey.isEmpty
        else {
            throw ProviderCredentialStoreError.malformedStoredValue
        }
        return apiKey
    }

    public func deleteAPIKey(for provider: ProviderID) async throws {
        let status = SecItemDelete(itemQuery(for: provider) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        try validate(status)
    }

    private func itemQuery(for provider: ProviderID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider.rawValue,
        ]
    }

    private func validate(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess:
            return
        case errSecAuthFailed, errSecUserCanceled, errSecMissingEntitlement:
            throw ProviderCredentialStoreError.accessDenied
        case errSecInteractionNotAllowed, errSecNotAvailable:
            throw ProviderCredentialStoreError.interactionUnavailable
        default:
            throw ProviderCredentialStoreError.storageUnavailable
        }
    }
}

/// Used only by stable signed builds. Reads the Keychain first, then performs
/// a one-way migration from the local development store and deletes the legacy
/// plaintext after the Keychain write is confirmed.
public actor MigratingProviderCredentialStore: ProviderCredentialStoring {
    private let primary: any ProviderCredentialStoring
    private let legacy: any ProviderCredentialStoring
    private var cleanupFailures: [ProviderID: String] = [:]

    public init(
        primary: any ProviderCredentialStoring,
        legacy: any ProviderCredentialStoring
    ) {
        self.primary = primary
        self.legacy = legacy
    }

    public func save(apiKey: String, for provider: ProviderID) async throws {
        try await primary.save(apiKey: apiKey, for: provider)
        let normalizedValue = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try await primary.apiKey(for: provider) == normalizedValue else {
            throw ProviderCredentialStoreError.storageUnavailable
        }
        await cleanLegacyIfMatchingPrimaryBestEffort(
            for: provider,
            primaryValue: normalizedValue
        )
    }

    public func apiKey(for provider: ProviderID) async throws -> String? {
        if let value = try await primary.apiKey(for: provider) {
            await cleanLegacyIfMatchingPrimaryBestEffort(
                for: provider,
                primaryValue: value
            )
            return value
        }
        guard let legacyValue = try await legacy.apiKey(for: provider) else {
            return nil
        }
        try await primary.save(apiKey: legacyValue, for: provider)
        guard try await primary.apiKey(for: provider) == legacyValue else {
            throw ProviderCredentialStoreError.storageUnavailable
        }
        await cleanLegacyIfMatchingPrimaryBestEffort(
            for: provider,
            primaryValue: legacyValue
        )
        return legacyValue
    }

    public func deleteAPIKey(for provider: ProviderID) async throws {
        // Legacy data must be gone before the trusted primary is removed.
        // Otherwise a failed plaintext cleanup can be migrated back into the
        // Keychain on the next read, effectively resurrecting a deleted key.
        try await legacy.deleteAPIKey(for: provider)
        guard try await legacy.apiKey(for: provider) == nil else {
            throw ProviderCredentialStoreError.storageUnavailable
        }
        try await primary.deleteAPIKey(for: provider)
        guard try await primary.apiKey(for: provider) == nil else {
            throw ProviderCredentialStoreError.storageUnavailable
        }
        cleanupFailures[provider] = nil
    }

    /// Proactively migrates every provider at startup so an unused optional
    /// provider cannot leave a plaintext development credential behind.
    public func migrateAllProviders() async {
        for provider in ProviderID.allCases {
            do {
                _ = try await apiKey(for: provider)
            } catch {
                cleanupFailures[provider] = Self.safeReason(error)
            }
        }
    }

    public func migrationNotice() -> String? {
        guard !cleanupFailures.isEmpty else { return nil }
        let providers = cleanupFailures.keys
            .map(\.rawValue)
            .sorted()
            .joined(separator: "、")
        return "\(providers) 的旧凭据尚未完成安全迁移；已保留可用的 Keychain 凭据，请在解锁 Mac 后重试。"
    }

    private func cleanLegacyIfMatchingPrimaryBestEffort(
        for provider: ProviderID,
        primaryValue: String
    ) async {
        do {
            guard let legacyValue = try await legacy.apiKey(for: provider) else {
                cleanupFailures[provider] = nil
                return
            }
            guard legacyValue == primaryValue else {
                cleanupFailures[provider] = Self.safeReason(
                    ProviderCredentialStoreError.conflictingStoredValues
                )
                return
            }
            try await legacy.deleteAPIKey(for: provider)
            guard try await legacy.apiKey(for: provider) == nil else {
                throw ProviderCredentialStoreError.storageUnavailable
            }
            cleanupFailures[provider] = nil
        } catch {
            cleanupFailures[provider] = Self.safeReason(error)
        }
    }

    private static func safeReason(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }
}

/// Reads legacy stores in order and always attempts to remove a provider from
/// every source. It is intentionally used only as the migration side of
/// `MigratingProviderCredentialStore`.
public actor LegacyProviderCredentialStoreChain: ProviderCredentialStoring {
    private let stores: [any ProviderCredentialStoring]

    public init(stores: [any ProviderCredentialStoring]) {
        self.stores = stores
    }

    public func save(apiKey: String, for provider: ProviderID) async throws {
        guard let first = stores.first else {
            throw ProviderCredentialStoreError.storageUnavailable
        }
        try await first.save(apiKey: apiKey, for: provider)
    }

    public func apiKey(for provider: ProviderID) async throws -> String? {
        var firstFailure: Error?
        var resolvedValue: String?
        for store in stores {
            do {
                if let value = try await store.apiKey(for: provider) {
                    if let resolvedValue, resolvedValue != value {
                        throw ProviderCredentialStoreError.conflictingStoredValues
                    }
                    resolvedValue = value
                }
            } catch let error as ProviderCredentialStoreError
                where error == .conflictingStoredValues
            {
                throw error
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        // Migration cleanup deletes every legacy source. A partial read is not
        // enough evidence to do that safely, even when another source yielded
        // a usable value.
        if let firstFailure { throw firstFailure }
        return resolvedValue
    }

    public func deleteAPIKey(for provider: ProviderID) async throws {
        var firstFailure: Error?
        for store in stores {
            do {
                try await store.deleteAPIKey(for: provider)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }
}
