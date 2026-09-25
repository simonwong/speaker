import AppKit
import SwiftUI

/// The menu bar extra's rows. Order comes from `MenuBarPresentation`; the
/// wording, symbols, and shortcuts of each row live here rather than in the
/// composition root.
package struct MenuBarContent: View {
    @ObservedObject var voiceInput: VoiceInputExperience
    @ObservedObject var refinement: RefinementSettingsModel
    @ObservedObject var microphones: MicrophoneSelectionFeature
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @ObservedObject var settingsNavigation: SettingsNavigationModel
    @ObservedObject var mainWindow: MainWindowModel
    let startRuntime: () -> Void
    let refreshPermissions: () -> Void
    let openOnboarding: () -> Void
    @Environment(\.openWindow) private var openWindow

    package init(
        voiceInput: VoiceInputExperience,
        refinement: RefinementSettingsModel,
        microphones: MicrophoneSelectionFeature,
        dataErasure: SpeakerDataErasureCoordinator,
        settingsNavigation: SettingsNavigationModel,
        mainWindow: MainWindowModel,
        startRuntime: @escaping () -> Void,
        refreshPermissions: @escaping () -> Void,
        openOnboarding: @escaping () -> Void
    ) {
        self.voiceInput = voiceInput
        self.refinement = refinement
        self.microphones = microphones
        self.dataErasure = dataErasure
        self.settingsNavigation = settingsNavigation
        self.mainWindow = mainWindow
        self.startRuntime = startRuntime
        self.refreshPermissions = refreshPermissions
        self.openOnboarding = openOnboarding
    }

    private var commandRouter: MenuBarCommandRouter {
        MenuBarCommandRouter(
            navigation: settingsNavigation,
            openOverview: { openMainWindow(.overview) },
            openOnboarding: openOnboarding,
            openSettings: { openMainWindow(.settings) },
            openDataErasureRecovery: { openMainWindow(.about) },
            activate: {
                NSApp.activate(ignoringOtherApps: true)
            },
            terminate: { NSApp.terminate(nil) }
        )
    }

    private var rows: [MenuBarRow] {
        MenuBarPresentation.rows(
            voice: MenuBarVoiceCapabilities(menu: voiceInput.state.menu),
            workspaceRoute: dataErasure.state.workspaceRoute
        )
    }

    private func openMainWindow(_ tab: MainWindowTab) {
        mainWindow.select(tab)
        openWindow(id: MainWindowModel.windowID)
    }

    package var body: some View {
        Group {
            ForEach(rows.indices, id: \.self) { index in
                row(rows[index])
            }
        }
        .task {
            startRuntime()
            if dataErasure.state == .idle {
                refreshPermissions()
            }
        }
    }

    @ViewBuilder
    private func row(_ row: MenuBarRow) -> some View {
        switch row {
        case .openSpeaker:
            Button("打开 Speaker") {
                commandRouter.perform(.overview)
            }
        case .refinementMode:
            Menu {
                refinementToggle(.defaultSmooth, title: SpeakerCopy.RefinementMode.defaultSmooth)
                refinementToggle(.conciseCleanup, title: SpeakerCopy.RefinementMode.conciseCleanup)
                refinementToggle(.fullRewrite, title: SpeakerCopy.RefinementMode.fullRewrite)
                if let customModeName = refinement.savedCustomModeName {
                    refinementToggle(.custom, title: customModeName)
                }
            } label: {
                Label(refinement.mode.displayName, systemImage: "text.alignleft")
            }
        case .microphone:
            MicrophoneSelectionMenu(model: microphones)
        case .voiceStatus:
            if let status = voiceInput.state.menu.status {
                Label(
                    status.title,
                    systemImage: status.icon
                )
            }
        case .cancelVoiceInput:
            if let cancelAction = voiceInput.state.menu.cancelAction {
                Button("取消当前输入") {
                    voiceInput.perform(cancelAction)
                }
            }
        case .voiceNotice:
            if let notice = voiceInput.state.menu.notice {
                Label(notice, systemImage: "info.circle")
            }
        case .copyRetainedText:
            if let copyAction = voiceInput.state.menu.copyRetainedTextAction {
                Button(
                    voiceInput.state.menu.copyRetainedTextTitle
                        ?? "复制保留的文字"
                ) {
                    voiceInput.perform(copyAction)
                }
            }
        case .recoverVoiceInput:
            if let recoveryAction = voiceInput.state.menu.recoveryAction {
                Button("检查语音设置…") {
                    guard let effect = voiceInput.perform(recoveryAction) else {
                        return
                    }
                    commandRouter.perform(effect)
                }
            }
        case .dismissVoiceInput:
            if let dismissAction = voiceInput.state.menu.dismissAction {
                Button("关闭当前提示") {
                    voiceInput.perform(dismissAction)
                }
            }
        case .onboarding:
            Button("使用引导…") { commandRouter.perform(.onboarding) }
        case .settings:
            Button("设置…") {
                commandRouter.perform(.settings)
            }
            .keyboardShortcut(",")
        case .dataErasureStatus:
            Label(
                dataErasure.state == .erasing
                    ? "正在清除本地数据"
                    : "本地数据尚未全部清除",
                systemImage: dataErasure.state == .erasing
                    ? "externaldrive.badge.timemachine"
                    : "exclamationmark.triangle"
            )
        case .dataErasureRecovery:
            Button("查看清除状态…") {
                commandRouter.perform(.dataErasureRecovery)
            }
        case .quit:
            Button("退出 Speaker") {
                commandRouter.perform(.quit)
            }
            .keyboardShortcut("q")
        case .divider:
            Divider()
        }
    }

    /// A menu toggle shows the current mode's checkmark. Modes other than the
    /// default need a saved Key, so they stay disabled rather than silently
    /// refusing the click.
    private func refinementToggle(_ choice: RefinementChoice, title: String) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { refinement.choice == choice },
                set: { isOn in
                    guard isOn else { return }
                    Task {
                        if choice == .custom {
                            await refinement.selectSavedCustomMode()
                        } else {
                            await refinement.select(choice)
                        }
                    }
                }
            )
        )
        .disabled(choice != .defaultSmooth && !refinement.hasStoredKey)
    }
}
