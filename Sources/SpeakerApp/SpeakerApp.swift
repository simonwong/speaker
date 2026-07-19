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
                mainWindow: runtime.mainWindow,
                startRuntime: runtime.start,
                refreshPermissions: runtime.refreshPermissions
            )
        }
        .menuBarExtraStyle(.menu)

        // Secondary Preferences surface kept for the standard ⌘, shortcut and the
        // voice HUD's "check speech settings" recovery, which routes through the
        // system `openSettings` action. The tabbed main window is the primary UI.
        Settings {
            SettingsView(workspace: runtime.settingsWorkspace)
                .frame(width: 860, height: 650)
        }

        Window("Speaker", id: MainWindowModel.windowID) {
            MainWindowView(
                mainWindow: runtime.mainWindow,
                dataErasure: runtime.dataErasure,
                overview: runtime.overviewModel,
                history: runtime.historyModel,
                settingsWorkspace: runtime.settingsWorkspace,
                dictionary: runtime.dictionarySettings
            )
        }
        .defaultSize(width: 900, height: 640)
    }

    private var menuBarIcon: String {
        MenuBarPresentation.systemImage(
            isRecording: runtime.voiceInput.state.isRecording,
            permissions: runtime.permissions.snapshot
        )
    }
}
