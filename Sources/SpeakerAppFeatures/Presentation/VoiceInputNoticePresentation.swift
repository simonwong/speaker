import Foundation
import SpeakerCore

/// The notice sentences the voice input surfaces announce. Each entry is
/// named so a specification can pin the case-to-sentence mapping without
/// repeating the wording.
extension VoiceInputNotice {
    package static let refinementNetworkFallbackMessage =
        "文字整理请求发生网络错误，已使用语音识别结果。"
    package static let refinementAuthenticationFallbackMessage =
        "文字整理服务鉴权失败，已使用语音识别结果。"
    package static let refinementRateLimitedFallbackMessage =
        "文字整理请求被限流，已使用语音识别结果。"
    package static let refinementFallbackMessage =
        "文字整理失败，已使用语音识别结果。"
    package static let refinementFallbackHUDTitle = "整理失败，已输入识别结果"
    package static let recordingLimitReachedMessage =
        "已到单次录音上限，录音已自动结束，正在转成文字。"

    /// The HUD's line after delivery, for the notices worth seeing without
    /// opening the menu. The full sentence still goes to VoiceOver.
    package var hudTitle: String? {
        if case .refinementFellBack = self { Self.refinementFallbackHUDTitle } else { nil }
    }

    package var userMessage: String {
        switch self {
        case .copied:
            SpeakerCopy.Clipboard.textCopied
        case .recordingLimitReached:
            Self.recordingLimitReachedMessage
        case .refinementFellBack(let kind):
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
        case .persistenceFailure(let notice):
            SpeakerCopy.History.urgentNotice(notice)
        }
    }
}

/// The HUD note for a shortcut press refused because another App holds
/// Secure Event Input, such as a password field or a terminal's secure
/// keyboard entry.
package enum SecureInputBlockedNotice {
    package static let genericTitle = "安全输入已开启，暂时无法录音"

    package static func title(holderName: String?) -> String {
        guard let name = holderName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return genericTitle }
        return "\(name) 开启了安全输入，暂时无法录音"
    }
}
