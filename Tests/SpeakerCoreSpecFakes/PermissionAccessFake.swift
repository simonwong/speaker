import SpeakerCore

@MainActor
package final class PermissionAccessFake: PermissionAccess {
    package var snapshot: PermissionSnapshot
    package private(set) var requestedPermissions: [PermissionKind] = []
    private let requestSnapshots: [PermissionKind: PermissionSnapshot]

    package init(
        snapshot: PermissionSnapshot,
        requestSnapshots: [PermissionKind: PermissionSnapshot] = [:]
    ) {
        self.snapshot = snapshot
        self.requestSnapshots = requestSnapshots
    }

    package func currentSnapshot() -> PermissionSnapshot { snapshot }

    package func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        requestedPermissions.append(permission)
        if let requestedSnapshot = requestSnapshots[permission] {
            snapshot = requestedSnapshot
        }
        return snapshot
    }
}
