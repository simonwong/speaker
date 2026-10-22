import ApplicationServices
import Foundation
import SpeakerCore
import SpeakerSpecSupport

@MainActor
final class AccessibilityStateFake {
    var granted: Bool

    init(granted: Bool) {
        self.granted = granted
    }
}

/// A stand-in for the general pasteboard. Speaker reads it from a background
/// executor and writes it on the main actor, so its state sits behind a lock.
final class ClipboardPasteboardFake: @unchecked Sendable {
    private struct State {
        var items: [[String: Data]]
        var changeCount = 0
        var clearCount = 0
        var itemTypesReadCount = 0
        var representationReadsOnMainThread = 0
        var writePurposes: [PasteboardWritePurpose] = []
        var clearsKeptOnCurrentHost: [Bool] = []
        var currentString: String?
        var currentMarker: (type: String, value: String)?
        var promise: PasteboardTextPromise?
        var didMutateWhileReading = false
    }

    private let lock = NSLock()
    private var state: State
    private let replacementWriteSucceeds: Bool
    private let replacementReadback: String?
    private let failedReplacementItems: [[String: Data]]?
    private let externalItemsAfterReplacement: [[String: Data]]?
    private let unreadableTypes: Set<String>
    private let itemEnumerationSucceeds: Bool
    private let mutatesWhileReadingRepresentations: Bool

    init(
        items: [[String: Data]],
        replacementWriteSucceeds: Bool = true,
        replacementReadback: String? = nil,
        failedReplacementItems: [[String: Data]]? = nil,
        externalItemsAfterReplacement: [[String: Data]]? = nil,
        unreadableTypes: Set<String> = [],
        itemEnumerationSucceeds: Bool = true,
        mutatesWhileReadingRepresentations: Bool = false
    ) {
        state = State(items: items)
        self.replacementWriteSucceeds = replacementWriteSucceeds
        self.replacementReadback = replacementReadback
        self.failedReplacementItems = failedReplacementItems
        self.externalItemsAfterReplacement = externalItemsAfterReplacement
        self.unreadableTypes = unreadableTypes
        self.itemEnumerationSucceeds = itemEnumerationSucceeds
        self.mutatesWhileReadingRepresentations =
            mutatesWhileReadingRepresentations
    }

    var items: [[String: Data]] { lock.withLock { state.items } }
    var changeCount: Int { lock.withLock { state.changeCount } }
    var clearCount: Int { lock.withLock { state.clearCount } }
    var itemTypesReadCount: Int { lock.withLock { state.itemTypesReadCount } }
    /// Representation reads made on the main thread, which a large
    /// clipboard would block.
    var representationReadsOnMainThread: Int {
        lock.withLock { state.representationReadsOnMainThread }
    }
    /// The purpose of every text write, in order.
    var writePurposes: [PasteboardWritePurpose] { lock.withLock { state.writePurposes } }
    /// Whether each clear kept the next value off Universal Clipboard.
    var clearsKeptOnCurrentHost: [Bool] { lock.withLock { state.clearsKeptOnCurrentHost } }

