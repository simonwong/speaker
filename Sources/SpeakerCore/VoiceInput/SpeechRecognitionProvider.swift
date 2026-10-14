import Foundation

public enum SpeechRecognitionProviderID: String, Codable, CaseIterable, Sendable {
    case doubao
    case openAI = "openai"
    case qwen
    case apple

    /// On-device providers transcribe on this Mac and need no API key.
    public var isOnDevice: Bool { self == .apple }
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
        provider == .doubao || provider.isOnDevice ? .streaming : .completeRecording
    }
}

public enum SpeechRecognitionProviderCatalog {
    public static func methods(for provider: SpeechRecognitionProviderID)
        -> [SpeechRecognitionMethod]
    {
        provider == .doubao || provider.isOnDevice
            ? [.streaming] : [.streaming, .completeRecording]
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
        case (.apple, .streaming): ["speech-transcriber"]
        case (.apple, .completeRecording): []
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

    /// The keychain entry holding this profile's API key; nil for on-device providers.
    public var credentialProviderID: ProviderID? {
        switch provider {
        case .doubao: .doubao
        case .openAI: .openAITranscription
        case .qwen: region == .beijing ? .qwenASRBeijing : .qwenASRSingapore
        case .apple: nil
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

    package var endpoint: URL? {
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
        case .apple: nil
        }
    }
}

/// Older builds decode `selectedProvider` with a closed enum and treat an unknown
/// value as corrupted settings. On-device selection therefore lives in its own
/// key, `selectedProvider` always holds the last cloud provider, and on-device
/// profiles are never written to `profiles`.
public struct SpeechRecognitionProviderSettings: Codable, Equatable, Sendable {
    public var selectedProvider: SpeechRecognitionProviderID {
        didSet { if !selectedProvider.isOnDevice { cloudProvider = selectedProvider } }
    }
    public var profiles: [String: SpeechRecognitionProfile]
    /// The cloud provider to fall back to when on-device recognition is unavailable.
    public private(set) var cloudProvider: SpeechRecognitionProviderID

    public init(
        selectedProvider: SpeechRecognitionProviderID = .doubao,
        profiles: [String: SpeechRecognitionProfile] = [:]
    ) {
        self.selectedProvider = selectedProvider
        self.profiles = profiles.filter { !$0.value.provider.isOnDevice }
        cloudProvider = selectedProvider.isOnDevice ? .doubao : selectedProvider
    }

    private enum CodingKeys: String, CodingKey {
        case selectedProvider, profiles, onDeviceProvider
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try values.decode(SpeechRecognitionProviderID.self, forKey: .selectedProvider)
        let profiles = try values.decode(
            [String: SpeechRecognitionProfile].self, forKey: .profiles)
        let onDevice = (try? values.decodeIfPresent(String.self, forKey: .onDeviceProvider))
            .flatMap { $0 }.flatMap(SpeechRecognitionProviderID.init(rawValue:))
            .flatMap { $0.isOnDevice ? $0 : nil }
        self.init(selectedProvider: stored, profiles: profiles)
        if let onDevice { selectedProvider = onDevice }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(cloudProvider, forKey: .selectedProvider)
        try values.encode(profiles.filter { !$0.value.provider.isOnDevice }, forKey: .profiles)
        if selectedProvider.isOnDevice {
            try values.encode(selectedProvider.rawValue, forKey: .onDeviceProvider)
        }
    }

    public func profile(for provider: SpeechRecognitionProviderID) -> SpeechRecognitionProfile {
        guard let profile = profiles[provider.rawValue], profile.provider == provider else {
            return .defaultProfile(for: provider)
        }
        return profile
    }

    public var selectedProfile: SpeechRecognitionProfile { profile(for: selectedProvider) }

    /// Falls back to the last cloud provider when on-device recognition is selected
    /// but this Mac cannot run it.
    public func resolved(onDeviceAvailable: Bool) -> Self {
        guard selectedProvider.isOnDevice, !onDeviceAvailable else { return self }
        var result = self
        result.selectedProvider = cloudProvider
        return result
    }

    public mutating func select(_ profile: SpeechRecognitionProfile) throws {
        let profile = try profile.validated()
        if !profile.provider.isOnDevice { profiles[profile.provider.rawValue] = profile }
        selectedProvider = profile.provider
    }

    public func validated() throws -> Self {
        var result = self
        for (key, profile) in profiles {
            guard key == profile.provider.rawValue, !profile.provider.isOnDevice else {
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
