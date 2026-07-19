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
        Group {
            if dataErasure.state == .idle {
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
            } else {
                ContentUnavailableView(
                    "本地数据清除中",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("完成清除或解决失败原因后才能继续使用 Speaker。")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}
