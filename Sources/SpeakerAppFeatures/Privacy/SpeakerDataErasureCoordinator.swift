import Combine
import Foundation

package enum SpeakerDataClass: String, CaseIterable, Hashable, Sendable {
    case loginItem
    case providerCredentials
    case history
    case settings
    case dictionary
    case preferences
    case legacyData
    case caches
}

package enum SpeakerDataErasureStage: String, Equatable, Sendable {
    case intent
    case runtime
    case loginItem
    case credentials
    case historyClose
    case applicationSupport
    case legacyData
    case caches
    case preferences
    case verification
    case intentClear
}

package enum SpeakerDataErasureReason: String, Error, Equatable, Sendable {
    case accessDenied
    case interactionUnavailable
    case busy
    case io
    case unsafePath
    case verificationMismatch
}

package struct SpeakerDataErasureIssue: Equatable, Sendable {
    package let stage: SpeakerDataErasureStage
    package let reason: SpeakerDataErasureReason

    package init(
        stage: SpeakerDataErasureStage,
        reason: SpeakerDataErasureReason
    ) {
        self.stage = stage
        self.reason = reason
    }
}

package struct SpeakerDataErasureFailure: Equatable, Sendable {
    package let issues: [SpeakerDataErasureIssue]
    package let remaining: Set<SpeakerDataClass>

    package init(
        issues: [SpeakerDataErasureIssue],
        remaining: Set<SpeakerDataClass>
    ) {
        self.issues = issues
        self.remaining = remaining
    }
}

package enum SpeakerDataErasureOutcome: Equatable, Sendable {
    case exitRequested
    case incomplete(SpeakerDataErasureFailure)
}

package enum SpeakerDataErasureState: Equatable, Sendable {
    case idle
    case erasing
    case failed(SpeakerDataErasureFailure)
}

package struct SpeakerDataErasureDependencies {
    package typealias Operation = @MainActor () async throws -> Void

    package let persistIntent: Operation
    package let quiesceRuntime: Operation
    package let eraseLoginItem: Operation
    package let eraseProviderCredentials: Operation
    package let closeHistory: Operation
    package let eraseApplicationSupport: Operation
    package let eraseLegacyData: Operation
    package let eraseCaches: Operation
    package let erasePreferences: Operation
    package let verifyErasure: Operation
    package let clearIntent: Operation
    package let requestExit: @MainActor () -> Void

    package init(
        persistIntent: @escaping Operation,
        quiesceRuntime: @escaping Operation,
        eraseLoginItem: @escaping Operation,
        eraseProviderCredentials: @escaping Operation,
        closeHistory: @escaping Operation,
        eraseApplicationSupport: @escaping Operation,
        eraseLegacyData: @escaping Operation,
        eraseCaches: @escaping Operation,
        erasePreferences: @escaping Operation,
        verifyErasure: @escaping Operation,
        clearIntent: @escaping Operation,
        requestExit: @escaping @MainActor () -> Void
    ) {
        self.persistIntent = persistIntent
        self.quiesceRuntime = quiesceRuntime
        self.eraseLoginItem = eraseLoginItem
        self.eraseProviderCredentials = eraseProviderCredentials
        self.closeHistory = closeHistory
        self.eraseApplicationSupport = eraseApplicationSupport
        self.eraseLegacyData = eraseLegacyData
        self.eraseCaches = eraseCaches
        self.erasePreferences = erasePreferences
        self.verifyErasure = verifyErasure
        self.clearIntent = clearIntent
        self.requestExit = requestExit
    }
}

