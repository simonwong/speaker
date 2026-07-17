import Combine
import Foundation

package enum SoftwareUpdateAvailability: Equatable, Sendable {
    case unavailable(diagnosticCode: String)
    case ready
}

package struct SoftwareUpdateConfiguration: Equatable, Sendable {
    package let availability: SoftwareUpdateAvailability

    package init(
        signingMode: SpeakerSigningMode,
        feedURLString: String?,
        publicEDKey: String?
    ) {
        guard signingMode == .developerID else {
            availability = .unavailable(
                diagnosticCode: "update.development-build"
            )
            return
        }
        guard let feedURLString,
              let feedURL = URL(string: feedURLString),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil,
              !feedURLString.contains(".invalid")
        else {
            availability = .unavailable(
                diagnosticCode: "update.invalid-feed"
            )
            return
        }
        guard let publicEDKey,
              !publicEDKey.contains("REPLACE_"),
              let keyData = Data(base64Encoded: publicEDKey),
              keyData.count == 32
        else {
            availability = .unavailable(
                diagnosticCode: "update.invalid-public-key"
            )
            return
        }
        availability = .ready
    }
}

package struct SoftwareUpdateDriverSnapshot: Equatable, Sendable {
    package let canCheckForUpdates: Bool
    package let automaticallyChecksForUpdates: Bool

    package init(
        canCheckForUpdates: Bool,
        automaticallyChecksForUpdates: Bool
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.automaticallyChecksForUpdates =
            automaticallyChecksForUpdates
    }
}

@MainActor
package protocol SoftwareUpdateDriving: AnyObject {
    func start(
        observing: @escaping @MainActor @Sendable (
            SoftwareUpdateDriverSnapshot
        ) -> Void
    ) throws -> SoftwareUpdateDriverSnapshot
    func checkForUpdates()
    func setAutomaticallyChecksForUpdates(
        _ enabled: Bool
    ) -> SoftwareUpdateDriverSnapshot
}

package struct SoftwareUpdateState: Equatable, Sendable {
    package let isAvailable: Bool
    package let canCheckForUpdates: Bool
    package let automaticallyChecksForUpdates: Bool
    package let diagnosticCode: String

    package static func unavailable(_ diagnosticCode: String) -> Self {
        .init(
            isAvailable: false,
            canCheckForUpdates: false,
            automaticallyChecksForUpdates: false,
            diagnosticCode: diagnosticCode
        )
    }

    fileprivate static func ready(
        _ snapshot: SoftwareUpdateDriverSnapshot
    ) -> Self {
        .init(
            isAvailable: true,
            canCheckForUpdates: snapshot.canCheckForUpdates,
            automaticallyChecksForUpdates:
                snapshot.automaticallyChecksForUpdates,
            diagnosticCode: "update.ready"
        )
    }
}

/// Owns all product policy for software updates.
///
/// Callers only send semantic intent and observe product state. Sparkle types,
/// KVO, scheduler behavior and update UI stay inside the live App adapter.
@MainActor
package final class SoftwareUpdateFeature: ObservableObject {
    package typealias MakeDriver =
        @MainActor () -> any SoftwareUpdateDriving

    @Published package private(set) var state: SoftwareUpdateState

    private var driver: (any SoftwareUpdateDriving)?
    private var hasStarted = false

    package init(
        configuration: SoftwareUpdateConfiguration,
        makeDriver: MakeDriver
    ) {
        switch configuration.availability {
        case let .unavailable(diagnosticCode):
            state = .unavailable(diagnosticCode)
        case .ready:
            driver = makeDriver()
            state = .init(
                isAvailable: true,
                canCheckForUpdates: false,
                automaticallyChecksForUpdates: false,
                diagnosticCode: "update.not-started"
            )
        }
    }

    package func start() {
        guard !hasStarted, let driver else { return }
        hasStarted = true
        do {
            let snapshot = try driver.start { [weak self] snapshot in
                self?.state = .ready(snapshot)
            }
            state = .ready(snapshot)
        } catch {
            self.driver = nil
            state = .unavailable("update.start-failed")
        }
    }

    package func checkForUpdates() {
        guard state.canCheckForUpdates else { return }
        driver?.checkForUpdates()
    }

    package func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard state.isAvailable, let driver else { return }
        state = .ready(
            driver.setAutomaticallyChecksForUpdates(enabled)
        )
    }
}
