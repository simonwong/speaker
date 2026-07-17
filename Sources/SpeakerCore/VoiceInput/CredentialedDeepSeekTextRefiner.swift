import Foundation

/// Resolves the user's current BYOK value for every request, keeping the key
/// out of settings persistence, session history, and long-lived app state.
public actor CredentialedDeepSeekTextRefiner: DeepSeekTextRefining {
    private let credentials: any ProviderCredentialStoring
    private let transport: any DeepSeekTransport
    private let endpoint: URL

    public init(
        credentials: any ProviderCredentialStoring,
        transport: any DeepSeekTransport = URLSessionDeepSeekTransport(),
        endpoint: URL = DeepSeekRefinementConfiguration.defaultEndpoint
    ) {
        self.credentials = credentials
        self.transport = transport
        self.endpoint = endpoint
    }

    public func refine(
        _ text: String,
        using mode: TextRefinementMode
    ) async throws -> DeepSeekRefinementResult {
        let apiKey: String
        do {
            guard let storedKey = try await credentials.apiKey(for: .deepSeek) else {
                throw DeepSeekRefinementFailure(kind: .invalidCredential)
            }
            apiKey = storedKey
        } catch let failure as ProviderCredentialStoreError {
            throw DeepSeekRefinementFailure(
                kind: Self.refinementFailureKind(for: failure)
            )
        }
        let client = DeepSeekRefinementClient(
            configuration: .init(apiKey: apiKey, endpoint: endpoint),
            transport: transport
        )
        return try await client.refine(text, using: mode)
    }

    public func hasAPIKey() async throws -> Bool {
        try await credentials.apiKey(for: .deepSeek) != nil
    }

    public func saveAPIKey(_ apiKey: String) async throws {
        try await credentials.save(apiKey: apiKey, for: .deepSeek)
    }

    public func deleteAPIKey() async throws {
        try await credentials.deleteAPIKey(for: .deepSeek)
    }

    public func checkConnection() async throws -> String? {
        try await refine(
            "连接检查。",
            using: .conciseCleanup
        ).providerRequestID
    }

    private static func refinementFailureKind(
        for failure: ProviderCredentialStoreError
    ) -> DeepSeekRefinementFailureKind {
        switch failure {
        case .emptyAPIKey, .apiKeyTooLarge:
            .invalidCredential
        case .accessDenied:
            .credentialAccessDenied
        case .interactionUnavailable:
            .credentialInteractionUnavailable
        case .malformedStoredValue:
            .credentialMalformed
        case .conflictingStoredValues, .storageUnavailable:
            .credentialStorageUnavailable
        }
    }
}
