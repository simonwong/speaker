import Foundation

public actor CredentialedTextRefiner: TextRefining {
    private struct CustomCredential: Codable {
        let baseURL: String
        let apiKey: String
    }

    private let credentials: any ProviderCredentialStoring
    private let transport: any ChatCompletionTransport

    public init(
        credentials: any ProviderCredentialStoring,
        transport: any ChatCompletionTransport = URLSessionChatCompletionTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    public func refine(
        _ text: String, using context: TextRefinementContext
    ) async throws -> TextRefinementResult {
        let profile = try context.provider.validated()
        let key: String
        do {
            guard let stored = try await apiKey(for: profile) else {
                throw TextRefinementFailure(kind: .invalidCredential)
            }
            key = stored
        } catch let failure as ProviderCredentialStoreError {
            let kind: TextRefinementFailureKind =
                switch failure {
                case .emptyAPIKey, .apiKeyTooLarge: .invalidCredential
                case .accessDenied: .credentialAccessDenied
                case .interactionUnavailable: .credentialInteractionUnavailable
                case .malformedStoredValue: .credentialMalformed
                case .conflictingStoredValues, .storageUnavailable: .credentialStorageUnavailable
                }
            throw TextRefinementFailure(kind: kind)
        }
        return try await ChatCompletionRefinementClient(
            configuration: .init(apiKey: key, profile: profile), transport: transport
        ).refine(text, using: context)
    }

    public func hasAPIKey(for profile: RefinementProviderProfile) async throws -> Bool {
        try await apiKey(for: profile.validated()) != nil
    }

    public func saveAPIKey(_ key: String, for profile: RefinementProviderProfile) async throws {
        let profile = try profile.validated()
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            !normalized.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { throw ProviderCredentialStoreError.emptyAPIKey }
        guard normalized.utf8.count <= 16_384 else {
            throw ProviderCredentialStoreError.apiKeyTooLarge
        }
        let stored: String
        if profile.provider == .custom {
            stored = String(
                decoding: try JSONEncoder().encode(
                    CustomCredential(baseURL: profile.baseURL, apiKey: normalized)
                ), as: UTF8.self)
        } else {
            stored = normalized
        }
        try await credentials.save(apiKey: stored, for: profile.provider.credentialProvider)
    }

    public func deleteAPIKey(for provider: RefinementProviderID) async throws {
        try await credentials.deleteAPIKey(for: provider.credentialProvider)
    }

    public func checkConnection(profile: RefinementProviderProfile) async throws -> String? {
        try await refine(
            "连接检查。", using: .init(mode: .conciseCleanup(), provider: profile)
        ).providerRequestID
    }

    private func apiKey(for profile: RefinementProviderProfile) async throws -> String? {
        guard let stored = try await credentials.apiKey(for: profile.provider.credentialProvider)
        else {
            return nil
        }
        guard profile.provider == .custom else { return stored }
        guard
            let envelope = try? JSONDecoder().decode(
                CustomCredential.self, from: Data(stored.utf8)),
            !envelope.apiKey.isEmpty
        else { throw ProviderCredentialStoreError.malformedStoredValue }
        guard envelope.baseURL == profile.baseURL else { return nil }
        return envelope.apiKey
    }
}
