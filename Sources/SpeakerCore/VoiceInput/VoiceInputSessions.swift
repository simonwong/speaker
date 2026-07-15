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

    public init(revision: UInt64, activity: VoiceInputActivity) {
        self.revision = revision
        self.activity = activity
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

public struct VoiceInputHistoryRecord: Equatable, Sendable {
    public let sessionID: VoiceInputSessionID
    public let startedAt: Date
    public let applicationName: String?
    public let transcription: String?
    public let finalText: String?
    public let providerRequestID: String?
    public let providerErrorCode: String?
    public let deepSeekText: String?
    public let deepSeekRequestID: String?
    public let refinementModeName: String?
    public let refinementStatus: String?
    public let refinementFailureCode: String?
    public let dictionarySnapshotID: UUID?
    public let dictionaryReplacements: [DictionaryReplacement]
    public let outcome: VoiceInputActivity

    public init(
        sessionID: VoiceInputSessionID,
        startedAt: Date,
        applicationName: String?,
        transcription: String?,
        finalText: String?,
        providerRequestID: String? = nil,
        providerErrorCode: String? = nil,
        deepSeekText: String? = nil,
        deepSeekRequestID: String? = nil,
        refinementModeName: String? = nil,
        refinementStatus: String? = nil,
        refinementFailureCode: String? = nil,
        dictionarySnapshotID: UUID? = nil,
        dictionaryReplacements: [DictionaryReplacement] = [],
        outcome: VoiceInputActivity
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.applicationName = applicationName
        self.transcription = transcription
        self.finalText = finalText
        self.providerRequestID = providerRequestID
        self.providerErrorCode = providerErrorCode
        self.deepSeekText = deepSeekText
        self.deepSeekRequestID = deepSeekRequestID
        self.refinementModeName = refinementModeName
        self.refinementStatus = refinementStatus
        self.refinementFailureCode = refinementFailureCode
        self.dictionarySnapshotID = dictionarySnapshotID
        self.dictionaryReplacements = dictionaryReplacements
        self.outcome = outcome
    }
}

public protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async throws -> CapturedAudio
    func cancel() async
}

public protocol InputTargetCapturing: Sendable {
    func capture() async -> InputTargetCaptureResult
}

public protocol SpeechTranscribing: Sendable {
    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult
}

public protocol TextDelivering: Sendable {
    func deliver(_ text: String, to target: InputTargetSnapshot) async -> DeliveryOutcome
}

public protocol ClipboardWriting: Sendable {
    func copy(_ text: String) async
}

