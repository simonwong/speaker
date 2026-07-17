import ServiceManagement
import SpeakerAppFeatures

@MainActor
final class LoginItemServiceAdapter: LoginItemServicing {
    var state: LoginItemServiceState {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
