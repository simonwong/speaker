import SwiftUI

/// Replaces the app menu's standard Settings item. ⌘, then opens the main
/// window's Settings tab, the only settings surface, instead of a second
/// fixed-size window.
package struct MainWindowSettingsCommands: Commands {
    let mainWindow: MainWindowModel
    let navigation: SettingsNavigationModel

    package init(mainWindow: MainWindowModel, navigation: SettingsNavigationModel) {
        self.mainWindow = mainWindow
        self.navigation = navigation
    }

    package var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            MainWindowSettingsCommandButton(
                mainWindow: mainWindow,
                navigation: navigation
            )
        }
    }
}

/// A view, so it can read `openWindow` from the menu's environment.
private struct MainWindowSettingsCommandButton: View {
    let mainWindow: MainWindowModel
    let navigation: SettingsNavigationModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("设置…") {
            navigation.openTop()
            mainWindow.select(.settings)
            openWindow(id: MainWindowModel.windowID)
        }
        .keyboardShortcut(",")
    }
}
