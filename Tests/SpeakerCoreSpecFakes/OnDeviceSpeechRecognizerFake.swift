import Foundation
import SpeakerCore

/// An on-device recognizer double. It drains the audio stream, waits for the
/// capture completion gate like the real adapter, then answers with `text` or
/// throws `failure`. `installModel()` reports progress and marks the model installed.
public actor OnDeviceSpeechRecognizerFake: OnDeviceSpeechRecognizing {
    public private(set) var status: OnDeviceSpeechModelStatus
    private let text: String
    private let failure: (any Error & Sendable)?
    public private(set) var receivedBytes = 0
    public private(set) var transcribeCount = 0
    public private(set) var installCount = 0

    public init(
        status: OnDeviceSpeechModelStatus = .installed, text: String = "本机结果",
        failure: (any Error & Sendable)? = nil
    ) {
        self.status = status
        self.text = text
        self.failure = failure
    }

    public func modelStatus() async -> OnDeviceSpeechModelStatus { status }

    public func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        installCount += 1
        progress(0.5)
        status = .installed
        progress(1)
    }

    public func transcribe(
        _ chunks: AsyncStream<Data>, completion: AudioCaptureCompletionGate?
    ) async throws -> String {
        transcribeCount += 1
        for await chunk in chunks { receivedBytes += chunk.count }
        try await completion?.wait()
        if let failure { throw failure }
        return text
    }
}
