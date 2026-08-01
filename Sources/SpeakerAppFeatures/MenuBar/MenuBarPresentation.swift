import SpeakerCore

package enum MenuBarIconState: Equatable, Sendable {
    case ready
    case recording
    case needsPermission
}

package enum MenuBarPresentation {
    package static func iconState(
        isRecording: Bool,
        permissions: PermissionSnapshot
    ) -> MenuBarIconState {
        if isRecording {
            return .recording
        }
        return permissions.allGranted
            ? .ready
            : .needsPermission
    }
}
