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
    AudioCaptureFailureProviding
{
    private var continuation: AsyncStream<Data>.Continuation?
    private var failureContinuation: AsyncStream<AudioCaptureError>.Continuation?
    private var activeFailure: AudioCaptureError?
    private var activeStartID: UUID?
    private var cancelledStartIDs: Set<UUID> = []
    private var firstAudioChunksContinuation: CheckedContinuation<Void, Never>?
    private let delaysFirstAudioChunks: Bool
    private(set) var audioChunksCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private let stoppedAudio: CapturedAudio

    init(
        stoppedAudio: CapturedAudio = CapturedAudio(
            data: Data(),
            duration: .seconds(1),
            peakPower: -12
        ),
        delaysFirstAudioChunks: Bool = false
    ) {
        self.stoppedAudio = stoppedAudio
        self.delaysFirstAudioChunks = delaysFirstAudioChunks
    }

    var isActive: Bool { activeStartID != nil }

    func audioChunks() async -> AsyncStream<Data> {
        audioChunksCount += 1
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        if delaysFirstAudioChunks, audioChunksCount == 1 {
            await withCheckedContinuation { firstAudioChunksContinuation = $0 }
        }
        return stream
    }

    func resumeFirstAudioChunks() {
        firstAudioChunksContinuation?.resume()
        firstAudioChunksContinuation = nil
    }

    func observeFailures() -> AsyncStream<AudioCaptureError> {
        let (stream, continuation) = AsyncStream<AudioCaptureError>.makeStream()
        failureContinuation = continuation
        if let activeFailure { continuation.yield(activeFailure) }
        return stream
    }

    nonisolated func prepareStart() -> AudioCaptureStart {
        let id = UUID()
        return AudioCaptureStart(
            start: { try await self.start(id: id) },
            cancel: { await self.cancel(id: id) }
        )
    }

    func start() async throws { try await prepareStart().start() }

    private func start(id: UUID) throws {
        guard !cancelledStartIDs.contains(id) else { throw CancellationError() }
        activeStartID = id
        startCount += 1
    }

    func emit(_ data: Data) {
        continuation?.yield(data)
    }

    func emitFailure(_ failure: AudioCaptureError) {
        activeFailure = failure
        failureContinuation?.yield(failure)
    }

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        activeStartID = nil
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
        activeStartID = nil
        continuation?.finish()
        continuation = nil
        failureContinuation?.finish()
        failureContinuation = nil
        activeFailure = nil
    }

    private func cancel(id: UUID) async {
        cancelledStartIDs.insert(id)
        guard activeStartID == id else { return }
        await cancel()
    }
}

actor DelayedFailingStopAudioCapture: AudioCapturing {
    private(set) var stopCount = 0
    private var stopContinuation: CheckedContinuation<CapturedAudio, Error>?

    nonisolated func prepareStart() -> AudioCaptureStart {
        AudioCaptureStart(start: {}, cancel: {})
    }

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

    nonisolated func prepareStart() -> AudioCaptureStart {
        AudioCaptureStart(start: { try await self.start() }, cancel: {})
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
    private var activeStartID: UUID?

    func audioChunks() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        audioContinuation = continuation
        return stream
    }

    nonisolated func prepareStart() -> AudioCaptureStart {
        let id = UUID()
        return AudioCaptureStart(
            start: { await self.start(id: id) },
            cancel: { await self.cancel(id: id) }
        )
    }

    func start() async throws { try await prepareStart().start() }

    private func start(id: UUID) {
        activeStartID = id
    }

    func stop() async throws -> CapturedAudio {
        activeStartID = nil
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
        activeStartID = nil
        audioContinuation?.finish()
        audioContinuation = nil
        await withCheckedContinuation { continuation in
            cancelContinuation = continuation
        }
    }

    private func cancel(id: UUID) async {
        guard activeStartID == id else { return }
        await cancel()
    }

    func waitUntilCancelStarted() async {
        while !cancelStarted { await Task.yield() }
    }

    func finishCancel() {
        cancelContinuation?.resume()
        cancelContinuation = nil
    }
}

final class AudioCaptureHardwareFake: AudioCaptureHardware, @unchecked Sendable {
    private let lock = NSLock()
    private let readbackOverride: UInt32?
    private let startFailure: AudioCaptureError?
    private var selectedID: UInt32 = 0
    private var running = false
    private var stops = 0
    private var stream: BoundedAudioChunkStream?
    private var failureCallback: (@Sendable (AudioCaptureError) async -> Void)?

    init(readbackOverride: UInt32? = nil, startFailure: AudioCaptureError? = nil) {
        self.readbackOverride = readbackOverride
        self.startFailure = startFailure
    }

    var currentDeviceID: UInt32 { lock.withLock { readbackOverride ?? selectedID } }
    var isRunning: Bool { lock.withLock { running } }
    var stopCount: Int { lock.withLock { stops } }
    var streamsAudio: Bool { lock.withLock { stream != nil } }
    var environmentSnapshot: AudioCaptureEnvironmentSnapshot? { nil }
    var metrics: AudioCaptureHardwareMetrics {
        AudioCaptureHardwareMetrics(
            currentPower: -12, peakPower: -12,
            didExhaustStreamBuffer: false, didFailConversion: false
        )
    }

    func start(
        deviceID: UInt32,
        audioStream: BoundedAudioChunkStream?,
        onFailure: @escaping @Sendable (AudioCaptureError) async -> Void
    ) throws {
        try lock.withLock {
            selectedID = deviceID
            stream = audioStream
            failureCallback = onFailure
            if let startFailure { throw startFailure }
            running = true
        }
    }

    func stop() {
        let stream = lock.withLock {
            stops += 1
            running = false
            return self.stream
        }
        stream?.finish()
    }

    func emitFailure(_ failure: AudioCaptureError) async {
        let callback = lock.withLock { failureCallback }
        await callback?(failure)
    }

}

final class AudioCaptureHardwareFactoryFake: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [AudioCaptureHardwareFake] = []
    private let readbackOverride: UInt32?
    private let startFailure: AudioCaptureError?

    init(readbackOverride: UInt32? = nil, startFailure: AudioCaptureError? = nil) {
        self.readbackOverride = readbackOverride
        self.startFailure = startFailure
    }

    var instances: [AudioCaptureHardwareFake] { lock.withLock { created } }

    var factory: AudioCaptureHardwareFactory {
        AudioCaptureHardwareFactory(
            checkPermission: {},
            make: { [self] in
                let hardware = AudioCaptureHardwareFake(
                    readbackOverride: readbackOverride, startFailure: startFailure
                )
                lock.withLock { created.append(hardware) }
                return hardware
            })
    }
}
