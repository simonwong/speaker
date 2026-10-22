import Foundation

/// The stored form of one Session Record.
///
/// Every `history_records.payload` value in `history.sqlite3` is this JSON
/// object, and so is every element of the legacy `history.json` document's
/// `records` array, which is why the legacy reader and the SQLite store share
/// one codec. The property names of `SessionRecordPayloadV1` and
/// `SessionRecordOutcomePayloadV1` are the stored keys: renaming one, or
/// changing the date strategy, changes what existing rows decode to.
/// `SessionRecordPayloadFixtures` in the core specifications pins the bytes.
///
/// Target-application identity and free-text provider or refinement messages
/// are never encoded; they are dropped here, before anything reaches disk.
enum SessionRecordPayloadCodec {
    static func encode(_ record: VoiceInputHistoryRecord) throws -> Data {
        try encoder.encode(SessionRecordPayloadV1(record))
    }

    static func decode(_ payload: Data) throws -> VoiceInputHistoryRecord {
        try decoder.decode(SessionRecordPayloadV1.self, from: payload).domainRecord
    }

    /// Sorted keys make an unchanged record encode to unchanged bytes, which
    /// the legacy import's read-back verification compares.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

struct SessionRecordPayloadV1: Codable {
    let sessionID: UUID
    let startedAt: Date
    /// Only payloads written by early builds carry it; it is never written.
    let applicationName: String?
    let transcription: String?
    let finalText: String?
    let transcriptionProvider: String?
    let transcriptionModelID: String?
    let providerRequestID: String?
    let providerErrorCode: String?
    let providerOperation: String?
    let providerStatusCode: String?
    let providerMessage: String?
    let deliveryDiagnosticCode: String?
    let deepSeekText: String?
    let deepSeekRequestID: String?
    let refinementProviderID: RefinementProviderID?
    let refinementModelID: String?
    let refinementModeName: String?
    let refinementPrompt: String?
    let refinementStatus: String?
    let refinementFailureCode: String?
    let refinementFailureStatusCode: String?
    let refinementFailureMessage: String?
    let cancelledAtStage: String?
    let dictionarySnapshotID: UUID?
    let dictionarySnapshotEntries: [RecordedDictionaryEntry]?
    let dictionaryRequestContext: DictionaryRequestContext?
    let dictionaryReplacements: [DictionaryReplacement]?
    let durationMilliseconds: Int?
    let stageDurationsMilliseconds: [String: Int]?
    /// Added after schema 1 shipped. Absent in older payloads and omitted
    /// when nil, so payloads without it keep their bytes.
    let releaseToDeliveryMilliseconds: Int?
    let outcome: SessionRecordOutcomePayloadV1

    init(_ record: VoiceInputHistoryRecord) {
        sessionID = record.sessionID.rawValue
        startedAt = record.startedAt
        applicationName = nil
        transcription = record.transcription
        finalText = record.finalText
        transcriptionProvider = record.transcriptionProvider
        transcriptionModelID = record.transcriptionModelID
        providerRequestID = record.providerRequestID
        providerErrorCode = record.providerErrorCode
        providerOperation = record.providerOperation
        providerStatusCode = record.providerStatusCode
        providerMessage = nil
        deliveryDiagnosticCode = record.deliveryDiagnosticCode
        deepSeekText = record.deepSeekText
        deepSeekRequestID = record.deepSeekRequestID
        refinementProviderID = record.refinementProviderID
        refinementModelID = record.refinementModelID
        refinementModeName = record.refinementModeName
        refinementPrompt = record.refinementPrompt
        refinementStatus = record.refinementStatus
        refinementFailureCode = record.refinementFailureCode
        refinementFailureStatusCode = record.refinementFailureStatusCode
        refinementFailureMessage = nil
        cancelledAtStage = record.cancelledAtStage
        dictionarySnapshotID = record.dictionarySnapshotID
        dictionarySnapshotEntries = record.dictionarySnapshotEntries
        dictionaryRequestContext = record.dictionaryRequestContext
        dictionaryReplacements = record.dictionaryReplacements
        durationMilliseconds = record.durationMilliseconds
        stageDurationsMilliseconds = record.stageDurationsMilliseconds
        releaseToDeliveryMilliseconds = record.releaseToDeliveryMilliseconds
        outcome = SessionRecordOutcomePayloadV1(record.outcome)
    }

