@preconcurrency import AVFoundation
import AppKit
import Foundation

public enum AudioCaptureError: Error, Equatable, Sendable {
    case alreadyRecording
    case couldNotPrepare
    case couldNotStart
    case microphonePermissionDenied
    case microphoneUnavailable
    case microphoneSelectionFailed
    case noActiveRecording
    case tooShort
    case silent
    case streamBufferExhausted
    case conversionFailed
    case deviceConfigurationChanged
}

public enum AudioCaptureVoiceProcessingFailure: String, Equatable, Sendable {
    case audioSystem
    case mediaServices
    case other

    package static func classify(
        _ error: any Error
    ) -> AudioCaptureVoiceProcessingFailure {
        switch (error as NSError).domain {
        case NSOSStatusErrorDomain, "com.apple.coreaudio.avfaudio":
            .audioSystem
        case "AVFoundationErrorDomain":
            .mediaServices
        default:
            .other
        }
    }
}

public enum AudioCaptureMicrophoneMode: String, Equatable, Sendable {
    case standard
    case wideSpectrum
    case voiceIsolation
    case unknown
}

public struct AudioCaptureEnvironmentSnapshot: Equatable, Sendable {
    public let voiceProcessingRequested: Bool
    public let voiceProcessingActive: Bool
    public let voiceProcessingEnableFailure: AudioCaptureVoiceProcessingFailure?
    public let automaticGainControlEnabled: Bool
    public let preferredMicrophoneMode: AudioCaptureMicrophoneMode
    public let activeMicrophoneMode: AudioCaptureMicrophoneMode

    public init(
        voiceProcessingRequested: Bool,
        voiceProcessingActive: Bool,
        voiceProcessingEnableFailure: AudioCaptureVoiceProcessingFailure?,
        automaticGainControlEnabled: Bool,
        preferredMicrophoneMode: AudioCaptureMicrophoneMode,
        activeMicrophoneMode: AudioCaptureMicrophoneMode
    ) {
        self.voiceProcessingRequested = voiceProcessingRequested
        self.voiceProcessingActive = voiceProcessingActive
        self.voiceProcessingEnableFailure = voiceProcessingEnableFailure
        self.automaticGainControlEnabled = automaticGainControlEnabled
        self.preferredMicrophoneMode = preferredMicrophoneMode
        self.activeMicrophoneMode = activeMicrophoneMode
    }
}

public protocol AudioCaptureEnvironmentProviding: Sendable {
    func captureEnvironmentSnapshot() async -> AudioCaptureEnvironmentSnapshot?
}

package enum AudioCaptureQualityPolicy {
    /// Peak amplitude below this boundary is effectively digital silence.
    ///
    /// This deliberately does not attempt speech recognition or noise
    /// classification. A conservative boundary avoids rejecting quiet users;
    /// ambiguous audio remains the provider's responsibility.
    package static let definiteSilencePeakPower: Float = -72

    package static func validate(
        duration: Duration,
        peakPower: Float
    ) throws {
        guard duration >= .milliseconds(300) else {
            throw AudioCaptureError.tooShort
        }
        guard peakPower > definiteSilencePeakPower else {
            throw AudioCaptureError.silent
        }
    }
}

