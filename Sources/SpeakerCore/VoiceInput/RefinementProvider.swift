import Foundation

public enum RefinementProviderID: String, Codable, CaseIterable, Sendable {
    case deepSeek = "deepseek"
    case openAI = "openai"
    case kimi
    case glm
    case custom

    package var credentialProvider: ProviderID {
        switch self {
        case .deepSeek: .deepSeek
        case .openAI: .openAI
        case .kimi: .kimi
        case .glm: .glm
        case .custom: .customRefinement
        }
    }
}

public enum RefinementProviderCatalog {
    public static func modelIDs(for provider: RefinementProviderID) -> [String] {
        switch provider {
        case .deepSeek: ["deepseek-v4-flash", "deepseek-flash"]
        case .openAI: ["gpt-5.6-luna", "gpt-5.6-terra"]
        case .kimi: ["kimi-k2.6"]
        case .glm: ["glm-5.3-flash", "glm-4.7-flash", "glm-4.7-flashx", "glm-5.2"]
        case .custom: []
        }
    }

    public static func baseURL(for provider: RefinementProviderID) -> String {
        switch provider {
        case .deepSeek: "https://api.deepseek.com"
        case .openAI: "https://api.openai.com/v1"
        case .kimi: "https://api.moonshot.cn/v1"
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        case .custom: ""
        }
    }
}

public struct RefinementProviderProfile: Codable, Equatable, Sendable {
    public var provider: RefinementProviderID
    public var modelID: String
    public var baseURL: String

    public init(provider: RefinementProviderID, modelID: String, baseURL: String) {
        self.provider = provider
        self.modelID = modelID
        self.baseURL = baseURL
    }

    public static let legacyDeepSeek = Self(
        provider: .deepSeek, modelID: "deepseek-v4-flash",
        baseURL: RefinementProviderCatalog.baseURL(for: .deepSeek)
    )

    public static func defaultProfile(for provider: RefinementProviderID) -> Self {
        Self(
            provider: provider,
            modelID: RefinementProviderCatalog.modelIDs(for: provider).first ?? "",
            baseURL: RefinementProviderCatalog.baseURL(for: provider)
        )
    }

    public func validated() throws -> Self {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 200,
            !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw TextRefinementFailure(kind: .invalidRequest) }
        let address =
            provider == .custom ? baseURL : RefinementProviderCatalog.baseURL(for: provider)
        let normalizedURL = try Self.validatedBaseURL(address)
        return Self(provider: provider, modelID: model, baseURL: normalizedURL.absoluteString)
    }

    public func completionEndpoint() throws -> URL {
        let profile = try validated()
        return URL(string: profile.baseURL)!.appendingPathComponent("chat/completions")
    }

    private static func validatedBaseURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 2_048,
            !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            }),
            var components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            !components.path.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }),
            !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            components.port == nil || (1...65_535).contains(components.port!),
            !components.percentEncodedPath.lowercased().contains("%2f"),
            !components.percentEncodedPath.lowercased().contains("%5c"),
            !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw TextRefinementFailure(kind: .invalidRequest) }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw TextRefinementFailure(kind: .invalidRequest) }
        return url
    }
}

public struct RefinementProviderSettings: Codable, Equatable, Sendable {
    public var selectedProvider: RefinementProviderID
    public var profiles: [String: RefinementProviderProfile]

    public init(
        selectedProvider: RefinementProviderID = .deepSeek,
        profiles: [String: RefinementProviderProfile] = [:]
    ) {
        self.selectedProvider = selectedProvider
        self.profiles = profiles
    }

    public func profile(for provider: RefinementProviderID) -> RefinementProviderProfile {
        if let profile = profiles[provider.rawValue], profile.provider == provider {
            return profile
        }
        return provider == .deepSeek ? .legacyDeepSeek : .defaultProfile(for: provider)
    }

    public var selectedProfile: RefinementProviderProfile { profile(for: selectedProvider) }
}
