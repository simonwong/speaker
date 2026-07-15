import Foundation

public struct VoiceInputSessionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum VoiceInputCommand: Sendable {
    case pressed
    case released
    case cancel
    case copyPendingResult
    case dismissResult
}

public enum VoiceInputProcessingStage: Equatable, Sendable {
    case capturingTarget
    case transcribing
    case refining
    case delivering
}

public enum PendingCopyReason: String, Equatable, Sendable {
    case missingTarget
    case secureTarget
    case unsupportedTarget
    case invalidatedTarget
    case changedTarget
    case deliveryFailed
}

public enum VoiceInputFailure: String, Equatable, Sendable {
    case recordingFailed
    case transcriptionFailed
    case providerNotConfigured
    case providerCredentialUnavailable
    case noSpeechDetected
    case providerResourceUnavailable
    case providerRateLimited
    case providerUnavailable
    case networkUnavailable
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
}

public struct VoiceInputPresentation: Equatable, Sendable {
    public let revision: UInt64
    public let activity: VoiceInputActivity
    public let recordingTelemetry: RecordingTelemetry?
    public let notice: String?

    public init(
        revision: UInt64,
        activity: VoiceInputActivity,
        recordingTelemetry: RecordingTelemetry? = nil,
        notice: String? = nil
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

public enum DeliveryOutcome: Equatable, Sendable {
    case delivered
    case pendingCopy(PendingCopyReason)
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

public struct VoiceInputHistoryRecord: Equatable, Sendable {
    public let sessionID: VoiceInputSessionID
    public let startedAt: Date
    public let applicationName: String?
    public let transcription: String?
    public let finalText: String?
    public let transcriptionProvider: String?
    public let providerRequestID: String?
    public let providerErrorCode: String?
    public let deepSeekText: String?
    public let deepSeekRequestID: String?
    public let refinementModeName: String?
    public let refinementPrompt: String?
    public let refinementStatus: String?
    public let refinementFailureCode: String?
    public let dictionarySnapshotID: UUID?
    public let dictionarySnapshotEntries: [DictionaryEntry]
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
        deepSeekText: String? = nil,
        deepSeekRequestID: String? = nil,
        refinementModeName: String? = nil,
        refinementPrompt: String? = nil,
        refinementStatus: String? = nil,
        refinementFailureCode: String? = nil,
        dictionarySnapshotID: UUID? = nil,
        dictionarySnapshotEntries: [DictionaryEntry] = [],
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
        self.deepSeekText = deepSeekText
        self.deepSeekRequestID = deepSeekRequestID
        self.refinementModeName = refinementModeName
        self.refinementPrompt = refinementPrompt
        self.refinementStatus = refinementStatus
        self.refinementFailureCode = refinementFailureCode
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

public protocol AudioCaptureTelemetryProviding: Sendable {
    func observeTelemetry() async -> AsyncStream<RecordingTelemetry>
}

public protocol InputTargetCapturing: Sendable {
    func capture() async -> InputTargetCaptureResult
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
    func copy(_ text: String) async
}

public protocol SessionHistoryRecording: Sendable {
    func save(_ record: VoiceInputHistoryRecord) async
    func persistenceFailureNotice() async -> String?
}

public extension SessionHistoryRecording {
    func persistenceFailureNotice() async -> String? { nil }
}

public protocol RecordingWatchdog: Sendable {
    func wait() async
}

public struct SixtySecondRecordingWatchdog: RecordingWatchdog {
    public init() {}

    public func wait() async {
        try? await Task.sleep(for: .seconds(60))
    }
}

public actor VoiceInputSessions {
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

    private let audioCapture: any AudioCapturing
    private let targetCapture: any InputTargetCapturing
    private let textProcessor: any VoiceTextProcessing
    private let delivery: any TextDelivering
    private let clipboard: any ClipboardWriting
    private let history: any SessionHistoryRecording
    private let watchdog: any RecordingWatchdog

    private var phase: Phase = .idle
    private var releasePending = false
    private var watchdogTask: Task<Void, Never>?
    private var transcriptionTask: Task<VoiceTextProcessingResult, Error>?
    private var telemetryTask: Task<Void, Never>?
    private var deliveryCommitGate: DeliveryCommitGate?
    private var historyWriteTasks: [VoiceInputSessionID: Task<Void, Never>] = [:]
    private var preparingStartedAt: Date?
    private var activeSnapshot: VoiceTextProcessingSnapshot?
    private var activeTriggerSequence: UInt64?
    private var auditSessionID: VoiceInputSessionID?
    private var auditStageName: String?
    private var auditStageStartedAt: ContinuousClock.Instant?
    private var auditStageDurations: [String: Int] = [:]
    private var auditApplicationName: String?
    private var presentation = VoiceInputPresentation(revision: 0, activity: .idle)
    private var observers: [UUID: AsyncStream<VoiceInputPresentation>.Continuation] = [:]

    public init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        transcriber: any SpeechTranscribing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording,
        watchdog: any RecordingWatchdog = SixtySecondRecordingWatchdog()
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        textProcessor = BasicVoiceTextProcessor(transcriber: transcriber)
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
        self.watchdog = watchdog
    }

    public init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        textProcessor: any VoiceTextProcessing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording,
        watchdog: any RecordingWatchdog = SixtySecondRecordingWatchdog()
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        self.textProcessor = textProcessor
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
        self.watchdog = watchdog
    }

    public func observe() -> AsyncStream<VoiceInputPresentation> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<VoiceInputPresentation>.makeStream()
        observers[id] = continuation
        continuation.yield(presentation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeObserver(id)
            }
        }
        return stream
    }

