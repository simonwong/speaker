import Foundation

public struct VoiceInputSessionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package enum VoiceInputCommand: Sendable {
    case pressed
    case released
    case cancel
    case copyPendingResult
    case dismissResult
}

/// Content-free identity frozen inside the physical stop-gesture callback.
///
/// Full Accessibility inspection remains asynchronous, but it must resolve to
/// this exact process. Switching to another App after ending the recording
/// therefore fails closed instead of capturing the newer App.
public struct InputTargetCaptureHint: Equatable, Sendable {
    public let processID: Int32
    package let targetToken: UUID?

    public init(processID: Int32) {
        self.processID = processID
        targetToken = nil
    }

    package init(processID: Int32, targetToken: UUID) {
        self.processID = processID
        self.targetToken = targetToken
    }
}

public enum VoiceInputProcessingStage: Equatable, Sendable {
    case capturingTarget
    case transcribing
    case refining
    case delivering
}

public enum PendingCopyReason: String, Equatable, Sendable {
    case missingTarget
    case accessibilityPermissionMissing
    case secureTarget
    case unsupportedTarget
    case invalidatedTarget
    case changedTarget
    case deliveryFailed
    case targetApplicationUnresponsive
    /// Kept only so history written by older builds remains decodable.
    case deliveryTimedOut
    case deliveryUnconfirmed
    case clipboardFailed
}

public enum VoiceInputActivity: Equatable, Sendable {
    case idle
    case preparing(VoiceInputSessionID)
    case recording(VoiceInputSessionID)
    case processing(
        VoiceInputSessionID,
        VoiceInputProcessingStage,
        applicationName: String?
    )
    case delivered(
        VoiceInputSessionID,
        applicationName: String,
        text: String
    )
    case pendingCopy(
        VoiceInputSessionID,
        text: String,
        reason: PendingCopyReason
    )
    case cancelled(VoiceInputSessionID)
    case failed(VoiceInputSessionID, VoiceInputFailure)

    public var isRecording: Bool {
        if case .recording = self { true } else { false }
    }

    public var isDelivered: Bool {
        if case .delivered = self { true } else { false }
    }

    public var isTerminal: Bool {
        switch self {
        case .delivered, .pendingCopy, .cancelled, .failed:
            true
        case .idle, .preparing, .recording, .processing:
            false
        }
    }

    public var stage: VoiceInputProcessingStage? {
        if case let .processing(_, stage, _) = self { stage } else { nil }
    }

    public var pendingCopyReason: PendingCopyReason? {
        if case let .pendingCopy(_, _, reason) = self { reason } else { nil }
    }

    public var pendingText: String? {
        if case let .pendingCopy(_, text, _) = self { text } else { nil }
    }

    package var sessionID: VoiceInputSessionID? {
        switch self {
        case .idle:
            nil
        case let .preparing(id),
             let .recording(id),
             let .processing(id, _, _),
             let .delivered(id, _, _),
             let .pendingCopy(id, _, _),
             let .cancelled(id),
             let .failed(id, _):
            id
        }
    }
}

public enum VoiceInputNotice: Equatable, Sendable {
    case copied
    case refinementFellBack(DeepSeekRefinementFailureKind?)
    case persistenceFailure(String)
}

public struct VoiceInputPresentation: Equatable, Sendable {
    public let revision: UInt64
    public let activity: VoiceInputActivity
    public let recordingTelemetry: RecordingTelemetry?
    public let notice: VoiceInputNotice?

    public init(
        revision: UInt64,
        activity: VoiceInputActivity,
        recordingTelemetry: RecordingTelemetry? = nil,
        notice: VoiceInputNotice? = nil
    ) {
        self.revision = revision
        self.activity = activity
        self.recordingTelemetry = recordingTelemetry
        self.notice = notice
    }
}

public struct RecordingTelemetry: Equatable, Sendable {
    public let elapsedMilliseconds: Int
    public let peakPower: Float

    public init(elapsedMilliseconds: Int, peakPower: Float) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.peakPower = peakPower
    }
}

public struct CapturedAudio: Equatable, Sendable {
    public let data: Data
    public let duration: Duration
    public let peakPower: Float

    public init(data: Data, duration: Duration, peakPower: Float) {
        self.data = data
        self.duration = duration
        self.peakPower = peakPower
    }
}

public struct InputTargetSnapshot: Equatable, Hashable, Sendable {
    public let id: UUID
    public let applicationName: String

    public init(id: UUID, applicationName: String) {
        self.id = id
        self.applicationName = applicationName
    }
}

public enum InputTargetCaptureResult: Equatable, Sendable {
    case writable(InputTargetSnapshot)
    case unavailable(PendingCopyReason)
}

public struct TranscriptionResult: Equatable, Sendable {
    public let text: String
    public let providerRequestID: String?

    public init(text: String, providerRequestID: String?) {
        self.text = text
        self.providerRequestID = providerRequestID
    }
}

public struct DeliveryDiagnostic: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case securityRead
        case roleRead
        case directSelection
        case directWrite
        case directReceipt
        case fallbackEligibility
        case focusRead
        case fallbackSelection
        case valueRead
        case unicodePost
        case unicodeReceipt
    }

    public enum Cause: String, Equatable, Sendable {
        case invalidated
        case unsupported
        case unconfirmed
        case cancelled
        case invalidUIElement
        case attributeUnsupported
        case notImplemented
        case cannotComplete
        case other
        case notFrontmost
        case rejected
        case changed
    }

    public let stage: Stage
    public let cause: Cause

    public init(stage: Stage, cause: Cause) {
        self.stage = stage
        self.cause = cause
    }

    public var code: String {
        "\(stage.rawValue).\(cause.rawValue)"
    }
}

public enum DeliveryOutcome: Equatable, Sendable {
    case delivered
    case pendingCopy(PendingCopyReason)
    case pendingCopyDiagnosed(
        PendingCopyReason,
        DeliveryDiagnostic
    )

    public var pendingCopyReason: PendingCopyReason? {
        switch self {
        case .delivered: nil
        case let .pendingCopy(reason),
             let .pendingCopyDiagnosed(reason, _):
            reason
        }
    }

    public var deliveryDiagnostic: DeliveryDiagnostic? {
        if case let .pendingCopyDiagnosed(_, diagnostic) = self {
            diagnostic
        } else {
            nil
        }
    }
}

