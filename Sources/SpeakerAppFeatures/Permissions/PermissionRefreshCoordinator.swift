import Combine
import Foundation
import SpeakerCore

/// Keeps the permission snapshot and shortcut monitor in one ordered refresh.
///
/// macOS permission changes happen outside Speaker. Observing workspace
/// activation means the shortcut can recover when the user leaves System
/// Settings directly for the app where they intend to dictate, without first
/// bringing Speaker to the foreground.
@MainActor
package final class PermissionRefreshCoordinator {
    private let permissions: PermissionModel
    private let shortcut: VoiceShortcutFeature
    private var activationCancellable: AnyCancellable?

    package init(
        permissions: PermissionModel,
        shortcut: VoiceShortcutFeature
    ) {
        self.permissions = permissions
        self.shortcut = shortcut
    }

    package func start(
        observing activations: AnyPublisher<Void, Never>
    ) {
        guard activationCancellable == nil else { return }
        activationCancellable = activations.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
    }

    package func refreshNow() {
        permissions.refresh()
        shortcut.synchronize()
    }

    package func stop() {
        activationCancellable?.cancel()
        activationCancellable = nil
    }
}
