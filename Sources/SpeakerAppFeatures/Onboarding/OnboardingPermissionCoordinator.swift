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
        await permissions.request(permission)
        synchronize()
    }
}