public actor AVAudioCapture: AudioCapturing, AudioCaptureTelemetryProviding,
    AudioCaptureFailureProviding, AudioCaptureEnvironmentProviding, MicrophoneLevelTesting
{
    package static let maximumBufferedAudioBytes = 1_024_000
    package static let maximumLevelTestDuration: Duration = .seconds(8)

    private nonisolated let microphones: MicrophoneRouting
    private let hardwareFactory: AudioCaptureHardwareFactory
    private let clock: any VoiceInputClock
    private var hardware: (any AudioCaptureHardware)?
    private var lease: MicrophoneCaptureLease?
    private var previewContinuation:
        AsyncThrowingStream<RecordingTelemetry, any Error>.Continuation?
    private var pendingAudioStream: BoundedAudioChunkStream?
    private var pendingStreamID: UUID?
    private var activeStreamID: UUID?
    private var recordingStartedAt: Duration?
    private var meterTask: Task<Void, Never>?
    private var deviceObservation: Task<Void, Never>?
    private var previewDeadline: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var activeRuntimeFailure: AudioCaptureError?
    private var latestEnvironmentSnapshot: AudioCaptureEnvironmentSnapshot?
    private var telemetryObservers: [UUID: AsyncStream<RecordingTelemetry>.Continuation] = [:]
    private var failureObservers: [UUID: AsyncStream<AudioCaptureError>.Continuation] = [:]

    public init(microphones: MicrophoneRouting) {
        self.microphones = microphones
        hardwareFactory = .live
        clock = ContinuousVoiceInputClock()
    }

    public init() {
        microphones = MicrophoneRouting(devices: CoreAudioMicrophoneDevices())
        hardwareFactory = .live
        clock = ContinuousVoiceInputClock()
    }

    package init(
        microphones: MicrophoneRouting,
        hardwareFactory: AudioCaptureHardwareFactory,
        clock: any VoiceInputClock = ContinuousVoiceInputClock()
    ) {
        self.microphones = microphones
        self.hardwareFactory = hardwareFactory
        self.clock = clock
    }

    public nonisolated func prepareStart() -> AudioCaptureStart {
        let plan = microphones.prepareCapture()
        return AudioCaptureStart(
            start: { [self] in try await start(plan: plan) },
            cancel: { [self] in
                plan.cancel()
                await cancel(planID: plan.id)
            }
        )
    }

    public func audioChunks() -> AsyncStream<Data> {
        pendingAudioStream?.finish()
        let id = UUID()
        let audioStream = BoundedAudioChunkStream(
            maximumBufferedBytes: Self.maximumBufferedAudioBytes,
            nominalChunkSize: 6_400,
            onBufferExhausted: { [weak self] in
                Task { await self?.reportStreamFailure(.streamBufferExhausted, id: id) }
            }
        )
        pendingAudioStream = audioStream
        pendingStreamID = id
        return audioStream.stream
    }

    public func start() async throws {
        try start(plan: microphones.prepareCapture())
    }

    private func start(plan: MicrophoneCapturePlan) throws {
        guard !plan.isCancelled else { throw CancellationError() }
        if let lease, lease.purpose == .levelTest {
            cleanUpCapture(lease)
        }
        guard lease == nil else { throw AudioCaptureError.alreadyRecording }
        guard let audioStream = pendingAudioStream, let streamID = pendingStreamID else {
            throw AudioCaptureError.couldNotPrepare
        }
        pendingAudioStream = nil
        pendingStreamID = nil
        do {
            try hardwareFactory.checkPermission()
            let lease = try microphones.acquire(plan, purpose: .voice)
            self.lease = lease
            activeStreamID = streamID
            try configureCapture(lease, audioStream: audioStream)
            guard !plan.isCancelled else { throw CancellationError() }
        } catch {
            if let lease { cleanUpCapture(lease) }
            audioStream.finish()
            throw error
        }
    }

    public func startLevelTest() async throws -> AsyncThrowingStream<RecordingTelemetry, any Error>
    {
        guard lease == nil else { throw AudioCaptureError.alreadyRecording }
        try hardwareFactory.checkPermission()
        let lease = try microphones.acquire(microphones.prepareCapture(), purpose: .levelTest)
        self.lease = lease
        let (stream, continuation) = AsyncThrowingStream<RecordingTelemetry, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        previewContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopLevelTest(lease) }
        }
        do {
            try configureCapture(lease, audioStream: nil)
            let deadline = clock.monotonicNow + Self.maximumLevelTestDuration
            previewDeadline = Task { [weak self, clock] in
                let remaining = deadline - clock.monotonicNow
                if remaining > .zero {
                    do { try await clock.sleep(for: remaining) } catch { return }
                }
                await self?.stopLevelTest(lease)
            }
            return stream
        } catch {
            cleanUpCapture(lease)
            throw error
        }
    }

    public func stopLevelTest() async {
        guard let lease, lease.purpose == .levelTest else { return }
        cleanUpCapture(lease)
    }

    private func stopLevelTest(_ lease: MicrophoneCaptureLease) {
        guard lease.purpose == .levelTest else { return }
        cleanUpCapture(lease)
    }

    private func configureCapture(
        _ lease: MicrophoneCaptureLease,
        audioStream: BoundedAudioChunkStream?
    ) throws {
        let hardware = hardwareFactory.make()
        self.hardware = hardware
        activeRuntimeFailure = nil
        try hardware.start(deviceID: lease.device.deviceID, audioStream: audioStream) {
            [weak self] failure in
            await self?.reportRuntimeFailure(failure, lease: lease)
        }
        guard hardware.currentDeviceID == lease.device.deviceID,
            microphones.refreshAndValidate(lease), hardware.isRunning
        else { throw AudioCaptureError.microphoneSelectionFailed }
        latestEnvironmentSnapshot = hardware.environmentSnapshot
        recordingStartedAt = clock.monotonicNow
        microphones.markStarted(lease)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.reportRuntimeFailure(.deviceConfigurationChanged, lease: lease) }
        }
        let changes = microphones.observe()
        deviceObservation = Task { [weak self, microphones] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                guard microphones.isCurrent(lease), microphones.deviceIsAvailable(lease) else {
                    await self?.reportRuntimeFailure(.deviceConfigurationChanged, lease: lease)
                    return
                }
            }
        }
        meterTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: .milliseconds(50)) } catch { return }
                await self?.sampleMeters(lease)
            }
        }
    }

    public func stop() async throws -> CapturedAudio {
        guard let lease, lease.purpose == .voice, let hardware, let recordingStartedAt else {
            throw AudioCaptureError.noActiveRecording
        }
        sampleMeters(lease)
        let duration = clock.monotonicNow - recordingStartedAt
        let runtimeFailure = activeRuntimeFailure
        cleanUpCapture(lease)
        let metrics = hardware.metrics
        if let runtimeFailure { throw runtimeFailure }
        guard !metrics.didExhaustStreamBuffer else { throw AudioCaptureError.streamBufferExhausted }
        guard !metrics.didFailConversion else { throw AudioCaptureError.conversionFailed }
        try AudioCaptureQualityPolicy.validate(duration: duration, peakPower: metrics.peakPower)
        return CapturedAudio(data: Data(), duration: duration, peakPower: metrics.peakPower)
    }

    private func cancel(planID: UUID) {
        guard let lease, lease.planID == planID else { return }
        cleanUpCapture(lease)
    }

    public func cancel() async {
        if let lease { cleanUpCapture(lease) }
        pendingAudioStream?.finish()
        pendingAudioStream = nil
        pendingStreamID = nil
    }

    private func cleanUpCapture(
        _ lease: MicrophoneCaptureLease, previewFailure: AudioCaptureError? = nil
    ) {
        guard self.lease?.id == lease.id else { return }
        self.lease = nil
        meterTask?.cancel()
        meterTask = nil
        deviceObservation?.cancel()
        deviceObservation = nil
        previewDeadline?.cancel()
        previewDeadline = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        sleepObserver = nil
        hardware?.stop()
        hardware = nil
        activeStreamID = nil
        recordingStartedAt = nil
        activeRuntimeFailure = nil
        previewContinuation?.finish(throwing: previewFailure)
        previewContinuation = nil
        microphones.release(lease)
    }

    public func observeTelemetry() -> AsyncStream<RecordingTelemetry> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RecordingTelemetry>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        telemetryObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTelemetryObserver(id) }
        }
        return stream
    }

    public func observeFailures() -> AsyncStream<AudioCaptureError> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AudioCaptureError>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        failureObservers[id] = continuation
        if let activeRuntimeFailure { continuation.yield(activeRuntimeFailure) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeFailureObserver(id) }
        }
        return stream
    }

    public func captureEnvironmentSnapshot() -> AudioCaptureEnvironmentSnapshot? {
        latestEnvironmentSnapshot
    }

    private func sampleMeters(_ lease: MicrophoneCaptureLease) {
        guard self.lease?.id == lease.id, microphones.isCurrent(lease), let recordingStartedAt
        else {
            return
        }
        let power = hardware?.metrics.currentPower ?? -160
        let telemetry = RecordingTelemetry(
            elapsedMilliseconds: Self.milliseconds(clock.monotonicNow - recordingStartedAt),
            peakPower: power
        )
        if lease.purpose == .levelTest {
            previewContinuation?.yield(telemetry)
        } else {
            for continuation in telemetryObservers.values { continuation.yield(telemetry) }
        }
    }

    private func removeTelemetryObserver(_ id: UUID) { telemetryObservers[id] = nil }
    private func removeFailureObserver(_ id: UUID) { failureObservers[id] = nil }

    private func reportStreamFailure(_ failure: AudioCaptureError, id: UUID) {
        guard activeStreamID == id, let lease else { return }
        reportRuntimeFailure(failure, lease: lease)
    }

    private func reportRuntimeFailure(
        _ failure: AudioCaptureError,
        lease: MicrophoneCaptureLease
    ) {
        guard self.lease?.id == lease.id, microphones.isCurrent(lease),
            hardware != nil, activeRuntimeFailure == nil
        else { return }
        if lease.purpose == .levelTest {
            cleanUpCapture(lease, previewFailure: failure)
            return
        }
        activeRuntimeFailure = failure
        hardware?.stop()
        for continuation in failureObservers.values { continuation.yield(failure) }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(
            clamping: components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

package struct AudioCaptureHardwareMetrics: Sendable {
    package let currentPower: Float
    package let peakPower: Float
    package let didExhaustStreamBuffer: Bool
    package let didFailConversion: Bool

    package init(
        currentPower: Float, peakPower: Float, didExhaustStreamBuffer: Bool, didFailConversion: Bool
    ) {
        self.currentPower = currentPower
        self.peakPower = peakPower
        self.didExhaustStreamBuffer = didExhaustStreamBuffer
        self.didFailConversion = didFailConversion
    }
}

package protocol AudioCaptureHardware: AnyObject, Sendable {
    var currentDeviceID: UInt32 { get }
    var isRunning: Bool { get }
    var metrics: AudioCaptureHardwareMetrics { get }
    var environmentSnapshot: AudioCaptureEnvironmentSnapshot? { get }
    func start(
        deviceID: UInt32,
        audioStream: BoundedAudioChunkStream?,
        onFailure: @escaping @Sendable (AudioCaptureError) async -> Void
    ) throws
    func stop()
}

package struct AudioCaptureHardwareFactory: Sendable {
    package let checkPermission: @Sendable () throws -> Void
    package let make: @Sendable () -> any AudioCaptureHardware

    package init(
        checkPermission: @escaping @Sendable () throws -> Void,
        make: @escaping @Sendable () -> any AudioCaptureHardware
    ) {
        self.checkPermission = checkPermission
        self.make = make
    }

    package static let live = AudioCaptureHardwareFactory(
        checkPermission: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .denied, .restricted: throw AudioCaptureError.microphonePermissionDenied
            case .authorized, .notDetermined: break
            @unknown default: throw AudioCaptureError.couldNotPrepare
            }
        },
        make: { LiveAudioCaptureHardware() }
    )
}

