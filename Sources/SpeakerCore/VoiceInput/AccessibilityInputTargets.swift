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
    TextDelivering
{
    private struct StoredTarget {
        let evidence: AccessibilityTargetEvidence
    }

    private var targets: [UUID: StoredTarget] = [:]
    private let system: any AccessibilityTargetSystem
    private nonisolated let releaseCapture: @Sendable () -> AccessibilityReleaseCapture
    private nonisolated let releaseCaptureCache =
        AccessibilityReleaseCaptureCache()

    public init() {
        let system = LiveAccessibilityTargetSystem()
        self.system = system
        releaseCapture = {
            system.captureReleaseProcess()
        }
    }

    package init(
        system: any AccessibilityTargetSystem,
        releaseCapture:
            @escaping @Sendable () -> AccessibilityReleaseCapture = {
                .unavailable(processID: 0, reason: .missingTarget)
            }
    ) {
        self.system = system
        self.releaseCapture = releaseCapture
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
        case .process(let processID):
            guard processID == hint.processID else {
                return .unavailable(.invalidatedTarget)
            }
            let capture = await system.captureFocusedTarget(in: processID)
            return store(capture, expectedProcessID: processID)
        case .unavailable(_, let reason):
            return .unavailable(reason)
        case .target(let target):
            guard target.processID == hint.processID else {
                return .unavailable(.invalidatedTarget)
            }
            let exactCapture = await system.captureTarget(target)
            switch exactCapture {
            case .writable:
                return store(
                    exactCapture,
                    expectedProcessID: hint.processID
                )
            case .unavailable(.invalidatedTarget),
                .unavailable(.missingTarget):
                let currentCapture = await system.captureFocusedTarget(
                    in: hint.processID
                )
                return store(
                    currentCapture,
                    expectedProcessID: hint.processID
                )
            case .unavailable:
                return store(
                    exactCapture,
                    expectedProcessID: hint.processID
                )
            }
        }
    }

    /// Freezes only the frontmost process while the physical stop gesture is
    /// still being handled. The focused input is read immediately after the
    /// callback returns, avoiding target-App AX IPC inside the event tap.
    public nonisolated func releaseCaptureHint() -> InputTargetCaptureHint? {
        let capture = releaseCapture()
        let token = releaseCaptureCache.store(capture)
        return InputTargetCaptureHint(
            processID: capture.processID,
            targetToken: token
        )
    }

    package nonisolated var releaseCaptureDiagnostic: String? {
        system.captureDiagnostic
    }

    /// Captures the focused target only when it belongs to the exact process
    /// selected by the caller.
    ///
    /// A frontmost-app change before the AX capture fails closed instead of
    /// freezing a target in the wrong process.
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
        case .unavailable(let reason):
            return .unavailable(reason)
        case .writable(let evidence):
            guard
                expectedProcessID == nil
                    || evidence.processID == expectedProcessID
            else {
                return .unavailable(.invalidatedTarget)
            }
            let id = UUID()
            targets[id] = StoredTarget(evidence: evidence)
            return .writable(
                .init(
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
        case .success(let subrole?) where subrole == "AXSecureTextField":
            return .pendingCopy(.secureTarget)
        case .failure(.attributeUnsupported), .failure(.notImplemented),
            .success:
            // Normal text controls are not required to expose a subrole.
            break
        case .failure(let failure):
            return Self.failedOperation(
                stage: .securityRead,
                failure: failure
            )
        }
        guard !(await system.secureInputEnabled()) else {
            return .pendingCopy(.secureTarget)
        }

        switch await system.role(of: evidence.reference) {
        case .success(let role?) where !role.isEmpty:
            break
        case .success:
            return .pendingCopy(.invalidatedTarget)
        case .failure(let failure):
            return Self.failedOperation(
                stage: .roleRead,
                failure: failure
            )
        }

        if let originalValue = evidence.originalValue {
            switch await system.value(of: evidence.reference) {
            case .success(let value?) where value == originalValue:
                break
            case .success:
                return .pendingCopyDiagnosed(
                    .changedTarget,
                    .init(stage: .valueRead, cause: .changed)
                )
            case .failure(let failure):
                return Self.failedOperation(
                    stage: .valueRead,
                    failure: failure
                )
            }
        }
        let expectedValue = replacingSelection(in: evidence, with: text)

        let isFrontmostExactTarget = await system.isFrontmost(
            processID: evidence.processID
        )
        guard isFrontmostExactTarget else {
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
        case .failure(let failure):
            return Self.failedOperation(
                stage: .focusRead,
                failure: failure
            )
        }
        if let originalValue = evidence.originalValue {
            switch await system.value(of: evidence.reference) {
            case .success(let value?) where value == originalValue:
                break
            case .success:
                return .pendingCopy(.changedTarget)
            case .failure(let failure):
                return Self.failedOperation(
                    stage: .valueRead,
                    failure: failure
                )
            }
        }
        if let selection = evidence.selection {
            switch await system.selection(of: evidence.reference) {
            case .success(let current?) where current == selection:
                break
            case .success:
                return .pendingCopy(.changedTarget)
            case .failure(let failure):
                return Self.failedOperation(
                    stage: .fallbackSelection,
                    failure: failure
                )
            }
        }
        guard !(await system.secureInputEnabled()) else {
            return .pendingCopy(.secureTarget)
        }
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        guard !Task.isCancelled else {
            return .pendingCopy(.deliveryFailed)
        }
        switch await system.paste(
            text,
            to: evidence.reference,
            in: evidence.processID
        ) {
        case .posted:
            if let expectedValue,
                let originalValue = evidence.originalValue
            {
                return await verifyMutationReceipt(
                    expectedValue,
                    originalValue: originalValue,
                    target: evidence.reference,
                    diagnosticStage: .pasteReceipt
                )
            }
            return .pasteCommandPosted(
                .init(
                    stage: .pasteReceipt,
                    cause: .unconfirmed
                ))
        case .secureTarget:
            return .pendingCopy(.secureTarget)
        case .targetChanged:
            return .pendingCopy(.invalidatedTarget)
        case .targetFailure(let failure):
            return Self.failedOperation(stage: .focusRead, failure: failure)
        case .clipboardFailed, .eventFailed:
            return .pendingCopyDiagnosed(
                .deliveryFailed,
                .init(
                    stage: .pastePost,
                    cause: .rejected
                )
            )
        }
    }

    public func discard(_ target: InputTargetSnapshot) async {
        targets[target.id] = nil
    }

    public func shutdown() async {
        await system.shutdown()
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
            case .success(let value?) where value == expectedValue:
                return .delivered
            case .success(let value?) where value == originalValue:
                break
            case .success(nil), .failure(.cannotComplete):
                break
            case .failure(.invalidUIElement):
                return .pasteCommandPosted(
                    .init(
                        stage: diagnosticStage,
                        cause: .invalidated
                    )
                )
            case .failure(.attributeUnsupported), .failure(.notImplemented):
                return .pasteCommandPosted(
                    .init(
                        stage: diagnosticStage,
                        cause: .unsupported
                    )
                )
            case .failure(.other), .success(.some):
                return .pasteCommandPosted(
                    .init(
                        stage: diagnosticStage,
                        cause: .unconfirmed
                    )
                )
            }
            guard clock.now < deadline else {
                return .pasteCommandPosted(
                    .init(
                        stage: diagnosticStage,
                        cause: .unconfirmed
                    )
                )
            }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else {
                return .pasteCommandPosted(
                    .init(
                        stage: diagnosticStage,
                        cause: .cancelled
                    )
                )
            }
        }
    }

    private func replacingSelection(
        in evidence: AccessibilityTargetEvidence,
        with text: String
    ) -> String? {
        guard let originalValue = evidence.originalValue,
            let range = evidence.selection
        else { return nil }
        let original = originalValue as NSString
        guard range.location >= 0, range.length >= 0,
            NSMaxRange(range) <= original.length
        else { return nil }
        return original.replacingCharacters(in: range, with: text)
    }

    private static func diagnostic(
        stage: DeliveryDiagnostic.Stage,
        failure: AccessibilityOperationFailure
    ) -> DeliveryDiagnostic {
        let cause: DeliveryDiagnostic.Cause =
            switch failure {
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
