import Foundation

public protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async throws -> CapturedAudio
    func cancel() async
}

public protocol AudioChunkStreaming: Sendable {
    func audioChunks() async -> AsyncStream<Data>
}

package protocol AudioCaptureTelemetryProviding: Sendable {
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

extension InputTargetCapturing {
    public func capture(
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
    func shutdown() async
}

extension TextDelivering {
    public func shutdown() async {}
}

public protocol ClipboardWriting: Sendable {
    @discardableResult
    func copy(_ text: String) async -> Bool
}

public protocol SessionHistoryRecording: Sendable {
    func save(_ record: VoiceInputHistoryRecord) async
    func persistenceFailureNotice() async -> LocalHistoryPersistenceNotice?
}

extension SessionHistoryRecording {
    public func persistenceFailureNotice() async -> LocalHistoryPersistenceNotice? { nil }
}
