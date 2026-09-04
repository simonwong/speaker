import SpeakerCore
import SwiftUI

struct PermissionSettingsPage: View {
    @ObservedObject var permissions: PermissionModel
    let requestPermission: (PermissionKind) async -> Void
    var buildInfo = SpeakerBuildInfoReader.main

    private var signingMode: SpeakerSigningMode {
        buildInfo.signingMode
    }

    var body: some View {
        SettingsCard {
            if let notice = signingMode.permissionIdentityNotice {
                SettingsNotice(text: notice, color: .orange)
                SettingsRowDivider()
            }

            PermissionSettingsRow(
                title: "麦克风",
                explanation: "音频只在内存中流式处理，不写入磁盘或历史。",
                kind: .microphone,
                state: permissions.snapshot.microphone,
                requestPermission: requestPermission
            )

            SettingsRowDivider()

            PermissionSettingsRow(
                title: "辅助功能",
                explanation: "监听全局快捷键，并把文字送达结束录音时的输入框。",
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
