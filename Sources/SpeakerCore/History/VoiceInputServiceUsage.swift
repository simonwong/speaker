import Foundation

/// Recording time sent to one Speech Recognition Provider model.
///
/// `provider` is the stored provider identifier (a `SpeechRecognitionProviderID`
/// raw value for records written by current builds). `modelID` is empty when
/// the Session Record did not name a model.
public struct SpeechRecognitionServiceUsage: Equatable, Sendable {
    public let provider: String
    public let modelID: String
    public let sessionCount: Int
    public let recordingMilliseconds: Int

    public init(provider: String, modelID: String, sessionCount: Int, recordingMilliseconds: Int) {
        self.provider = provider
        self.modelID = modelID
        self.sessionCount = sessionCount
        self.recordingMilliseconds = recordingMilliseconds
    }
}

/// Successful requests sent to one Refinement Provider model, with the
/// characters those requests sent and received. Characters, not tokens: the
/// tokenizer belongs to the provider, so turning characters into tokens is an
/// estimate made where prices are.
///
/// A Custom Refinement Provider's model is stored as an empty `modelID`: the
/// name is user-entered configuration and the totals outlive a history clear.
public struct RefinementServiceUsage: Equatable, Sendable {
    public let provider: RefinementProviderID
    public let modelID: String
    public let requestCount: Int
    public let inputCharacterCount: Int
    public let outputCharacterCount: Int

    public init(
        provider: RefinementProviderID,
        modelID: String,
        requestCount: Int,
        inputCharacterCount: Int,
        outputCharacterCount: Int
    ) {
        self.provider = provider
        self.modelID = modelID
        self.requestCount = requestCount
        self.inputCharacterCount = inputCharacterCount
        self.outputCharacterCount = outputCharacterCount
    }
}

/// What the overview's estimated cost and latency read: usage per provider
/// service, and release-to-delivery samples per Speech Recognition Provider.
///
/// Service usage includes counts archived from deleted Session Records.
/// Latency samples come only from Session Records still stored, because the
/// archive keeps counts, not distributions.
public struct VoiceInputServiceUsage: Equatable, Sendable {
    /// Ordered by provider, then model.
    public let recognition: [SpeechRecognitionServiceUsage]
    /// Ordered by provider, then model.
    public let refinement: [RefinementServiceUsage]
    /// Release-to-delivery milliseconds of delivered sessions, ascending, per
    /// stored Speech Recognition Provider identifier.
    public let releaseToDeliveryMilliseconds: [String: [Int]]

    public init(
        recognition: [SpeechRecognitionServiceUsage],
        refinement: [RefinementServiceUsage],
        releaseToDeliveryMilliseconds: [String: [Int]]
    ) {
        self.recognition = recognition
        self.refinement = refinement
        self.releaseToDeliveryMilliseconds = releaseToDeliveryMilliseconds
    }

    public static let empty = VoiceInputServiceUsage(
        recognition: [],
        refinement: [],
        releaseToDeliveryMilliseconds: [:]
    )
}

/// Folds Session Records and archived rows into `VoiceInputServiceUsage`.
package struct VoiceInputServiceUsageAccumulator {
    package struct RecognitionKey: Hashable, Sendable {
        package let provider: String
        package let modelID: String
    }

    package struct RefinementKey: Hashable, Sendable {
        package let provider: RefinementProviderID
        package let modelID: String
    }

    package struct RecognitionTotals: Equatable, Sendable {
        package var sessions = 0
        package var milliseconds = 0
    }

    package struct RefinementTotals: Equatable, Sendable {
        package var requests = 0
        package var inputCharacters = 0
        package var outputCharacters = 0
    }

    package private(set) var recognition: [RecognitionKey: RecognitionTotals] = [:]
    package private(set) var refinement: [RefinementKey: RefinementTotals] = [:]
    private var latency: [String: [Int]] = [:]

    package init() {}

    /// Adds one counted Session Record.
    ///
    /// Recognition counts every record that names its provider, whatever the
    /// outcome: audio was sent once recording time exists. Refinement counts
    /// only requests that succeeded, the ones a provider certainly answered.
    /// Latency counts only delivered sessions that measured it.
    package mutating func add(_ record: VoiceInputHistoryRecord) {
        if let provider = record.transcriptionProvider, !provider.isEmpty {
            let key = RecognitionKey(provider: provider, modelID: record.transcriptionModelID ?? "")
            recognition[key, default: .init()].sessions += 1
            recognition[key, default: .init()].milliseconds += record.speakingMilliseconds
        }
        if let provider = record.refinementProviderID,
            record.refinementStatus == TextRefinementStatus.succeeded.rawValue
        {
            let key = RefinementKey(
                provider: provider,
                modelID: provider == .custom ? "" : record.refinementModelID ?? ""
            )
            let input = ChatCompletionRefinementClient.requestMessageCharacterCount(
                text: record.transcription ?? "",
                instruction: record.refinementPrompt ?? "",
                dictionaryWords: record.dictionarySnapshotEntries.map(\.word)
            )
            let output = ChatCompletionRefinementClient.responseCharacterCount(
                text: record.refinedText ?? record.finalText ?? ""
            )
            refinement[key, default: .init()].requests += 1
            refinement[key, default: .init()].inputCharacters += input
            refinement[key, default: .init()].outputCharacters += output
        }
        if case .delivered = record.outcome,
            let provider = record.transcriptionProvider, !provider.isEmpty,
            let milliseconds = record.releaseToDeliveryMilliseconds, milliseconds >= 0
        {
            latency[provider, default: []].append(milliseconds)
        }
    }

    package mutating func addArchivedRecognition(
        _ key: RecognitionKey,
        sessions: Int,
        milliseconds: Int
    ) {
        recognition[key, default: .init()].sessions += max(0, sessions)
        recognition[key, default: .init()].milliseconds += max(0, milliseconds)
    }

    package mutating func addArchivedRefinement(
        _ key: RefinementKey,
        requests: Int,
        inputCharacters: Int,
        outputCharacters: Int
    ) {
        refinement[key, default: .init()].requests += max(0, requests)
        refinement[key, default: .init()].inputCharacters += max(0, inputCharacters)
        refinement[key, default: .init()].outputCharacters += max(0, outputCharacters)
    }

    package func usage() -> VoiceInputServiceUsage {
        VoiceInputServiceUsage(
            recognition:
                recognition
                .sorted { ($0.key.provider, $0.key.modelID) < ($1.key.provider, $1.key.modelID) }
                .map {
                    SpeechRecognitionServiceUsage(
                        provider: $0.key.provider,
                        modelID: $0.key.modelID,
                        sessionCount: $0.value.sessions,
                        recordingMilliseconds: $0.value.milliseconds
                    )
                },
            refinement:
                refinement
                .sorted {
                    ($0.key.provider.rawValue, $0.key.modelID)
                        < ($1.key.provider.rawValue, $1.key.modelID)
                }
                .map {
                    RefinementServiceUsage(
                        provider: $0.key.provider,
                        modelID: $0.key.modelID,
                        requestCount: $0.value.requests,
                        inputCharacterCount: $0.value.inputCharacters,
                        outputCharacterCount: $0.value.outputCharacters
                    )
                },
            releaseToDeliveryMilliseconds: latency.mapValues { $0.sorted() }
        )
    }
}