public actor DeliveryCommitGate {
    private enum State: Equatable { case pending, committed, cancelled }
    private var state = State.pending

    public init() {}

    public func commit() -> Bool {
        guard state == .pending else { return state == .committed }
        state = .committed
        return true
    }

    /// Returns true only when cancellation wins before the mutation commit.
    public func cancel() -> Bool {
        guard state == .pending else { return false }
        state = .cancelled
        return true
    }
}

private actor DeliveryResolution {
    private var outcome: DeliveryOutcome?
    private var continuation: CheckedContinuation<DeliveryOutcome, Never>?

    func wait() async -> DeliveryOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ outcome: DeliveryOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

public struct VoiceInputHistoryRecord: Equatable, Sendable {
    public let sessionID: VoiceInputSessionID
    public let startedAt: Date
    public let applicationName: String?
    public let transcription: String?
    public let finalText: String?
    public let transcriptionProvider: String?
    public let providerRequestID: String?
    public let providerErrorCode: String?
    public let providerOperation: String?
    public let providerStatusCode: String?
    public let providerMessage: String?
    public let deliveryDiagnosticCode: String?
    public let deepSeekText: String?
    public let deepSeekRequestID: String?
    public let refinementModeName: String?
    public let refinementPrompt: String?
    public let refinementStatus: String?
    public let refinementFailureCode: String?
    public let refinementFailureStatusCode: String?
    public let refinementFailureMessage: String?
    public let cancelledAtStage: String?
    public let dictionarySnapshotID: UUID?
    public let dictionarySnapshotEntries: [RecordedDictionaryEntry]
    public let dictionaryRequestContext: DictionaryRequestContext?
    public let dictionaryReplacements: [DictionaryReplacement]
    public let durationMilliseconds: Int
    public let stageDurationsMilliseconds: [String: Int]
    public let outcome: VoiceInputActivity

    public init(
        sessionID: VoiceInputSessionID,
        startedAt: Date,
        applicationName: String?,
        transcription: String?,
        finalText: String?,
        transcriptionProvider: String? = nil,
        providerRequestID: String? = nil,
        providerErrorCode: String? = nil,
        providerOperation: String? = nil,
        providerStatusCode: String? = nil,
        providerMessage: String? = nil,
        deliveryDiagnosticCode: String? = nil,
        deepSeekText: String? = nil,
        deepSeekRequestID: String? = nil,
        refinementModeName: String? = nil,
        refinementPrompt: String? = nil,
        refinementStatus: String? = nil,
        refinementFailureCode: String? = nil,
        refinementFailureStatusCode: String? = nil,
        refinementFailureMessage: String? = nil,
        cancelledAtStage: String? = nil,
        dictionarySnapshotID: UUID? = nil,
        dictionarySnapshotEntries: [RecordedDictionaryEntry] = [],
        dictionaryRequestContext: DictionaryRequestContext? = nil,
        dictionaryReplacements: [DictionaryReplacement] = [],
        durationMilliseconds: Int = 0,
        stageDurationsMilliseconds: [String: Int] = [:],
        outcome: VoiceInputActivity
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.applicationName = applicationName
        self.transcription = transcription
        self.finalText = finalText
        self.transcriptionProvider = transcriptionProvider
        self.providerRequestID = providerRequestID
        self.providerErrorCode = providerErrorCode
        self.providerOperation = providerOperation
        self.providerStatusCode = providerStatusCode
        self.providerMessage = providerMessage
        self.deliveryDiagnosticCode = deliveryDiagnosticCode
        self.deepSeekText = deepSeekText
        self.deepSeekRequestID = deepSeekRequestID
        self.refinementModeName = refinementModeName
        self.refinementPrompt = refinementPrompt
        self.refinementStatus = refinementStatus
        self.refinementFailureCode = refinementFailureCode
        self.refinementFailureStatusCode = refinementFailureStatusCode
        self.refinementFailureMessage = refinementFailureMessage
        self.cancelledAtStage = cancelledAtStage
        self.dictionarySnapshotID = dictionarySnapshotID
        self.dictionarySnapshotEntries = dictionarySnapshotEntries
        self.dictionaryRequestContext = dictionaryRequestContext
        self.dictionaryReplacements = dictionaryReplacements
        self.durationMilliseconds = durationMilliseconds
        self.stageDurationsMilliseconds = stageDurationsMilliseconds
        self.outcome = outcome
    }
}

public protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async throws -> CapturedAudio
    func cancel() async
}

public protocol AudioChunkStreaming: Sendable {
    func audioChunks() async -> AsyncStream<Data>
}

public protocol AudioCaptureTelemetryProviding: Sendable {
    func observeTelemetry() async -> AsyncStream<RecordingTelemetry>
}

public protocol AudioCaptureFailureProviding: Sendable {
    func observeFailures() async -> AsyncStream<AudioCaptureError>
}

public protocol InputTargetCapturing: Sendable {
    func capture() async -> InputTargetCaptureResult
    func capture(
        matching hint: InputTargetCaptureHint
    ) async -> InputTargetCaptureResult
}

public extension InputTargetCapturing {
    func capture(
        matching hint: InputTargetCaptureHint
    ) async -> InputTargetCaptureResult {
        await capture()
    }
}

public protocol InputTargetDiscarding: Sendable {
    func discard(_ target: InputTargetSnapshot) async
}

public protocol SpeechTranscribing: Sendable {
    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult
}

public protocol TextDelivering: Sendable {
    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome
}

public protocol ClipboardWriting: Sendable {
    @discardableResult
    func copy(_ text: String) async -> Bool
}

public protocol SessionHistoryRecording: Sendable {
    func save(_ record: VoiceInputHistoryRecord) async
    func persistenceFailureNotice() async -> String?
}

public extension SessionHistoryRecording {
    func persistenceFailureNotice() async -> String? { nil }
}

