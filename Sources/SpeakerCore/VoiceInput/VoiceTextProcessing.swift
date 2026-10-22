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
        refinementProvider: RefinementProviderProfile = .defaultProfile(for: .deepSeek),
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
    /// The Speech Recognition Provider's confirmed text.
    public let recognitionText: String
    public let normalizedText: String
    /// The Refinement Provider's text, when refinement produced one.
    public let refinedText: String?
    public let finalText: String
    public let recognitionRequestID: String?
    public let refinementRequestID: String?
    public let refinementStatus: TextRefinementStatus
    public let refinementFailure: TextRefinementFailure?
    public let stageDurationsMilliseconds: [String: Int]

    public init(
        recognitionText: String,
        normalizedText: String,
        refinedText: String?,
        finalText: String,
        recognitionRequestID: String?,
        refinementRequestID: String?,
        refinementStatus: TextRefinementStatus,
        refinementFailure: TextRefinementFailure?,
        stageDurationsMilliseconds: [String: Int] = [:]
    ) {
        self.recognitionText = recognitionText
        self.normalizedText = normalizedText
        self.refinedText = refinedText
        self.finalText = finalText
        self.recognitionRequestID = recognitionRequestID
        self.refinementRequestID = refinementRequestID
        self.refinementStatus = refinementStatus
        self.refinementFailure = refinementFailure
        self.stageDurationsMilliseconds = stageDurationsMilliseconds
    }
}

