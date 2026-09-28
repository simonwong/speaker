import SpeakerCore
import SwiftUI

struct ShortcutSettingsPage: View {
    @ObservedObject var shortcut: VoiceShortcutFeature
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel
    let openPermissionSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        SettingsCard {
            recorderRow

            if shortcutRecorder.isRecording,
                let notice = shortcutRecorder.notice
            {
                recordingNotice(notice)
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
        HStack(spacing: 14) {
            ShortcutKeycap(name: shortcut.preference.displayName)

            // The keycap already names a working shortcut; only a shortcut
            // that is not listening needs words beside it.
            if let status = shortcutStatus {
                StatusBadge(text: status.text, icon: status.icon, color: status.color)
            }

            Spacer()

            Button("使用 Fn") {
                shortcutRecorder.stop()
                shortcut.select(.functionKey)
            }
            .disabled(shortcut.activation.activePreference == .functionKey)

            Button(shortcutRecorder.isRecording ? "取消" : "更改快捷键") {
                if shortcutRecorder.isRecording {
                    shortcutRecorder.stop()
                } else {
                    shortcutRecorder.start { hotKey in
                        shortcut.select(.init(customHotKey: hotKey))
                    }
                }
            }
        }
    }

    private func recordingNotice(_ notice: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "circle.fill")
                // A fixed 8pt recording light, not a text glyph.
                .font(.system(size: 8))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text(notice)
                .font(SpeakerTypography.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color.primary.opacity(contrast == .increased ? 0.08 : 0.04),
            in: noticeShape
        )
        .overlay {
            if contrast == .increased {
                noticeShape.stroke(Color.secondary.opacity(0.7), lineWidth: 1)
            }
        }
    }

    private var noticeShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
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
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        Text(name)
            .font(Font.system(.title2, design: .rounded).weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 72, minHeight: 40)
            .background(Color.primary.opacity(0.06), in: shape)
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.4 : 0.10),
                    lineWidth: 1
                )
            }
    }
}
