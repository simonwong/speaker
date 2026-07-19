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
        self.stageDurationsMilliseconds = stageDurationsMilliseconds
    }
}

public struct VoiceTextProcessingProgress: Equatable, Sendable {
    public let stage: VoiceInputProcessingStage
    public let confirmedDoubaoResult: TranscriptionResult?

    public init(
        stage: VoiceInputProcessingStage,
        confirmedDoubaoResult: TranscriptionResult? = nil
    ) {
        self.stage = stage
        self.confirmedDoubaoResult = confirmedDoubaoResult
    }
}

public struct VoiceTextProcessingFailure: Error, Equatable, Sendable {
    public let problem: VoiceInputProblem

    public var userFailure: VoiceInputFailure { problem.failure }
    public var providerDiagnostic: VoiceProviderDiagnostic? { problem.diagnostic }

    public init(
        userFailure: VoiceInputFailure,
        providerDiagnostic: VoiceProviderDiagnostic? = nil
    ) {
        problem = VoiceInputProblem(
            failure: userFailure,
            diagnostic: providerDiagnostic
        )
    }

    init(doubaoFailure: DoubaoASRFailure) {
        problem = VoiceInputProblem(doubaoFailure: doubaoFailure)
    }

    init(doubaoCredentialFailure: ProviderCredentialStoreError) {
        problem = VoiceInputProblem(doubaoCredentialFailure: doubaoCredentialFailure)
    }
}

public protocol VoiceTextProcessing: Sendable {
    func captureSnapshot() async -> VoiceTextProcessingSnapshot
    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult
}

public protocol ContextualSpeechTranscribing: SpeechTranscribing {
    func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String]
    ) async throws -> TranscriptionResult
}

public protocol StreamingContextualSpeechTranscribing: Sendable {
    func transcribe(
        _ audioChunks: AsyncStream<Data>,
        hotwords: [String]
    ) async throws -> TranscriptionResult
}

public protocol StreamingVoiceTextProcessing: Sendable {
    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult
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
        let dictionarySnapshot = dictionary.snapshot()
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
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        let clock = ContinuousClock()
        let doubaoStarted = clock.now
        let doubaoResult: TranscriptionResult
        do {
            doubaoResult = try await doubao.transcribe(
                audio,
                hotwords: snapshot.dictionaryContext.hotwords
            )
        } catch let failure as DoubaoASRFailure {
            throw VoiceTextProcessingFailure(doubaoFailure: failure)
        } catch let failure as ProviderCredentialStoreError {
            throw VoiceTextProcessingFailure(doubaoCredentialFailure: failure)
        }
        let doubaoDuration = doubaoStarted.duration(to: clock.now)
        return try await finishProcessing(
            doubaoResult,
            snapshot: snapshot,
            recordingDuration: audio.duration,
            doubaoDuration: doubaoDuration,
            progress: progress
        )
    }

    public func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        guard let streamingDoubao = doubao as? any StreamingContextualSpeechTranscribing else {
            throw VoiceTextProcessingFailure(
                userFailure: .transcriptionFailed,
                providerDiagnostic: .init(provider: "doubao", code: "streamingUnavailable")
            )
        }
        let clock = ContinuousClock()
        let doubaoStarted = clock.now
        let doubaoResult: TranscriptionResult
        do {
            doubaoResult = try await streamingDoubao.transcribe(
                audioChunks,
                hotwords: snapshot.dictionaryContext.hotwords
            )
        } catch let failure as DoubaoASRFailure {
            throw VoiceTextProcessingFailure(doubaoFailure: failure)
        } catch let failure as ProviderCredentialStoreError {
            throw VoiceTextProcessingFailure(doubaoCredentialFailure: failure)
        }
        let doubaoDuration = doubaoStarted.duration(to: clock.now)
        return try await finishProcessing(
            doubaoResult,
            snapshot: snapshot,
            recordingDuration: nil,
            doubaoDuration: doubaoDuration,
            progress: progress
        )
    }

    private func finishProcessing(
        _ doubaoResult: TranscriptionResult,
        snapshot: VoiceTextProcessingSnapshot,
        recordingDuration: Duration?,
        doubaoDuration: Duration,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        if snapshot.refinementMode.requiresDeepSeek {
            await progress(.init(
                stage: .refining,
                confirmedDoubaoResult: doubaoResult
            ))
        }
        let refinementStarted = ContinuousClock.now
        let refinementOutcome = try await refinement.refine(
            doubaoText: doubaoResult.text,
            mode: snapshot.refinementMode
        )
        let refinementDuration = refinementStarted.duration(to: .now)

        var stageDurations = [
            "doubao": Self.milliseconds(doubaoDuration),
            "deepseek": snapshot.refinementMode.requiresDeepSeek
                ? Self.milliseconds(refinementDuration)
                : 0,
        ]
        if let recordingDuration {
            stageDurations["recording"] = Self.milliseconds(recordingDuration)
        }
        return VoiceTextProcessingResult(
            doubaoText: doubaoResult.text,
            normalizedText: doubaoResult.text,
            deepSeekText: refinementOutcome.deepSeekText,
            finalText: refinementOutcome.finalText,
            doubaoRequestID: doubaoResult.providerRequestID,
            deepSeekRequestID: refinementOutcome.providerRequestID,
            refinementStatus: refinementOutcome.status,
            refinementFailure: refinementOutcome.failure,
            stageDurationsMilliseconds: stageDurations
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let millisecondsFromSeconds = components.seconds * 1_000
        let millisecondsFromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: millisecondsFromSeconds + millisecondsFromAttoseconds)
    }
}

extension DefaultVoiceTextProcessor: StreamingVoiceTextProcessing {}

struct BasicVoiceTextProcessor: VoiceTextProcessing {
    let transcriber: any SpeechTranscribing

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        let result: TranscriptionResult
        do {
            result = try await transcriber.transcribe(audio)
        } catch let failure as DoubaoASRFailure {
            throw VoiceTextProcessingFailure(doubaoFailure: failure)
        } catch let failure as ProviderCredentialStoreError {
            throw VoiceTextProcessingFailure(doubaoCredentialFailure: failure)
        }
        return VoiceTextProcessingResult(
            doubaoText: result.text,
            normalizedText: result.text,
            deepSeekText: nil,
            finalText: result.text,
            doubaoRequestID: result.providerRequestID,
            deepSeekRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil,
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

extension ProviderCredentialStoreError {
    var diagnosticCode: String {
        switch self {
        case .emptyAPIKey: "emptyAPIKey"
        case .apiKeyTooLarge: "apiKeyTooLarge"
        case .accessDenied: "accessDenied"
        case .interactionUnavailable: "interactionUnavailable"
        case .malformedStoredValue: "malformedStoredValue"
        case .conflictingStoredValues: "conflictingStoredValues"
        case .storageUnavailable: "storageUnavailable"
        }
    }
}