/// Removes C0 and C1 control characters, and DEL, from provider text. Line
/// feeds and tabs stay; CR LF and a lone CR become a line feed. An escape
/// sequence such as `ESC [201~` from a model would otherwise end a terminal's
/// bracketed paste and run the rest of the text as typed commands.
package enum ProviderTextSanitizer {
    package static func removingControlCharacters(from text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            defer { previousWasCarriageReturn = scalar == "\r" }
            switch scalar.value {
            case 0x0D:
                scalars.append("\n")
            case 0x0A:
                if !previousWasCarriageReturn { scalars.append(scalar) }
            case 0x09:
                scalars.append(scalar)
            case 0x00...0x1F, 0x7F...0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

extension VoiceTextProcessingResult {
    package func removingControlCharacters() -> Self {
        let clean = ProviderTextSanitizer.removingControlCharacters(from:)
        return VoiceTextProcessingResult(
            recognitionText: clean(recognitionText),
            normalizedText: clean(normalizedText),
            refinedText: refinedText.map(clean),
            finalText: clean(finalText),
            recognitionRequestID: recognitionRequestID,
            refinementRequestID: refinementRequestID,
            refinementStatus: refinementStatus,
            refinementFailure: refinementFailure,
            stageDurationsMilliseconds: stageDurationsMilliseconds
        )
    }
}

public struct VoiceTextProcessingProgress: Equatable, Sendable {
    public let stage: VoiceInputProcessingStage
    /// The recognition Stage Result, reported once recognition is confirmed
    /// and refinement has begun.
    public let confirmedRecognitionResult: TranscriptionResult?

    public init(
        stage: VoiceInputProcessingStage,
        confirmedRecognitionResult: TranscriptionResult? = nil
    ) {
        self.stage = stage
        self.confirmedRecognitionResult = confirmedRecognitionResult
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

    init(recognitionFailure failure: SpeechRecognitionFailure) {
        self.init(
            userFailure: failure.userFailure,
            providerDiagnostic: failure.providerDiagnostic
        )
    }
}

public protocol VoiceTextProcessing: Sendable {
    /// This processor's form that recognizes audio while it is recorded, or
    /// `nil` when it needs the complete recording.
    var streaming: (any StreamingVoiceTextProcessing)? { get }
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
        refinementProvider: RefinementProviderProfile = .defaultProfile(for: .deepSeek),
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

    public nonisolated var streaming: (any StreamingVoiceTextProcessing)? { self }

    public func captureSnapshot() async -> VoiceTextProcessingSnapshot {
        await configuration.captureSnapshot()
    }

    public func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        // The complete recording arrives after recording ended, so refinement
        // is next: its connection opens while recognition runs.
        prepareRefinementConnection(for: snapshot)
        let clock = ContinuousClock()
        let transcriptionStarted = clock.now
        let transcriptionResult: TranscriptionResult
        do {
            transcriptionResult = try await transcriber.transcribe(
                audio,
                context: Self.transcriptionContext(for: snapshot)
            )
        } catch let failure as SpeechRecognitionFailure {
            throw VoiceTextProcessingFailure(recognitionFailure: failure)
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
        if let audioCaptureCompletion {
            // Recording ends when the session accepts the capture; refinement
            // is then next, so its connection opens while recognition settles.
            // A rejected capture opens nothing.
            prepareRefinementConnection(for: snapshot, after: audioCaptureCompletion)
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
            throw VoiceTextProcessingFailure(recognitionFailure: failure)
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
        let dictionaryWords = snapshot.dictionary.entries.map(\.word)
        // A transcript that skips refinement goes straight to delivery; it
        // never presents a pending refinement.
        if snapshot.refinementMode.requiresRefinement,
            !refinement.skipsRefinement(
                of: transcriptionResult.text,
                mode: snapshot.refinementMode,
                dictionaryWords: dictionaryWords
            )
        {
            await progress(
                .init(
                    stage: .refining,
                    confirmedRecognitionResult: transcriptionResult
                ))
        }
        let refinementStarted = ContinuousClock.now
        let refinementOutcome = try await refinement.refine(
            doubaoText: transcriptionResult.text,
            mode: snapshot.refinementMode,
            dictionaryWords: dictionaryWords,
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
            recognitionText: transcriptionResult.text,
            normalizedText: transcriptionResult.text,
            refinedText: refinementOutcome.deepSeekText,
            finalText: refinementOutcome.finalText,
            recognitionRequestID: transcriptionResult.providerRequestID,
            refinementRequestID: refinementOutcome.providerRequestID,
            refinementStatus: refinementOutcome.status,
            refinementFailure: refinementOutcome.failure,
            stageDurationsMilliseconds: stageDurations
        )
    }

    /// Starts, without waiting for it, the connection the refinement request
    /// will reuse, once `gate` accepts the capture when one is given. Default
    /// Smoothing contacts no Refinement Provider.
    private nonisolated func prepareRefinementConnection(
        for snapshot: VoiceTextProcessingSnapshot,
        after gate: AudioCaptureCompletionGate? = nil
    ) {
        guard snapshot.refinementMode.requiresRefinement else { return }
        let refinement = refinement
        Task {
            do { try await gate?.wait() } catch { return }
            await refinement.prepareConnection(
                mode: snapshot.refinementMode,
                provider: snapshot.refinementProvider
            )
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let millisecondsFromSeconds = components.seconds * 1_000
        let millisecondsFromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: millisecondsFromSeconds + millisecondsFromAttoseconds)
    }
}

extension DefaultVoiceTextProcessor: StreamingVoiceTextProcessing {}

/// Recognizes the complete recording with one transcriber and delivers its
/// text unchanged: no snapshot, refinement, or streaming.
package struct BasicVoiceTextProcessor: VoiceTextProcessing {
    let transcriber: any SpeechTranscribing

    package init(transcriber: any SpeechTranscribing) {
        self.transcriber = transcriber
    }

    package var streaming: (any StreamingVoiceTextProcessing)? { nil }

    package func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    package func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        let result: TranscriptionResult
        do {
            result = try await transcriber.transcribe(audio)
        } catch let failure as SpeechRecognitionFailure {
            throw VoiceTextProcessingFailure(recognitionFailure: failure)
        }
        return VoiceTextProcessingResult(
            recognitionText: result.text,
            normalizedText: result.text,
            refinedText: nil,
            finalText: result.text,
            recognitionRequestID: result.providerRequestID,
            refinementRequestID: nil,
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
