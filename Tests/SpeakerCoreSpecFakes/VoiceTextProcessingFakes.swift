import Foundation
import SpeakerCore

/// A transcriber double that answers with one fixed Stage Result.
///
/// `delaysResponse` holds the answer open until `resume()`, which is how a case reaches the
/// Waiting For Result state and observes what User Cancellation does to a late Stage Result.
public actor SpeechTranscriberFake: SpeechTranscribing {
    public let text: String
    public let delaysResponse: Bool
    public private(set) var callCount = 0
    public private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    public init(text: String, delaysResponse: Bool = false) {
        self.text = text
        self.delaysResponse = delaysResponse
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
        try Task.checkCancellation()
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

    public init(
        result: VoiceTextProcessingResult,
        reportedStages: [VoiceInputProcessingStage] = []
    ) {
        self.result = result
        self.reportedStages = reportedStages
    }

    public func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

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
public actor HangingVoiceTextProcessor: VoiceTextProcessing {
    public let reportedStage: VoiceInputProcessingStage
    public private(set) var cancellationCount = 0

    public init(reportedStage: VoiceInputProcessingStage = .transcribing) {
        self.reportedStage = reportedStage
    }

    public func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    public func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        await progress(.init(stage: reportedStage))
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
        throw VoiceTextProcessingFailure(userFailure: .transcriptionFailed)
    }
}
