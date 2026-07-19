import SpeakerAppFeatures
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var mainWindow: MainWindowModel
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    let overview: OverviewModel
    let history: HistoryModel
    let settingsWorkspace: SettingsWorkspace
    let dictionary: DictionarySettingsModel

    var body: some View {
        MainWindowLayoutContainer {
            switch dataErasure.state.workspaceRoute {
            case .normal:
                TabView(selection: $mainWindow.selection) {
                    OverviewView(model: overview)
                        .tabItem {
                            Label(
                                MainWindowTab.overview.title,
                                systemImage: MainWindowTab.overview.icon
                            )
                        }
                        .tag(MainWindowTab.overview)

                    HistoryView(model: history)
                        .tabItem {
                            Label(
                                MainWindowTab.history.title,
                                systemImage: MainWindowTab.history.icon
                            )
                        }
                        .tag(MainWindowTab.history)

                    SettingsView(workspace: settingsWorkspace)
                        .tabItem {
                            Label(
                                MainWindowTab.settings.title,
                                systemImage: MainWindowTab.settings.icon
                            )
                        }
                        .tag(MainWindowTab.settings)

                    DictionaryTabView(model: dictionary)
                        .tabItem {
                            Label(
                                MainWindowTab.dictionary.title,
                                systemImage: MainWindowTab.dictionary.icon
                            )
                        }
                        .tag(MainWindowTab.dictionary)

                    AboutView(workspace: settingsWorkspace)
                        .tabItem {
                            Label(
                                MainWindowTab.about.title,
                                systemImage: MainWindowTab.about.icon
                            )
                        }
                        .tag(MainWindowTab.about)
                }
            case .erasing:
                DataErasureInProgressView()
            case .aboutRecovery:
                AboutView(workspace: settingsWorkspace)
            }
        }
    }
}
