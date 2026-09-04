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

actor AudioCaptureFake: AudioCapturing {
    let delaysStart: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var isActive = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(delaysStart: Bool = false) {
        self.delaysStart = delaysStart
    }

    func start() async throws {
        startCount += 1
        if delaysStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        isActive = true
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        isActive = false
        return CapturedAudio(
            data: Data([0x52, 0x49, 0x46, 0x46]),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    func cancel() async {
        cancelCount += 1
        isActive = false
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

actor DelayedFailingStartAudioCapture: AudioCapturing {
    func start() async throws {
        try await Task.sleep(for: .milliseconds(20))
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

actor ControlledRecordingDeadline {
    private(set) var requestedDuration: Duration?
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancelledRequests: Set<Int> = []

    func sleep(for duration: Duration) async throws {
        let requestID = requestCount
        requestCount += 1
        requestedDuration = duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancelledRequests.contains(requestID) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[requestID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }
    }

    func waitUntilStarted() async {
        while requestedDuration == nil {
            await Task.yield()
        }
    }

    func waitUntilRequestCount(_ expectedCount: Int) async {
        while requestCount < expectedCount {
            await Task.yield()
        }
    }

    func waitUntilCancelled() async {
        while cancellationCount == 0 {
            await Task.yield()
        }
    }

    func fire() {
        guard let requestID = continuations.keys.min(),
              let continuation = continuations.removeValue(forKey: requestID)
        else { return }
        continuation.resume()
    }

    private func cancel(requestID: Int) {
        guard cancelledRequests.insert(requestID).inserted else { return }
        cancellationCount += 1
        continuations.removeValue(forKey: requestID)?
            .resume(throwing: CancellationError())
    }
}

actor StubbornRecordingDeadline {
    private(set) var requestCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(for duration: Duration) async throws {
        let requestID = requestCount
        requestCount += 1
        await withCheckedContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func waitUntilRequestCount(_ expectedCount: Int) async {
        while requestCount < expectedCount { await Task.yield() }
    }

    func fire(requestID: Int) {
        continuations.removeValue(forKey: requestID)?.resume()
    }
}
