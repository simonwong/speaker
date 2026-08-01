@MainActor
package enum MenuBarCommand: Equatable, Sendable {
    case overview
    case permissionSettings
    case settings
    case dataErasureRecovery
    case quit
}

@MainActor
package struct MenuBarCommandRouter {
    private let navigation: SettingsNavigationModel
    private let openOverview: () -> Void
    private let openSettings: () -> Void
    private let openDataErasureRecovery: () -> Void
    private let activate: () -> Void
    private let terminate: () -> Void

    package init(
        navigation: SettingsNavigationModel,
        openOverview: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openDataErasureRecovery: @escaping () -> Void,
        activate: @escaping () -> Void,
        terminate: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.openOverview = openOverview
        self.openSettings = openSettings
        self.openDataErasureRecovery = openDataErasureRecovery
        self.activate = activate
        self.terminate = terminate
    }

    package func perform(_ command: MenuBarCommand) {
        switch command {
        case .overview:
            openOverview()
            activate()
        case .permissionSettings:
            navigation.open(.permissions)
            openSettings()
            activate()
        case .settings:
            openSettings()
            activate()
        case .dataErasureRecovery:
            openDataErasureRecovery()
            activate()
        case .quit:
            terminate()
        }
    }
}
