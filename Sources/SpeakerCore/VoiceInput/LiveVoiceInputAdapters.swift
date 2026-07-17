@preconcurrency import AVFoundation
import AppKit
import Foundation

public enum AudioCaptureError: Error, Equatable, Sendable {
    case alreadyRecording
    case couldNotPrepare
    case couldNotStart
    case microphonePermissionDenied
    case noActiveRecording
    case tooShort
    case silent
    case streamBufferExhausted
    case conversionFailed
    case deviceConfigurationChanged
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
    AudioCaptureFailureProviding {
    /// Caps audio waiting to be consumed by the provider transport. This is a
    /// memory/resource boundary, not a deadline: healthy consumers keep the
    /// buffer close to empty regardless of recording duration.
    package static let maximumBufferedAudioBytes = 1_024_000

    private var engine: AVAudioEngine?
    private var bridge: PCMStreamingBridge?
    private var pendingAudioStream: BoundedAudioChunkStream?
    private var recordingStartedAt: ContinuousClock.Instant?
    private var meterTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var activeRuntimeFailure: AudioCaptureError?
    private var telemetryObservers: [
        UUID: AsyncStream<RecordingTelemetry>.Continuation
    ] = [:]
    private var failureObservers: [
        UUID: AsyncStream<AudioCaptureError>.Continuation
    ] = [:]

    public init() {}

    public func audioChunks() -> AsyncStream<Data> {
        pendingAudioStream?.finish()
        let audioStream = BoundedAudioChunkStream(
            maximumBufferedBytes: Self.maximumBufferedAudioBytes,
            nominalChunkSize: 6_400,
            onBufferExhausted: { [weak self] in
                Task { await self?.reportRuntimeFailure(.streamBufferExhausted) }
            }
        )
        pendingAudioStream = audioStream
        return audioStream.stream
    }

    public func start() async throws {
        guard engine == nil else {
            throw AudioCaptureError.alreadyRecording
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw AudioCaptureError.microphonePermissionDenied
        case .authorized, .notDetermined:
            break
        @unknown default:
            throw AudioCaptureError.couldNotPrepare
        }
        guard let audioStream = pendingAudioStream else {
            throw AudioCaptureError.couldNotPrepare
        }
        pendingAudioStream = nil

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            audioStream.finish()
            throw AudioCaptureError.couldNotPrepare
        }

        let bridge = PCMStreamingBridge(
            converter: converter,
            outputFormat: outputFormat,
            audioStream: audioStream,
            onConversionFailure: { [weak self] in
                Task { await self?.reportRuntimeFailure(.conversionFailed) }
            }
        )
        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat
        ) { buffer, _ in
            bridge.consume(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioStream.finish()
            throw AudioCaptureError.couldNotStart
        }

        self.engine = engine
        self.bridge = bridge
        activeRuntimeFailure = nil
        recordingStartedAt = .now
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.reportRuntimeFailure(.deviceConfigurationChanged)
            }
        }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                await self?.sampleMeters()
            }
        }
    }

    public func stop() async throws -> CapturedAudio {
        guard let engine, let bridge, let recordingStartedAt else {
            throw AudioCaptureError.noActiveRecording
        }

        meterTask?.cancel()
        meterTask = nil
        sampleMeters()
        let duration = recordingStartedAt.duration(to: .now)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        bridge.finish()
        let metrics = bridge.metrics()
        removeConfigurationObserver()
        let runtimeFailure = activeRuntimeFailure
        self.engine = nil
        self.bridge = nil
        self.recordingStartedAt = nil
        activeRuntimeFailure = nil

        if let runtimeFailure { throw runtimeFailure }
        guard !metrics.didExhaustStreamBuffer else {
            throw AudioCaptureError.streamBufferExhausted
        }
        guard !metrics.didFailConversion else {
            throw AudioCaptureError.conversionFailed
        }
        try AudioCaptureQualityPolicy.validate(
            duration: duration,
            peakPower: metrics.peakPower
        )

        return CapturedAudio(
            data: Data(),
            duration: duration,
            peakPower: metrics.peakPower
        )
    }

    public func cancel() async {
        meterTask?.cancel()
        meterTask = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        removeConfigurationObserver()
        bridge?.finish()
        pendingAudioStream?.finish()
        engine = nil
        bridge = nil
        pendingAudioStream = nil
        recordingStartedAt = nil
        activeRuntimeFailure = nil
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
        if let activeRuntimeFailure {
            continuation.yield(activeRuntimeFailure)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeFailureObserver(id) }
        }
        return stream
    }

    private func sampleMeters() {
        guard let bridge, let recordingStartedAt else { return }
        let metrics = bridge.metrics()
        let telemetry = RecordingTelemetry(
            elapsedMilliseconds: Self.milliseconds(recordingStartedAt.duration(to: .now)),
            peakPower: metrics.currentPower
        )
        for continuation in telemetryObservers.values {
            continuation.yield(telemetry)
        }
    }

    private func removeTelemetryObserver(_ id: UUID) {
        telemetryObservers[id] = nil
    }

    private func removeFailureObserver(_ id: UUID) {
        failureObservers[id] = nil
    }

    private func reportRuntimeFailure(_ failure: AudioCaptureError) {
        guard engine != nil, activeRuntimeFailure == nil else { return }
        activeRuntimeFailure = failure
        engine?.stop()
        bridge?.finish()
        for continuation in failureObservers.values {
            continuation.yield(failure)
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(clamping:
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }
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

    func consume(_ input: AVAudioPCMBuffer) {
        let power = Self.power(of: input)
        var chunks: [Data] = []

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        currentPower = power
        peakPower = max(peakPower, power)

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            didFailConversion = true
            lock.unlock()
            onConversionFailure()
            return
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
            didFailConversion = true
            lock.unlock()
            onConversionFailure()
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for buffer in buffers {
            guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let converted = Data(bytes: bytes, count: Int(buffer.mDataByteSize))
            chunks.append(contentsOf: chunkBuffer.append(converted))
        }
        lock.unlock()

        for chunk in chunks {
            guard audioStream.yield(chunk) == .accepted else { return }
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

    private static func power(of buffer: AVAudioPCMBuffer) -> Float {
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

public struct LocalPreviewTranscriber: SpeechTranscribing {
    private let text: String

    public init(text: String = "本地语音输入 tracer 已完成。") {
        self.text = text
    }

    public func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        TranscriptionResult(text: text, providerRequestID: "local-preview")
    }
}

package struct ClipboardPasteboardAccess: Sendable {
    let clearContents: @MainActor @Sendable () -> Void
    let setString: @MainActor @Sendable (String) -> Bool
    let readString: @MainActor @Sendable () -> String?

    package init(
        clearContents: @escaping @MainActor @Sendable () -> Void,
        setString: @escaping @MainActor @Sendable (String) -> Bool,
        readString: @escaping @MainActor @Sendable () -> String?
    ) {
        self.clearContents = clearContents
        self.setString = setString
        self.readString = readString
    }

    static let live = ClipboardPasteboardAccess(
        clearContents: {
            NSPasteboard.general.clearContents()
        },
        setString: {
            NSPasteboard.general.setString($0, forType: .string)
        },
        readString: {
            NSPasteboard.general.string(forType: .string)
        }
    )
}

public struct SystemClipboardWriter: ClipboardWriting {
    private let pasteboard: ClipboardPasteboardAccess

    public init() {
        pasteboard = .live
    }

    package init(pasteboard: ClipboardPasteboardAccess) {
        self.pasteboard = pasteboard
    }

    public func copy(_ text: String) async -> Bool {
        await MainActor.run {
            pasteboard.clearContents()
            guard pasteboard.setString(text) else { return false }
            return pasteboard.readString() == text
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
