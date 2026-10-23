import SpeakerCore
import SwiftUI

struct ShortcutSettingsPage: View {
    @ObservedObject var shortcut: VoiceShortcutFeature
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel
    let openPermissionSettings: () -> Void

    var body: some View {
        SpeakerCard {
            recorderRow

            if shortcutRecorder.isRecording, let rejection = shortcutRecorder.rejection {
                Text(rejection)
                    .font(SpeakerTypography.detail)
                    .foregroundStyle(SpeakerTone.warning.color)
            }

            if shortcut.preference == .functionKey, !shortcutRecorder.isRecording {
                FunctionKeyConflictHint()
            }

            if let notice = shortcut.notice {
                SpeakerNotice(
                    tone: noticeTone(notice.level),
                    text: notice.message
                )
                if let recovery = notice.recovery {
                    recoveryRow(recovery)
                }
            }
        }
    }

    private var recorderRow: some View {
        SpeakerRow("录音快捷键") {
            HStack(spacing: 14) {
                SpeakerKeycap(
                    name: shortcutRecorder.isRecording
                        ? "按下新快捷键" : shortcut.preference.displayName,
                    isRecording: shortcutRecorder.isRecording
                )

                // The keycap already names a working shortcut; only a shortcut
                // that is not listening needs words beside it.
                if let status = shortcutStatus, !shortcutRecorder.isRecording {
                    StatusBadge(text: status.text, icon: status.icon, tone: status.tone)
                }

                recorderButtons
            }
        }
    }

    @ViewBuilder
    private var recorderButtons: some View {
        if shortcutRecorder.isRecording {
            Button("取消") { shortcutRecorder.stop() }
        } else {
            if shortcut.preference != .functionKey {
                Button("恢复默认") { shortcut.select(.functionKey) }
            }
            Button("更改快捷键") {
                // The live shortcut would swallow its own press before the
                // recorder saw it, so it stops listening until recording ends.
                shortcut.suspendForRecorder()
                shortcutRecorder.start(
                    onCapture: { hotKey in
                        shortcut.select(.init(customHotKey: hotKey))
                    },
                    onEnd: { shortcut.resumeAfterRecorder() }
                )
            }
        }
    }

    private func recoveryRow(
        _ recovery: VoiceShortcutNotice.Recovery
    ) -> some View {
        HStack {
            Spacer()
            Button(recovery == .openAccessibilitySettings ? "查看权限设置" : "重试") {
                switch recovery {
                case .retryActivation:
                    shortcut.retryActivation()
                case .retryPersistence:
                    shortcut.retryPersistence()
                case .openAccessibilitySettings:
                    openPermissionSettings()
                }
            }
        }
    }

    private var shortcutStatus: (text: String, icon: String, tone: SpeakerTone)? {
        switch shortcut.activation {
        case .active:
            nil
        case .waitingForAccessibility:
            ("已选择，等待辅助功能权限", "exclamationmark.circle.fill", .warning)
        case .unavailable:
            ("已选择，但监听尚未启用", "exclamationmark.circle.fill", .warning)
        case .stopped:
            ("监听已停止", "pause.circle.fill", .error)
        }
    }

    private func noticeTone(_ level: VoiceShortcutNotice.Level) -> SpeakerTone {
        switch level {
        case .information: .neutral
        case .warning: .warning
        case .error: .error
        }
    }
}
