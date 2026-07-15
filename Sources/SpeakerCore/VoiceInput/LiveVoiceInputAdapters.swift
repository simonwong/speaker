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

public actor AVAudioCapture: AudioCapturing {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTask: Task<Void, Never>?
    private var peakPower: Float = -160

    public init() {}

    public func start() async throws {
        guard recorder == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.couldNotPrepare
        }
        guard recorder.record() else {
            recorder.deleteRecording()
            throw AudioCaptureError.couldNotStart
        }

        self.recorder = recorder
        recordingURL = url
        peakPower = -160
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                await self?.sampleMeters()
            }
        }
    }

    public func stop() async throws -> CapturedAudio {
        guard let recorder, let recordingURL else {
            throw AudioCaptureError.noActiveRecording
        }

        meterTask?.cancel()
        meterTask = nil
        sampleMeters()
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.recordingURL = nil

        defer {
            try? FileManager.default.removeItem(at: recordingURL)
        }

        guard duration >= 0.3 else {
            throw AudioCaptureError.tooShort
        }
        guard peakPower > -45 else {
            throw AudioCaptureError.silent
        }

        return CapturedAudio(
            data: try Data(contentsOf: recordingURL),
            duration: .seconds(duration),
            peakPower: peakPower
        )
    }

    public func cancel() async {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder?.deleteRecording()
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recorder = nil
        recordingURL = nil
        peakPower = -160
    }

    private func sampleMeters() {
        guard let recorder else { return }
        recorder.updateMeters()
        peakPower = max(peakPower, recorder.peakPower(forChannel: 0))
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
        records.append(record)
    }
}