// The owning capture actor serializes lifecycle calls; tap metrics synchronize separately.
private final class LiveAudioCaptureHardware: AudioCaptureHardware, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var bridge: PCMStreamingBridge?
    private var previewMeter: AudioCaptureLevelMeter?
    private var configurationObserver: NSObjectProtocol?
    private var hasTap = false
    private(set) var environmentSnapshot: AudioCaptureEnvironmentSnapshot?

    var currentDeviceID: UInt32 { engine.inputNode.auAudioUnit.deviceID }
    var isRunning: Bool { engine.isRunning }
    var metrics: AudioCaptureHardwareMetrics {
        if let bridge {
            let metrics = bridge.metrics()
            return AudioCaptureHardwareMetrics(
                currentPower: metrics.currentPower, peakPower: metrics.peakPower,
                didExhaustStreamBuffer: metrics.didExhaustStreamBuffer,
                didFailConversion: metrics.didFailConversion
            )
        }
        let power = previewMeter?.power ?? -160
        return AudioCaptureHardwareMetrics(
            currentPower: power, peakPower: power,
            didExhaustStreamBuffer: false, didFailConversion: false
        )
    }

    func start(
        deviceID: UInt32,
        audioStream: BoundedAudioChunkStream?,
        onFailure: @escaping @Sendable (AudioCaptureError) async -> Void
    ) throws {
        let input = engine.inputNode
        do { try input.auAudioUnit.setDeviceID(deviceID) } catch {
            throw AudioCaptureError.microphoneSelectionFailed
        }
        guard currentDeviceID == deviceID else { throw AudioCaptureError.microphoneSelectionFailed }
        // Binding precedes format, converter, and tap creation so no old route defines the graph.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.couldNotPrepare
        }
        if let audioStream {
            guard
                let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                    channels: 1, interleaved: true
                ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            else {
                throw AudioCaptureError.couldNotPrepare
            }
            let bridge = PCMStreamingBridge(
                converter: converter, outputFormat: outputFormat, audioStream: audioStream,
                onConversionFailure: { Task { await onFailure(.conversionFailed) } }
            )
            self.bridge = bridge
            input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
                bridge.consume(buffer)
            }
        } else {
            let meter = AudioCaptureLevelMeter()
            previewMeter = meter
            input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
                meter.consume(buffer)
            }
        }
        hasTap = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in Task { await onFailure(.deviceConfigurationChanged) } }
        do {
            engine.prepare()
            try engine.start()
        } catch { throw AudioCaptureError.couldNotStart }
        environmentSnapshot = AudioCaptureEnvironmentSnapshot(
            voiceProcessingRequested: false,
            voiceProcessingActive: input.isVoiceProcessingEnabled,
            voiceProcessingEnableFailure: nil,
            automaticGainControlEnabled: input.isVoiceProcessingAGCEnabled,
            preferredMicrophoneMode: Self.microphoneMode(AVCaptureDevice.preferredMicrophoneMode),
            activeMicrophoneMode: Self.microphoneMode(AVCaptureDevice.activeMicrophoneMode)
        )
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        bridge?.finish()
        previewMeter?.finish()
    }

    private static func microphoneMode(_ mode: AVCaptureDevice.MicrophoneMode)
        -> AudioCaptureMicrophoneMode
    {
        switch mode {
        case .standard: .standard
        case .wideSpectrum: .wideSpectrum
        case .voiceIsolation: .voiceIsolation
        @unknown default: .unknown
        }
    }
}

