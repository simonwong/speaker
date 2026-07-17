import SpeakerCore

package extension VoiceInputNotice {
    var userMessage: String {
        switch self {
        case .copied:
            "文字已复制"
        case let .refinementFellBack(kind):
            switch kind {
            case .network, .systemNetworkTimeout:
                "DeepSeek 请求发生网络错误，已使用豆包结果。"
            case .invalidCredential, .authentication:
                "DeepSeek 鉴权失败，已使用豆包结果。"
            case .rateLimited:
                "DeepSeek 请求被限流，已使用豆包结果。"
            default:
                "DeepSeek 整理失败，已使用豆包结果。"
            }
        case let .persistenceFailure(message):
            message
        }
    }
}
