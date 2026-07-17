@MainActor
package enum MenuBarCommand: Equatable, Sendable {
    case permissionSettings
    case history
    case settings
    case about
    case quit
}

@MainActor
package struct MenuBarCommandRouter {
    private let navigation: SettingsNavigationModel
    private let openSettings: () -> Void
    private let openHistory: () -> Void
    private let activate: () -> Void
    private let terminate: () -> Void

    package init(
        navigation: SettingsNavigationModel,
        openSettings: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        activate: @escaping () -> Void,
        terminate: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.activate = activate
        self.terminate = terminate
    }

    package func perform(_ command: MenuBarCommand) {
        switch command {
        case .permissionSettings:
            navigation.open(.permissions)
            openSettings()
            activate()
        case .history:
            openHistory()
            activate()
        case .settings:
            openSettings()
            activate()
        case .about:
            navigation.open(.about)
            openSettings()
            activate()
        case .quit:
            terminate()
        }
    }
}
