import Combine
import SpeakerCore

@MainActor
package final class ShortcutAnnouncementCoordinator {
    package typealias Announce = AccessibilityAnnounce

    private var cancellables = Set<AnyCancellable>()

    package init(
        feature: VoiceShortcutFeature,
        announce: @escaping Announce
    ) {
        feature.$notice
            .removeDuplicates()
            .compactMap { $0?.message }
            .sink(receiveValue: announce)
            .store(in: &cancellables)

        feature.$activation
            .removeDuplicates()
            .dropFirst()
            .compactMap { activation -> String? in
                guard case let .active(preference) = activation else { return nil }
                return preference.activationAnnouncement
            }
            .sink(receiveValue: announce)
            .store(in: &cancellables)

        feature.$persistenceConfirmation
            .compactMap { $0?.persistenceConfirmationMessage }
            .sink(receiveValue: announce)
            .store(in: &cancellables)
    }
}
