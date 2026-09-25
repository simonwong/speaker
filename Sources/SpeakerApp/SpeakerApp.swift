import SpeakerAppFeatures
import SwiftUI

@main
struct SpeakerApp: App {
    @NSApplicationDelegateAdaptor(SpeakerApplicationDelegate.self)
    private var applicationDelegate

    @StateObject private var runtime: SpeakerRuntime

    init() {
        let runtime = SpeakerRuntime(
            termination: _applicationDelegate.wrappedValue.terminationCoordinator
        )
        _runtime = StateObject(wrappedValue: runtime)
        Task { @MainActor in
            runtime.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                voiceInput: runtime.voiceInput,
                refinement: runtime.refinementSettings,
                microphones: runtime.microphones,
                dataErasure: runtime.dataErasure,
                settingsNavigation: runtime.settingsNavigation,
                mainWindow: runtime.mainWindow,
                startRuntime: runtime.start,
                refreshPermissions: runtime.refreshPermissions,
                openOnboarding: runtime.showOnboarding
            )
        } label: {
            MenuBarStatusLabel(
                voiceInput: runtime.voiceInput,
                permissions: runtime.permissions
            )
        }
        .menuBarExtraStyle(.menu)

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
        .defaultSize(
            width: MainWindowLayout.preferredContentSize.width,
            height: MainWindowLayout.preferredContentSize.height
        )
        // The page tabs are the title bar's only content.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            MainWindowSettingsCommands(
                mainWindow: runtime.mainWindow,
                navigation: runtime.settingsNavigation
            )
        }
    }
}
