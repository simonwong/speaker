import AppKit
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var voiceInput: VoiceInputExperience
    @ObservedObject var refinement: RefinementSettingsModel
    @ObservedObject var softwareUpdate: SoftwareUpdateFeature
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @ObservedObject var settingsNavigation: SettingsNavigationModel
    let startRuntime: () -> Void
    let refreshPermissions: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private var commandRouter: MenuBarCommandRouter {
        MenuBarCommandRouter(
            navigation: settingsNavigation,
            openSettings: { openSettings() },
            openHistory: { openWindow(id: "history") },
            activate: {
                NSApp.activate(ignoringOtherApps: true)
            },
            terminate: { NSApp.terminate(nil) }
        )
    }

    var body: some View {
        Group {
            if dataErasure.state == .idle {
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
            if let status = voiceInput.state.menu.status {
                Label(
                    status.title,
                    systemImage: status.icon
                )
                if let cancelAction = voiceInput.state.menu.cancelAction {
                    Button("取消当前输入") {
                        voiceInput.perform(cancelAction)
                    }
                }
            }

            if let notice = voiceInput.state.menu.notice {
                Label(notice, systemImage: "info.circle")
            }

            if let copyAction = voiceInput.state.menu.copyRetainedTextAction {
                Button(
                    voiceInput.state.menu.copyRetainedTextTitle
                        ?? "复制保留的文字"
                ) {
                    voiceInput.perform(copyAction)
                }
            }

            if let recoveryAction = voiceInput.state.menu.recoveryAction {
                Button("检查语音设置…") {
                    guard voiceInput.perform(recoveryAction) != nil else {
                        return
                    }
                    commandRouter.perform(.permissionSettings)
                }
            }

            if let dismissAction = voiceInput.state.menu.dismissAction {
                Button("关闭当前提示") {
                    voiceInput.perform(dismissAction)
                }
            }

            Divider()

            if !permissions.snapshot.allGranted {
                Button("继续完成权限设置…") {
                    commandRouter.perform(.permissionSettings)
                }
            }

            Button("会话历史") {
                commandRouter.perform(.history)
            }

            Button("设置…") {
                commandRouter.perform(.settings)
            }
            .keyboardShortcut(",")

            Button("关于 Speaker…") {
                commandRouter.perform(.about)
            }

            if softwareUpdate.state.isAvailable {
                Button("检查更新…") {
                    softwareUpdate.checkForUpdates()
                }
                .disabled(!softwareUpdate.state.canCheckForUpdates)
            }

            Divider()

            Button("退出 Speaker") {
                commandRouter.perform(.quit)
            }
            .keyboardShortcut("q")
            } else {
                Label(
                    dataErasure.state == .erasing
                        ? "正在清除本地数据"
                        : "本地数据尚未全部清除",
                    systemImage: dataErasure.state == .erasing
                        ? "externaldrive.badge.timemachine"
                        : "exclamationmark.triangle"
                )

                Button("查看清除状态…") {
                    commandRouter.perform(.about)
                }

                Divider()

                Button("退出 Speaker") {
                    commandRouter.perform(.quit)
                }
                .keyboardShortcut("q")
            }
        }
        .task {
            startRuntime()
            if dataErasure.state == .idle {
                refreshPermissions()
            }
        }
    }

}