/// Owns the destructive local-data lifecycle behind one idempotent operation.
///
/// The caller cannot reorder deletion steps or report success before every
/// owned store has been verified. Concurrent callers share the same operation;
/// cancelling one waiter does not cancel an erasure that has already started.
@MainActor
package final class SpeakerDataErasureCoordinator: ObservableObject {
    @Published package private(set) var state: SpeakerDataErasureState = .idle

    private let dependencies: SpeakerDataErasureDependencies
    private var operationTask: Task<SpeakerDataErasureOutcome, Never>?

    package init(dependencies: SpeakerDataErasureDependencies) {
        self.dependencies = dependencies
    }

    package func eraseAllAndExit() async -> SpeakerDataErasureOutcome {
        if let operationTask {
            return await operationTask.value
        }

        state = .erasing
        let dependencies = dependencies
        let task = Task { @MainActor in
            await Self.perform(using: dependencies)
        }
        operationTask = task
        let outcome = await task.value
        operationTask = nil
        if case let .incomplete(failure) = outcome {
            state = .failed(failure)
        }
        return outcome
    }

    private static func perform(
        using dependencies: SpeakerDataErasureDependencies
    ) async -> SpeakerDataErasureOutcome {
        let strictStages: [(
            SpeakerDataErasureStage,
            Set<SpeakerDataClass>,
            SpeakerDataErasureDependencies.Operation
        )] = [
            (.intent, Set(SpeakerDataClass.allCases), dependencies.persistIntent),
            (.runtime, Set(SpeakerDataClass.allCases), dependencies.quiesceRuntime),
            (
                .loginItem,
                Set(SpeakerDataClass.allCases),
                dependencies.eraseLoginItem
            ),
            (
                .credentials,
                [
                    .providerCredentials,
                    .history,
                    .settings,
                    .dictionary,
                    .preferences,
                    .legacyData,
                    .caches,
                ],
                dependencies.eraseProviderCredentials
            ),
            (
                .historyClose,
                [
                    .history,
                    .settings,
                    .dictionary,
                    .preferences,
                    .legacyData,
                    .caches,
                ],
                dependencies.closeHistory
            ),
        ]

        for (stage, remaining, operation) in strictStages {
            if let issue = await issue(for: stage, operation: operation) {
                return .incomplete(
                    SpeakerDataErasureFailure(
                        issues: [issue],
                        remaining: remaining
                    )
                )
            }
        }

        let independentStages: [(
            SpeakerDataErasureStage,
            SpeakerDataClass,
            SpeakerDataErasureDependencies.Operation
        )] = [
            (
                .applicationSupport,
                .settings,
                dependencies.eraseApplicationSupport
            ),
            (.legacyData, .legacyData, dependencies.eraseLegacyData),
            (.caches, .caches, dependencies.eraseCaches),
        ]
        var issues: [SpeakerDataErasureIssue] = []
        var remaining: Set<SpeakerDataClass> = []
        for (stage, dataClass, operation) in independentStages {
            if let issue = await issue(for: stage, operation: operation) {
                issues.append(issue)
                remaining.insert(dataClass)
                if stage == .applicationSupport {
                    remaining.formUnion([.history, .dictionary])
                }
            }
        }
        guard issues.isEmpty else {
            remaining.insert(.preferences)
            return .incomplete(
                SpeakerDataErasureFailure(
                    issues: issues,
                    remaining: remaining
                )
            )
        }

        if let issue = await issue(
            for: .preferences,
            operation: dependencies.erasePreferences
        ) {
            return .incomplete(
                SpeakerDataErasureFailure(
                    issues: [issue],
                    remaining: [.preferences]
                )
            )
        }

        if let issue = await issue(
            for: .verification,
            operation: dependencies.verifyErasure
        ) {
            return .incomplete(
                SpeakerDataErasureFailure(
                    issues: [issue],
                    remaining: Set(SpeakerDataClass.allCases)
                )
            )
        }

        if let issue = await issue(
            for: .intentClear,
            operation: dependencies.clearIntent
        ) {
            return .incomplete(
                SpeakerDataErasureFailure(
                    issues: [issue],
                    remaining: [.preferences]
                )
            )
        }

        dependencies.requestExit()
        return .exitRequested
    }

    private static func issue(
        for stage: SpeakerDataErasureStage,
        operation: SpeakerDataErasureDependencies.Operation
    ) async -> SpeakerDataErasureIssue? {
        do {
            try await operation()
            return nil
        } catch let reason as SpeakerDataErasureReason {
            return SpeakerDataErasureIssue(stage: stage, reason: reason)
        } catch {
            return SpeakerDataErasureIssue(stage: stage, reason: .io)
        }
    }
}