public actor VoiceInputSessions {
    private struct TerminalHistoryPresentation: Sendable {
        let activity: VoiceInputActivity
        let notice: VoiceInputNotice?
    }

    private enum Phase: Equatable {
        case idle
        case preparing(VoiceInputSessionID)
        case recording(
            VoiceInputSessionID,
            startedAt: Date,
            snapshot: VoiceTextProcessingSnapshot
        )
        case processing(
            VoiceInputSessionID,
            startedAt: Date,
            snapshot: VoiceTextProcessingSnapshot
        )
        case finalizing(VoiceInputSessionID)
    }

    /// History text is fail-closed until the release-time Accessibility target
    /// has been classified. A secure target must never let provider text enter
    /// an in-flight, cancelled, failed, or terminal history record.
    private enum HistoryTextPolicy {
        case unclassified
        case allowed
        case redacted
    }

    private let audioCapture: any AudioCapturing
    private let targetCapture: any InputTargetCapturing
    private let textProcessor: any VoiceTextProcessing
    private let delivery: any TextDelivering
    private let clipboard: any ClipboardWriting
    private let history: any SessionHistoryRecording

    private var phase: Phase = .idle
    private var releasePending = false
    private var pendingReleaseCaptureHint: InputTargetCaptureHint?
    private var transcriptionTask: Task<VoiceTextProcessingResult, Error>?
    private var streamingCompletionTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var captureFailureTask: Task<Void, Never>?
    private var deliveryCommitGate: DeliveryCommitGate?
    private var deliveryTask: Task<DeliveryOutcome, Never>?
    private var deliveryResolution: DeliveryResolution?
    private var suppressedTerminalPresentationSessionID: VoiceInputSessionID?
    private var finishingTask: Task<Void, Never>?
    private var historyWriteTasks: [VoiceInputSessionID: Task<Void, Never>] = [:]
    private var historyWriteTokens: [VoiceInputSessionID: UUID] = [:]
    private var isShutDown = false
    private var preparingStartedAt: Date?
    private var activeSnapshot: VoiceTextProcessingSnapshot?
    private var confirmedDoubaoResult: TranscriptionResult?
    private var historyTextPolicy = HistoryTextPolicy.unclassified
    private var activeTriggerSequence: UInt64?
    private var auditSessionID: VoiceInputSessionID?
    private var auditStageName: String?
    private var auditStageStartedAt: ContinuousClock.Instant?
    private var auditStageDurations: [String: Int] = [:]
    private var auditApplicationName: String?
    private var presentation = VoiceInputPresentation(revision: 0, activity: .idle)
    private var observers: [UUID: AsyncStream<VoiceInputPresentation>.Continuation] = [:]
    private var triggerTerminationObservers: [
        UUID: AsyncStream<UInt64>.Continuation
    ] = [:]

    public init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        transcriber: any SpeechTranscribing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        textProcessor = BasicVoiceTextProcessor(transcriber: transcriber)
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
    }

    public init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        textProcessor: any VoiceTextProcessing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        self.textProcessor = textProcessor
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
    }

    public func observe() -> AsyncStream<VoiceInputPresentation> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<VoiceInputPresentation>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[id] = continuation
        continuation.yield(presentation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeObserver(id)
            }
        }
        return stream
    }

    /// Emits the dispatcher sequence owned by a session when that session
    /// reaches a terminal state without requiring another physical key edge.
    /// Consumers must compare the sequence before resetting gesture state so a
    /// delayed terminal event cannot affect a newer session.
    package func observeTriggerTerminations() -> AsyncStream<UInt64> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        triggerTerminationObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTriggerTerminationObserver(id) }
        }
        return stream
    }

    package func isActive(triggerSequence: UInt64) -> Bool {
        activeTriggerSequence == triggerSequence
    }

    package func send(_ command: VoiceInputCommand) async {
        await send(command, triggerSequence: nil)
    }

    package func send(
        _ command: VoiceInputCommand,
        triggerSequence: UInt64
    ) async {
        await send(command, triggerSequence: Optional(triggerSequence))
    }

    package func releaseFromDispatcher(
        captureHint: InputTargetCaptureHint?
    ) {
        if case .preparing = phase {
            releasePending = true
            pendingReleaseCaptureHint = captureHint
        } else {
            beginFinishingSession(captureHint: captureHint)
        }
    }

    public func cancel(triggeredAtSequence sequence: UInt64) async {
        guard let activeTriggerSequence,
              activeTriggerSequence <= sequence
        else { return }
        await cancelSession()
    }

    package func cancel(expectedSessionID: VoiceInputSessionID) async {
        guard currentActiveSessionID == expectedSessionID else { return }
        await cancelSession()
    }

    package func copyPendingResult(expectedSessionID: VoiceInputSessionID) async {
        guard case let .pendingCopy(id, text, _) = presentation.activity,
              id == expectedSessionID
        else { return }
        let copied = await clipboard.copy(text)
        guard phase == .idle,
              case let .pendingCopy(currentID, _, _) = presentation.activity,
              currentID == expectedSessionID
        else { return }
        if copied {
            publish(.idle, notice: .copied)
        } else {
            publish(
                .pendingCopy(
                    expectedSessionID,
                    text: text,
                    reason: .clipboardFailed
                )
            )
        }
    }

    package func dismissResult(expectedSessionID: VoiceInputSessionID) {
        guard phase == .idle,
              presentation.activity.sessionID == expectedSessionID
        else { return }
        publish(.idle)
    }

    /// Stops active work and waits until every queued history mutation has
    /// reached durable storage. App termination must use this instead of only
    /// sending `.cancel`, otherwise the final cancellation record can be lost.
    public func shutdown() async {
        isShutDown = true
        await cancelSession()
        await finishingTask?.value
        let pending = Array(historyWriteTasks.values)
        for task in pending {
            await task.value
        }
        // Completed tasks are safe to discard. No new session can begin
        // through a dispatcher after its consumer has been stopped.
        historyWriteTasks.removeAll()
        historyWriteTokens.removeAll()
    }

    private func send(
        _ command: VoiceInputCommand,
        triggerSequence: UInt64?
    ) async {
        switch command {
        case .pressed:
            await beginSession(triggerSequence: triggerSequence)
        case .released:
            if case .preparing = phase {
                releasePending = true
                pendingReleaseCaptureHint = nil
            } else {
                beginFinishingSession(captureHint: nil)
                await finishingTask?.value
            }
        case .cancel:
            await cancelSession()
        case .copyPendingResult:
            guard case let .pendingCopy(id, text, _) = presentation.activity else { return }
            let copied = await clipboard.copy(text)
            guard phase == .idle,
                  case let .pendingCopy(currentID, _, _) = presentation.activity,
                  currentID == id
            else { return }
            if copied {
                publish(.idle, notice: .copied)
            } else {
                publish(
                    .pendingCopy(
                        id,
                        text: text,
                        reason: .clipboardFailed
                    )
                )
            }
        case .dismissResult:
            guard phase == .idle else { return }
            publish(.idle)
        }
    }

    private var currentActiveSessionID: VoiceInputSessionID? {
        switch phase {
        case .idle:
            nil
        case let .preparing(id),
             let .recording(id, _, _),
             let .processing(id, _, _),
             let .finalizing(id):
            id
        }
    }

    private func beginSession(triggerSequence: UInt64?) async {
        guard !isShutDown, phase == .idle else {
            if let triggerSequence {
                finishRejectedTriggerSequence(triggerSequence)
            }
            return
        }
        // A press while retained text is awaiting copy deliberately abandons
        // that text: the user chose to re-record, and the notice must never
        // block the next session. The retained body may exist nowhere else
        // (unclassified targets keep it out of history), so this is an
        // explicit, user-initiated discard.
        let id = VoiceInputSessionID()
        let requestedAt = Date()
        releasePending = false
        pendingReleaseCaptureHint = nil
        phase = .preparing(id)
        activeTriggerSequence = triggerSequence
        preparingStartedAt = requestedAt
        confirmedDoubaoResult = nil
        historyTextPolicy = .unclassified
        suppressedTerminalPresentationSessionID = nil
        beginAudit(id: id, stage: "preparing")
        publish(.preparing(id))
        saveStage(.preparing(id), id: id, startedAt: requestedAt)
        let snapshot = await textProcessor.captureSnapshot()
        guard phase == .preparing(id) else { return }
        activeSnapshot = snapshot

        let liveStream: AsyncStream<Data>?
        let streamingProcessor: (any StreamingVoiceTextProcessing)?
        if let chunkSource = audioCapture as? any AudioChunkStreaming,
           let processor = textProcessor as? any StreamingVoiceTextProcessing {
            liveStream = await chunkSource.audioChunks()
            streamingProcessor = processor
        } else {
            liveStream = nil
            streamingProcessor = nil
        }

        do {
            try await audioCapture.start()
            guard phase == .preparing(id) else {
                await audioCapture.cancel()
                return
            }
            let startedAt = requestedAt
            phase = .recording(id, startedAt: startedAt, snapshot: snapshot)
            advanceAudit(id: id, stage: "recording")
            publish(.recording(id))
            if let liveStream, let streamingProcessor {
                let sessions = self
                transcriptionTask = Task {
                    try await streamingProcessor.processStreaming(
                        liveStream,
                        snapshot: snapshot
                    ) { progress in
                        await sessions.receivedProcessingProgress(
                            progress,
                            id: id,
                            startedAt: startedAt,
                            snapshot: snapshot,
                            applicationName: nil
                        )
                    }
                }
                if let transcriptionTask {
                    observeStreamingCompletion(
                        transcriptionTask,
                        id: id,
                        startedAt: startedAt,
                        snapshot: snapshot
                    )
                }
            }
            observeRecordingTelemetry(for: id)
            observeCaptureFailures(
                for: id,
                startedAt: startedAt,
                snapshot: snapshot
            )
            saveStage(.recording(id), id: id, startedAt: startedAt, snapshot: snapshot)
            if releasePending {
                releasePending = false
                let captureHint = pendingReleaseCaptureHint
                pendingReleaseCaptureHint = nil
                beginFinishingSession(captureHint: captureHint)
                await finishingTask?.value
            }
        } catch {
            guard phase == .preparing(id) else {
                await audioCapture.cancel()
                return
            }
            phase = .finalizing(id)
            finishActiveTriggerSequence()
            preparingStartedAt = nil
            activeSnapshot = nil
            confirmedDoubaoResult = nil
            historyTextPolicy = .unclassified
            let problem = (error as? AudioCaptureError)
                .map(VoiceInputProblem.init(audioCaptureError:))
                ?? VoiceInputProblem(failure: .recordingFailed)
            let activity = VoiceInputActivity.failed(id, problem.failure)
            let audit = finishAudit(id: id)
            let elapsed = max(0, Int(Date().timeIntervalSince(requestedAt) * 1_000))
            let record = VoiceInputHistoryRecord(
                sessionID: id,
                startedAt: requestedAt,
                applicationName: nil,
                transcription: nil,
                finalText: nil,
                refinementModeName: snapshot.refinementMode.displayName,
                refinementPrompt: snapshot.refinementMode.deepSeekRule,
                dictionarySnapshotID: snapshot.dictionary.id,
                dictionarySnapshotEntries: snapshot.dictionary.entries.map(
                    RecordedDictionaryEntry.init
                ),
                dictionaryRequestContext: snapshot.dictionaryContext,
                durationMilliseconds: elapsed,
                stageDurationsMilliseconds: audit.stageDurations,
                outcome: activity
            )
            phase = .idle
            publish(activity)
            _ = queueHistory(
                record,
                terminalPresentation: .init(activity: activity, notice: nil)
            )
        }
    }

    private func beginFinishingSession(
        captureHint: InputTargetCaptureHint?
    ) {
        guard case let .recording(id, startedAt, snapshot) = phase else { return }
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()
        captureFailureTask = nil
        phase = .processing(id, startedAt: startedAt, snapshot: snapshot)
        advanceAudit(id: id, stage: "targetCapture")
        publish(.processing(id, .capturingTarget, applicationName: nil))
        saveStage(
            .processing(id, .capturingTarget, applicationName: nil),
            id: id,
            startedAt: startedAt,
            snapshot: snapshot
        )
        let targetCapture = targetCapture
        let audioCapture = audioCapture
        let targetTask = Task {
            await Self.captureWithTiming(
                targetCapture,
                matching: captureHint
            )
        }
        let audioTask = Task<CapturedAudio, Error> {
            try await audioCapture.stop()
        }
        finishingTask = Task { [weak self] in
            await self?.finishSession(
                id: id,
                startedAt: startedAt,
                snapshot: snapshot,
                targetTask: targetTask,
                audioTask: audioTask
            )
        }
    }

    private func finishSession(
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        targetTask: Task<(InputTargetCaptureResult, Int), Never>,
        audioTask: Task<CapturedAudio, Error>
    ) async {
        let (target, targetCaptureMilliseconds) = await targetTask.value
        historyTextPolicy = switch target {
        case .unavailable(.secureTarget): .redacted
        case .writable: .allowed
        case .unavailable: .unclassified
        }
        var sessionStageDurations = ["targetCapture": targetCaptureMilliseconds]
        let audio: CapturedAudio
        do {
            audio = try await audioTask.value
        } catch {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            streamingCompletionTask?.cancel()
            streamingCompletionTask = nil
            await discard(target)
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
                return
            }
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: (error as? AudioCaptureError)
                    .map(VoiceInputProblem.init(audioCaptureError:))
                    ?? VoiceInputProblem(failure: .recordingFailed),
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
            return
        }
        sessionStageDurations["recording"] = Self.milliseconds(audio.duration)

        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
            await discard(target)
            return
        }
        let applicationName = target.applicationName
        advanceAudit(id: id, stage: "doubao", applicationName: applicationName)
        publish(.processing(id, .transcribing, applicationName: applicationName))
        saveStage(
            .processing(id, .transcribing, applicationName: applicationName),
            id: id,
            startedAt: startedAt,
            applicationName: applicationName,
            snapshot: snapshot
        )

        let task: Task<VoiceTextProcessingResult, Error>
        if let liveTask = transcriptionTask {
            task = liveTask
        } else {
            let activeProcessor = textProcessor
            task = Task {
                try await activeProcessor.process(
                    audio,
                    snapshot: snapshot
                ) { [weak self] progress in
                    await self?.receivedProcessingProgress(
                        progress,
                        id: id,
                        startedAt: startedAt,
                        snapshot: snapshot,
                        applicationName: applicationName
                    )
                }
            }
            transcriptionTask = task
        }
        let processedText: VoiceTextProcessingResult
        do {
            processedText = try await task.value
        } catch let failure as VoiceTextProcessingFailure {
            transcriptionTask = nil
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
                await discard(target)
                return
            }
            await discard(target)
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: failure.problem,
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
            return
        } catch {
            transcriptionTask = nil
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
                await discard(target)
                return
            }
            await discard(target)
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: VoiceInputProblem(failure: .transcriptionFailed),
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
            return
        }
        transcriptionTask = nil
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil

        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
            await discard(target)
            return
        }

        switch target {
        case let .writable(targetSnapshot):
            advanceAudit(
                id: id,
                stage: "delivery",
                applicationName: targetSnapshot.applicationName
            )
            publish(.processing(id, .delivering, applicationName: targetSnapshot.applicationName))
            saveStage(
                .processing(id, .delivering, applicationName: targetSnapshot.applicationName),
                id: id,
                startedAt: startedAt,
                applicationName: targetSnapshot.applicationName,
                snapshot: snapshot
            )
            let commitGate = DeliveryCommitGate()
            deliveryCommitGate = commitGate
            let deliveryStarted = ContinuousClock.now
            let resolution = DeliveryResolution()
            deliveryResolution = resolution
            let delivery = delivery
            let finalText = processedText.finalText
            let deliveryTask = Task {
                let outcome = await delivery.deliver(
                    finalText,
                    to: targetSnapshot,
                    commitGate: commitGate
                )
                await resolution.resolve(outcome)
                return outcome
            }
            self.deliveryTask = deliveryTask
            let outcome = await resolution.wait()
            self.deliveryTask = nil
            deliveryResolution = nil
            deliveryCommitGate = nil
            sessionStageDurations["delivery"] = Self.milliseconds(
                deliveryStarted.duration(to: .now)
            )
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }
            switch outcome {
            case .delivered:
                let activity = VoiceInputActivity.delivered(
                    id,
                    applicationName: targetSnapshot.applicationName,
                    text: processedText.finalText
                )
                await finishTerminal(
                    activity,
                    id: id,
                    startedAt: startedAt,
                    applicationName: targetSnapshot.applicationName,
                    transcription: processedText.doubaoText,
                    finalText: processedText.finalText,
                    providerRequestID: processedText.doubaoRequestID,
                    processedText: processedText,
                    processingSnapshot: snapshot,
                    additionalStageDurations: sessionStageDurations
                )
            case let .pendingCopy(reason),
                 let .pendingCopyDiagnosed(reason, _):
                let activity = VoiceInputActivity.pendingCopy(
                    id,
                    text: processedText.finalText,
                    reason: reason
                )
                if reason == .secureTarget {
                    historyTextPolicy = .redacted
                    await finishTerminal(
                        activity,
                        id: id,
                        startedAt: startedAt,
                        applicationName: targetSnapshot.applicationName,
                        transcription: nil,
                        finalText: nil,
                        transcriptionProvider: "doubao",
                        providerRequestID: processedText.doubaoRequestID,
                        deliveryDiagnosticCode: outcome
                            .deliveryDiagnostic?.code,
                        processingSnapshot: snapshot,
                        additionalStageDurations: sessionStageDurations,
                        historyOutcome: .pendingCopy(
                            id,
                            text: "",
                            reason: .secureTarget
                        )
                    )
                    return
                }
                await finishTerminal(
                    activity,
                    id: id,
                    startedAt: startedAt,
                    applicationName: targetSnapshot.applicationName,
                    transcription: processedText.doubaoText,
                    finalText: processedText.finalText,
                    providerRequestID: processedText.doubaoRequestID,
                    deliveryDiagnosticCode: outcome
                        .deliveryDiagnostic?.code,
                    processedText: processedText,
                    processingSnapshot: snapshot,
                    additionalStageDurations: sessionStageDurations
                )
            }
        case let .unavailable(reason):
            let activity = VoiceInputActivity.pendingCopy(
                id,
                text: processedText.finalText,
                reason: reason
            )
            if reason == .secureTarget {
                historyTextPolicy = .redacted
                await finishTerminal(
                    activity,
                    id: id,
                    startedAt: startedAt,
                    applicationName: nil,
                    transcription: nil,
                    finalText: nil,
                    transcriptionProvider: "doubao",
                    providerRequestID: processedText.doubaoRequestID,
                    processingSnapshot: snapshot,
                    additionalStageDurations: sessionStageDurations,
                    historyOutcome: .pendingCopy(id, text: "", reason: .secureTarget)
                )
                return
            }
            await finishTerminal(
                activity,
                id: id,
                startedAt: startedAt,
                applicationName: nil,
                transcription: processedText.doubaoText,
                finalText: processedText.finalText,
                providerRequestID: processedText.doubaoRequestID,
                processedText: processedText,
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
        }
    }

    private func cancelSession() async {
        if let deliveryCommitGate {
            // Once the delivery adapter has crossed its mutation boundary,
            // the target App may already contain the text. Hide the active UI
            // immediately, stop consuming Esc, and let the bounded receipt
            // task finish history in the background without resurfacing a
            // late result card or falsely rewriting the mutation as cancelled.
            guard await deliveryCommitGate.cancel() else {
                guard let id = currentActiveSessionID,
                      suppressedTerminalPresentationSessionID != id
                else { return }
                suppressedTerminalPresentationSessionID = id
                finishActiveTriggerSequence()
                publish(.cancelled(id))
                return
            }
        }
        let id: VoiceInputSessionID
        let startedAt: Date
        let processingSnapshot: VoiceTextProcessingSnapshot?
        let confirmedDoubaoResult = historyTextPolicy == .allowed
            ? confirmedDoubaoResult
            : nil
        switch phase {
        case let .preparing(sessionID):
            id = sessionID
            startedAt = preparingStartedAt ?? Date()
            processingSnapshot = activeSnapshot
        case let .recording(sessionID, sessionStartedAt, snapshot),
             let .processing(sessionID, sessionStartedAt, snapshot):
            id = sessionID
            startedAt = sessionStartedAt
            processingSnapshot = snapshot
        case .idle, .finalizing:
            return
        }

        let cancelledAtStage = auditStageName
        let audit = finishAudit(id: id)
        phase = .finalizing(id)
        finishActiveTriggerSequence()
        preparingStartedAt = nil
        activeSnapshot = nil
        self.confirmedDoubaoResult = nil
        historyTextPolicy = .unclassified
        releasePending = false
        pendingReleaseCaptureHint = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        if let deliveryResolution {
            await deliveryResolution.resolve(.pendingCopy(.deliveryFailed))
        }
        deliveryResolution = nil
        deliveryCommitGate = nil
        suppressedTerminalPresentationSessionID = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()
        captureFailureTask = nil
        let activity = VoiceInputActivity.cancelled(id)
        // Cancellation is committed before cleanup or history I/O. The overlay
        // disappears immediately and late results are fenced by `.finalizing`.
        publish(activity)
        await audioCapture.cancel()
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        _ = queueHistory(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: audit.applicationName,
            transcription: confirmedDoubaoResult?.text,
            finalText: nil,
            transcriptionProvider: confirmedDoubaoResult == nil ? nil : "doubao",
            providerRequestID: confirmedDoubaoResult?.providerRequestID,
            refinementModeName: processingSnapshot?.refinementMode.displayName,
            refinementPrompt: processingSnapshot?.refinementMode.deepSeekRule,
            cancelledAtStage: cancelledAtStage,
            dictionarySnapshotID: processingSnapshot?.dictionary.id,
            dictionarySnapshotEntries: processingSnapshot?.dictionary.entries
                .map(RecordedDictionaryEntry.init) ?? [],
            dictionaryRequestContext: processingSnapshot?.dictionaryContext,
            durationMilliseconds: elapsed,
            stageDurationsMilliseconds: audit.stageDurations.isEmpty
                ? ["beforeCancellation": elapsed]
                : audit.stageDurations,
            outcome: activity
        ))
        phase = .idle
    }

    private func finishWithFailure(
        id: VoiceInputSessionID,
        startedAt: Date,
        problem: VoiceInputProblem,
        processingSnapshot: VoiceTextProcessingSnapshot? = nil,
        additionalStageDurations: [String: Int] = [:]
    ) async {
        let activity = VoiceInputActivity.failed(id, problem.failure)
        await finishTerminal(
            activity,
            id: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: nil,
            finalText: nil,
            problem: problem,
            processingSnapshot: processingSnapshot,
            additionalStageDurations: additionalStageDurations
        )
    }

    private func finishTerminal(
        _ activity: VoiceInputActivity,
        id: VoiceInputSessionID,
        startedAt: Date,
        applicationName: String?,
        transcription: String?,
        finalText: String?,
        transcriptionProvider: String? = nil,
        providerRequestID: String? = nil,
        providerErrorCode: String? = nil,
        deliveryDiagnosticCode: String? = nil,
        problem: VoiceInputProblem? = nil,
        processedText: VoiceTextProcessingResult? = nil,
        processingSnapshot: VoiceTextProcessingSnapshot? = nil,
        additionalStageDurations: [String: Int] = [:],
        historyOutcome: VoiceInputActivity? = nil
    ) async {
        let audit = finishAudit(id: id)
        let terminalHistoryTextPolicy = historyTextPolicy
        let suppressTerminalPresentation =
            suppressedTerminalPresentationSessionID == id
        phase = .finalizing(id)
        finishActiveTriggerSequence()
        preparingStartedAt = nil
        activeSnapshot = nil
        confirmedDoubaoResult = nil
        historyTextPolicy = .unclassified
        releasePending = false
        pendingReleaseCaptureHint = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()
        captureFailureTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        deliveryResolution = nil
        deliveryCommitGate = nil
        suppressedTerminalPresentationSessionID = nil
        let processingNotice: VoiceInputNotice? = if processedText?.refinementStatus
            == .fellBack
        {
            .refinementFellBack(processedText?.refinementFailure?.kind)
        } else {
            nil
        }
        let measuredStageDurations = (processedText?.stageDurationsMilliseconds ?? [:])
            .merging(additionalStageDurations) { _, latest in latest }
        let stageDurations = audit.stageDurations
            .merging(measuredStageDurations) { _, measured in measured }
        let providerDiagnostic = problem?.diagnostic
        let refinementDiagnostic = processedText?.refinementFailure?.providerDiagnostic
        let mayPersistBody = terminalHistoryTextPolicy == .allowed
        let mayPersistProviderRequestID = terminalHistoryTextPolicy != .redacted
        let persistedOutcome = Self.historyOutcome(
            historyOutcome ?? activity,
            mayPersistBody: mayPersistBody
        )
        let record = VoiceInputHistoryRecord(
            sessionID: id,
            startedAt: startedAt,
            applicationName: applicationName ?? audit.applicationName,
            transcription: mayPersistBody ? transcription : nil,
            finalText: mayPersistBody ? finalText : nil,
            transcriptionProvider: providerDiagnostic?.provider
                ?? transcriptionProvider
                ?? (processedText == nil ? nil : "doubao"),
            providerRequestID: mayPersistProviderRequestID
                ? (providerDiagnostic?.requestID ?? providerRequestID)
                : nil,
            providerErrorCode: providerDiagnostic?.code ?? providerErrorCode,
            providerOperation: providerDiagnostic?.operation.rawValue,
            providerStatusCode: providerDiagnostic?.statusCode,
            // Provider messages are untrusted response text and can echo
            // credentials or user context. Keep structured codes only.
            providerMessage: nil,
            deliveryDiagnosticCode: deliveryDiagnosticCode,
            deepSeekText: mayPersistBody ? processedText?.deepSeekText : nil,
            deepSeekRequestID: mayPersistProviderRequestID
                ? processedText?.deepSeekRequestID
                : nil,
            refinementModeName: processingSnapshot?.refinementMode.displayName,
            refinementPrompt: processingSnapshot?.refinementMode.deepSeekRule,
            refinementStatus: processedText?.refinementStatus.rawValue,
            refinementFailureCode: processedText?.refinementFailure?.kind.rawValue,
            refinementFailureStatusCode: refinementDiagnostic?.statusCode,
            refinementFailureMessage: nil,
            dictionarySnapshotID: processingSnapshot?.dictionary.id,
            dictionarySnapshotEntries: processingSnapshot?.dictionary.entries
                .map(RecordedDictionaryEntry.init) ?? [],
            dictionaryRequestContext: processingSnapshot?.dictionaryContext,
            dictionaryReplacements: [],
            durationMilliseconds: max(
                0,
                Int(Date().timeIntervalSince(startedAt) * 1_000)
            ),
            stageDurationsMilliseconds: stageDurations,
            outcome: persistedOutcome
        )
        phase = .idle
        if !suppressTerminalPresentation {
            publish(activity, notice: processingNotice)
        }
        _ = queueHistory(
            record,
            terminalPresentation: suppressTerminalPresentation
                ? nil
                : .init(
                    activity: activity,
                    notice: processingNotice
                )
        )
    }

    private static func historyOutcome(
        _ activity: VoiceInputActivity,
        mayPersistBody: Bool
    ) -> VoiceInputActivity {
        guard !mayPersistBody,
              case let .pendingCopy(id, _, reason) = activity
        else { return activity }
        return .pendingCopy(id, text: "", reason: reason)
    }

    private func publish(
        _ activity: VoiceInputActivity,
        telemetry: RecordingTelemetry? = nil,
        notice: VoiceInputNotice? = nil
    ) {
        presentation = VoiceInputPresentation(
            revision: presentation.revision &+ 1,
            activity: activity,
            recordingTelemetry: telemetry,
            notice: notice
        )
        for continuation in observers.values {
            continuation.yield(presentation)
        }
    }

    private func observeRecordingTelemetry(for id: VoiceInputSessionID) {
        telemetryTask?.cancel()
        guard let source = audioCapture as? any AudioCaptureTelemetryProviding else { return }
        telemetryTask = Task { [weak self] in
            let stream = await source.observeTelemetry()
            for await telemetry in stream {
                guard !Task.isCancelled else { return }
                await self?.receivedTelemetry(telemetry, for: id)
            }
        }
    }

    private func observeStreamingCompletion(
        _ task: Task<VoiceTextProcessingResult, Error>,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) {
        streamingCompletionTask?.cancel()
        streamingCompletionTask = Task { [weak self] in
            let result = await task.result
            guard case let .failure(error) = result else { return }
            await self?.receivedStreamingFailureWhileRecording(
                error,
                id: id,
                startedAt: startedAt,
                snapshot: snapshot
            )
        }
    }

    private func observeCaptureFailures(
        for id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) {
        captureFailureTask?.cancel()
        guard let source = audioCapture as? any AudioCaptureFailureProviding else { return }
        captureFailureTask = Task { [weak self] in
            let stream = await source.observeFailures()
            for await failure in stream {
                guard !Task.isCancelled else { return }
                await self?.receivedCaptureFailureWhileRecording(
                    failure,
                    id: id,
                    startedAt: startedAt,
                    snapshot: snapshot
                )
                return
            }
        }
    }

    private func receivedCaptureFailureWhileRecording(
        _ failure: AudioCaptureError,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) async {
        await failActiveRecording(
            id: id,
            startedAt: startedAt,
            snapshot: snapshot,
            problem: VoiceInputProblem(audioCaptureError: failure)
        )
    }

    private func receivedStreamingFailureWhileRecording(
        _ error: Error,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) async {
        let problem = (error as? VoiceTextProcessingFailure)?.problem
            ?? VoiceInputProblem(failure: .transcriptionFailed)
        await failActiveRecording(
            id: id,
            startedAt: startedAt,
            snapshot: snapshot,
            problem: problem
        )
    }

    private func failActiveRecording(
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        problem: VoiceInputProblem
    ) async {
        guard case .recording(id, startedAt: startedAt, snapshot: snapshot) = phase else {
            return
        }
        let audit = finishAudit(id: id)
        phase = .finalizing(id)
        finishActiveTriggerSequence()
        preparingStartedAt = nil
        activeSnapshot = nil
        confirmedDoubaoResult = nil
        historyTextPolicy = .unclassified
        releasePending = false
        pendingReleaseCaptureHint = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        streamingCompletionTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()
        captureFailureTask = nil

        let activity = VoiceInputActivity.failed(id, problem.failure)
        // The provider has already returned a definite failure. Surface that
        // fact before recorder cleanup or history I/O, then fence late events.
        publish(activity)
        await audioCapture.cancel()

        let diagnostic = problem.diagnostic
        _ = queueHistory(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: audit.applicationName,
            transcription: nil,
            finalText: nil,
            transcriptionProvider: diagnostic?.provider ?? "doubao",
            providerRequestID: diagnostic?.requestID,
            providerErrorCode: diagnostic?.code,
            providerOperation: diagnostic?.operation.rawValue,
            providerStatusCode: diagnostic?.statusCode,
            providerMessage: nil,
            refinementModeName: snapshot.refinementMode.displayName,
            refinementPrompt: snapshot.refinementMode.deepSeekRule,
            dictionarySnapshotID: snapshot.dictionary.id,
            dictionarySnapshotEntries: snapshot.dictionary.entries.map(
                RecordedDictionaryEntry.init
            ),
            dictionaryRequestContext: snapshot.dictionaryContext,
            durationMilliseconds: max(
                0,
                Int(Date().timeIntervalSince(startedAt) * 1_000)
            ),
            stageDurationsMilliseconds: audit.stageDurations,
            outcome: activity
        ))
        phase = .idle
    }

    private func receivedTelemetry(
        _ telemetry: RecordingTelemetry,
        for id: VoiceInputSessionID
    ) {
        guard case let .recording(activeID, _, _) = phase, activeID == id else { return }
        publish(.recording(id), telemetry: telemetry)
    }

    private func receivedProcessingProgress(
        _ progress: VoiceTextProcessingProgress,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        applicationName: String?
    ) async {
        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }
        let stage = progress.stage
        if let confirmed = progress.confirmedDoubaoResult {
            confirmedDoubaoResult = confirmed
        }
        let auditStage = switch stage {
        case .capturingTarget: "targetCapture"
        case .transcribing: "doubao"
        case .refining: "deepseek"
        case .delivering: "delivery"
        }
        advanceAudit(
            id: id,
            stage: auditStage,
            applicationName: applicationName
        )
        let activity = VoiceInputActivity.processing(
            id,
            stage,
            applicationName: applicationName
        )
        publish(activity)
        saveStage(
            activity,
            id: id,
            startedAt: startedAt,
            applicationName: applicationName,
            snapshot: snapshot
        )
    }

    private func saveStage(
        _ activity: VoiceInputActivity,
        id: VoiceInputSessionID,
        startedAt: Date,
        applicationName: String? = nil,
        snapshot: VoiceTextProcessingSnapshot? = nil
    ) {
        _ = queueHistory(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: applicationName,
            // Provider text is terminal data. Persisting it during processing
            // creates a crash window where a secure target can leave sensitive
            // text in SQLite/WAL before the target classification is applied.
            transcription: nil,
            finalText: nil,
            transcriptionProvider: nil,
            providerRequestID: nil,
            refinementModeName: snapshot?.refinementMode.displayName,
            refinementPrompt: snapshot?.refinementMode.deepSeekRule,
            dictionarySnapshotID: snapshot?.dictionary.id,
            dictionarySnapshotEntries: snapshot?.dictionary.entries
                .map(RecordedDictionaryEntry.init) ?? [],
            dictionaryRequestContext: snapshot?.dictionaryContext,
            outcome: activity
        ))
    }

    @discardableResult
    private func queueHistory(
        _ record: VoiceInputHistoryRecord,
        terminalPresentation: TerminalHistoryPresentation? = nil
    ) -> Task<Void, Never> {
        let previous = historyWriteTasks[record.sessionID]
        let history = history
        let token = UUID()
        historyWriteTokens[record.sessionID] = token
        let task = Task { [weak self] in
            await previous?.value
            await history.save(record)
            let persistenceNotice = terminalPresentation == nil
                ? nil
                : await history.persistenceFailureNotice()
            await self?.historyWriteDidComplete(
                sessionID: record.sessionID,
                token: token,
                terminalPresentation: terminalPresentation,
                persistenceNotice: persistenceNotice
            )
        }
        historyWriteTasks[record.sessionID] = task
        return task
    }

    private func historyWriteDidComplete(
        sessionID: VoiceInputSessionID,
        token: UUID,
        terminalPresentation: TerminalHistoryPresentation?,
        persistenceNotice: String?
    ) {
        guard historyWriteTokens[sessionID] == token else { return }
        historyWriteTasks[sessionID] = nil
        historyWriteTokens[sessionID] = nil
        guard let terminalPresentation,
              let persistenceNotice,
              presentation.activity == terminalPresentation.activity
        else { return }
        publish(
            terminalPresentation.activity,
            notice: .persistenceFailure(persistenceNotice)
        )
    }

    private func discard(_ captureResult: InputTargetCaptureResult) async {
        guard case let .writable(target) = captureResult,
              let discarding = targetCapture as? any InputTargetDiscarding
        else { return }
        await discarding.discard(target)
    }

    private static func captureWithTiming(
        _ capture: any InputTargetCapturing,
        matching hint: InputTargetCaptureHint?
    ) async -> (InputTargetCaptureResult, Int) {
        let started = ContinuousClock.now
        let result = if let hint {
            await capture.capture(matching: hint)
        } else {
            await capture.capture()
        }
        return (result, milliseconds(started.duration(to: .now)))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(clamping:
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }

    private func beginAudit(id: VoiceInputSessionID, stage: String) {
        auditSessionID = id
        auditStageName = stage
        auditStageStartedAt = .now
        auditStageDurations = [:]
        auditApplicationName = nil
    }

    private func advanceAudit(
        id: VoiceInputSessionID,
        stage: String,
        applicationName: String? = nil
    ) {
        guard auditSessionID == id else { return }
        accumulateCurrentAuditStage()
        auditStageName = stage
        auditStageStartedAt = .now
        if let applicationName {
            auditApplicationName = applicationName
        }
    }

    private func finishAudit(
        id: VoiceInputSessionID
    ) -> (applicationName: String?, stageDurations: [String: Int]) {
        guard auditSessionID == id else { return (nil, [:]) }
        accumulateCurrentAuditStage()
        let result = (auditApplicationName, auditStageDurations)
        auditSessionID = nil
        auditStageName = nil
        auditStageStartedAt = nil
        auditStageDurations = [:]
        auditApplicationName = nil
        return result
    }

    private func accumulateCurrentAuditStage() {
        guard let stage = auditStageName,
              let startedAt = auditStageStartedAt
        else { return }
        auditStageDurations[stage, default: 0] += Self.milliseconds(
            startedAt.duration(to: .now)
        )
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func removeTriggerTerminationObserver(_ id: UUID) {
        triggerTerminationObservers[id] = nil
    }

    private func finishActiveTriggerSequence() {
        guard let sequence = activeTriggerSequence else { return }
        activeTriggerSequence = nil
        for continuation in triggerTerminationObservers.values {
            continuation.yield(sequence)
        }
    }

    private func finishRejectedTriggerSequence(_ sequence: UInt64) {
        for continuation in triggerTerminationObservers.values {
            continuation.yield(sequence)
        }
    }

}

private extension InputTargetCaptureResult {
    var applicationName: String? {
        if case let .writable(snapshot) = self {
            snapshot.applicationName
        } else {
            nil
        }
    }
}
