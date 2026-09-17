import Foundation
import SpeakerCore

public actor MicrophoneLevelTesterFake: MicrophoneLevelTesting {
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var isActive = false
    private let routing: MicrophoneRouting?
    private let failure: AudioCaptureError?
    private let delaysStart: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var continuation: AsyncThrowingStream<RecordingTelemetry, any Error>.Continuation?
    private var lease: MicrophoneCaptureLease?

    public init(
        routing: MicrophoneRouting? = nil,
        failure: AudioCaptureError? = nil,
        delaysStart: Bool = false
    ) {
        self.routing = routing
        self.failure = failure
        self.delaysStart = delaysStart
    }

    public func startLevelTest() async throws -> AsyncThrowingStream<RecordingTelemetry, any Error>
    {
        startCount += 1
        if delaysStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        if let failure { throw failure }
        if let routing {
            let lease = try routing.acquire(routing.prepareCapture(), purpose: .levelTest)
            self.lease = lease
            routing.markStarted(lease)
        }
        let (stream, continuation) = AsyncThrowingStream<RecordingTelemetry, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        isActive = true
        return stream
    }

    public func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    public func emit(_ telemetry: RecordingTelemetry) {
        continuation?.yield(telemetry)
    }

    public func finish(error: AudioCaptureError? = nil) {
        continuation?.finish(throwing: error)
        continuation = nil
        if let lease { routing?.release(lease) }
        lease = nil
        isActive = false
    }

    public func stopLevelTest() {
        stopCount += 1
        finish()
    }
}
