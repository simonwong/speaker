import SpeakerCore

/// The wording every voice input surface shows for a session's activity.
/// Each sentence is a named entry so a specification can pin which state
/// shows which sentence without repeating the sentence itself.
extension VoiceInputActivity {
    package static let idleCompactTitle = "Speaker"
    package static let preparingCompactTitle = "正在准备…"
    package static let recordingCompactTitle = "正在录音"
    package static let deliveredCompactTitle = "已完成"
    package static let pendingCopyCompactTitle = "文字已保留"
    package static let cancelledCompactTitle = "已取消"

    package static let preparingAnnouncement = "Speaker 正在准备录音"
    package static let recordingAnnouncement = "Speaker 正在录音，按 Esc 可以取消"
    package static let deliveredAnnouncement = "文字已输入"
    package static let cancelledAnnouncement = "语音输入已取消"

    /// The pending-copy announcement names the reason first, then repeats the
    /// promise that the text is still available.
    package static func pendingCopyAnnouncement(
        _ reason: PendingCopyReason
    ) -> String {
        "\(reason.userTitle)，文字已保留，可以选择复制"
    }

    /// A failure announcement names the failure, then its guidance.
    package static func failureAnnouncement(_ failure: VoiceInputFailure) -> String {
        "\(failure.userTitle)，\(failure.userGuidance)"
    }

    package var isActive: Bool {
        switch self {
        case .preparing, .recording, .processing:
            true
        case .idle, .delivered, .pendingCopy, .cancelled, .failed:
            false
        }
    }

    package var compactTitle: String {
        switch self {
        case .idle: Self.idleCompactTitle
        case .preparing: Self.preparingCompactTitle
        case .recording: Self.recordingCompactTitle
        case .processing(_, let stage, _): stage.compactTitle
        case .delivered: Self.deliveredCompactTitle
        case .pendingCopy: Self.pendingCopyCompactTitle
        case .cancelled: Self.cancelledCompactTitle
        case .failed(_, let failure): failure.userTitle
        }
    }

    package var icon: String {
        switch self {
        case .idle: "waveform"
        case .preparing: "mic.badge.plus"
        case .recording: "mic.fill"
        case .processing: "sparkles"
        case .delivered: "checkmark.circle.fill"
        case .pendingCopy: "doc.on.clipboard"
        case .cancelled: "xmark.circle"
        case .failed(_, let failure): failure.userIcon
        }
    }

    package var accessibilityAnnouncement: String? {
        switch self {
        case .idle:
            nil
        case .preparing:
            Self.preparingAnnouncement
        case .recording:
            Self.recordingAnnouncement
        case .processing(_, let stage, _):
            stage.accessibilityAnnouncement
        case .delivered:
            Self.deliveredAnnouncement
        case .pendingCopy(_, _, let reason):
            Self.pendingCopyAnnouncement(reason)
        case .cancelled:
            Self.cancelledAnnouncement
        case .failed(_, let failure):
            Self.failureAnnouncement(failure)
        }
    }
}

extension VoiceInputProcessingStage {
    package static let capturingTargetCompactTitle = "正在准备文字…"
    package static let transcribingCompactTitle = "正在转成文字…"
    package static let refiningCompactTitle = "正在整理表达…"
    package static let deliveringCompactTitle = "正在输入…"

    package static let capturingTargetAnnouncement = "正在确认输入位置"
    package static let transcribingAnnouncement = "正在等待豆包返回文字"
    package static let refiningAnnouncement = "正在等待 DeepSeek 整理文字"
    package static let deliveringAnnouncement = "正在输入文字"

    package var compactTitle: String {
        switch self {
        case .capturingTarget: Self.capturingTargetCompactTitle
        case .transcribing: Self.transcribingCompactTitle
        case .refining: Self.refiningCompactTitle
        case .delivering: Self.deliveringCompactTitle
        }
    }

    package var accessibilityAnnouncement: String {
        switch self {
        case .capturingTarget: Self.capturingTargetAnnouncement
        case .transcribing: Self.transcribingAnnouncement
        case .refining: Self.refiningAnnouncement
        case .delivering: Self.deliveringAnnouncement
        }
    }
}

extension PendingCopyReason {
    package static let missingTargetTitle = "没有检测到输入框"
    package static let accessibilityPermissionMissingTitle = "辅助功能权限不可用"
    package static let secureTargetTitle = "已跳过密码框"
    package static let unsupportedTargetTitle = "这个输入框需要手动粘贴"
    package static let changedTargetTitle = "输入位置已经变化"
    package static let deliveryFailedTitle = "文字需要手动粘贴"
    package static let targetApplicationUnresponsiveTitle = "目标应用没有响应"
    package static let deliveryUnconfirmedTitle = "可能已经输入，请先检查"
    package static let clipboardFailedTitle = "复制失败，请重试"

    package var userTitle: String {
        switch self {
        case .missingTarget: Self.missingTargetTitle
        case .accessibilityPermissionMissing:
            Self.accessibilityPermissionMissingTitle
        case .secureTarget: Self.secureTargetTitle
        case .unsupportedTarget: Self.unsupportedTargetTitle
        case .invalidatedTarget, .changedTarget: Self.changedTargetTitle
        case .deliveryFailed: Self.deliveryFailedTitle
        case .targetApplicationUnresponsive, .deliveryTimedOut:
            Self.targetApplicationUnresponsiveTitle
        case .deliveryUnconfirmed: Self.deliveryUnconfirmedTitle
        case .clipboardFailed: Self.clipboardFailedTitle
        }
    }
}
