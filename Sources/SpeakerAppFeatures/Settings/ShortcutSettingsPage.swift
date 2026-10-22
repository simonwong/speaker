import SpeakerCore
import SwiftUI

struct ShortcutSettingsPage: View {
    @ObservedObject var shortcut: VoiceShortcutFeature
    @ObservedObject var refinementModeShortcut: RefinementModeShortcutFeature
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel
    let openPermissionSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        SettingsCard {
            recorderRow

            if shortcut.preference == .functionKey {
                FunctionKeyConflictHint()
            }

            if shortcutRecorder.target == .recording,
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

            SettingsRowDivider()
            modeShortcutRow

            if shortcutRecorder.target == .refinementMode,
                let notice = shortcutRecorder.notice
            {
                recordingNotice(notice)
            }

            modeShortcutNotice
        }
    }

    /// The optional shortcut that steps to the next Refinement Mode for the
    /// next session. It never depends on the frontmost App.
    private var modeShortcutRow: some View {
        SpeakerRow(SpeakerCopy.RefinementModeShortcut.title) {
            HStack(spacing: 14) {
                ShortcutKeycap(
                    name: refinementModeShortcut.hotKey?.displayName
                        ?? SpeakerCopy.RefinementModeShortcut.unset
                )

                if let status = modeShortcutStatus {
                    StatusBadge(text: status.text, icon: status.icon, color: status.color)
                }

                if refinementModeShortcut.hotKey != nil {
                    Button("清除") {
                        shortcutRecorder.stop()
                        refinementModeShortcut.clear()
                    }
                }

                Button(
                    shortcutRecorder.target == .refinementMode
                        ? "取消" : refinementModeShortcut.hotKey == nil ? "设置快捷键" : "更改快捷键"
                ) {
                    if shortcutRecorder.target == .refinementMode {
                        shortcutRecorder.stop()
                    } else {
                        shortcutRecorder.start(
                            for: .refinementMode,
                            prompt: SpeakerCopy.RefinementModeShortcut.recordingPrompt,
                            validate: { hotKey in
                                RefinementModeShortcutFeature.rejection(
                                    for: hotKey, recordingShortcut: shortcut.preference
                                ).map(SpeakerCopy.RefinementModeShortcut.message(for:))
                            },
                            onCapture: { hotKey in
                                refinementModeShortcut.select(hotKey)
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modeShortcutNotice: some View {
        if shortcutRecorder.target != .refinementMode {
            Text("每按一次，下一次输入改用下一个整理模式；正在录音或处理的输入不受影响。")
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.secondary)
        }
        if refinementModeShortcut.persistenceFailed {
            SettingsNotice(text: "快捷键已生效，但未能保存到本机设置。", color: .orange)
            HStack {
                Spacer()
                Button("重试") { refinementModeShortcut.retryPersistence() }
            }
        }
    }

    private var modeShortcutStatus: (text: String, icon: String, color: Color)? {
        switch refinementModeShortcut.activation {
        case .notSet, .active:
            nil
        case .conflict:
            ("与录音快捷键相同，未启用", "exclamationmark.circle.fill", .orange)
        case .unavailable:
            ("已选择，但未能注册", "exclamationmark.circle.fill", .orange)
        case .stopped:
            ("已停止", "pause.circle.fill", .red)
        }
    }

    private var recorderRow: some View {
        SpeakerRow("录音快捷键") {
            HStack(spacing: 14) {
                ShortcutKeycap(name: shortcut.preference.displayName)

                // The keycap already names a working shortcut; only a shortcut
                // that is not listening needs words beside it.
                if let status = shortcutStatus {
                    StatusBadge(text: status.text, icon: status.icon, color: status.color)
                }

                recorderButtons
            }
        }
    }

    @ViewBuilder
    private var recorderButtons: some View {
        Button("使用 Fn") {
            shortcutRecorder.stop()
            shortcut.select(.functionKey)
        }
        .disabled(shortcut.activation.activePreference == .functionKey)

        Button(shortcutRecorder.target == .recording ? "取消" : "更改快捷键") {
            if shortcutRecorder.target == .recording {
                shortcutRecorder.stop()
            } else {
                shortcutRecorder.start(
                    for: .recording,
                    validate: { hotKey in
                        refinementModeShortcut.conflicts(withRecordingShortcut: hotKey)
                            ? SpeakerCopy.RefinementModeShortcut.usedByModeShortcut : nil
                    },
                    onCapture: { hotKey in
                        shortcut.select(.init(customHotKey: hotKey))
                    }
                )
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
