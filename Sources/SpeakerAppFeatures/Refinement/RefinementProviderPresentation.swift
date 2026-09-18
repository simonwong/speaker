import Foundation
import SpeakerCore

extension RefinementProviderID {
    package var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .kimi: "Kimi"
        case .glm: "GLM"
        case .custom: "自定义"
        }
    }
}
