import AVFoundation
import Foundation
import Speech

public enum OnDeviceSpeechModelStatus: Equatable, Sendable {
    /// This Mac runs a macOS release without SpeechAnalyzer, or has no supported language.
    case unsupported
    case notInstalled
    case installed
}

/// Transcribes 16 kHz mono Int16 PCM on this Mac. Audio never leaves the device.
public protocol OnDeviceSpeechRecognizing: Sendable {
    func modelStatus() async -> OnDeviceSpeechModelStatus
    /// Downloads the system language model. `progress` receives values from 0 to 1.
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Consumes `chunks` while recording, waits for `completion`, then returns the final text.
    func transcribe(
        _ chunks: AsyncStream<Data>, completion: AudioCaptureCompletionGate?
    ) async throws -> String
}

/// Apple SpeechAnalyzer with SpeechTranscriber, available on macOS 26 and later.
/// The language follows the first supported entry in the user's preferred languages.
public struct AppleSpeechRecognizer: OnDeviceSpeechRecognizing {
    public init() {}

    /// Whether this Mac can offer on-device recognition at all. Checked synchronously
    /// so settings can hide the option on earlier macOS releases.
    public static var isSupported: Bool {
        guard #available(macOS 26, *) else { return false }
        return SpeechTranscriber.isAvailable
    }

    public func modelStatus() async -> OnDeviceSpeechModelStatus {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
            let locale = await Self.locale()
        else { return .unsupported }
        return await Self.isInstalled(locale) ? .installed : .notInstalled
    }

    public func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26, *), let locale = await Self.locale() else {
            throw Self.unavailable
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        guard
            let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        else {
            progress(1)
            return
        }
        let monitor = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    public func transcribe(
        _ chunks: AsyncStream<Data>, completion: AudioCaptureCompletionGate?
    ) async throws -> String {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
            let locale = await Self.locale(), await Self.isInstalled(locale)
        else { throw Self.unavailable }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
            let source = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                interleaved: true)
        else { throw Self.unavailable }
        let converter =
            format == source ? nil : AVAudioConverter(from: source, to: format)
        if format != source, converter == nil { throw Self.unavailable }
        let analyzer = SpeechAnalyzer(modules: [module])
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task {
            try await module.results.reduce(into: "") { $0 += String($1.text.characters) }
        }
        return try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputSequence: input)
                var carry: UInt8?
                for await chunk in chunks {
                    try Task.checkCancellation()
                    var bytes = Data(chunk)
                    if let carry { bytes.insert(carry, at: 0) }
                    carry = bytes.count.isMultiple(of: 2) ? nil : bytes.removeLast()
                    guard !bytes.isEmpty else { continue }
                    let buffer = try Self.buffer(bytes, format: source)
                    continuation.yield(
                        AnalyzerInput(
                            buffer: try converter.map { try Self.convert(buffer, $0) }
                                ?? buffer))
                }
                try Task.checkCancellation()
                try await completion?.wait()
                continuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let text = try await results.value
                try Task.checkCancellation()
                return Self.normalizedSpacing(text)
            } catch {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                results.cancel()
                throw error
            }
        } onCancel: {
            continuation.finish()
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// SpeechTranscriber separates Latin words and digits from Chinese with spaces
    /// ("下午 3点", "Swift和 GitHub"). Chinese text does not use those spaces, so they
    /// are removed wherever either neighbour is a CJK character or punctuation mark.
    package static func normalizedSpacing(_ text: String) -> String {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var result = ""
        for (index, character) in characters.enumerated() {
            if character == " ", index > 0, index + 1 < characters.count,
                isCJK(characters[index - 1]) || isCJK(characters[index + 1])
            {
                continue
            }
            result.append(character)
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            switch $0.value {
            case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                0xFF00...0xFFEF, 0x20000...0x2FA1F:
                true
            default: false
            }
        }
    }

    private static let unavailable = SpeechRecognitionFailure(
        provider: .apple, kind: .onDeviceModelUnavailable)

    @available(macOS 26, *)
    private static func locale() async -> Locale? {
        for identifier in Locale.preferredLanguages {
            if let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier))
            {
                return locale
            }
        }
        return await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "zh-CN"))
    }

    @available(macOS 26, *)
    private static func isInstalled(_ locale: Locale) async -> Bool {
        let target = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47) == target
        }
    }

    private static func buffer(_ bytes: Data, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(bytes.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let channel = buffer.int16ChannelData
        else { throw SpeechRecognitionFailure(provider: .apple, kind: .invalidAudio) }
        buffer.frameLength = frames
        bytes.withUnsafeBytes { raw in
            _ = memcpy(channel[0], raw.baseAddress!, bytes.count)
        }
        return buffer
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { throw SpeechRecognitionFailure(provider: .apple, kind: .invalidAudio) }
        // The converter calls this block synchronously, before `convert` returns.
        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if error != nil {
            throw SpeechRecognitionFailure(provider: .apple, kind: .invalidAudio)
        }
        return output
    }
}
