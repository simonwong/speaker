import SwiftUI

/// The Overview's top row while a `VoiceInputSetupGap` remains. It names what
/// is missing and opens the Settings group that fixes it. Finishing setup is
/// the one thing the Overview asks for, so its action is the only prominent
/// notice action.
package struct VoiceInputSetupBanner: View {
    let gap: VoiceInputSetupGap
    let open: () -> Void

    package var body: some View {
        SpeakerNotice(
            tone: .warning,
            text: Self.text(for: gap),
            action: .init(Self.actionTitle, prominent: true, perform: open)
        )
    }

    /// What is missing, and nothing more: the action says where to fix it.
    package static func text(for gap: VoiceInputSetupGap) -> String {
        switch gap {
        case .permissions:
            "缺少麦克风或辅助功能权限"
        case .speechRecognitionKey(let provider) where provider.isOnDevice:
            "\(provider.displayName)的语言模型未下载"
        case .speechRecognitionKey(let provider):
            "未保存\(provider.displayName)的 API Key"
        }
    }

    package static let actionTitle = "去设置"
}
