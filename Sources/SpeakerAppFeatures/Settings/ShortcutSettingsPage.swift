import SpeakerCore
import SwiftUI

struct ShortcutSettingsPage: View {
    @ObservedObject var shortcut: VoiceShortcutFeature
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel
    let openPermissionSettings: () -> Void

    var body: some View {
        SettingsCard {
            recorderRow

            if shortcutRecorder.isRecording, let rejection = shortcutRecorder.rejection {
                Text(rejection)
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.orange)
            }

            if shortcut.preference == .functionKey, !shortcutRecorder.isRecording {
                FunctionKeyConflictHint()
            }

            if let notice = shortcut.notice {
                SettingsNotice(
                    text: notice.message,
                    color: noticeColor(notice.level)
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
                ShortcutKeycap(
                    name: shortcutRecorder.isRecording
                        ? "按下新快捷键" : shortcut.preference.displayName,
                    isListening: shortcutRecorder.isRecording
                )

                // The keycap already names a working shortcut; only a shortcut
                // that is not listening needs words beside it.
                if let status = shortcutStatus, !shortcutRecorder.isRecording {
                    StatusBadge(text: status.text, icon: status.icon, color: status.color)
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

    private var shortcutStatus: (text: String, icon: String, color: Color)? {
        switch shortcut.activation {
        case .active:
            nil
        case .waitingForAccessibility:
            ("已选择，等待辅助功能权限", "exclamationmark.circle.fill", .orange)
        case .unavailable:
            ("已选择，但监听尚未启用", "exclamationmark.circle.fill", .orange)
        case .stopped:
            ("监听已停止", "pause.circle.fill", .red)
        }
    }

    private func noticeColor(_ level: VoiceShortcutNotice.Level) -> Color {
        switch level {
        case .information: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

/// The current shortcut drawn as one key. Settings and the onboarding
/// tutorial show the same keycap.
struct ShortcutKeycap: View {
    let name: String
    /// Settings is waiting for a new shortcut: the keycap asks for one.
    var isListening = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        Text(name)
            .font(
                isListening
                    ? SpeakerTypography.body
                    : Font.system(.title2, design: .rounded).weight(.semibold)
            )
            .foregroundStyle(isListening ? .secondary : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 72, minHeight: 40)
            .background(Color.primary.opacity(0.06), in: shape)
            .overlay {
                if isListening {
                    shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
                } else {
                    shape.strokeBorder(
                        Color.primary.opacity(contrast == .increased ? 0.4 : 0.10),
                        lineWidth: 1
                    )
                }
            }
    }
}