    var access: ClipboardPasteboardAccess {
        ClipboardPasteboardAccess(
            changeCount: { self.lock.withLock { self.state.changeCount } },
            itemCount: {
                self.lock.withLock {
                    self.itemEnumerationSucceeds ? self.state.items.count : nil
                }
            },
            itemTypes: { itemIndex in
                self.lock.withLock {
                    self.state.itemTypesReadCount += 1
                    guard self.state.items.indices.contains(itemIndex) else { return nil }
                    return Array(self.state.items[itemIndex].keys)
                }
            },
            data: { itemIndex, type in
                let onMainThread = Thread.isMainThread
                return self.lock.withLock {
                    if onMainThread { self.state.representationReadsOnMainThread += 1 }
                    guard !self.unreadableTypes.contains(type) else { return nil }
                    if self.mutatesWhileReadingRepresentations,
                        !self.state.didMutateWhileReading
                    {
                        // Another application copied while Speaker was still
                        // materializing representations.
                        self.state.didMutateWhileReading = true
                        self.state.changeCount += 1
                    }
                    return self.state.items[itemIndex][type]
                }
            },
            clearContents: { currentHostOnly in
                self.lock.withLock {
                    self.state.items = []
                    self.state.currentString = nil
                    self.state.currentMarker = nil
                    self.state.promise = nil
                    self.state.changeCount += 1
                    self.state.clearCount += 1
                    self.state.clearsKeptOnCurrentHost.append(currentHostOnly)
                    return self.state.changeCount
                }
            },
            writeText: { text, marker, purpose in
                self.lock.withLock {
                    self.write(text, marker: marker, purpose: purpose, promise: nil)
                }
            },
            writePromisedText: { promise, marker, purpose in
                self.lock.withLock {
                    self.write(promise.text, marker: marker, purpose: purpose, promise: promise)
                }
            },
            readString: { self.lock.withLock { self.state.currentString } },
            readMarker: { purpose in
                self.lock.withLock {
                    guard let currentMarker = self.state.currentMarker,
                        currentMarker.type == purpose.markerType.rawValue
                    else { return nil }
                    return currentMarker.value
                }
            },
            writeItems: { items in
                self.lock.withLock {
                    self.state.items = items
                    self.state.currentString = nil
                    self.state.currentMarker = nil
                    self.state.promise = nil
                    self.state.changeCount += 1
                    return true
                }
            }
        )
    }

    /// Called with the lock held.
    private func write(
        _ text: String,
        marker: String,
        purpose: PasteboardWritePurpose,
        promise: PasteboardTextPromise?
    ) -> Bool {
        state.writePurposes.append(purpose)
        guard replacementWriteSucceeds else {
            if let failedReplacementItems {
                state.currentString = text
                state.currentMarker = (purpose.markerType.rawValue, marker)
                state.items = failedReplacementItems
                state.changeCount += 1
            }
            return false
        }
        state.currentString = replacementReadback ?? text
        state.currentMarker = (purpose.markerType.rawValue, marker)
        state.items = [["public.utf8-plain-text": Data(text.utf8)]]
        state.promise = promise
        state.changeCount += 1
        if let externalItemsAfterReplacement {
            state.items = externalItemsAfterReplacement
            state.currentString = "new external copy"
            state.currentMarker = nil
            state.promise = nil
            state.changeCount += 1
        }
        return true
    }

    /// Another App asks for the clipboard text, which renders a promised
    /// value. Returns `nil` when no promise is on the clipboard.
    @discardableResult
    func readPromisedTextAsAnotherApplication() -> String? {
        let promise = lock.withLock { state.promise }
        return promise?.provideText()
    }

    func replaceExternally(with items: [[String: Data]]) {
        lock.withLock {
            state.items = items
            state.currentString = nil
            state.currentMarker = nil
            state.promise = nil
            state.changeCount += 1
        }
    }

    /// A value an earlier Speaker process wrote and never restored.
    func leaveSpeakerValue(_ text: String, purpose: PasteboardWritePurpose) {
        lock.withLock {
            state.items = [["public.utf8-plain-text": Data(text.utf8)]]
            state.currentString = text
            state.currentMarker = (purpose.markerType.rawValue, "earlier-process")
            state.changeCount += 1
        }
    }
}

