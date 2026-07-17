import Combine
import SpeakerCore

@MainActor
package protocol LoginItemServicing: AnyObject {
    var state: LoginItemServiceState { get }

    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
package final class LoginItemSettingsModel: ObservableObject {
    @Published package private(set) var isEnabled = false
    @Published package private(set) var notice: String?
    @Published package private(set) var showsSystemSettingsButton = false

    private let service: any LoginItemServicing
    private let settingsStore: VersionedLocalAppSettingsStore
    private var desiredEnabled = false

    package init(
        service: any LoginItemServicing,
        settingsStore: VersionedLocalAppSettingsStore
    ) {
        self.service = service
        self.settingsStore = settingsStore
    }

    package func restore(desiredEnabled: Bool) async {
        self.desiredEnabled = desiredEnabled
        // `notRegistered` can mean that the user explicitly disabled Speaker
        // in System Settings. Reflect the effective state and wait for an
        // explicit toggle instead of silently fighting that system choice.
        applyCurrentStatus()
    }

    package func refresh() async {
        applyCurrentStatus()
    }

    package func setEnabled(_ enabled: Bool) async {
        let previousDesiredEnabled = desiredEnabled
        do {
            try await setServiceEnabled(enabled)
            desiredEnabled = enabled
            try await settingsStore.updateLaunchAtLogin(enabled)
            applyCurrentStatus()
        } catch {
            desiredEnabled = previousDesiredEnabled
            try? await setServiceEnabled(previousDesiredEnabled)
            applyCurrentStatus()
            notice = "无法更新登录项：\(error.localizedDescription)"
        }
    }

    package func openSystemSettings() {
        service.openSystemSettings()
    }

    private func setServiceEnabled(_ enabled: Bool) async throws {
        if enabled {
            try service.register()
        } else {
            try await service.unregister()
        }
    }

    private func applyCurrentStatus() {
        let presentation = LoginItemPresentation(
            desiredEnabled: desiredEnabled,
            serviceState: service.state
        )
        isEnabled = presentation.isEnabled
        notice = presentation.notice
        showsSystemSettingsButton = presentation.showsSystemSettingsButton
    }
}
