import Combine
import SpeakerAppFeatures
import Sparkle

@MainActor
final class SparkleSoftwareUpdateDriver: SoftwareUpdateDriving {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var observation: AnyCancellable?

    func start(
        observing: @escaping @MainActor @Sendable (
            SoftwareUpdateDriverSnapshot
        ) -> Void
    ) throws -> SoftwareUpdateDriverSnapshot {
        try controller.updater.start()
        observation = controller.updater.publisher(
            for: \.canCheckForUpdates,
            options: [.initial, .new]
        )
        .combineLatest(
            controller.updater.publisher(
                for: \.automaticallyChecksForUpdates,
                options: [.initial, .new]
            )
        )
        .sink { canCheck, automaticallyChecks in
            observing(.init(
                canCheckForUpdates: canCheck,
                automaticallyChecksForUpdates: automaticallyChecks
            ))
        }
        return snapshot
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(
        _ enabled: Bool
    ) -> SoftwareUpdateDriverSnapshot {
        controller.updater.automaticallyChecksForUpdates = enabled
        return snapshot
    }

    private var snapshot: SoftwareUpdateDriverSnapshot {
        .init(
            canCheckForUpdates:
                controller.updater.canCheckForUpdates,
            automaticallyChecksForUpdates:
                controller.updater.automaticallyChecksForUpdates
        )
    }
}
