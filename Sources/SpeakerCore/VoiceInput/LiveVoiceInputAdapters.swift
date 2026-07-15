@preconcurrency import AVFoundation
import AppKit
import Foundation

public enum AudioCaptureError: Error, Equatable, Sendable {
    case alreadyRecording
    case couldNotPrepare
    case couldNotStart
    case noActiveRecording
    case tooShort
    case silent
}

public actor AVAudioCapture: AudioCapturing, AudioCaptureTelemetryProviding {
    private var engine: AVAudioEngine?
    private var bridge: PCMStreamingBridge?
    private var pendingAudioContinuation: AsyncStream<Data>.Continuation?
    private var recordingStartedAt: ContinuousClock.Instant?
    private var meterTask: Task<Void, Never>?
    private var telemetryObservers: [
        UUID: AsyncStream<RecordingTelemetry>.Continuation
    ] = [:]

    public init() {}

    public func audioChunks() -> AsyncStream<Data> {
        pendingAudioContinuation?.finish()
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .unbounded
        )
        pendingAudioContinuation = continuation
        return stream
    }

    public func start() async throws {
        guard engine == nil else {
            throw AudioCaptureError.alreadyRecording
        }
        guard let continuation = pendingAudioContinuation else {
            throw AudioCaptureError.couldNotPrepare
        }
        pendingAudioContinuation = nil

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
            continuation.finish()
            throw AudioCaptureError.couldNotPrepare
        }

        let bridge = PCMStreamingBridge(
            converter: converter,
            outputFormat: outputFormat,
            continuation: continuation
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
            continuation.finish()
            throw AudioCaptureError.couldNotStart
        }

        self.engine = engine
        self.bridge = bridge
        recordingStartedAt = .now
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
        self.engine = nil
        self.bridge = nil
        self.recordingStartedAt = nil

        guard duration >= .milliseconds(300) else {
            throw AudioCaptureError.tooShort
        }
        guard metrics.peakPower > -45 else {
            throw AudioCaptureError.silent
        }

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
        bridge?.finish()
        pendingAudioContinuation?.finish()
        engine = nil
        bridge = nil
        pendingAudioContinuation = nil
        recordingStartedAt = nil
    }

    public func observeTelemetry() -> AsyncStream<RecordingTelemetry> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RecordingTelemetry>.makeStream()
        telemetryObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTelemetryObserver(id) }
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

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(clamping:
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }
}

extension AVAudioCapture: AudioChunkStreaming {}

private final class PCMStreamingBridge: @unchecked Sendable {
    struct Metrics: Sendable {
        let currentPower: Float
        let peakPower: Float
    }

    private static let chunkSize = 6_400
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<Data>.Continuation
    private var bufferedPCM = Data()
    private var currentPower: Float = -160
    private var peakPower: Float = -160
    private var isFinished = false

    init(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        continuation: AsyncStream<Data>.Continuation
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.continuation = continuation
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
            lock.unlock()
            return
        }

        var suppliedInput = false
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
            lock.unlock()
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for buffer in buffers {
            guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            bufferedPCM.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
        }
        while bufferedPCM.count >= Self.chunkSize {
            chunks.append(bufferedPCM.subdata(in: 0..<Self.chunkSize))
            bufferedPCM.removeFirst(Self.chunkSize)
        }
        lock.unlock()

        for chunk in chunks {
            continuation.yield(chunk)
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let remainder = bufferedPCM
        bufferedPCM.removeAll(keepingCapacity: false)
        lock.unlock()

        if !remainder.isEmpty {
            continuation.yield(remainder)
        }
        continuation.finish()
    }

    func metrics() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        return Metrics(currentPower: currentPower, peakPower: peakPower)
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

public struct LocalPreviewTranscriber: SpeechTranscribing {
    private let text: String

    public init(text: String = "本地语音输入 tracer 已完成。") {
        self.text = text
    }

    public func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        TranscriptionResult(text: text, providerRequestID: "local-preview")
    }
}

public struct SystemClipboardWriter: ClipboardWriting {
    public init() {}

    public func copy(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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
