import SpeakerCore

package extension VoiceInputActivity {
    var historyLabel: String {
        switch self {
        case .idle: "空闲"
        case .preparing: "准备中"
        case .recording: "录音中"
        case .processing: "处理中"
        case .delivered: "已自动送达"
        case .pendingCopy: "等待复制"
        case .cancelled: "已取消"
        case .failed: "失败"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .processing:
            true
        case .idle, .delivered, .pendingCopy, .cancelled, .failed:
            false
        }
    }

    var compactTitle: String {
        switch self {
        case .idle: "Speaker"
        case .preparing: "正在准备…"
        case .recording: "正在录音"
        case let .processing(_, stage, _): stage.compactTitle
        case .delivered: "已完成"
        case .pendingCopy: "文字已保留"
        case .cancelled: "已取消"
        case let .failed(_, failure): failure.userTitle
        }
    }

    var icon: String {
        switch self {
        case .idle: "waveform"
        case .preparing: "mic.badge.plus"
        case .recording: "mic.fill"
        case .processing: "sparkles"
        case .delivered: "checkmark.circle.fill"
        case .pendingCopy: "doc.on.clipboard"
        case .cancelled: "xmark.circle"
        case let .failed(_, failure): failure.userIcon
        }
    }

    var accessibilityAnnouncement: String? {
        switch self {
        case .idle:
            nil
        case .preparing:
            "Speaker 正在准备录音"
        case .recording:
            "Speaker 正在录音，按 Esc 可以取消"
        case let .processing(_, stage, _):
            stage.accessibilityAnnouncement
        case .delivered:
            "文字已输入"
        case let .pendingCopy(_, _, reason):
            "\(reason.userTitle)，文字已保留，可以选择复制"
        case .cancelled:
            "语音输入已取消"
        case let .failed(_, failure):
            "\(failure.userTitle)，\(failure.userGuidance)"
        }
    }
}

package extension VoiceInputProcessingStage {
    var compactTitle: String {
        switch self {
        case .capturingTarget: "正在准备文字…"
        case .transcribing: "正在转成文字…"
        case .refining: "正在整理表达…"
        case .delivering: "正在输入…"
        }
    }

    var accessibilityAnnouncement: String {
        switch self {
        case .capturingTarget: "正在确认输入位置"
        case .transcribing: "正在等待豆包返回文字"
        case .refining: "正在等待 DeepSeek 整理文字"
        case .delivering: "正在输入文字"
        }
    }
}

package extension PendingCopyReason {
    var userTitle: String {
        switch self {
        case .missingTarget: "没有检测到输入框"
        case .accessibilityPermissionMissing: "辅助功能权限不可用"
        case .secureTarget: "已跳过密码框"
        case .unsupportedTarget: "这个输入框需要手动粘贴"
        case .invalidatedTarget, .changedTarget: "输入位置已经变化"
        case .deliveryFailed: "文字需要手动粘贴"
        case .targetApplicationUnresponsive, .deliveryTimedOut:
            "目标应用没有响应"
        case .deliveryUnconfirmed: "可能已经输入，请先检查"
        case .clipboardFailed: "复制失败，请重试"
        }
    }
}
