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
                        .tabItem { Label("概览", systemImage: "chart.bar.xaxis") }
                        .tag(MainWindowTab.overview)

                    HistoryView(model: history)
                        .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
                        .tag(MainWindowTab.history)

                    SettingsView(workspace: settingsWorkspace)
                        .tabItem { Label("设置", systemImage: "gearshape") }
                        .tag(MainWindowTab.settings)

                    DictionaryTabView(model: dictionary)
                        .tabItem { Label("词典", systemImage: "text.book.closed") }
                        .tag(MainWindowTab.dictionary)
                }
            } else {
                ContentUnavailableView(
                    "本地数据清除中",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("完成清除或解决失败原因后才能查看概览、历史和设置。")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}