    public func send(_ command: VoiceInputCommand) async {
        await send(command, triggerSequence: nil)
    }

    public func send(
        _ command: VoiceInputCommand,
        triggerSequence: UInt64
    ) async {
        await send(command, triggerSequence: Optional(triggerSequence))
    }

    public func cancel(triggeredAtSequence sequence: UInt64) async {
        guard let activeTriggerSequence,
              activeTriggerSequence <= sequence
        else { return }
        await cancelSession()
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
            } else {
                await finishSession()
            }
        case .cancel:
            await cancelSession()
        case .copyPendingResult:
            if case let .pendingCopy(_, text, _) = presentation.activity {
                await clipboard.copy(text)
            }
        case .dismissResult:
            guard phase == .idle else { return }
            publish(.idle)
        }
    }

    private func beginSession(triggerSequence: UInt64?) async {
        guard phase == .idle else { return }
        let id = VoiceInputSessionID()
        let requestedAt = Date()
        releasePending = false
        phase = .preparing(id)
        activeTriggerSequence = triggerSequence
        preparingStartedAt = requestedAt
        beginAudit(id: id, stage: "preparing")
        publish(.preparing(id))
        saveStage(.preparing(id), id: id, startedAt: requestedAt)
        let snapshot = await textProcessor.captureSnapshot()
        guard phase == .preparing(id) else { return }
        activeSnapshot = snapshot

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
            observeRecordingTelemetry(for: id)
            scheduleWatchdog(for: id)
            saveStage(.recording(id), id: id, startedAt: startedAt, snapshot: snapshot)
            if releasePending {
                releasePending = false
                await finishSession()
            }
        } catch {
            guard phase == .preparing(id) else {
                await audioCapture.cancel()
                return
            }
            phase = .finalizing(id)
            activeTriggerSequence = nil
            preparingStartedAt = nil
            activeSnapshot = nil
            let activity = VoiceInputActivity.failed(id, .recordingFailed)
            let audit = finishAudit(id: id)
            let elapsed = max(0, Int(Date().timeIntervalSince(requestedAt) * 1_000))
            let historyNotice = await saveHistoryAndWait(.init(
                sessionID: id,
                startedAt: requestedAt,
                applicationName: nil,
                transcription: nil,
                finalText: nil,
                refinementModeName: snapshot.refinementMode.displayName,
                refinementPrompt: snapshot.refinementMode.deepSeekRule,
                dictionarySnapshotID: snapshot.dictionary.id,
                dictionarySnapshotEntries: snapshot.dictionary.entries,
                dictionaryRequestContext: snapshot.dictionaryContext,
                durationMilliseconds: elapsed,
                stageDurationsMilliseconds: audit.stageDurations,
                outcome: activity
            ))
            phase = .idle
            publish(activity, notice: historyNotice)
        }
    }

    private func finishSession() async {
        guard case let .recording(id, startedAt, snapshot) = phase else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        phase = .processing(id, startedAt: startedAt, snapshot: snapshot)
        advanceAudit(id: id, stage: "targetCapture")
        publish(.processing(id, .capturingTarget, applicationName: nil))
        async let timedTarget = Self.captureWithTiming(targetCapture)
        async let audioResult = audioCapture.stop()
        saveStage(
            .processing(id, .capturingTarget, applicationName: nil),
            id: id,
            startedAt: startedAt,
            snapshot: snapshot
        )

        let (target, targetCaptureMilliseconds) = await timedTarget
        var sessionStageDurations = ["targetCapture": targetCaptureMilliseconds]
        let audio: CapturedAudio
        do {
            audio = try await audioResult
        } catch {
            await discard(target)
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
                return
            }
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                failure: .recordingFailed,
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
            return
        }

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

        let activeProcessor = textProcessor
        let task = Task {
            try await activeProcessor.process(
                audio,
                snapshot: snapshot
            ) { [weak self] stage in
                await self?.receivedProcessingStage(
                    stage,
                    id: id,
                    startedAt: startedAt,
                    snapshot: snapshot,
                    applicationName: applicationName
                )
            }
        }
        transcriptionTask = task
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
            let diagnostic = failure.providerDiagnostic
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                failure: failure.userFailure,
                transcriptionProvider: diagnostic?.provider,
                providerRequestID: diagnostic?.requestID,
                providerErrorCode: diagnostic?.code,
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
                failure: .transcriptionFailed,
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
            return
        }
        transcriptionTask = nil

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
            let outcome = await delivery.deliver(
                processedText.finalText,
                to: targetSnapshot,
                commitGate: commitGate
            )
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
            case let .pendingCopy(reason):
                let activity = VoiceInputActivity.pendingCopy(
                    id,
                    text: processedText.finalText,
                    reason: reason
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
            }
        case let .unavailable(reason):
            let activity = VoiceInputActivity.pendingCopy(
                id,
                text: processedText.finalText,
                reason: reason
            )
            if reason == .secureTarget {
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
            guard await deliveryCommitGate.cancel() else { return }
            self.deliveryCommitGate = nil
        }
        let id: VoiceInputSessionID
        let startedAt: Date
        let processingSnapshot: VoiceTextProcessingSnapshot?
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

        let audit = finishAudit(id: id)
        phase = .finalizing(id)
        activeTriggerSequence = nil
        preparingStartedAt = nil
        activeSnapshot = nil
        releasePending = false
        watchdogTask?.cancel()
        watchdogTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        deliveryCommitGate = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        await audioCapture.cancel()
        let activity = VoiceInputActivity.cancelled(id)
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let historyNotice = await saveHistoryAndWait(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: audit.applicationName,
            transcription: nil,
            finalText: nil,
            refinementModeName: processingSnapshot?.refinementMode.displayName,
            refinementPrompt: processingSnapshot?.refinementMode.deepSeekRule,
            dictionarySnapshotID: processingSnapshot?.dictionary.id,
            dictionarySnapshotEntries: processingSnapshot?.dictionary.entries ?? [],
            dictionaryRequestContext: processingSnapshot?.dictionaryContext,
            durationMilliseconds: elapsed,
            stageDurationsMilliseconds: audit.stageDurations.isEmpty
                ? ["beforeCancellation": elapsed]
                : audit.stageDurations,
            outcome: activity
        ))
        phase = .idle
        publish(activity, notice: historyNotice)
    }

    private func finishWithFailure(
        id: VoiceInputSessionID,
        startedAt: Date,
        failure: VoiceInputFailure,
        transcriptionProvider: String? = nil,
        providerRequestID: String? = nil,
        providerErrorCode: String? = nil,
        processingSnapshot: VoiceTextProcessingSnapshot? = nil,
        additionalStageDurations: [String: Int] = [:]
    ) async {
        let activity = VoiceInputActivity.failed(id, failure)
        await finishTerminal(
            activity,
            id: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: nil,
            finalText: nil,
            transcriptionProvider: transcriptionProvider,
            providerRequestID: providerRequestID,
            providerErrorCode: providerErrorCode,
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
        processedText: VoiceTextProcessingResult? = nil,
        processingSnapshot: VoiceTextProcessingSnapshot? = nil,
        additionalStageDurations: [String: Int] = [:],
        historyOutcome: VoiceInputActivity? = nil
    ) async {
        let audit = finishAudit(id: id)
        phase = .finalizing(id)
        activeTriggerSequence = nil
        preparingStartedAt = nil
        activeSnapshot = nil
        releasePending = false
        watchdogTask?.cancel()
        watchdogTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        deliveryCommitGate = nil
        let processingNotice = processedText?.refinementStatus == .fellBack
            ? "进一步整理失败，已使用豆包结果。"
            : nil
        let measuredStageDurations = (processedText?.stageDurationsMilliseconds ?? [:])
            .merging(additionalStageDurations) { _, latest in latest }
        let stageDurations = audit.stageDurations
            .merging(measuredStageDurations) { _, measured in measured }
        let historyNotice = await saveHistoryAndWait(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: applicationName ?? audit.applicationName,
            transcription: transcription,
            finalText: finalText,
            transcriptionProvider: transcriptionProvider ?? (processedText == nil ? nil : "doubao"),
            providerRequestID: providerRequestID,
            providerErrorCode: providerErrorCode,
            deepSeekText: processedText?.deepSeekText,
            deepSeekRequestID: processedText?.deepSeekRequestID,
            refinementModeName: processingSnapshot?.refinementMode.displayName,
            refinementPrompt: processingSnapshot?.refinementMode.deepSeekRule,
            refinementStatus: processedText?.refinementStatus.rawValue,
            refinementFailureCode: processedText?.refinementFailure?.kind.rawValue,
            dictionarySnapshotID: processingSnapshot?.dictionary.id,
            dictionarySnapshotEntries: processingSnapshot?.dictionary.entries ?? [],
            dictionaryRequestContext: processingSnapshot?.dictionaryContext,
            dictionaryReplacements: processedText?.dictionaryReplacements ?? [],
            durationMilliseconds: max(
                0,
                Int(Date().timeIntervalSince(startedAt) * 1_000)
            ),
            stageDurationsMilliseconds: stageDurations,
            outcome: historyOutcome ?? activity
        ))
        let notice = [processingNotice, historyNotice]
            .compactMap { $0 }
            .joined(separator: " ")
        phase = .idle
        publish(activity, notice: notice.isEmpty ? nil : notice)
    }

    private func publish(
        _ activity: VoiceInputActivity,
        telemetry: RecordingTelemetry? = nil,
        notice: String? = nil
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

    private func scheduleWatchdog(for id: VoiceInputSessionID) {
        watchdogTask?.cancel()
        let watchdog = watchdog
        watchdogTask = Task { [weak self] in
            await watchdog.wait()
            guard !Task.isCancelled else { return }
            await self?.watchdogFired(for: id)
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

    private func receivedTelemetry(
        _ telemetry: RecordingTelemetry,
        for id: VoiceInputSessionID
    ) {
        guard case let .recording(activeID, _, _) = phase, activeID == id else { return }
        publish(.recording(id), telemetry: telemetry)
    }

    private func receivedProcessingStage(
        _ stage: VoiceInputProcessingStage,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        applicationName: String?
    ) async {
        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }
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
            transcription: nil,
            finalText: nil,
            refinementModeName: snapshot?.refinementMode.displayName,
            refinementPrompt: snapshot?.refinementMode.deepSeekRule,
            dictionarySnapshotID: snapshot?.dictionary.id,
            dictionarySnapshotEntries: snapshot?.dictionary.entries ?? [],
            dictionaryRequestContext: snapshot?.dictionaryContext,
            outcome: activity
        ))
    }

    @discardableResult
    private func queueHistory(
        _ record: VoiceInputHistoryRecord
    ) -> Task<Void, Never> {
        let previous = historyWriteTasks[record.sessionID]
        let history = history
        let task = Task {
            await previous?.value
            await history.save(record)
        }
        historyWriteTasks[record.sessionID] = task
        return task
    }

    private func saveHistoryAndWait(
        _ record: VoiceInputHistoryRecord
    ) async -> String? {
        let task = queueHistory(record)
        await task.value
        historyWriteTasks[record.sessionID] = nil
        return await history.persistenceFailureNotice()
    }

    private func discard(_ captureResult: InputTargetCaptureResult) async {
        guard case let .writable(target) = captureResult,
              let discarding = targetCapture as? any InputTargetDiscarding
        else { return }
        await discarding.discard(target)
    }

    private static func captureWithTiming(
        _ capture: any InputTargetCapturing
    ) async -> (InputTargetCaptureResult, Int) {
        let started = ContinuousClock.now
        let result = await capture.capture()
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

    private func watchdogFired(for id: VoiceInputSessionID) async {
        guard case let .recording(activeID, _, _) = phase, activeID == id else {
            return
        }
        watchdogTask = nil
        await finishSession()
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
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
