import SpeakerCore

package enum OnboardingPermissionAction: Equatable, Sendable {
    case request
    case openSystemSettings
}

package struct OnboardingPresentation: Equatable, Sendable {
    package let permissions: PermissionSnapshot
    package let doubaoStatus: DoubaoConnectionStatus
    package let hasStoredDoubaoKey: Bool

    package init(
        permissions: PermissionSnapshot,
        doubaoStatus: DoubaoConnectionStatus,
        hasStoredDoubaoKey: Bool
    ) {
        self.permissions = permissions
        self.doubaoStatus = doubaoStatus
        self.hasStoredDoubaoKey = hasStoredDoubaoKey
    }

    package var isReady: Bool {
        permissions.allGranted && hasStoredDoubaoKey && connectionSucceeded
    }

    package var connectionSucceeded: Bool {
        if case .success = doubaoStatus { true } else { false }
    }

    package var isCheckingConnection: Bool {
        if case .checking = doubaoStatus { true } else { false }
    }

    package var canCheckConnection: Bool {
        hasStoredDoubaoKey && !isCheckingConnection
    }

    package var canSelectResource: Bool {
        !isCheckingConnection
    }

    package var canComplete: Bool { isReady }

    package func permissionAction(
        for permission: PermissionKind
    ) -> OnboardingPermissionAction? {
        switch permissions[permission] {
        case .notDetermined: .request
        case .denied: .openSystemSettings
        case .granted, .restricted: nil
        }
    }
}
