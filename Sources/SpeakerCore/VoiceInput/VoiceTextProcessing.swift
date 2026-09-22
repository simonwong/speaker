import Foundation

public struct VoiceTextProcessingSnapshot: Equatable, Sendable {
    public let dictionary: PersonalDictionarySnapshot
    public let dictionaryContext: DictionaryRequestContext
    public let refinementMode: TextRefinementMode
    public let refinementProvider: RefinementProviderProfile
    public let recognitionProvider: SpeechRecognitionProfile

    public init(
        dictionary: PersonalDictionarySnapshot,
        dictionaryContext: DictionaryRequestContext,
        refinementMode: TextRefinementMode,
        refinementProvider: RefinementProviderProfile = .legacyDeepSeek,
        recognitionProvider: SpeechRecognitionProfile = .doubao
    ) {
        self.dictionary = dictionary
        self.dictionaryContext = dictionaryContext
        self.refinementMode = refinementMode
        self.refinementProvider = refinementProvider
        self.recognitionProvider = recognitionProvider
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
    public let refinementStatus: TextRefinementStatus
    public let refinementFailure: TextRefinementFailure?
    public let stageDurationsMilliseconds: [String: Int]

    public init(
        doubaoText: String,
        normalizedText: String,
        deepSeekText: String?,
        finalText: String,
        doubaoRequestID: String?,
        deepSeekRequestID: String?,
        refinementStatus: TextRefinementStatus,
        refinementFailure: TextRefinementFailure?,
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

public enum SpeechTranscriptionPurpose: Equatable, Sendable {
    case defaultSmoothing
    case refinementSource
}

public struct SpeechTranscriptionContext: Equatable, Sendable {
    public let hotwords: [String]
    public let purpose: SpeechTranscriptionPurpose
    public let recognitionProvider: SpeechRecognitionProfile
    public let audioCaptureCompletion: AudioCaptureCompletionGate?

    public init(
        hotwords: [String],
        purpose: SpeechTranscriptionPurpose,
        recognitionProvider: SpeechRecognitionProfile = .doubao,
        audioCaptureCompletion: AudioCaptureCompletionGate? = nil
    ) {
        self.hotwords = hotwords
        self.purpose = purpose
        self.recognitionProvider = recognitionProvider
        self.audioCaptureCompletion = audioCaptureCompletion
    }
}

public protocol ContextualSpeechTranscribing: SpeechTranscribing {
    func transcribe(
        _ audio: CapturedAudio,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult
}

public protocol StreamingContextualSpeechTranscribing: Sendable {
    func transcribe(
        _ audioChunks: AsyncStream<Data>,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult
}

public protocol StreamingVoiceTextProcessing: Sendable {
    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        audioCaptureCompletion: AudioCaptureCompletionGate,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult

}

extension StreamingVoiceTextProcessing {
    public func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        audioCaptureCompletion: AudioCaptureCompletionGate,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        try await processStreaming(audioChunks, snapshot: snapshot, progress: progress)
    }
}

public actor VoiceInputConfigurationController {
    private var dictionary: PersonalDictionary
    private var refinementMode: TextRefinementMode
    private var refinementProvider: RefinementProviderProfile
    private var recognitionProvider: SpeechRecognitionProfile

    public init(
        dictionary: PersonalDictionary = .empty,
        refinementMode: TextRefinementMode = .defaultSmooth,
        refinementProvider: RefinementProviderProfile = .legacyDeepSeek,
        recognitionProvider: SpeechRecognitionProfile = .doubao
    ) {
        self.dictionary = dictionary
        self.refinementMode = refinementMode
        self.refinementProvider = refinementProvider
        self.recognitionProvider = recognitionProvider
    }

    public func captureSnapshot() -> VoiceTextProcessingSnapshot {
        let dictionarySnapshot = dictionary.snapshot()
        return VoiceTextProcessingSnapshot(
            dictionary: dictionarySnapshot,
            dictionaryContext: DictionaryRequestContextBuilder.makeContext(
                from: dictionarySnapshot),
            refinementMode: refinementMode,
            refinementProvider: refinementProvider,
            recognitionProvider: recognitionProvider
        )
    }

    public func currentDictionary() -> PersonalDictionary { dictionary }

    public func replaceDictionary(_ dictionary: PersonalDictionary) {
        self.dictionary = dictionary
    }

    public func selectRefinementProvider(
        _ profile: RefinementProviderProfile, mode: TextRefinementMode
    ) throws {
        let validatedProfile = try profile.validated()
        let validatedMode = try mode.validated()
        refinementProvider = validatedProfile
        refinementMode = validatedMode
    }

    public func restoreRecognitionProvider(_ profile: SpeechRecognitionProfile) {
        recognitionProvider = profile
    }

    public func selectRecognitionProvider(_ profile: SpeechRecognitionProfile) throws {
        recognitionProvider = try profile.validated()
    }

    public func currentRefinementMode() -> TextRefinementMode { refinementMode }

    public func selectRefinementMode(_ mode: TextRefinementMode) throws {
        refinementMode = try mode.validated()
    }
}

public actor DefaultVoiceTextProcessor: VoiceTextProcessing {
    private let configuration: VoiceInputConfigurationController
    private let transcriber: any ContextualSpeechTranscribing
    private let refinement: OptionalTextRefinementPipeline

    public init(
        configuration: VoiceInputConfigurationController,
        transcriber: any ContextualSpeechTranscribing,
        refinement: OptionalTextRefinementPipeline
    ) {
        self.configuration = configuration
        self.transcriber = transcriber
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
        let transcriptionStarted = clock.now
        let transcriptionResult: TranscriptionResult
        do {
            transcriptionResult = try await transcriber.transcribe(
                audio,
                context: Self.transcriptionContext(for: snapshot)
            )
        } catch let failure as SpeechRecognitionFailure {
            throw VoiceTextProcessingFailure(
                userFailure: failure.userFailure,
                providerDiagnostic: failure.providerDiagnostic
            )
        } catch let failure as DoubaoASRFailure {
            throw VoiceTextProcessingFailure(doubaoFailure: failure)
        } catch let failure as ProviderCredentialStoreError {
            throw VoiceTextProcessingFailure(doubaoCredentialFailure: failure)
        }
        let transcriptionDuration = transcriptionStarted.duration(to: clock.now)
        return try await finishProcessing(
            transcriptionResult,
            snapshot: snapshot,
            recordingDuration: audio.duration,
            transcriptionDuration: transcriptionDuration,
            progress: progress
        )
    }

    public func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        try await transcribeStreaming(
            audioChunks, snapshot: snapshot, audioCaptureCompletion: nil, progress: progress)
    }

    public func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        audioCaptureCompletion: AudioCaptureCompletionGate,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        try await transcribeStreaming(
            audioChunks, snapshot: snapshot, audioCaptureCompletion: audioCaptureCompletion,
            progress: progress)
    }

    private func transcribeStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        audioCaptureCompletion: AudioCaptureCompletionGate?,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        guard let streamingTranscriber = transcriber as? any StreamingContextualSpeechTranscribing
        else {
            throw VoiceTextProcessingFailure(
                userFailure: .transcriptionFailed,
                providerDiagnostic: .init(
                    provider: snapshot.recognitionProvider.provider.rawValue,
                    code: "streamingUnavailable"
                )
            )
        }
        let clock = ContinuousClock()
        let transcriptionStarted = clock.now
        let transcriptionResult: TranscriptionResult
        do {
            transcriptionResult = try await streamingTranscriber.transcribe(
                audioChunks,
                context: Self.transcriptionContext(
                    for: snapshot, audioCaptureCompletion: audioCaptureCompletion)
            )
        } catch let failure as SpeechRecognitionFailure {
            throw VoiceTextProcessingFailure(
                userFailure: failure.userFailure,
                providerDiagnostic: failure.providerDiagnostic
            )
        } catch let failure as DoubaoASRFailure {
            throw VoiceTextProcessingFailure(doubaoFailure: failure)
        } catch let failure as ProviderCredentialStoreError {
            throw VoiceTextProcessingFailure(doubaoCredentialFailure: failure)
        }
        let transcriptionDuration = transcriptionStarted.duration(to: clock.now)
        return try await finishProcessing(
            transcriptionResult,
            snapshot: snapshot,
            recordingDuration: nil,
            transcriptionDuration: transcriptionDuration,
            progress: progress
        )
    }

    private static func transcriptionContext(
        for snapshot: VoiceTextProcessingSnapshot,
        audioCaptureCompletion: AudioCaptureCompletionGate? = nil
    ) -> SpeechTranscriptionContext {
        SpeechTranscriptionContext(
            hotwords: snapshot.dictionaryContext.hotwords,
            purpose: snapshot.refinementMode.requiresRefinement
                ? .refinementSource
                : .defaultSmoothing,
            recognitionProvider: snapshot.recognitionProvider,
            audioCaptureCompletion: audioCaptureCompletion
        )
    }

    private func finishProcessing(
        _ transcriptionResult: TranscriptionResult,
        snapshot: VoiceTextProcessingSnapshot,
        recordingDuration: Duration?,
        transcriptionDuration: Duration,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        try Task.checkCancellation()
        if snapshot.refinementMode.requiresRefinement {
            await progress(
                .init(
                    stage: .refining,
                    confirmedDoubaoResult: transcriptionResult
                ))
        }
        let refinementStarted = ContinuousClock.now
        let refinementOutcome = try await refinement.refine(
            doubaoText: transcriptionResult.text,
            mode: snapshot.refinementMode,
            dictionaryWords: snapshot.dictionary.entries.map(\.word),
            provider: snapshot.refinementProvider
        )
        let refinementDuration = refinementStarted.duration(to: .now)

        var stageDurations = [
            snapshot.recognitionProvider.provider.rawValue: Self.milliseconds(
                transcriptionDuration),
            "deepseek": snapshot.refinementMode.requiresRefinement
                ? Self.milliseconds(refinementDuration)
                : 0,
        ]
        if let recordingDuration {
            stageDurations["recording"] = Self.milliseconds(recordingDuration)
        }
        return VoiceTextProcessingResult(
            doubaoText: transcriptionResult.text,
            normalizedText: transcriptionResult.text,
            deepSeekText: refinementOutcome.deepSeekText,
            finalText: refinementOutcome.finalText,
            doubaoRequestID: transcriptionResult.providerRequestID,
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
        } catch let failure as SpeechRecognitionFailure {
            throw VoiceTextProcessingFailure(
                userFailure: failure.userFailure,
                providerDiagnostic: failure.providerDiagnostic
            )
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
        return Int(
            clamping:
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
