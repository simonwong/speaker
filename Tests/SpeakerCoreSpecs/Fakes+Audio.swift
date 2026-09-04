import Foundation
import SpeakerCore
import SpeakerSpecSupport

func makeAudioStream(_ chunks: [Data]) -> AsyncStream<Data> {
    AsyncStream { continuation in
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }
}

actor StreamingAudioCaptureFake: AudioCapturing, AudioChunkStreaming,
    AudioCaptureFailureProviding {
    private var continuation: AsyncStream<Data>.Continuation?
    private var failureContinuation: AsyncStream<AudioCaptureError>.Continuation?
    private var activeFailure: AudioCaptureError?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private let stoppedAudio: CapturedAudio

    init(
        stoppedAudio: CapturedAudio = CapturedAudio(
            data: Data(),
            duration: .seconds(1),
            peakPower: -12
        )
    ) {
        self.stoppedAudio = stoppedAudio
    }

    func audioChunks() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        return stream
    }

    func observeFailures() -> AsyncStream<AudioCaptureError> {
        let (stream, continuation) = AsyncStream<AudioCaptureError>.makeStream()
        failureContinuation = continuation
        if let activeFailure { continuation.yield(activeFailure) }
        return stream
    }

    func start() async throws { startCount += 1 }

    func emit(_ data: Data) {
        continuation?.yield(data)
    }

    func emitFailure(_ failure: AudioCaptureError) {
        activeFailure = failure
        failureContinuation?.yield(failure)
    }

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        continuation?.finish()
        continuation = nil
        failureContinuation?.finish()
        failureContinuation = nil
        activeFailure = nil
        try AudioCaptureQualityPolicy.validate(
            duration: stoppedAudio.duration,
            peakPower: stoppedAudio.peakPower
        )
        return stoppedAudio
    }

    func cancel() async {
        cancelCount += 1
        continuation?.finish()
        continuation = nil
        failureContinuation?.finish()
        failureContinuation = nil
        activeFailure = nil
    }
}

actor DelayedFailingStopAudioCapture: AudioCapturing {
    private(set) var stopCount = 0
    private var stopContinuation: CheckedContinuation<CapturedAudio, Error>?

    func start() async throws {}

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func cancel() async {}

    func failStop() {
        stopContinuation?.resume(throwing: SpecFailure(message: "late recorder failure"))
        stopContinuation = nil
    }
}

/// Fails to start after moving the session's clock forward by `startDelay`,
/// so preparation timing is exact instead of depending on scheduling.
actor DelayedFailingStartAudioCapture: AudioCapturing {
    private let clock: ManualVoiceInputClock
    private let startDelay: Duration

    init(clock: ManualVoiceInputClock, startDelay: Duration) {
        self.clock = clock
        self.startDelay = startDelay
    }

    func start() async throws {
        clock.advance(by: startDelay)
        throw SpecFailure(message: "recorder start failed")
    }

    func stop() async throws -> CapturedAudio { specAudio }

    func cancel() async {}
}

actor BlockingCancelAudioCapture: AudioCapturing, AudioChunkStreaming {
    private var cancelStarted = false
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private var audioContinuation: AsyncStream<Data>.Continuation?

    func audioChunks() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        audioContinuation = continuation
        return stream
    }

    func start() async throws {}

    func stop() async throws -> CapturedAudio {
        audioContinuation?.finish()
        audioContinuation = nil
        return CapturedAudio(
            data: Data([0x52, 0x49, 0x46, 0x46]),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    func cancel() async {
        cancelStarted = true
        audioContinuation?.finish()
        audioContinuation = nil
        await withCheckedContinuation { continuation in
            cancelContinuation = continuation
        }
    }

    func waitUntilCancelStarted() async {
        while !cancelStarted { await Task.yield() }
    }

    func finishCancel() {
        cancelContinuation?.resume()
        cancelContinuation = nil
    }
}
