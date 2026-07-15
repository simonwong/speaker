import Foundation

public struct VoiceTextProcessingSnapshot: Equatable, Sendable {
    public let dictionary: PersonalDictionarySnapshot
    public let dictionaryContext: DictionaryRequestContext
    public let refinementMode: TextRefinementMode

    public init(
        dictionary: PersonalDictionarySnapshot,
        dictionaryContext: DictionaryRequestContext,
        refinementMode: TextRefinementMode
    ) {
        self.dictionary = dictionary
        self.dictionaryContext = dictionaryContext
        self.refinementMode = refinementMode
    }

    public static let empty = {
        let dictionary = PersonalDictionarySnapshot(entries: [])
        return VoiceTextProcessingSnapshot(
            dictionary: dictionary,
            dictionaryContext: DictionaryRequestContextBuilder.makeContext(from: dictionary),
            refinementMode: .defaultSmooth
        )
    }()
}

public struct VoiceTextProcessingResult: Equatable, Sendable {
    public let doubaoText: String
    public let normalizedText: String
    public let deepSeekText: String?
    public let finalText: String
    public let doubaoRequestID: String?
    public let deepSeekRequestID: String?
    public let refinementStatus: DeepSeekRefinementStatus
    public let refinementFailure: DeepSeekRefinementFailure?
    public let dictionaryReplacements: [DictionaryReplacement]
    public let stageDurationsMilliseconds: [String: Int]

    public init(
        doubaoText: String,
        normalizedText: String,
        deepSeekText: String?,
        finalText: String,
        doubaoRequestID: String?,
        deepSeekRequestID: String?,
        refinementStatus: DeepSeekRefinementStatus,
        refinementFailure: DeepSeekRefinementFailure?,
        dictionaryReplacements: [DictionaryReplacement],
        stageDurationsMilliseconds: [String: Int] = [:]
    ) {
        self.doubaoText = doubaoText
        self.normalizedText = normalizedText
        self.deepSeekText = deepSeekText
        self.finalText = finalText
        self.doubaoRequestID = doubaoRequestID
        self.deepSeekRequestID = deepSeekRequestID
        self.refinementStatus = refinementStatus
        self.refinementFailure = refinementFailure
        self.dictionaryReplacements = dictionaryReplacements
        self.stageDurationsMilliseconds = stageDurationsMilliseconds
    }
}

public protocol VoiceTextProcessing: Sendable {
    func captureSnapshot() async -> VoiceTextProcessingSnapshot
    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot
    ) async throws -> VoiceTextProcessingResult
}

public protocol ContextualSpeechTranscribing: SpeechTranscribing {
    func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult
}

public actor VoiceInputConfigurationController {
    private var dictionary: PersonalDictionary
    private var refinementMode: TextRefinementMode

    public init(
        dictionary: PersonalDictionary = .empty,
        refinementMode: TextRefinementMode = .defaultSmooth
    ) {
        self.dictionary = dictionary
        self.refinementMode = refinementMode
    }

    public func captureSnapshot() -> VoiceTextProcessingSnapshot {
        let dictionarySnapshot = dictionary.snapshotEnabled()
        return VoiceTextProcessingSnapshot(
            dictionary: dictionarySnapshot,
            dictionaryContext: DictionaryRequestContextBuilder.makeContext(from: dictionarySnapshot),
            refinementMode: refinementMode
        )
    }

    public func currentDictionary() -> PersonalDictionary { dictionary }

    public func replaceDictionary(_ dictionary: PersonalDictionary) {
        self.dictionary = dictionary
    }

    public func currentRefinementMode() -> TextRefinementMode { refinementMode }

    public func selectRefinementMode(_ mode: TextRefinementMode) throws {
        refinementMode = try mode.validated()
    }
}

public actor DefaultVoiceTextProcessor: VoiceTextProcessing {
    private let configuration: VoiceInputConfigurationController
    private let doubao: any ContextualSpeechTranscribing
    private let refinement: OptionalTextRefinementPipeline

    public init(
        configuration: VoiceInputConfigurationController,
        doubao: any ContextualSpeechTranscribing,
        refinement: OptionalTextRefinementPipeline
    ) {
        self.configuration = configuration
        self.doubao = doubao
        self.refinement = refinement
    }

    public func captureSnapshot() async -> VoiceTextProcessingSnapshot {
        await configuration.captureSnapshot()
    }

    public func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot
    ) async throws -> VoiceTextProcessingResult {
        let clock = ContinuousClock()
        let doubaoStarted = clock.now
        let doubaoResult = try await doubao.transcribe(
            audio,
            hotwords: snapshot.dictionaryContext.hotwords,
            context: nil
        )
        let doubaoDuration = doubaoStarted.duration(to: clock.now)
        let normalization = DictionaryAliasNormalizer.normalize(
            doubaoResult.text,
            using: snapshot.dictionary
        )
        let refinementStarted = clock.now
        let refinementOutcome = await refinement.refine(
            doubaoText: normalization.normalizedText,
            mode: snapshot.refinementMode
        )
        let refinementDuration = refinementStarted.duration(to: clock.now)

        return VoiceTextProcessingResult(
            doubaoText: doubaoResult.text,
            normalizedText: normalization.normalizedText,
            deepSeekText: refinementOutcome.deepSeekText,
            finalText: refinementOutcome.finalText,
            doubaoRequestID: doubaoResult.providerRequestID,
            deepSeekRequestID: refinementOutcome.providerRequestID,
            refinementStatus: refinementOutcome.status,
            refinementFailure: refinementOutcome.failure,
            dictionaryReplacements: normalization.replacements,
            stageDurationsMilliseconds: [
                "recording": Self.milliseconds(audio.duration),
                "doubao": Self.milliseconds(doubaoDuration),
                "deepseek": snapshot.refinementMode.requiresDeepSeek
                    ? Self.milliseconds(refinementDuration)
                    : 0,
            ]
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let millisecondsFromSeconds = components.seconds * 1_000
        let millisecondsFromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: millisecondsFromSeconds + millisecondsFromAttoseconds)
    }
}

struct BasicVoiceTextProcessor: VoiceTextProcessing {
    let transcriber: any SpeechTranscribing

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot
    ) async throws -> VoiceTextProcessingResult {
        let result = try await transcriber.transcribe(audio)
        return VoiceTextProcessingResult(
            doubaoText: result.text,
            normalizedText: result.text,
            deepSeekText: nil,
            finalText: result.text,
            doubaoRequestID: result.providerRequestID,
            deepSeekRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil,
            dictionaryReplacements: [],
            stageDurationsMilliseconds: [
                "recording": Self.milliseconds(audio.duration)
            ]
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(clamping:
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }
}
