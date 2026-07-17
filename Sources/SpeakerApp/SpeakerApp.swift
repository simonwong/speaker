import SpeakerAppFeatures
import SwiftUI

@main
struct SpeakerApp: App {
    @NSApplicationDelegateAdaptor(SpeakerApplicationDelegate.self)
    private var applicationDelegate

    @StateObject private var runtime: SpeakerRuntime

    init() {
        let runtime = SpeakerRuntime()
        _runtime = StateObject(wrappedValue: runtime)
        Task { @MainActor in
            runtime.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("Speaker", systemImage: menuBarIcon) {
            MenuBarContent(
                permissions: runtime.permissions,
                voiceInput: runtime.voiceInput,
                refinement: runtime.refinementSettings,
                softwareUpdate: runtime.softwareUpdate,
                dataErasure: runtime.dataErasure,
                settingsNavigation: runtime.settingsNavigation,
                startRuntime: runtime.start,
                refreshPermissions: runtime.refreshPermissions
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(workspace: runtime.settingsWorkspace)
        }

        Window("会话历史", id: "history") {
            if runtime.dataErasure.state == .idle {
                HistoryView(model: runtime.historyModel)
            } else {
                ContentUnavailableView(
                    "本地数据清除中",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("完成清除或解决失败原因后才能查看会话历史。")
                )
            }
        }
        .defaultSize(width: 820, height: 560)
    }

    private var menuBarIcon: String {
        MenuBarPresentation.systemImage(
            isRecording: runtime.voiceInput.state.isRecording,
            permissions: runtime.permissions.snapshot
        )
    }
}