private final class AudioCaptureLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var currentPower: Float = -160
    private var isFinished = false

    var power: Float { lock.withLock { currentPower } }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let power = PCMStreamingBridge.power(of: buffer)
        lock.withLock {
            guard !isFinished else { return }
            currentPower = power
        }
    }

    func finish() { lock.withLock { isFinished = true } }
}

extension AVAudioCapture: AudioChunkStreaming {}

package enum AudioChunkYieldResult: Equatable, Sendable {
    case accepted
    case bufferExhausted
    case terminated
}

/// A bounded handoff between the real-time audio tap and async provider I/O.
/// Once exhausted it terminates rather than silently dropping part of an
/// utterance or allowing a stalled network path to grow memory indefinitely.
package final class BoundedAudioChunkStream: @unchecked Sendable {
    package let stream: AsyncStream<Data>

    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let onBufferExhausted: @Sendable () -> Void
    private var isFinished = false
    private var exhausted = false

    package init(
        maximumBufferedBytes: Int,
        nominalChunkSize: Int,
        onBufferExhausted: @escaping @Sendable () -> Void = {}
    ) {
        precondition(maximumBufferedBytes > 0)
        precondition(nominalChunkSize > 0)
        let chunkCapacity = max(1, maximumBufferedBytes / nominalChunkSize)
        let pair = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(chunkCapacity)
        )
        stream = pair.stream
        continuation = pair.continuation
        self.onBufferExhausted = onBufferExhausted
    }

    @discardableResult
    package func yield(_ chunk: Data) -> AudioChunkYieldResult {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return .terminated
        }
        switch continuation.yield(chunk) {
        case .enqueued:
            lock.unlock()
            return .accepted
        case .dropped:
            exhausted = true
            isFinished = true
            lock.unlock()
            continuation.finish()
            onBufferExhausted()
            return .bufferExhausted
        case .terminated:
            isFinished = true
            lock.unlock()
            return .terminated
        @unknown default:
            isFinished = true
            lock.unlock()
            continuation.finish()
            return .terminated
        }
    }

    package func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()
        continuation.finish()
    }

    package var didExhaustBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exhausted
    }
}

