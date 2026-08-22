import Combine
import SpeakerAppFeatures
import Sparkle

@MainActor
final class SparkleSoftwareUpdateDriver: SoftwareUpdateDriving {
    private let updaterDelegate: SparkleUpdaterDelegate
    private let controller: SPUStandardUpdaterController
    private var observation: AnyCancellable?

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        stableFeedURLString: String? = Bundle.main.object(
            forInfoDictionaryKey: "SUFeedURL"
        ) as? String
    ) {
        let feedURL = SoftwareUpdateFeedOverridePolicy.stagingFeedURL(
            arguments: arguments,
            stableFeedURLString: stableFeedURLString
        )
        let updaterDelegate = SparkleUpdaterDelegate(feedURLString: feedURL)
        self.updaterDelegate = updaterDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
    }

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

private final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let feedURLString: String?

    init(feedURLString: String?) {
        self.feedURLString = feedURLString
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLString
    }
}
