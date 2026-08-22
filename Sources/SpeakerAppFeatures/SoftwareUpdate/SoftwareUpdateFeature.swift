import Combine
import Foundation

package enum SoftwareUpdateAvailability: Equatable, Sendable {
    case unavailable(SoftwareUpdateStatusCode)
    case ready
}

package enum SoftwareUpdateStatusCode: String, Equatable, Sendable {
    case developmentBuild = "update.development-build"
    case invalidFeed = "update.invalid-feed"
    case invalidPublicKey = "update.invalid-public-key"
    case notStarted = "update.not-started"
    case ready = "update.ready"
    case startFailed = "update.start-failed"
}

package struct SoftwareUpdateConfiguration: Equatable, Sendable {
    package let availability: SoftwareUpdateAvailability

    package init(
        signingMode: SpeakerSigningMode,
        feedURLString: String?,
        publicEDKey: String?
    ) {
        guard signingMode == .developerID else {
            availability = .unavailable(.developmentBuild)
            return
        }
        guard let feedURLString,
              let feedURL = URL(string: feedURLString),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil,
              !feedURLString.contains(".invalid")
        else {
            availability = .unavailable(.invalidFeed)
            return
        }
        guard let publicEDKey,
              !publicEDKey.contains("REPLACE_"),
              let keyData = Data(base64Encoded: publicEDKey),
              keyData.count == 32
        else {
            availability = .unavailable(.invalidPublicKey)
            return
        }
        availability = .ready
    }
}

package enum SoftwareUpdateFeedOverridePolicy {
    package static func stagingFeedURL(
        arguments: [String],
        stableFeedURLString: String?
    ) -> String? {
        guard let optionIndex = arguments.firstIndex(
            of: "--speaker-update-feed"
        ), arguments.indices.contains(optionIndex + 1),
              arguments.lastIndex(of: "--speaker-update-feed") == optionIndex,
              let stableFeedURLString,
              let stableURL = URL(string: stableFeedURLString),
              let candidateURL = URL(string: arguments[optionIndex + 1]),
              stableURL.scheme?.lowercased() == "https",
              candidateURL.scheme?.lowercased() == "https",
              candidateURL.host?.lowercased() == stableURL.host?.lowercased(),
              stableURL.user == nil,
              stableURL.password == nil,
              stableURL.port == nil,
              candidateURL.user == nil,
              candidateURL.password == nil,
              candidateURL.port == nil
        else {
            return nil
        }
        let stableParts = stableURL.pathComponents.filter { $0 != "/" }
        let candidateParts = candidateURL.pathComponents.filter { $0 != "/" }
        let versionParts = candidateParts.indices.contains(4)
            ? candidateParts[4].dropFirst().split(separator: ".")
            : []
        guard stableParts.count == 6,
              candidateParts.count == 6,
              Array(candidateParts.prefix(3))
                == Array(stableParts.prefix(3)),
              Array(stableParts[3...5])
                == ["latest", "download", "appcast.xml"],
              candidateParts[3] == "download",
              candidateParts[4].first == "v",
              versionParts.count == 3,
              versionParts.allSatisfy({ part in
                  !part.isEmpty
                    && part.allSatisfy(\.isNumber)
                    && (part == "0" || !part.hasPrefix("0"))
              }),
              candidateParts[5] == "appcast.xml",
              candidateURL.query == nil,
              candidateURL.fragment == nil,
              stableURL.query == nil,
              stableURL.fragment == nil
        else {
            return nil
        }
        return candidateURL.absoluteString
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
    package let statusCode: SoftwareUpdateStatusCode

    package var diagnosticCode: String { statusCode.rawValue }

    package static func unavailable(_ statusCode: SoftwareUpdateStatusCode) -> Self {
        .init(
            isAvailable: false,
            canCheckForUpdates: false,
            automaticallyChecksForUpdates: false,
            statusCode: statusCode
        )
    }

    package var unavailableMessage: String? {
        guard !isAvailable else { return nil }
        return switch statusCode {
        case .developmentBuild:
            "检查更新仅用于正式发布版本。"
        case .invalidFeed, .invalidPublicKey:
            "正式更新配置无效；已停止检查更新。"
        case .startFailed:
            "更新服务启动失败；请重新打开 Speaker 后重试。"
        case .notStarted, .ready:
            "当前无法检查更新。"
        }
    }

    fileprivate static func ready(
        _ snapshot: SoftwareUpdateDriverSnapshot
    ) -> Self {
        .init(
            isAvailable: true,
            canCheckForUpdates: snapshot.canCheckForUpdates,
            automaticallyChecksForUpdates:
                snapshot.automaticallyChecksForUpdates,
            statusCode: .ready
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
        case let .unavailable(statusCode):
            state = .unavailable(statusCode)
        case .ready:
            driver = makeDriver()
            state = .init(
                isAvailable: true,
                canCheckForUpdates: false,
                automaticallyChecksForUpdates: false,
                statusCode: .notStarted
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
            state = .unavailable(.startFailed)
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