private final class PCMStreamingBridge: @unchecked Sendable {
    struct Metrics: Sendable {
        let currentPower: Float
        let peakPower: Float
        let didExhaustStreamBuffer: Bool
        let didFailConversion: Bool
    }

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let audioStream: BoundedAudioChunkStream
    private let onConversionFailure: @Sendable () -> Void
    private var chunkBuffer = PCMChunkBuffer(chunkSize: 6_400)
    private var currentPower: Float = -160
    private var peakPower: Float = -160
    private var didFailConversion = false
    private var isFinished = false

    init(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        audioStream: BoundedAudioChunkStream,
        onConversionFailure: @escaping @Sendable () -> Void
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.audioStream = audioStream
        self.onConversionFailure = onConversionFailure
    }

    /// The engine tap delivers buffers serially, so the converter and the
    /// chunk buffer are only ever touched from one thread at a time. The lock
    /// protects the metrics and the finished flag that `metrics()` and
    /// `finish()` read from other threads; format conversion happens outside
    /// it so a slow conversion never blocks a meter read.
    func consume(_ input: AVAudioPCMBuffer) {
        let power = Self.power(of: input)

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        currentPower = power
        peakPower = max(peakPower, power)
        lock.unlock()

        guard let converted = convert(input) else {
            lock.lock()
            didFailConversion = true
            lock.unlock()
            onConversionFailure()
            return
        }

        var chunks: [Data] = []
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        for data in converted {
            chunks.append(contentsOf: chunkBuffer.append(data))
        }
        lock.unlock()

        for chunk in chunks {
            guard audioStream.yield(chunk) == .accepted else { return }
        }
    }

