import SpeakerCore
import SwiftUI

struct PermissionSettingsPage: View {
    @ObservedObject var permissions: PermissionModel
    let requestPermission: (PermissionKind) async -> Void

    var body: some View {
        SettingsCard {
            PermissionSettingsRow(
                title: "麦克风",
                explanation: "录制语音",
                kind: .microphone,
                state: permissions.snapshot.microphone,
                requestPermission: requestPermission
            )

            SettingsRowDivider()

            PermissionSettingsRow(
                title: "辅助功能",
                explanation: "响应快捷键并输入文字",
                kind: .accessibility,
                state: permissions.snapshot.accessibility,
                requestPermission: requestPermission
            )
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let explanation: String
    let kind: PermissionKind
    let state: PermissionState
    let requestPermission: (PermissionKind) async -> Void

    var body: some View {
        SpeakerRow(
            title,
            detail: explanation,
            icon: icon,
            iconTint: status.tint
        ) {
            HStack(spacing: 10) {
                StatusBadge(
                    text: status.text,
                    icon: status.symbolName,
                    color: status.tint
                )

                if state != .granted, state != .restricted {
                    Button(buttonTitle) {
                        Task { await requestPermission(kind) }
                    }
                    // Both rows can show the same title; VoiceOver hears which.
                    .accessibilityLabel(
                        state == .notDetermined ? "请求\(title)权限" : "打开\(title)设置"
                    )
                }
            }
        }
    }

    private var icon: String {
        switch kind {
        case .accessibility: "accessibility"
        case .microphone: "mic.fill"
        }
    }

    private var status: PermissionStatusPresentation {
        PermissionStatusPresentation(state: state)
    }

    private var buttonTitle: String {
        state == .notDetermined ? "请求授权" : "打开设置"
    }
}
