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
        guard let apiKey = try await credentials.apiKey(for: .deepSeek) else {
            throw DeepSeekRefinementFailure(kind: .invalidCredential)
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
}
