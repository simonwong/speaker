import SpeakerCore

@MainActor
package final class OnboardingPermissionCoordinator {
    package typealias Synchronize = @MainActor () -> Void

    private let permissions: PermissionModel
    private let synchronize: Synchronize

    package init(
        permissions: PermissionModel,
        synchronize: @escaping Synchronize
    ) {
        self.permissions = permissions
        self.synchronize = synchronize
    }

    package func request(_ permission: PermissionKind) async {
        let previous = permissions.snapshot
        await permissions.request(permission)
        synchronize()

        guard permission == .microphone,
              previous.microphone == .notDetermined,
              permissions.snapshot.microphone == .granted
        else { return }

        switch permissions.snapshot.accessibility {
        case .denied, .notDetermined:
            await permissions.request(.accessibility)
            synchronize()
        case .granted, .restricted:
            break
        }
    }
}
