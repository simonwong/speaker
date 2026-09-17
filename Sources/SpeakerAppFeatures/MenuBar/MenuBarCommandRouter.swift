@MainActor
package enum MenuBarCommand: Equatable, Sendable {
    case overview
    case onboarding
    case permissionSettings
    case settings
    case settingsSection(SettingsGroup)
    case dataErasureRecovery
    case quit
}

@MainActor
package struct MenuBarCommandRouter {
    private let navigation: SettingsNavigationModel
    private let openOverview: () -> Void
    private let openOnboarding: () -> Void
    private let openSettings: () -> Void
    private let openDataErasureRecovery: () -> Void
    private let activate: () -> Void
    private let terminate: () -> Void

    package init(
        navigation: SettingsNavigationModel,
        openOverview: @escaping () -> Void,
        openOnboarding: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openDataErasureRecovery: @escaping () -> Void,
        activate: @escaping () -> Void,
        terminate: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.openOverview = openOverview
        self.openOnboarding = openOnboarding
        self.openSettings = openSettings
        self.openDataErasureRecovery = openDataErasureRecovery
        self.activate = activate
        self.terminate = terminate
    }

    package func perform(_ effect: VoiceInputExperienceEffect) {
        switch effect {
        case .openSettings(let group):
            perform(.settingsSection(group))
        }
    }

    package func perform(_ command: MenuBarCommand) {
        switch command {
        case .onboarding:
            openOnboarding()
            activate()
        case .overview:
            openOverview()
            activate()
        case .permissionSettings:
            navigation.open(.permissions)
            openSettings()
            activate()
        case .settingsSection(let group):
            navigation.open(group)
            openSettings()
            activate()
        case .settings:
            navigation.openTop()
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