public protocol SessionHistoryRecording: Sendable {
    func save(_ record: VoiceInputHistoryRecord) async
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
        switch command {
        case .pressed:
            await beginSession()
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

    private func beginSession() async {
        guard phase == .idle else { return }
        let id = VoiceInputSessionID()
        releasePending = false
        phase = .preparing(id)
        publish(.preparing(id))
        let snapshot = await textProcessor.captureSnapshot()

        do {
            try await audioCapture.start()
            guard phase == .preparing(id) else {
                await audioCapture.cancel()
                return
            }
            let startedAt = Date()
            phase = .recording(id, startedAt: startedAt, snapshot: snapshot)
            publish(.recording(id))
            scheduleWatchdog(for: id)
            if releasePending {
                releasePending = false
                await finishSession()
            }
        } catch {
            phase = .idle
            let activity = VoiceInputActivity.failed(id, .recordingFailed)
            publish(activity)
            await history.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: nil,
                transcription: nil,
                finalText: nil,
                outcome: activity
            ))
        }
    }

    private func finishSession() async {
        guard case let .recording(id, startedAt, snapshot) = phase else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        phase = .processing(id, startedAt: startedAt, snapshot: snapshot)
        publish(.processing(id, .capturingTarget, applicationName: nil))

        async let targetResult = targetCapture.capture()
        async let audioResult = audioCapture.stop()

        let target = await targetResult
        let audio: CapturedAudio
        do {
            audio = try await audioResult
        } catch {
            await finishWithFailure(id: id, startedAt: startedAt, failure: .recordingFailed)
            return
        }

        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }
        let applicationName = target.applicationName
        publish(.processing(id, .transcribing, applicationName: applicationName))

        let activeProcessor = textProcessor
        let task = Task {
            try await activeProcessor.process(audio, snapshot: snapshot)
        }
        transcriptionTask = task
        let processedText: VoiceTextProcessingResult
        do {
            processedText = try await task.value
        } catch let failure as DoubaoASRFailure {
            transcriptionTask = nil
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                failure: Self.userFailure(for: failure.kind),
                providerRequestID: failure.providerRequestID,
                providerErrorCode: failure.kind.rawValue
            )
            return
        } catch {
            transcriptionTask = nil
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }
            await finishWithFailure(id: id, startedAt: startedAt, failure: .transcriptionFailed)
            return
        }
        transcriptionTask = nil

        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }

        switch target {
        case let .writable(targetSnapshot):
            publish(.processing(id, .delivering, applicationName: targetSnapshot.applicationName))
            let outcome = await delivery.deliver(processedText.finalText, to: targetSnapshot)
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
                    processingSnapshot: snapshot
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
                    processingSnapshot: snapshot
                )
            }
        case let .unavailable(reason):
            let activity = VoiceInputActivity.pendingCopy(
                id,
                text: processedText.finalText,
                reason: reason
            )
            await finishTerminal(
                activity,
                id: id,
                startedAt: startedAt,
                applicationName: nil,
                transcription: processedText.doubaoText,
                finalText: processedText.finalText,
                providerRequestID: processedText.doubaoRequestID,
                processedText: processedText,
                processingSnapshot: snapshot
            )
        }
    }

    private func cancelSession() async {
        let id: VoiceInputSessionID
        let startedAt: Date
        switch phase {
        case let .preparing(sessionID):
            id = sessionID
            startedAt = Date()
        case let .recording(sessionID, sessionStartedAt, _),
             let .processing(sessionID, sessionStartedAt, _):
            id = sessionID
            startedAt = sessionStartedAt
        case .idle:
            return
        }

        phase = .idle
        releasePending = false
        watchdogTask?.cancel()
        watchdogTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        await audioCapture.cancel()
        let activity = VoiceInputActivity.cancelled(id)
        publish(activity)
        await history.save(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: nil,
            finalText: nil,
            outcome: activity
        ))
    }

    private func finishWithFailure(
        id: VoiceInputSessionID,
        startedAt: Date,
        failure: VoiceInputFailure,
        providerRequestID: String? = nil,
        providerErrorCode: String? = nil
    ) async {
        let activity = VoiceInputActivity.failed(id, failure)
        await finishTerminal(
            activity,
            id: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: nil,
            finalText: nil,
            providerRequestID: providerRequestID,
            providerErrorCode: providerErrorCode
        )
    }

    private func finishTerminal(
        _ activity: VoiceInputActivity,
        id: VoiceInputSessionID,
        startedAt: Date,
        applicationName: String?,
        transcription: String?,
        finalText: String?,
        providerRequestID: String? = nil,
        providerErrorCode: String? = nil,
        processedText: VoiceTextProcessingResult? = nil,
        processingSnapshot: VoiceTextProcessingSnapshot? = nil
    ) async {
        phase = .idle
        releasePending = false
        watchdogTask?.cancel()
        watchdogTask = nil
        publish(activity)
        await history.save(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: applicationName,
            transcription: transcription,
            finalText: finalText,
            providerRequestID: providerRequestID,
            providerErrorCode: providerErrorCode,
            deepSeekText: processedText?.deepSeekText,
            deepSeekRequestID: processedText?.deepSeekRequestID,
            refinementModeName: processingSnapshot?.refinementMode.displayName,
            refinementStatus: processedText?.refinementStatus.rawValue,
            refinementFailureCode: processedText?.refinementFailure?.kind.rawValue,
            dictionarySnapshotID: processingSnapshot?.dictionary.id,
            dictionaryReplacements: processedText?.dictionaryReplacements ?? [],
            outcome: activity
        ))
    }

    private func publish(_ activity: VoiceInputActivity) {
        presentation = VoiceInputPresentation(
            revision: presentation.revision &+ 1,
            activity: activity
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

    private static func userFailure(for kind: DoubaoASRFailureKind) -> VoiceInputFailure {
        switch kind {
        case .invalidCredential:
            .providerNotConfigured
        case .silence, .emptyAudio, .emptyTranscript:
            .noSpeechDetected
        case .resourceNotActivated:
            .providerResourceUnavailable
        case .rateLimited:
            .providerRateLimited
        case .network:
            .networkUnavailable
        case .serverBusy, .serviceUnavailable:
            .providerUnavailable
        case .cancelled, .invalidRequest, .invalidAudioFormat, .invalidResponse:
            .transcriptionFailed
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
