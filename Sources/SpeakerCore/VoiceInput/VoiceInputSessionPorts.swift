import Foundation

public struct AudioCaptureStart: Sendable {
    private let operation: @Sendable () async throws -> Void
    private let cancellation: @Sendable () async -> Void

    public init(
        start: @escaping @Sendable () async throws -> Void,
        cancel: @escaping @Sendable () async -> Void
    ) {
        operation = start
        cancellation = cancel
    }

    public func start() async throws {
        try await operation()
    }

    public func cancel() async {
        await cancellation()
    }
}

public protocol AudioCapturing: Sendable {
    func prepareStart() -> AudioCaptureStart
    func start() async throws
    func stop() async throws -> CapturedAudio
    func cancel() async
    /// Opens the stream of audio for the next recording while it is captured,
    /// or returns `nil` when this capture delivers only the complete recording.
    func audioChunks() async -> AsyncStream<Data>?
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

/// How clipboard managers and Universal Clipboard may treat a copied value.
public enum ClipboardCopyPrivacy: Equatable, Sendable {
    /// An ordinary copy the user asked for.
    case ordinary
    /// Text meant for a secure Input Target: marked concealed so clipboard
    /// managers do not record it, and kept on this Mac.
    case concealed
}

public protocol ClipboardWriting: Sendable {
    @discardableResult
    func copy(_ text: String, privacy: ClipboardCopyPrivacy) async -> Bool
}

extension ClipboardWriting {
    @discardableResult
    public func copy(_ text: String) async -> Bool {
        await copy(text, privacy: .ordinary)
    }
}

public protocol SessionHistoryRecording: Sendable {
    func save(_ record: VoiceInputHistoryRecord) async
    func persistenceFailureNotice() async -> LocalHistoryPersistenceNotice?
}

extension SessionHistoryRecording {
    public func persistenceFailureNotice() async -> LocalHistoryPersistenceNotice? { nil }
}
