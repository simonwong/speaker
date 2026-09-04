import AppKit
import SpeakerCore
import SwiftUI

package struct SettingsView: View {
    let workspace: SettingsWorkspace
    @StateObject private var shortcutRecorder = ShortcutRecorderModel()
    @ObservedObject private var dataErasure: SpeakerDataErasureCoordinator

    package init(workspace: SettingsWorkspace) {
        self.workspace = workspace
        dataErasure = workspace.dataErasure
    }

    package var body: some View {
        Group {
            switch dataErasure.state.workspaceRoute {
            case .normal:
                SettingsOverviewView(
                    workspace: workspace,
                    shortcutRecorder: shortcutRecorder
                )
            case .erasing:
                DataErasureInProgressView()
            case .aboutRecovery:
                DataErasureRecoveryView(
                    dataErasure: dataErasure,
                    routeEffects: workspace.routeEffects
                )
            }
        }
        .task {
            await workspace.refresh()
        }
        .onDisappear { shortcutRecorder.stop() }
    }
}

package struct DataErasureInProgressView: View {
    package init() {}

    package var body: some View {
        ContentUnavailableView(
            "本地数据清除中",
            systemImage: "externaldrive.badge.xmark",
            description: Text("Speaker 会在安全清除完成后自动退出。")
        )
    }
}

/// Full-window recovery surface shown when a local-data erasure did not
/// complete. This is its own destination, not the About page.
package struct DataErasureRecoveryView: View {
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    let routeEffects: SettingsRouteEffects
    @State private var confirmsRetry = false

    package init(
        dataErasure: SpeakerDataErasureCoordinator,
        routeEffects: SettingsRouteEffects
    ) {
        self.dataErasure = dataErasure
        self.routeEffects = routeEffects
    }

    package var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "本地数据尚未全部清除",
                systemImage: "externaldrive.badge.xmark",
                description: Text(failureText)
            )

            HStack(spacing: 12) {
                Button("打开本地数据文件夹") {
                    routeEffects.openURL(speakerApplicationSupportDirectory)
                }
                Button("重试清除并退出", role: .destructive) {
                    confirmsRetry = true
                }
                .disabled(dataErasure.state == .erasing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "重试清除 Speaker 保存的所有本地数据？",
            isPresented: $confirmsRetry
        ) {
            Button("取消", role: .cancel) {}
            Button("清除并退出", role: .destructive) {
                Task {
                    _ = await dataErasure.eraseAllAndExit()
                }
            }
        } message: {
            Text(
                "API Key、文字历史、个人词库、设置和登录项将被永久移除。Speaker 不会删除系统权限记录，也无法恢复这些本地数据。"
            )
        }
    }

    private var failureText: String {
        guard case let .failed(failure) = dataErasure.state else {
            return "Speaker 正在完成剩余的清除步骤。"
        }
        return SpeakerCopy.LocalDataErase.failureMessage(failure)
    }
}

private struct SettingsOverviewView: View {
    let workspace: SettingsWorkspace
    @ObservedObject private var navigation: SettingsNavigationModel
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel

    init(
        workspace: SettingsWorkspace,
        shortcutRecorder: ShortcutRecorderModel
    ) {
        self.workspace = workspace
        navigation = workspace.navigation
        self.shortcutRecorder = shortcutRecorder
    }

    var body: some View {
        SettingsOverviewScrollView(navigation: navigation) { group in
            sectionGroup(group) {
                sectionContent(group)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sectionGroup<Content: View>(
        _ group: SettingsGroup,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SpeakerSectionHeader(
                group.title,
                tint: group == .localData ? .red : .secondary
            )
            content()
        }
    }

    @ViewBuilder
    private func sectionContent(_ group: SettingsGroup) -> some View {
        switch group {
        case .shortcut:
            ShortcutSettingsPage(
                shortcut: workspace.shortcut,
                shortcutRecorder: shortcutRecorder,
                openPermissionSettings: {
                    navigation.open(.permissions)
                }
            )
        case .permissions:
            PermissionSettingsPage(
                permissions: workspace.permissions,
                requestPermission: workspace.requestPermission
            )
        case .apiKeys:
            APIKeySettingsPage(
                doubao: workspace.doubao,
                refinement: workspace.refinement
            )
        case .refinement:
            RefinementSettingsPage(model: workspace.refinement)
        case .general:
            GeneralSettingsPage(
                loginItemSettings: workspace.loginItemSettings,
                historyRetention: workspace.historyRetention,
                softwareUpdate: workspace.softwareUpdate
            )
        case .localData:
            LocalDataSettingsPage(dataErasure: workspace.dataErasure)
        }
    }
}