/// Marks when a paste transaction's conditional restore has run.
actor PasteboardRestoreCompletion {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }

    func waitUntilCompleted(before timeout: Duration = .seconds(2)) async throws {
        let completed = await eventually(before: timeout) { await self.isCompleted }
        try expect(completed, "the conditional clipboard restore never ran")
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

struct LifecycleAccessibilityTargetSystem: AccessibilityTargetSystem {
    let live: LiveAccessibilityTargetSystem
    private let evidence = AccessibilityTargetEvidence(
        reference: AccessibilityTargetReference(),
        selection: nil,
        valueSample: nil,
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

    func textSample(
        of target: AccessibilityTargetReference,
        in range: NSRange
    ) async -> AccessibilityOperationResult<AccessibilityTextSample?> {
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
        in processID: pid_t,
        receipt: PasteReceipt
    ) async -> AccessibilityPasteResult {
        await live.paste(text, to: target, in: processID, receipt: receipt)
    }

    func shutdown() async {
        await live.shutdown()
    }
}

actor AccessibilityTargetSystemFake: AccessibilityTargetSystem {
    private let evidence: AccessibilityTargetEvidence
    private let originalValue: String?
    private var valueResponses: [AccessibilityOperationResult<String?>]
    private var selectionResponses: [AccessibilityOperationResult<NSRange?>]
    private var subroleResponses: [AccessibilityOperationResult<String?>]
    private var roleResponses: [AccessibilityOperationResult<String?>]
    private var focusResponses: [AccessibilityOperationResult<Bool>]
    private let valueAfterResponses: AccessibilityOperationResult<String?>?
    private let frontmost: Bool
    private let pasteResult: AccessibilityPasteResult
    private let captureGate: OneShotGate?
    private let pasteHandler: (@Sendable (String, PasteReceipt) async -> AccessibilityPasteResult)?
    private(set) var pasteCallCount = 0
    private(set) var pasteReceipts: [PasteReceipt] = []
    private(set) var captureFocusedCallCount = 0
    private(set) var captureTargetCallCount = 0
    /// The ranges asked of `textSample(of:in:)`, in order.
    private(set) var sampleRangesRead: [NSRange] = []

    /// Value responses are whole values; each read returns the asked window
    /// of one. `valueAfterResponses` answers every value read once
    /// `valueResponses` runs out; by default the original value.
    /// `pasteHandler`, when given, performs the paste instead of returning
    /// `pasteResult`.
    init(
        originalValue: String? = "Hello",
        selection: NSRange? = NSRange(location: 5, length: 0),
        processID: pid_t = 42,
        referenceScope: AccessibilityTargetScope = .element,
        isFrontmost: Bool = true,
        valueResponses: [AccessibilityOperationResult<String?>],
        valueAfterResponses: AccessibilityOperationResult<String?>? = nil,
        selectionResponses: [AccessibilityOperationResult<NSRange?>] = [],
        subroleResponses: [AccessibilityOperationResult<String?>] = [],
        roleResponses: [AccessibilityOperationResult<String?>] = [],
        focusResponses: [AccessibilityOperationResult<Bool>] = [],
        pasteResult: AccessibilityPasteResult = .posted,
        pasteHandler: (@Sendable (String, PasteReceipt) async -> AccessibilityPasteResult)? = nil,
        captureGate: OneShotGate? = nil
    ) {
        self.valueAfterResponses = valueAfterResponses
        self.pasteHandler = pasteHandler
        self.captureGate = captureGate
        self.originalValue = originalValue
        evidence = AccessibilityTargetEvidence(
            reference: AccessibilityTargetReference(scope: referenceScope),
            selection: selection,
            valueSample: originalValue.flatMap {
                AccessibilityTextSample.evidence(fromValue: $0, selection: selection)
            },
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

    /// With a `captureGate`, the capture is counted at once but answers only
    /// after the case opens the gate.
    func captureFocusedTarget() async -> AccessibilityTargetCapture {
        captureFocusedCallCount += 1
        await captureGate?.wait()
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

    func textSample(
        of target: AccessibilityTargetReference,
        in range: NSRange
    ) async -> AccessibilityOperationResult<AccessibilityTextSample?> {
        sampleRangesRead.append(range)
        let response =
            valueResponses.isEmpty
            ? valueAfterResponses ?? .success(originalValue)
            : valueResponses.removeFirst()
        switch response {
        case .success(let value?)
        where value.utf16.count <= AccessibilityValueEvidenceLimits.maximumCharacterCount:
            return .success(AccessibilityTextSample(value: value, range: range))
        case .success:
            return .success(nil)
        case .failure(let failure):
            return .failure(failure)
        }
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
        in processID: pid_t,
        receipt: PasteReceipt
    ) async -> AccessibilityPasteResult {
        pasteCallCount += 1
        pasteReceipts.append(receipt)
        if let pasteHandler {
            return await pasteHandler(text, receipt)
        }
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
        return .writable(
            .init(
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
