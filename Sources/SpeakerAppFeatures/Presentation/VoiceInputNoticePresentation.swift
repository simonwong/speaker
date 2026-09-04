import SpeakerCore

/// The notice sentences the voice input surfaces announce. Each entry is
/// named so a specification can pin the case-to-sentence mapping without
/// repeating the wording.
package extension VoiceInputNotice {
    static let refinementNetworkFallbackMessage =
        "DeepSeek 请求发生网络错误，已使用豆包结果。"
    static let refinementAuthenticationFallbackMessage =
        "DeepSeek 鉴权失败，已使用豆包结果。"
    static let refinementRateLimitedFallbackMessage =
        "DeepSeek 请求被限流，已使用豆包结果。"
    static let refinementFallbackMessage =
        "DeepSeek 整理失败，已使用豆包结果。"

    var userMessage: String {
        switch self {
        case .copied:
            SpeakerCopy.Clipboard.textCopied
        case let .refinementFellBack(kind):
            switch kind {
            case .network, .systemNetworkTimeout:
                Self.refinementNetworkFallbackMessage
            case .invalidCredential, .authentication:
                Self.refinementAuthenticationFallbackMessage
            case .rateLimited:
                Self.refinementRateLimitedFallbackMessage
            default:
                Self.refinementFallbackMessage
            }
        case let .persistenceFailure(notice):
            SpeakerCopy.History.urgentNotice(notice)
        }
    }
}
