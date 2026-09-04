import Foundation
import ApplicationServices
import SpeakerCore
import SpeakerSpecSupport

@MainActor
final class AccessibilityStateFake {
    var granted: Bool

    init(granted: Bool) {
        self.granted = granted
    }
}

@MainActor
final class ClipboardPasteboardFake {
    private(set) var items: [[String: Data]]
    private(set) var changeCount = 0
    private(set) var clearCount = 0
    private(set) var itemTypesReadCount = 0
    private var currentString: String?
    private var currentMarker: String?
    private let replacementWriteSucceeds: Bool
    private let replacementReadback: String?
    private let failedReplacementItems: [[String: Data]]?
    private let externalItemsAfterReplacement: [[String: Data]]?
    private let unreadableTypes: Set<String>

    init(
        items: [[String: Data]],
        replacementWriteSucceeds: Bool = true,
        replacementReadback: String? = nil,
        failedReplacementItems: [[String: Data]]? = nil,
        externalItemsAfterReplacement: [[String: Data]]? = nil,
        unreadableTypes: Set<String> = []
    ) {
        self.items = items
        self.replacementWriteSucceeds = replacementWriteSucceeds
        self.replacementReadback = replacementReadback
        self.failedReplacementItems = failedReplacementItems
        self.externalItemsAfterReplacement = externalItemsAfterReplacement
        self.unreadableTypes = unreadableTypes
    }

    var access: ClipboardPasteboardAccess {
        ClipboardPasteboardAccess(
            changeCount: { self.changeCount },
            itemCount: { self.items.count },
            itemTypes: { itemIndex in
                self.itemTypesReadCount += 1
                guard self.items.indices.contains(itemIndex) else { return nil }
                return Array(self.items[itemIndex].keys)
            },
            data: { itemIndex, type in
                guard !self.unreadableTypes.contains(type) else { return nil }
                return self.items[itemIndex][type]
            },
            clearContents: {
                self.items = []
                self.currentString = nil
                self.currentMarker = nil
                self.changeCount += 1
                self.clearCount += 1
                return self.changeCount
            },
            writeText: { text, marker in
                guard self.replacementWriteSucceeds else {
                    if let failedReplacementItems = self.failedReplacementItems {
                        self.currentString = text
                        self.currentMarker = marker
                        self.items = failedReplacementItems
                        self.changeCount += 1
                    }
                    return false
                }
                self.currentString = self.replacementReadback ?? text
                self.currentMarker = marker
                self.items = [["public.utf8-plain-text": Data(text.utf8)]]
                self.changeCount += 1
                if let externalItems = self.externalItemsAfterReplacement {
                    self.items = externalItems
                    self.currentString = "new external copy"
                    self.currentMarker = nil
                    self.changeCount += 1
                }
                return true
            },
            readString: { self.currentString },
            readMarker: { self.currentMarker },
            writeItems: { items in
                self.items = items
                self.currentString = nil
                self.currentMarker = nil
                self.changeCount += 1
                return true
            }
        )
    }

    func replaceExternally(with items: [[String: Data]]) {
        self.items = items
        currentString = nil
        currentMarker = nil
        changeCount += 1
    }
}

