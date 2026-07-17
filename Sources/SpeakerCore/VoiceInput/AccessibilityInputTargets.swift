import AppKit
import Foundation

private final class AccessibilityReleaseCaptureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [UUID: AccessibilityReleaseCapture] = [:]

    func store(_ capture: AccessibilityReleaseCapture) -> UUID {
        lock.withLock {
            // There can only be one active voice session. Purging abandoned
            // hints bounds retained AX objects if a monitor is interrupted.
            captures.removeAll(keepingCapacity: true)
            let token = UUID()
            captures[token] = capture
            return token
        }
    }

    func take(_ token: UUID) -> AccessibilityReleaseCapture? {
        lock.withLock { captures.removeValue(forKey: token) }
    }
}

public actor AccessibilityInputTargets: InputTargetCapturing, InputTargetDiscarding,
    TextDelivering {
    private struct StoredTarget {
        let evidence: AccessibilityTargetEvidence
    }

    private var targets: [UUID: StoredTarget] = [:]
    private let system: any AccessibilityTargetSystem
    private nonisolated let releaseCapture:
        @Sendable () -> AccessibilityReleaseCapture
    private nonisolated let releaseCaptureCache =
        AccessibilityReleaseCaptureCache()
    private let verifiedUnicodeDeliveryBundleIdentifiers: Set<String>

    public init(
        verifiedUnicodeDeliveryBundleIdentifiers: Set<String> = []
    ) {
        let system = LiveAccessibilityTargetSystem()
        self.system = system
        releaseCapture = { system.captureReleaseTarget() }
        self.verifiedUnicodeDeliveryBundleIdentifiers =
            verifiedUnicodeDeliveryBundleIdentifiers
    }

    package init(
        system: any AccessibilityTargetSystem,
        releaseCapture:
            @escaping @Sendable () -> AccessibilityReleaseCapture = {
                .unavailable(processID: 0, reason: .missingTarget)
            },
        verifiedUnicodeDeliveryBundleIdentifiers: Set<String> = []
    ) {
        self.system = system
        self.releaseCapture = releaseCapture
        self.verifiedUnicodeDeliveryBundleIdentifiers =
            verifiedUnicodeDeliveryBundleIdentifiers
    }

    public func capture() async -> InputTargetCaptureResult {
        await capture(expectedProcessID: nil)
    }

    public func capture(
        matching hint: InputTargetCaptureHint
    ) async -> InputTargetCaptureResult {
        guard let token = hint.targetToken,
              let releaseCapture = releaseCaptureCache.take(token)
        else {
            return .unavailable(.invalidatedTarget)
        }
        switch releaseCapture {
        case let .unavailable(_, reason):
            return .unavailable(reason)
        case let .target(target):
            guard target.processID == hint.processID else {
                return .unavailable(.invalidatedTarget)
            }
            let capture = await system.captureTarget(target)
            return store(capture, expectedProcessID: hint.processID)
        }
    }

    /// Freezes the exact focused AX element while the physical stop gesture is
    /// still being handled. Selection/value inspection remains asynchronous,
    /// but it can no longer follow the user to another field in the same App.
    public nonisolated func releaseCaptureHint() -> InputTargetCaptureHint? {
        let capture = releaseCapture()
        let token = releaseCaptureCache.store(capture)
        return InputTargetCaptureHint(
            processID: capture.processID,
            targetToken: token
        )
    }

    /// Captures the focused target only when it belongs to the exact process
    /// selected by the caller.
    ///
    /// This is used by explicit redelivery flows where a frontmost-app change
    /// between user confirmation and AX capture must fail closed.
    public func capture(
        expectedProcessID: Int32
    ) async -> InputTargetCaptureResult {
        await capture(expectedProcessID: Optional(expectedProcessID))
    }

    private func capture(
        expectedProcessID: Int32?
    ) async -> InputTargetCaptureResult {
        let capture = await system.captureFocusedTarget()
        return store(capture, expectedProcessID: expectedProcessID)
    }

    private func store(
        _ capture: AccessibilityTargetCapture,
        expectedProcessID: Int32?
    ) -> InputTargetCaptureResult {
        switch capture {
        case let .unavailable(reason):
            return .unavailable(reason)
        case let .writable(evidence):
            guard expectedProcessID == nil
                    || evidence.processID == expectedProcessID
            else {
                return .unavailable(.invalidatedTarget)
            }
            let id = UUID()
            targets[id] = StoredTarget(evidence: evidence)
            return .writable(.init(
                id: id,
                applicationName: evidence.applicationName
            ))
        }
    }

    public func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        guard let stored = targets.removeValue(forKey: target.id) else {
            return .pendingCopy(.invalidatedTarget)
        }
        let evidence = stored.evidence

        switch await system.subrole(of: evidence.reference) {
        case let .success(subrole?) where subrole == "AXSecureTextField":
            return .pendingCopy(.secureTarget)
        case .failure(.attributeUnsupported), .failure(.notImplemented),
             .success:
            // Normal text controls are not required to expose a subrole.
            break
        case let .failure(failure):
            return Self.failedOperation(
                stage: .securityRead,
                failure: failure
            )
        }
        guard !(await system.secureInputEnabled()) else {
            return .pendingCopy(.secureTarget)
        }

        switch await system.role(of: evidence.reference) {
        case let .success(role?) where !role.isEmpty:
            break
        case .success:
            return .pendingCopy(.invalidatedTarget)
        case let .failure(failure):
            return Self.failedOperation(
                stage: .roleRead,
                failure: failure
            )
        }

        let currentValue: String
        switch await system.value(of: evidence.reference) {
        case let .success(value?):
            currentValue = value
        case .success(nil):
            return .pendingCopy(.invalidatedTarget)
        case let .failure(failure):
            return Self.failedOperation(
                stage: .valueRead,
                failure: failure
            )
        }
        guard currentValue == evidence.originalValue else {
            return .pendingCopyDiagnosed(
                .changedTarget,
                .init(stage: .valueRead, cause: .changed)
            )
        }

        guard let expectedValue = replacingSelection(
            in: evidence,
            with: text
        ) else {
            return .pendingCopy(.unsupportedTarget)
        }

        var directFailure: AccessibilityOperationFailure?
        var directDiagnostic: DeliveryDiagnostic?
        var committed = false
        if evidence.supportsDirectInsertion {
            switch await system.selection(of: evidence.reference) {
            case let .success(selection?) where selection == evidence.selection:
                break
            case .success:
                return .pendingCopy(.changedTarget)
            case let .failure(failure):
                return Self.failedOperation(
                    stage: .directSelection,
                    failure: failure
                )
            }
            switch await system.value(of: evidence.reference) {
            case let .success(value?) where value == evidence.originalValue:
                break
            case .success:
                return .pendingCopy(.changedTarget)
            case let .failure(failure):
                return Self.failedOperation(
                    stage: .valueRead,
                    failure: failure
                )
            }
            guard !(await system.secureInputEnabled()) else {
                return .pendingCopy(.secureTarget)
            }
            guard await commitGate.commit() else {
                return .pendingCopy(.deliveryFailed)
            }
            committed = true
            guard !Task.isCancelled else {
                return .pendingCopy(.deliveryFailed)
            }
            // The current selection was just verified. Writing the historical
            // range back here would overwrite a cursor move that races after
            // the check; AXSelectedText already targets the current selection.
            switch await system.setSelectedText(
                text,
                of: evidence.reference
            ) {
            case .success, .failure(.cannotComplete):
                return await verifyMutationReceipt(
                    expectedValue,
                    originalValue: evidence.originalValue,
                    target: evidence.reference,
                    diagnosticStage: .directReceipt
                )
            case let .failure(error):
                directFailure = error
                directDiagnostic = Self.diagnostic(
                    stage: .directWrite,
                    failure: error
                )
                switch await system.value(of: evidence.reference) {
                case let .success(value?) where value == expectedValue:
                    return .delivered
                case let .success(value?) where value == evidence.originalValue:
                    break
                case .success:
                    return .pendingCopy(.changedTarget)
                case let .failure(failure):
                    return Self.failedOperation(
                        stage: .valueRead,
                        failure: failure
                    )
                }
            }
        }

        let isVerifiedApplication = Self.allowsUnicodeDelivery(
            to: evidence.applicationBundleIdentifier,
            verifiedBundleIdentifiers: verifiedUnicodeDeliveryBundleIdentifiers
        )
        let isFrontmostExactTarget = await system.isFrontmost(
            processID: evidence.processID
        )
        guard isVerifiedApplication || isFrontmostExactTarget else {
            if let directFailure, let directDiagnostic {
                return .pendingCopyDiagnosed(
                    directFailure.pendingCopyReason,
                    directDiagnostic
                )
            }
            return .pendingCopyDiagnosed(
                .unsupportedTarget,
                .init(
                    stage: .fallbackEligibility,
                    cause: .notFrontmost
                )
            )
        }
        switch await system.focusedState(
            evidence.reference,
            in: evidence.processID
        ) {
        case .success(true):
            break
        case .success(false):
            return .pendingCopy(.invalidatedTarget)
        case let .failure(failure):
            return Self.failedOperation(
                stage: .focusRead,
                failure: failure
            )
        }
        switch await system.value(of: evidence.reference) {
        case let .success(value?) where value == evidence.originalValue:
            break
        case .success:
            return .pendingCopy(.changedTarget)
        case let .failure(failure):
            return Self.failedOperation(
                stage: .valueRead,
                failure: failure
            )
        }
        switch await system.selection(of: evidence.reference) {
        case let .success(selection?) where selection == evidence.selection:
            break
        case .success:
            return .pendingCopy(.changedTarget)
        case let .failure(failure):
            return Self.failedOperation(
                stage: .fallbackSelection,
                failure: failure
            )
        }
        guard !(await system.secureInputEnabled()) else {
            return .pendingCopy(.secureTarget)
        }
        if !committed {
            guard await commitGate.commit() else {
                return .pendingCopy(.deliveryFailed)
            }
        }
        guard !Task.isCancelled else {
            return .pendingCopy(.deliveryFailed)
        }
        guard await system.postUnicode(text, to: evidence.processID) else {
            if let directFailure, let directDiagnostic {
                return .pendingCopyDiagnosed(
                    directFailure.pendingCopyReason,
                    directDiagnostic
                )
            }
            return .pendingCopyDiagnosed(
                .deliveryFailed,
                .init(
                    stage: .unicodePost,
                    cause: .rejected
                )
            )
        }
        return await verifyPostedUnicode(
            expectedValue,
            originalValue: evidence.originalValue,
            target: evidence.reference
        )
    }

    public func discard(_ target: InputTargetSnapshot) async {
        targets[target.id] = nil
    }

    package static func allowsUnicodeDelivery(
        to bundleIdentifier: String?,
        verifiedBundleIdentifiers: Set<String>
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return verifiedBundleIdentifiers.contains(bundleIdentifier)
    }

    private func verifyMutationReceipt(
        _ expectedValue: String,
        originalValue: String,
        target: AccessibilityTargetReference,
        diagnosticStage: DeliveryDiagnostic.Stage
    ) async -> DeliveryOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while true {
            switch await system.value(of: target) {
            case let .success(value?) where value == expectedValue:
                return .delivered
            case let .success(value?) where value == originalValue:
                break
            case .success(nil), .failure(.cannotComplete):
                break
            case .failure(.invalidUIElement):
                return .pendingCopyDiagnosed(
                    .invalidatedTarget,
                    .init(
                        stage: diagnosticStage,
                        cause: .invalidated
                    )
                )
            case .failure(.attributeUnsupported), .failure(.notImplemented):
                return .pendingCopyDiagnosed(
                    .unsupportedTarget,
                    .init(
                        stage: diagnosticStage,
                        cause: .unsupported
                    )
                )
            case .failure(.other), .success(.some):
                return .pendingCopyDiagnosed(
                    .deliveryUnconfirmed,
                    .init(
                        stage: diagnosticStage,
                        cause: .unconfirmed
                    )
                )
            }
            guard clock.now < deadline else {
                return .pendingCopyDiagnosed(
                    .deliveryUnconfirmed,
                    .init(
                        stage: diagnosticStage,
                        cause: .unconfirmed
                    )
                )
            }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else {
                return .pendingCopyDiagnosed(
                    .deliveryFailed,
                    .init(
                        stage: diagnosticStage,
                        cause: .cancelled
                    )
                )
            }
        }
    }

    private func verifyPostedUnicode(
        _ expectedValue: String,
        originalValue: String,
        target: AccessibilityTargetReference
    ) async -> DeliveryOutcome {
        await verifyMutationReceipt(
            expectedValue,
            originalValue: originalValue,
            target: target,
            diagnosticStage: .unicodeReceipt
        )
    }

    private func replacingSelection(
        in evidence: AccessibilityTargetEvidence,
        with text: String
    ) -> String? {
        let original = evidence.originalValue as NSString
        let range = evidence.selection
        guard range.location >= 0, range.length >= 0,
              NSMaxRange(range) <= original.length
        else { return nil }
        return original.replacingCharacters(in: range, with: text)
    }

    private static func diagnostic(
        stage: DeliveryDiagnostic.Stage,
        failure: AccessibilityOperationFailure
    ) -> DeliveryDiagnostic {
        let cause: DeliveryDiagnostic.Cause = switch failure {
        case .invalidUIElement: .invalidUIElement
        case .attributeUnsupported: .attributeUnsupported
        case .notImplemented: .notImplemented
        case .cannotComplete: .cannotComplete
        case .other: .other
        }
        return DeliveryDiagnostic(stage: stage, cause: cause)
    }

    private static func failedOperation(
        stage: DeliveryDiagnostic.Stage,
        failure: AccessibilityOperationFailure
    ) -> DeliveryOutcome {
        .pendingCopyDiagnosed(
            failure.pendingCopyReason,
            diagnostic(stage: stage, failure: failure)
        )
    }
}
