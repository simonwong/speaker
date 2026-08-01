import AppKit
import SpeakerAppFeatures
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var voiceInput: VoiceInputExperience
    @ObservedObject var refinement: RefinementSettingsModel
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @ObservedObject var settingsNavigation: SettingsNavigationModel
    @ObservedObject var mainWindow: MainWindowModel
    let startRuntime: () -> Void
    let refreshPermissions: () -> Void
    @Environment(\.openWindow) private var openWindow

    private var commandRouter: MenuBarCommandRouter {
        MenuBarCommandRouter(
            navigation: settingsNavigation,
            openOverview: { openMainWindow(.overview) },
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

    var body: some View {
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
                Button("默认顺滑") { Task { await refinement.select(.defaultSmooth) } }
                Button("精简清理") { Task { await refinement.select(.conciseCleanup) } }
                Button("完整重写") { Task { await refinement.select(.fullRewrite) } }
                if let customModeName = refinement.savedCustomModeName {
                    Button(customModeName) {
                        Task { await refinement.selectSavedCustomMode() }
                    }
                }
            } label: {
                Label(refinement.mode.displayName, systemImage: "text.alignleft")
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
                    guard voiceInput.perform(recoveryAction) != nil else {
                        return
                    }
                    commandRouter.perform(.permissionSettings)
                }
            }
        case .dismissVoiceInput:
            if let dismissAction = voiceInput.state.menu.dismissAction {
                Button("关闭当前提示") {
                    voiceInput.perform(dismissAction)
                }
            }
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
}
