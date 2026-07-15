import Foundation
import Security

public enum ProviderID: String, CaseIterable, Sendable {
    case doubao
    case deepSeek = "deepseek"
}

public enum ProviderCredentialStoreError: Error, Equatable, Sendable {
    case emptyAPIKey
    case accessDenied
    case interactionUnavailable
    case malformedStoredValue
    case storageUnavailable
}

extension ProviderCredentialStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            "API Key 不能为空。"
        case .accessDenied:
            "无法访问本机凭据存储。"
        case .interactionUnavailable:
            "本机凭据存储当前不可用，请解锁 Mac 后重试。"
        case .malformedStoredValue:
            "已保存的 API Key 无法读取，请删除后重新保存。"
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

public actor KeychainProviderCredentialStore: ProviderCredentialStoring {
    public static let defaultService = "com.local.speaker.provider-api-keys"

    private let service: String

    public init(service: String = KeychainProviderCredentialStore.defaultService) {
        self.service = service
    }

    public func save(apiKey: String, for provider: ProviderID) async throws {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else {
            throw ProviderCredentialStoreError.emptyAPIKey
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