    /// Converts one input buffer to the output format. Returns nil when the
    /// converter cannot produce output. Called only from the tap thread.
    private func convert(_ input: AVAudioPCMBuffer) -> [Data]? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            )
        else {
            return nil
        }

        // AVAudioConverter 在 convert 调用内同步执行输入闭包，不跨线程；
        // macOS 26 SDK 将该闭包标记为 @Sendable，这里显式豁免竞争检查。
        nonisolated(unsafe) var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil,
            status == .haveData || status == .inputRanDry,
            output.frameLength > 0
        else {
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        return buffers.compactMap { buffer in
            guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { return nil }
            return Data(bytes: bytes, count: Int(buffer.mDataByteSize))
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let remainder = chunkBuffer.finish()
        lock.unlock()

        if !remainder.isEmpty {
            audioStream.yield(remainder)
        }
        audioStream.finish()
    }

    func metrics() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        return Metrics(
            currentPower: currentPower,
            peakPower: peakPower,
            didExhaustStreamBuffer: audioStream.didExhaustBuffer,
            didFailConversion: didFailConversion
        )
    }

    fileprivate static func power(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -160 }
        var maximum: Float = 0

        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frames {
                    maximum = max(maximum, abs(channels[channel][frame]))
                }
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frames {
                    maximum = max(
                        maximum,
                        Float(abs(Int(channels[channel][frame]))) / Float(Int16.max)
                    )
                }
            }
        }
        guard maximum > 0 else { return -160 }
        return max(-160, 20 * log10f(maximum))
    }
}

package struct PCMChunkBuffer: Sendable {
    private let chunkSize: Int
    private var bufferedPCM = Data()

    package init(chunkSize: Int) {
        self.chunkSize = chunkSize
    }

    package mutating func append(_ data: Data) -> [Data] {
        bufferedPCM.append(data)
        var chunks: [Data] = []
        while bufferedPCM.count >= chunkSize {
            chunks.append(Data(bufferedPCM.prefix(chunkSize)))
            bufferedPCM.removeFirst(chunkSize)
        }
        return chunks
    }

    package mutating func finish() -> Data {
        defer { bufferedPCM.removeAll(keepingCapacity: false) }
        return Data(bufferedPCM)
    }
}