    var domainRecord: VoiceInputHistoryRecord {
        get throws {
            VoiceInputHistoryRecord(
                sessionID: VoiceInputSessionID(rawValue: sessionID),
                startedAt: startedAt,
                applicationName: applicationName,
                transcription: transcription,
                finalText: finalText,
                transcriptionProvider: transcriptionProvider,
                transcriptionModelID: transcriptionModelID,
                providerRequestID: providerRequestID,
                providerErrorCode: providerErrorCode,
                providerOperation: providerOperation,
                providerStatusCode: providerStatusCode,
                providerMessage: nil,
                deliveryDiagnosticCode: deliveryDiagnosticCode,
                deepSeekText: deepSeekText,
                deepSeekRequestID: deepSeekRequestID,
                refinementProviderID: refinementProviderID,
                refinementModelID: refinementModelID,
                refinementModeName: refinementModeName,
                refinementPrompt: refinementPrompt,
                refinementStatus: refinementStatus,
                refinementFailureCode: refinementFailureCode,
                refinementFailureStatusCode: refinementFailureStatusCode,
                refinementFailureMessage: nil,
                cancelledAtStage: cancelledAtStage,
                dictionarySnapshotID: dictionarySnapshotID,
                dictionarySnapshotEntries: dictionarySnapshotEntries ?? [],
                dictionaryRequestContext: dictionaryRequestContext,
                dictionaryReplacements: dictionaryReplacements ?? [],
                durationMilliseconds: durationMilliseconds ?? 0,
                stageDurationsMilliseconds: stageDurationsMilliseconds ?? [:],
                releaseToDeliveryMilliseconds: releaseToDeliveryMilliseconds,
                outcome: try outcome.domainOutcome
            )
        }
    }
}

struct SessionRecordOutcomePayloadV1: Codable {
    enum Kind: String, Codable {
        case idle
        case preparing
        case recording
        case processing
        case delivered
        case pendingCopy
        case cancelled
        case failed
    }

    let kind: Kind
    let sessionID: UUID?
    let processingStage: String?
    let applicationName: String?
    let text: String?
    let pendingCopyReason: String?
    let failure: String?

    init(_ outcome: VoiceInputActivity) {
        switch outcome {
        case .idle:
            self.init(kind: .idle)
        case .preparing(let id):
            self.init(kind: .preparing, sessionID: id.rawValue)
        case .recording(let id):
            self.init(kind: .recording, sessionID: id.rawValue)
        case .processing(let id, let stage, _):
            self.init(
                kind: .processing,
                sessionID: id.rawValue,
                processingStage: Self.encode(stage)
            )
        case .delivered(let id, _, let text):
            self.init(
                kind: .delivered,
                sessionID: id.rawValue,
                text: text
            )
        case .pendingCopy(let id, let text, let reason):
            self.init(
                kind: .pendingCopy,
                sessionID: id.rawValue,
                text: text,
                pendingCopyReason: reason.rawValue
            )
        case .cancelled(let id):
            self.init(kind: .cancelled, sessionID: id.rawValue)
        case .failed(let id, let failure):
            self.init(
                kind: .failed,
                sessionID: id.rawValue,
                failure: failure.rawValue
            )
        }
    }

    init(
        kind: Kind,
        sessionID: UUID? = nil,
        processingStage: String? = nil,
        applicationName: String? = nil,
        text: String? = nil,
        pendingCopyReason: String? = nil,
        failure: String? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.processingStage = processingStage
        self.applicationName = applicationName
        self.text = text
        self.pendingCopyReason = pendingCopyReason
        self.failure = failure
    }

    var domainOutcome: VoiceInputActivity {
        get throws {
            switch kind {
            case .idle:
                return .idle
            case .preparing:
                return .preparing(try requiredSessionID())
            case .recording:
                return .recording(try requiredSessionID())
            case .processing:
                guard let processingStage else {
                    throw SessionRecordPayloadDecodingError.missingField("processingStage")
                }
                return .processing(
                    try requiredSessionID(),
                    try Self.decodeStage(processingStage),
                    applicationName: applicationName
                )
            case .delivered:
                guard let text else {
                    throw SessionRecordPayloadDecodingError.missingField("text")
                }
                return .delivered(
                    try requiredSessionID(),
                    // The payload never stores target-application identity,
                    // so a decoded outcome has no name to restore. Nothing
                    // presents a stored outcome's application name; the
                    // empty string only satisfies the live activity's shape.
                    applicationName: applicationName ?? "",
                    text: text
                )
            case .pendingCopy:
                guard let text else {
                    throw SessionRecordPayloadDecodingError.missingField("text")
                }
                guard
                    let pendingCopyReason,
                    let reason = PendingCopyReason(rawValue: pendingCopyReason)
                else {
                    throw SessionRecordPayloadDecodingError.invalidField("pendingCopyReason")
                }
                return .pendingCopy(
                    try requiredSessionID(),
                    text: text,
                    reason: reason
                )
            case .cancelled:
                return .cancelled(try requiredSessionID())
            case .failed:
                guard
                    let failure,
                    let voiceInputFailure = VoiceInputFailure(rawValue: failure)
                else {
                    throw SessionRecordPayloadDecodingError.invalidField("failure")
                }
                return .failed(
                    try requiredSessionID(),
                    voiceInputFailure
                )
            }
        }
    }

    private static func encode(_ stage: VoiceInputProcessingStage) -> String {
        switch stage {
        case .capturingTarget: "capturingTarget"
        case .transcribing: "transcribing"
        case .refining: "refining"
        case .delivering: "delivering"
        }
    }

    private static func decodeStage(_ value: String) throws -> VoiceInputProcessingStage {
        switch value {
        case "capturingTarget": .capturingTarget
        case "transcribing": .transcribing
        case "refining": .refining
        case "delivering": .delivering
        default: throw SessionRecordPayloadDecodingError.invalidField("processingStage")
        }
    }

    private func requiredSessionID() throws -> VoiceInputSessionID {
        guard let sessionID else {
            throw SessionRecordPayloadDecodingError.missingField("sessionID")
        }
        return VoiceInputSessionID(rawValue: sessionID)
    }
}

enum SessionRecordPayloadDecodingError: Error {
    case missingField(String)
    case invalidField(String)
}
