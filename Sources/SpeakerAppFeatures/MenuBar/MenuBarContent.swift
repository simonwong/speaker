import AppKit
import SpeakerCore
import SwiftUI

/// The menu bar extra's rows. Order comes from `MenuBarPresentation`; the
/// wording, symbols, and shortcuts of each row live here rather than in the
/// composition root.
///
/// The menu keeps the native style. Every row but Quit carries an SF Symbol,
/// so all titles start on one column.
package struct MenuBarContent: View {
    @ObservedObject var voiceInput: VoiceInputExperience
    @ObservedObject var refinement: RefinementSettingsModel
    @ObservedObject var microphones: MicrophoneSelectionFeature
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @ObservedObject var settingsNavigation: SettingsNavigationModel
    @ObservedObject var mainWindow: MainWindowModel
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var recognition: SpeechRecognitionSettingsModel
    @ObservedObject var recentResults: MenuBarRecentResultsModel
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
        permissions: PermissionModel,
        recognition: SpeechRecognitionSettingsModel,
        recentResults: MenuBarRecentResultsModel,
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
        self.permissions = permissions
        self.recognition = recognition
        self.recentResults = recentResults
        self.startRuntime = startRuntime
        self.refreshPermissions = refreshPermissions
        self.openOnboarding = openOnboarding
    }

    private var commandRouter: MenuBarCommandRouter {
        MenuBarCommandRouter(
            navigation: settingsNavigation,
            openOverview: { openMainWindow(.overview) },
            openHistory: { openMainWindow(.history) },
            openOnboarding: openOnboarding,
            openSettings: { openMainWindow(.settings) },
            openDataErasureRecovery: { openMainWindow(.about) },
            activate: {
                NSApp.activate(ignoringOtherApps: true)
            },
            terminate: { NSApp.terminate(nil) }
        )
    }

    private var setupGap: VoiceInputSetupGap? {
        VoiceInputSetupGap.current(
            permissions: permissions.snapshot,
            recognition: recognition
        )
    }

    private var rows: [MenuBarRow] {
        MenuBarPresentation.rows(
            voice: MenuBarVoiceCapabilities(menu: voiceInput.state.menu),
            setupGap: setupGap,
            hasRecentResults: !recentResults.items.isEmpty,
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
            await recentResults.refresh()
        }
    }

    @ViewBuilder
    private func row(_ row: MenuBarRow) -> some View {
        switch row {
        case .completeSetup:
            if let setupGap {
                Button {
                    commandRouter.perform(.settingsSection(setupGap.settingsGroup))
                } label: {
                    Label(setupGap.menuTitle, systemImage: "exclamationmark.triangle")
                }
            }
        case .openSpeaker:
            Button {
                commandRouter.perform(.overview)
            } label: {
                Label("打开 Speaker", systemImage: "macwindow")
            }
        case .refinementMode:
            Menu {
                ForEach(refinement.menuEntries) { entry in
                    refinementToggle(entry)
                }
            } label: {
                Label(refinement.mode.displayName, systemImage: "text.alignleft")
            }
        case .microphone:
            MicrophoneSelectionMenu(model: microphones)
        case .recentResults:
            Menu {
                ForEach(recentResults.items) { item in
                    Button(item.title) {
                        Task { await recentResults.copy(item.id) }
                    }
                }
                Divider()
                Button("查看全部历史…") { commandRouter.perform(.history) }
            } label: {
                Label("最近结果", systemImage: "clock.arrow.circlepath")
            }
        case .voiceStatus:
            if let status = voiceInput.state.menu.status {
                Label(
                    status.title,
                    systemImage: status.icon
                )
            }
        case .cancelVoiceInput:
            if let cancelAction = voiceInput.state.menu.cancelAction {
                Button {
                    voiceInput.perform(cancelAction)
                } label: {
                    Label("取消当前输入", systemImage: "xmark.circle")
                }
            }
        case .voiceNotice:
            if let notice = voiceInput.state.menu.notice {
                Label(notice, systemImage: "info.circle")
            }
        case .copyRetainedText:
            if let copyAction = voiceInput.state.menu.copyRetainedTextAction {
                Button {
                    voiceInput.perform(copyAction)
                } label: {
                    Label(
                        voiceInput.state.menu.copyRetainedTextTitle ?? "复制保留的文字",
                        systemImage: "doc.on.doc"
                    )
                }
            }
        case .recoverVoiceInput:
            if let recoveryAction = voiceInput.state.menu.recoveryAction {
                Button {
                    guard let effect = voiceInput.perform(recoveryAction) else {
                        return
                    }
                    commandRouter.perform(effect)
                } label: {
                    Label("检查语音设置…", systemImage: "wrench.and.screwdriver")
                }
            }
        case .dismissVoiceInput:
            if let dismissAction = voiceInput.state.menu.dismissAction {
                Button {
                    voiceInput.perform(dismissAction)
                } label: {
                    Label("关闭当前提示", systemImage: "xmark")
                }
            }
        case .onboarding:
            Button {
                commandRouter.perform(.onboarding)
            } label: {
                Label("使用引导…", systemImage: "questionmark.circle")
            }
        case .settings:
            Button {
                commandRouter.perform(.settings)
            } label: {
                Label("设置…", systemImage: "gearshape")
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
            Button {
                commandRouter.perform(.dataErasureRecovery)
            } label: {
                Label("查看清除状态…", systemImage: "externaldrive")
            }
        case .quit:
            // The one row without a symbol, as in every Mac menu.
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
    private func refinementToggle(_ entry: RefinementModeMenuEntry) -> some View {
        Toggle(
            entry.title,
            isOn: Binding(
                get: { entry.isSelected },
                set: { isOn in
                    guard isOn else { return }
                    Task { await refinement.selectMode(entry.selection) }
                }
            )
        )
        .disabled(!entry.isEnabled)
    }
}