package struct ClipboardPasteboardAccess: Sendable {
    let changeCount: @MainActor @Sendable () -> Int
    let itemCount: @MainActor @Sendable () -> Int?
    let itemTypes: @MainActor @Sendable (Int) -> [String]?
    let data: @MainActor @Sendable (Int, String) -> Data?
    let clearContents: @MainActor @Sendable () -> Int
    let writeText: @MainActor @Sendable (String, String) -> Bool
    let readString: @MainActor @Sendable () -> String?
    let readMarker: @MainActor @Sendable () -> String?
    let writeItems: @MainActor @Sendable ([[String: Data]]) -> Bool

    package init(
        changeCount: @escaping @MainActor @Sendable () -> Int,
        itemCount: @escaping @MainActor @Sendable () -> Int?,
        itemTypes: @escaping @MainActor @Sendable (Int) -> [String]?,
        data: @escaping @MainActor @Sendable (Int, String) -> Data?,
        clearContents: @escaping @MainActor @Sendable () -> Int,
        writeText: @escaping @MainActor @Sendable (String, String) -> Bool,
        readString: @escaping @MainActor @Sendable () -> String?,
        readMarker: @escaping @MainActor @Sendable () -> String?,
        writeItems: @escaping @MainActor @Sendable ([[String: Data]]) -> Bool
    ) {
        self.changeCount = changeCount
        self.itemCount = itemCount
        self.itemTypes = itemTypes
        self.data = data
        self.clearContents = clearContents
        self.writeText = writeText
        self.readString = readString
        self.readMarker = readMarker
        self.writeItems = writeItems
    }

    package static let live = ClipboardPasteboardAccess(
        changeCount: { NSPasteboard.general.changeCount },
        itemCount: {
            NSPasteboard.general.pasteboardItems?.count
        },
        itemTypes: { itemIndex in
            let items = NSPasteboard.general.pasteboardItems ?? []
            guard items.indices.contains(itemIndex) else { return nil }
            return items[itemIndex].types.map(\.rawValue)
        },
        data: { itemIndex, type in
            let items = NSPasteboard.general.pasteboardItems ?? []
            guard items.indices.contains(itemIndex) else { return nil }
            return items[itemIndex].data(forType: .init(type))
        },
        clearContents: {
            NSPasteboard.general.clearContents()
        },
        writeText: { text, marker in
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string),
                item.setString(marker, forType: PasteboardTransactionMarker.type)
            else { return false }
            return NSPasteboard.general.writeObjects([item])
        },
        readString: {
            NSPasteboard.general.string(forType: .string)
        },
        readMarker: {
            NSPasteboard.general.string(forType: PasteboardTransactionMarker.type)
        },
        writeItems: { snapshots in
            let items = snapshots.compactMap { representations -> NSPasteboardItem? in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    guard item.setData(data, forType: .init(type)) else {
                        return nil
                    }
                }
                return item
            }
            guard items.count == snapshots.count else { return false }
            return NSPasteboard.general.writeObjects(items)
        }
    )
}

public struct SystemClipboardWriter: ClipboardWriting {
    private let pasteboard: ClipboardPasteboardAccess
    private let snapshotBudget: PasteboardSnapshotBudget

    public init() {
        pasteboard = .live
        snapshotBudget = .standard
    }

    package init(
        pasteboard: ClipboardPasteboardAccess,
        snapshotBudget: PasteboardSnapshotBudget = .standard
    ) {
        self.pasteboard = pasteboard
        self.snapshotBudget = snapshotBudget
    }

    public func copy(_ text: String) async -> Bool {
        await MainActor.run {
            guard
                let transaction = PasteboardReplacementTransaction.prepare(
                    text: text,
                    pasteboard: pasteboard,
                    budget: snapshotBudget
                )
            else { return false }
            guard transaction.verifies(text) else {
                transaction.restoreIfOwned()
                return false
            }
            return true
        }
    }
}

public actor MemorySessionHistory: SessionHistoryRecording {
    public private(set) var records: [VoiceInputHistoryRecord] = []

    public init() {}

    public func save(_ record: VoiceInputHistoryRecord) async {
        if let index = records.firstIndex(where: { $0.sessionID == record.sessionID }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }
}
