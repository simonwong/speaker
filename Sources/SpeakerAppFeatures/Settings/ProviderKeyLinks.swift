import Foundation
import SpeakerCore

/// A link beside a provider's key field: where the Key is issued, or how to
/// apply for one.
package struct ProviderKeyLink: Equatable, Sendable {
    package let title: String
    package let url: URL

    /// Doubao's Key and streaming resource are set up in two places on the
    /// Volcengine console, so it also links to Speaker's walkthrough.
    package static let doubaoGuide = Self(title: "怎么申请？", url: ExternalLinks.doubaoSetupGuide)
    package static let doubaoConsole = Self(
        title: "豆包控制台", url: ExternalLinks.doubaoConsoleAPIKeys)

    /// On-device recognition has no Key and no console.
    package static func console(for provider: SpeechRecognitionProviderID, region: QwenASRRegion)
        -> Self?
    {
        switch provider {
        case .doubao: doubaoConsole
        case .openAI:
            Self(title: "OpenAI 控制台", url: ExternalLinks.openAIAPIKeys)
        case .qwen:
            switch region {
            case .beijing: Self(title: "百炼控制台", url: ExternalLinks.qwenBeijingAPIKeys)
            case .singapore:
                Self(title: "Model Studio 控制台", url: ExternalLinks.qwenSingaporeAPIKeys)
            }
        case .apple: nil
        }
    }

    /// A custom provider has no console Speaker knows about.
    package static func console(for provider: RefinementProviderID) -> Self? {
        switch provider {
        case .deepSeek: Self(title: "DeepSeek 控制台", url: ExternalLinks.deepSeekAPIKeys)
        case .openAI: Self(title: "OpenAI 控制台", url: ExternalLinks.openAIAPIKeys)
        case .kimi: Self(title: "Kimi 控制台", url: ExternalLinks.kimiAPIKeys)
        case .glm: Self(title: "智谱控制台", url: ExternalLinks.glmAPIKeys)
        case .custom: nil
        }
    }
}