actor ControlledPasteboardRestoreSleep {
    private(set) var requestedDuration: Duration?
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var restoreCompleted = false

    func sleep(for duration: Duration) async throws {
        requestedDuration = duration
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func markRestoreCompleted() {
        restoreCompleted = true
    }

    func waitUntilRestoreCompleted() async {
        while !restoreCompleted {
            await Task.yield()
        }
    }
}

actor ControlledPasteboardPreparation {
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func block() async {
        isBlocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while !isBlocked { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

actor TargetCaptureFake: InputTargetCapturing {
    let result: InputTargetCaptureResult
    private(set) var captureCount = 0

    init(result: InputTargetCaptureResult) {
        self.result = result
    }

    func capture() async -> InputTargetCaptureResult {
        captureCount += 1
        return result
    }
}

struct LifecycleAccessibilityTargetSystem: AccessibilityTargetSystem {
    let live: LiveAccessibilityTargetSystem
    private let evidence = AccessibilityTargetEvidence(
        reference: AccessibilityTargetReference(),
        selection: nil,
        originalValue: nil,
        processID: 42,
        applicationName: "Editor"
    )

    func captureFocusedTarget() async -> AccessibilityTargetCapture {
        .writable(evidence)
    }

    func captureTarget(
        _ target: AccessibilityReleaseTarget
    ) async -> AccessibilityTargetCapture {
        guard target.processID == evidence.processID else {
            return .unavailable(.invalidatedTarget)
        }
        return .writable(evidence)
    }

    func secureInputEnabled() async -> Bool { false }

    func subrole(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        .success(nil)
    }

    func role(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        .success("AXTextArea")
    }

    func value(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        .success(nil)
    }

    func focusedState(
        _ target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityOperationResult<Bool> {
        .success(true)
    }

    func isFrontmost(processID: pid_t) async -> Bool { true }

    func selection(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<NSRange?> {
        .success(nil)
    }

    func paste(
        _ text: String,
        to target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityPasteResult {
        await live.paste(text, to: target, in: processID)
    }

    func shutdown() async {
        await live.shutdown()
    }
}

actor AccessibilityTargetSystemFake: AccessibilityTargetSystem {
    private let evidence: AccessibilityTargetEvidence
    private var valueResponses: [AccessibilityOperationResult<String?>]
    private var selectionResponses:
        [AccessibilityOperationResult<NSRange?>]
    private var subroleResponses: [AccessibilityOperationResult<String?>]
    private var roleResponses: [AccessibilityOperationResult<String?>]
    private var focusResponses: [AccessibilityOperationResult<Bool>]
    private let frontmost: Bool
    private let pasteResult: AccessibilityPasteResult
    private(set) var pasteCallCount = 0
    private(set) var captureFocusedCallCount = 0
    private(set) var captureTargetCallCount = 0

    init(
        originalValue: String? = "Hello",
        selection: NSRange? = NSRange(location: 5, length: 0),
        processID: pid_t = 42,
        referenceScope: AccessibilityTargetScope = .element,
        isFrontmost: Bool = true,
        valueResponses: [AccessibilityOperationResult<String?>],
        selectionResponses: [AccessibilityOperationResult<NSRange?>] = [],
        subroleResponses: [AccessibilityOperationResult<String?>] = [],
        roleResponses: [AccessibilityOperationResult<String?>] = [],
        focusResponses: [AccessibilityOperationResult<Bool>] = [],
        pasteResult: AccessibilityPasteResult = .posted
    ) {
        evidence = AccessibilityTargetEvidence(
            reference: AccessibilityTargetReference(scope: referenceScope),
            selection: selection,
            originalValue: originalValue,
            processID: processID,
            applicationName: "Editor"
        )
        frontmost = isFrontmost
        self.pasteResult = pasteResult
        self.valueResponses = valueResponses
        self.selectionResponses = selectionResponses
        self.subroleResponses = subroleResponses
        self.roleResponses = roleResponses
        self.focusResponses = focusResponses
    }

    func captureFocusedTarget() async -> AccessibilityTargetCapture {
        captureFocusedCallCount += 1
        return .writable(evidence)
    }

    func captureTarget(
        _ target: AccessibilityReleaseTarget
    ) async -> AccessibilityTargetCapture {
        captureTargetCallCount += 1
        guard target.processID == evidence.processID,
              target.reference == evidence.reference
        else {
            return .unavailable(.invalidatedTarget)
        }
        return .writable(evidence)
    }

    func secureInputEnabled() async -> Bool { false }

    func subrole(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard !subroleResponses.isEmpty else { return .success(nil) }
        return subroleResponses.removeFirst()
    }

    func role(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard !roleResponses.isEmpty else { return .success("AXTextArea") }
        return roleResponses.removeFirst()
    }

    func value(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard !valueResponses.isEmpty else {
            return .success(evidence.originalValue)
        }
        return valueResponses.removeFirst()
    }

    func focusedState(
        _ target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityOperationResult<Bool> {
        guard !focusResponses.isEmpty else { return .success(true) }
        return focusResponses.removeFirst()
    }

    func isFrontmost(processID: pid_t) async -> Bool {
        frontmost
    }

    func selection(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<NSRange?> {
        guard !selectionResponses.isEmpty else {
            return .success(evidence.selection)
        }
        return selectionResponses.removeFirst()
    }

    func paste(
        _ text: String,
        to target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityPasteResult {
        pasteCallCount += 1
        return pasteResult
    }
}

actor ReleaseTimeTargetCaptureFake: InputTargetCapturing {
    private var applicationName: String
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var captureCallCount = 0

    init(applicationName: String) {
        self.applicationName = applicationName
    }

    func update(applicationName: String) {
        self.applicationName = applicationName
    }

    func capture() async -> InputTargetCaptureResult {
        captureCallCount += 1
        let capturedApplicationName = applicationName
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .writable(.init(
            id: UUID(),
            applicationName: capturedApplicationName
        ))
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

final class LockedCaptureHintSource: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: Int32

    init(processID: Int32) {
        self.processID = processID
    }

    var hint: InputTargetCaptureHint {
        lock.withLock {
            InputTargetCaptureHint(processID: processID)
        }
    }

    func update(processID: Int32) {
        lock.withLock {
            self.processID = processID
        }
    }
}

actor HintRecordingTargetCaptureFake: InputTargetCapturing {
    let result: InputTargetCaptureResult
    private(set) var capturedProcessIDs: [Int32] = []

    init(result: InputTargetCaptureResult) {
        self.result = result
    }

    func capture() async -> InputTargetCaptureResult {
        result
    }

    func capture(
        matching hint: InputTargetCaptureHint
    ) async -> InputTargetCaptureResult {
        capturedProcessIDs.append(hint.processID)
        return result
    }
}

actor DiscardingTargetCaptureFake: InputTargetCapturing, InputTargetDiscarding {
    let snapshot: InputTargetSnapshot
    private(set) var discardedCount = 0

    init(snapshot: InputTargetSnapshot) {
        self.snapshot = snapshot
    }

    func capture() async -> InputTargetCaptureResult { .writable(snapshot) }

    func discard(_ target: InputTargetSnapshot) async {
        if target.id == snapshot.id { discardedCount += 1 }
    }
}

actor TextDeliveryFake: TextDelivering {
    let result: DeliveryOutcome
    private(set) var deliveredTexts: [String] = []

    init(result: DeliveryOutcome) {
        self.result = result
    }

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        deliveredTexts.append(text)
        return result
    }
}

actor TargetRecordingDeliveryFake: TextDelivering {
    private(set) var applicationNames: [String] = []

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        applicationNames.append(target.applicationName)
        return .delivered
    }
}

actor DelayedCommitDeliveryFake: TextDelivering {
    private(set) var entered = false
    private(set) var deliveredTexts: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        deliveredTexts.append(text)
        return .delivered
    }

    func allowCommitAttempt() {
        continuation?.resume()
        continuation = nil
    }
}

actor BlockingDeliveryFake: TextDelivering {
    let commitsBeforeBlocking: Bool
    private(set) var isBlocking = false
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<DeliveryOutcome, Never>?

    init(commitsBeforeBlocking: Bool) {
        self.commitsBeforeBlocking = commitsBeforeBlocking
    }

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        if commitsBeforeBlocking {
            guard await commitGate.commit() else {
                return .pendingCopy(.deliveryFailed)
            }
        }
        isBlocking = true
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.markCancelled() }
        }
        return Task.isCancelled ? .pendingCopy(.deliveryFailed) : outcome
    }

    func finish(with outcome: DeliveryOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func markCancelled() {
        cancellationCount += 1
    }
}

actor ClipboardFake: ClipboardWriting {
    private(set) var copiedTexts: [String] = []
    private let succeeds: Bool

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func copy(_ text: String) async -> Bool {
        copiedTexts.append(text)
        return succeeds
    }
}
