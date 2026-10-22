import Foundation
import SpeakerCore

/// A transcriber double that answers with one fixed Stage Result.
///
/// `delaysResponse` holds the answer open until `resume()`, which is how a case reaches the
/// Waiting For Result state and observes what User Cancellation does to a late Stage Result.
public actor SpeechTranscriberFake: ContextualSpeechTranscribing {
    public let text: String
    public let delaysResponse: Bool
    public let ignoresCancellation: Bool
    public let failure: SpeechRecognitionFailure?
    public private(set) var contexts: [SpeechTranscriptionContext] = []
    public private(set) var callCount = 0
    public private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    public init(
        text: String, delaysResponse: Bool = false, ignoresCancellation: Bool = false,
        failure: SpeechRecognitionFailure? = nil
    ) {
        self.text = text
        self.delaysResponse = delaysResponse
        self.ignoresCancellation = ignoresCancellation
        self.failure = failure
    }

    public func transcribe(
        _ audio: CapturedAudio, context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        contexts.append(context)
        return try await transcribe(audio)
    }

    public func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        callCount += 1
        if delaysResponse {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            } onCancel: {
                Task { await self.markCancelled() }
            }
        }
        if !ignoresCancellation { try Task.checkCancellation() }
        if let failure { throw failure }
        return TranscriptionResult(text: text, providerRequestID: "local-spec")
    }

    public func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func markCancelled() {
        cancellationCount += 1
    }
}

/// A text-processing double that reports the given stages and then answers with one
/// injected result, including a result that already recorded a refinement fallback.
public struct VoiceTextProcessorFake: VoiceTextProcessing {
    public let result: VoiceTextProcessingResult
    public let reportedStages: [VoiceInputProcessingStage]
    private let snapshotOperation: @Sendable () async -> VoiceTextProcessingSnapshot

    public init(
        result: VoiceTextProcessingResult,
        reportedStages: [VoiceInputProcessingStage] = [],
        captureSnapshot: @escaping @Sendable () async -> VoiceTextProcessingSnapshot = { .empty }
    ) {
        self.result = result
        self.reportedStages = reportedStages
        snapshotOperation = captureSnapshot
    }

    public var streaming: (any StreamingVoiceTextProcessing)? { nil }

    public func captureSnapshot() async -> VoiceTextProcessingSnapshot {
        await snapshotOperation()
    }

    public func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        for stage in reportedStages {
            await progress(.init(stage: stage))
        }
        return result
    }
}

/// A text-processing double that reports one injected Session Problem instead of a result.
public struct FailingVoiceTextProcessor: VoiceTextProcessing {
    public let failure: VoiceTextProcessingFailure

    public init(failure: VoiceTextProcessingFailure) {
        self.failure = failure
    }

    public var streaming: (any StreamingVoiceTextProcessing)? { nil }

    public func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    public func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw failure
    }
}

/// A text-processing double that reports one stage and then stays in Waiting For Result
/// until it is cancelled, counting the cancellations it observed.
/// Reporting `.refining` with `confirmedText` models refinement pending after
/// recognition was confirmed.
public actor HangingVoiceTextProcessor: VoiceTextProcessing {
    public let reportedStage: VoiceInputProcessingStage
    public let confirmedText: String?
    public private(set) var cancellationCount = 0

    public init(
        reportedStage: VoiceInputProcessingStage = .transcribing,
        confirmedText: String? = nil
    ) {
        self.reportedStage = reportedStage
        self.confirmedText = confirmedText
    }

    public nonisolated var streaming: (any StreamingVoiceTextProcessing)? { nil }

    public func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    public func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        await progress(
            .init(
                stage: reportedStage,
                confirmedRecognitionResult: confirmedText.map {
                    TranscriptionResult(text: $0, providerRequestID: nil)
                }
            ))
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
        throw VoiceTextProcessingFailure(userFailure: .transcriptionFailed)
    }
}

/// A streaming text-processing double whose recognition is confirmed as soon
/// as the session accepts the capture. It then reports `.refining` with
/// `confirmedText` and stays in refinement until cancelled, counting the
/// cancellations it observed.
public actor ConfirmedStreamingVoiceTextProcessor: VoiceTextProcessing,
    StreamingVoiceTextProcessing
{
    public let confirmedText: String
    public private(set) var hasReportedRefining = false
    public private(set) var cancellationCount = 0

    public init(confirmedText: String) {
        self.confirmedText = confirmedText
    }

    public nonisolated var streaming: (any StreamingVoiceTextProcessing)? { self }

    public func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    public func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw VoiceTextProcessingFailure(userFailure: .transcriptionFailed)
    }

    public func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw VoiceTextProcessingFailure(userFailure: .transcriptionFailed)
    }

    public func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        audioCaptureCompletion: AudioCaptureCompletionGate,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        for await _ in audioChunks {}
        try await audioCaptureCompletion.wait()
        await progress(
            .init(
                stage: .refining,
                confirmedRecognitionResult: TranscriptionResult(
                    text: confirmedText, providerRequestID: "confirmed-streaming-spec")
            ))
        hasReportedRefining = true
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
        throw VoiceTextProcessingFailure(userFailure: .transcriptionFailed)
    }
}

/// A Refinement Provider double that answers every request with `refinedText`
/// and records, in order, each connection preparation and each request.
public actor TextRefinerFake: TextRefining {
    public enum Event: Equatable, Sendable {
        case preparedConnection(RefinementProviderProfile)
        case refined(String)
    }

    public let refinedText: String
    public private(set) var events: [Event] = []

    public init(refinedText: String) {
        self.refinedText = refinedText
    }

    public var refineCount: Int {
        events.filter { if case .refined = $0 { true } else { false } }.count
    }

    public var preparedProviders: [RefinementProviderProfile] {
        events.compactMap {
            if case .preparedConnection(let provider) = $0 { provider } else { nil }
        }
    }

    public func prepareConnection(to provider: RefinementProviderProfile) async {
        events.append(.preparedConnection(provider))
    }

    public func refine(
        _ text: String,
        using context: TextRefinementContext
    ) async throws -> TextRefinementResult {
        events.append(.refined(text))
        return TextRefinementResult(text: refinedText, providerRequestID: "refiner-fake")
    }
}
