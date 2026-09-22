import Foundation

public enum SpeechRecognitionProviderID: String, Codable, CaseIterable, Sendable {
    case doubao
    case openAI = "openai"
    case qwen
}

public enum QwenASRRegion: String, Codable, CaseIterable, Sendable {
    case beijing
    case singapore
}

public enum SpeechRecognitionMethod: String, Codable, CaseIterable, Sendable {
    case streaming
    case completeRecording
    case unsupported

    public static let allCases: [Self] = [.streaming, .completeRecording]

    public static func defaultMethod(for provider: SpeechRecognitionProviderID) -> Self {
        provider == .doubao ? .streaming : .completeRecording
    }
}

public enum SpeechRecognitionProviderCatalog {
    public static func methods(for provider: SpeechRecognitionProviderID)
        -> [SpeechRecognitionMethod]
    {
        provider == .doubao ? [.streaming] : [.streaming, .completeRecording]
    }

    public static func modelIDs(
        for provider: SpeechRecognitionProviderID, method: SpeechRecognitionMethod? = nil
    ) -> [String] {
        switch (provider, method ?? .defaultMethod(for: provider)) {
        case (.doubao, .streaming): ["bigmodel_async"]
        case (.doubao, .completeRecording): []
        case (.openAI, .streaming): ["gpt-live-transcribe"]
        case (.openAI, .completeRecording):
            ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
        case (.qwen, .streaming): ["qwen3-asr-flash-realtime"]
        case (.qwen, .completeRecording): ["qwen3-asr-flash"]
        case (_, .unsupported): []
        }
    }
}

public struct SpeechRecognitionProfile: Codable, Equatable, Sendable {
    public var provider: SpeechRecognitionProviderID
    public var model: String
    public var method: SpeechRecognitionMethod
    public var region: QwenASRRegion

    public init(
        provider: SpeechRecognitionProviderID, model: String? = nil,
        region: QwenASRRegion = .beijing, method: SpeechRecognitionMethod? = nil
    ) {
        self.provider = provider
        self.method = method ?? .defaultMethod(for: provider)
        self.model =
            model ?? SpeechRecognitionProviderCatalog.modelIDs(for: provider, method: self.method)
            .first ?? ""
        self.region = region
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, region, method
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(SpeechRecognitionProviderID.self, forKey: .provider)
        model = try values.decode(String.self, forKey: .model)
        region = try values.decode(QwenASRRegion.self, forKey: .region)
        if values.contains(.method) {
            method =
                (try? values.decode(String.self, forKey: .method))
                .flatMap(SpeechRecognitionMethod.init(rawValue:)) ?? .unsupported
        } else {
            method = .defaultMethod(for: provider)
        }
    }

    public static let doubao = Self(provider: .doubao)

    public static func defaultProfile(for provider: SpeechRecognitionProviderID) -> Self {
        Self(provider: provider)
    }

    public var credentialProviderID: ProviderID {
        switch provider {
        case .doubao: .doubao
        case .openAI: .openAITranscription
        case .qwen: region == .beijing ? .qwenASRBeijing : .qwenASRSingapore
        }
    }

    public func validated() throws -> Self {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            SpeechRecognitionProviderCatalog.modelIDs(for: provider, method: method).contains(
                normalized)
        else {
            throw SpeechRecognitionFailure(provider: provider, kind: .invalidConfiguration)
        }
        return Self(provider: provider, model: normalized, region: region, method: method)
    }

    package var endpoint: URL {
        switch provider {
        case .doubao:
            URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
        case .openAI:
            URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        case .qwen:
            URL(
                string: region == .beijing
                    ? "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
                    : "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
            )!
        }
    }
}

public struct SpeechRecognitionProviderSettings: Codable, Equatable, Sendable {
    public var selectedProvider: SpeechRecognitionProviderID
    public var profiles: [String: SpeechRecognitionProfile]

    public init(
        selectedProvider: SpeechRecognitionProviderID = .doubao,
        profiles: [String: SpeechRecognitionProfile] = [:]
    ) {
        self.selectedProvider = selectedProvider
        self.profiles = profiles
    }

    public func profile(for provider: SpeechRecognitionProviderID) -> SpeechRecognitionProfile {
        guard let profile = profiles[provider.rawValue], profile.provider == provider else {
            return .defaultProfile(for: provider)
        }
        return profile
    }

    public var selectedProfile: SpeechRecognitionProfile { profile(for: selectedProvider) }

    public mutating func select(_ profile: SpeechRecognitionProfile) throws {
        let profile = try profile.validated()
        profiles[profile.provider.rawValue] = profile
        selectedProvider = profile.provider
    }

    public func validated() throws -> Self {
        var result = self
        for (key, profile) in profiles {
            guard key == profile.provider.rawValue else {
                throw SpeechRecognitionFailure(
                    provider: selectedProvider, kind: .invalidConfiguration)
            }
        }
        let selected = try result.selectedProfile.validated()
        if result.profiles[selectedProvider.rawValue] != nil {
            result.profiles[selectedProvider.rawValue] = selected
        }
        return result
    }
}
