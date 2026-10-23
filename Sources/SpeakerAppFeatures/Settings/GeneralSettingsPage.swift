import SpeakerCore
import SwiftUI

struct GeneralSettingsPage: View {
    let loginItemSettings: LoginItemSettingsModel
    let historyRetention: HistoryRetentionSettingsModel
    let softwareUpdate: SoftwareUpdateFeature

    var body: some View {
        SpeakerCard {
            LaunchAtLoginSettingsRow(model: loginItemSettings)
            SpeakerRowDivider()
            HistoryRetentionSettingsRow(model: historyRetention)
            SpeakerRowDivider()
            AutomaticUpdateSettingsRow(model: softwareUpdate)
        }
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @ObservedObject var model: LoginItemSettingsModel

    var body: some View {
        SpeakerRow("登录时自动启动") {
            Toggle(
                "登录时自动启动",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { enabled in
                        Task { await model.setEnabled(enabled) }
                    }
                )
            )
            .speakerSwitch()
            .labelsHidden()
            .disabled(model.isUpdating)
        }

        if let notice = model.notice {
            SpeakerNotice(
                tone: .warning,
                text: notice,
                action: model.showsSystemSettingsButton
                    ? SpeakerNotice.Action("打开登录项设置") { model.openSystemSettings() }
                    : nil
            )
        }
    }
}

/// 历史保留策略的唯一入口：设置-通用。历史页不再提供策略切换。
private struct HistoryRetentionSettingsRow: View {
    @ObservedObject var model: HistoryRetentionSettingsModel

    var body: some View {
        SpeakerRow("保存历史") {
            Picker(
                "保存历史",
                selection: Binding(
                    get: { model.retentionPolicy },
                    set: { policy in
                        Task { await model.setRetentionPolicy(policy) }
                    }
                )
            ) {
                ForEach(HistoryRetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .speakerTrailingMenu()
            .disabled(model.isUpdating)
        }

        if let notice = model.notice {
            SpeakerNotice(tone: .warning, text: notice)
        }
    }
}

private struct AutomaticUpdateSettingsRow: View {
    @ObservedObject var model: SoftwareUpdateFeature

    var body: some View {
        SpeakerRow("自动检查更新") {
            Toggle(
                "自动检查更新",
                isOn: Binding(
                    get: { model.state.automaticallyChecksForUpdates },
                    set: { model.setAutomaticallyChecksForUpdates($0) }
                )
            )
            .speakerSwitch()
            .labelsHidden()
            .disabled(!model.state.isAvailable)
        }

        if let message = model.state.unavailableMessage {
            SpeakerNotice(text: message)
        }
    }
}
