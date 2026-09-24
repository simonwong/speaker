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
                MainWindowTabs(selection: $mainWindow.selection) { tab in
                    switch tab {
                    case .overview: OverviewView(model: overview)
                    case .history: HistoryView(model: history)
                    case .dictionary: DictionaryTabView(model: dictionary)
                    case .settings: SettingsView(workspace: settingsWorkspace)
                    case .about: AboutView(workspace: settingsWorkspace)
                    }
                }
            case .erasing:
                DataErasureInProgressView()
            case .aboutRecovery:
                DataErasureRecoveryView(
                    dataErasure: dataErasure,
                    routeEffects: settingsWorkspace.routeEffects
                )
            }
        }
        .background(MainWindowVisibilityBridge())
    }
}
