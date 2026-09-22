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
            iconTint: color
        ) {
            HStack(spacing: 10) {
                StatusBadge(
                    text: statusTitle,
                    icon: statusIcon,
                    color: color
                )

                if state != .granted, state != .restricted {
                    Button(buttonTitle) {
                        Task { await requestPermission(kind) }
                    }
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

    private var color: Color {
        switch state {
        case .granted:
            .green
        case .restricted:
            .red
        case .denied, .notDetermined:
            .orange
        }
    }

    private var statusTitle: String {
        switch state {
        case .granted:
            "已授权"
        case .restricted:
            "受系统限制"
        case .denied, .notDetermined:
            "待完成"
        }
    }

    private var statusIcon: String {
        switch state {
        case .granted:
            "checkmark"
        case .restricted:
            "lock.fill"
        case .denied, .notDetermined:
            "exclamationmark"
        }
    }

    private var buttonTitle: String {
        state == .notDetermined ? "请求授权" : "打开设置"
    }
}
