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

/// The View menu's page items (⌘1 to ⌘5) and ⌘F for History search. The
/// menu bar only exists while the main window is open, so these never need
/// to open it.
package struct MainWindowTabCommands: Commands {
    let mainWindow: MainWindowModel

    package init(mainWindow: MainWindowModel) {
        self.mainWindow = mainWindow
    }

    package var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(MainWindowTab.allCases) { tab in
                Button(tab.title) { mainWindow.select(tab) }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(tab.commandNumber)))
                    )
            }
            Divider()
        }
        // Ahead of the standard Find items, so ⌘F reaches History search.
        CommandGroup(before: .textEditing) {
            Button("搜索历史") { mainWindow.requestHistorySearch() }
                .keyboardShortcut("f")
            Divider()
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
