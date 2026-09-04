import Foundation

extension Notification.Name {
    public static let speakerHistoryDidChange = Notification.Name(
        "com.local.speaker.history-did-change"
    )
}

public protocol LocalSessionHistoryStoring: SessionHistoryRecording {
    func allRecords() async -> [VoiceInputHistoryRecord]
    func record(sessionID: VoiceInputSessionID) async -> VoiceInputHistoryRecord?
    @discardableResult func delete(sessionID: VoiceInputSessionID) async -> Bool
    @discardableResult func clear() async -> Bool
    func persistenceStatus() async -> LocalHistoryPersistenceStatus
    func clearPersistenceNotice() async
    func currentRetentionPolicy() async -> HistoryRetentionPolicy
    @discardableResult func applyRetentionPolicy(
        _ policy: HistoryRetentionPolicy,
        now: Date
    ) async -> Bool
    func usageStatistics() async -> VoiceInputUsageSummary
}

extension LocalSessionHistoryStoring {
    public func latestRecord() async -> VoiceInputHistoryRecord? {
        await allRecords().first
    }

    /// Aggregates every stored session into all-time totals and per-day buckets.
    ///
    /// The default implementation folds `allRecords()`; stores backed by a
    /// database should override it to stream rows instead of loading the whole
    /// table into memory.
    public func usageStatistics() async -> VoiceInputUsageSummary {
        VoiceInputUsageStatistics.summarize(await allRecords())
    }
}

public struct LocalHistoryPersistenceStatus: Equatable, Sendable {
    public let recordCount: Int
    public let notice: LocalHistoryPersistenceNotice?

    public init(recordCount: Int, notice: LocalHistoryPersistenceNotice?) {
        self.recordCount = recordCount
        self.notice = notice
    }
}

/// Why the local history store could not finish its privacy migration.
public enum LocalHistoryFailureReason: Equatable, Sendable {
    case databaseUnavailable
    /// A privacy-safe technical detail already free of user or provider text.
    case detail(String)
}

public enum LocalHistoryPersistenceNotice: Equatable, Sendable {
    case corruptedDataPreserved(backupURL: URL, reason: String)
    case corruptedRecordsSkipped(count: Int)
    case privacyMigrationFailed(reason: LocalHistoryFailureReason)
    case writeFailed(reason: String)
    /// Preserved corruption evidence could not be pruned back inside its
    /// budget, so the store's directory keeps growing until it is cleared.
    case recoveryArchivePruneFailed(reason: String)
}

/// A permanent, local history store whose on-disk representation contains only
/// an explicit allow-list of `VoiceInputHistoryRecord` fields.
///
/// Audio, credentials, accessibility objects, the target's original value, and
/// clipboard contents are not accepted by this API and cannot be encoded by its
/// persistence DTOs.
public actor VersionedLocalSessionHistory: LocalSessionHistoryStoring {
    public static let currentSchemaVersion = 1
    public static let defaultMaximumRecordCount = 10_000
    private static let maximumLegacyDocumentByteCount = 64 * 1_024 * 1_024

    private let documents: VersionedOwnerOnlyDocumentStore<[VoiceInputHistoryRecord]>
    private let maximumRecordCount: Int
    private var storedRecords: [VoiceInputHistoryRecord]
    private var retentionPolicy: HistoryRetentionPolicy
    private var notice: LocalHistoryPersistenceNotice?

    public init(
        fileURL: URL,
        retentionPolicy: HistoryRetentionPolicy = .forever,
        maximumRecordCount: Int = VersionedLocalSessionHistory.defaultMaximumRecordCount
    ) {
        self.init(
            fileURL: fileURL,
            retentionPolicy: retentionPolicy,
            maximumRecordCount: maximumRecordCount,
            fileProtection: .ownerOnly
        )
    }

    package init(
        fileURL: URL,
        retentionPolicy: HistoryRetentionPolicy = .forever,
        maximumRecordCount: Int = VersionedLocalSessionHistory.defaultMaximumRecordCount,
        fileProtection: LocalFileProtection
    ) {
        let resolvedMaximumRecordCount = max(1, maximumRecordCount)
        let documents = VersionedOwnerOnlyDocumentStore(
            fileURL: fileURL,
            schema: Self.schema,
            maximumByteCount: Self.maximumLegacyDocumentByteCount,
            backupInfix: "corrupt-",
            fileProtection: fileProtection
        )
        self.documents = documents
        self.retentionPolicy = retentionPolicy
        self.maximumRecordCount = resolvedMaximumRecordCount

        let load = documents.load()
        switch load.outcome {
        case .absent:
            storedRecords = []
            notice = nil
        case .loaded(let records, _):
            storedRecords = SessionHistoryRecordPolicy.retained(
                records,
                policy: retentionPolicy,
                maximumCount: resolvedMaximumRecordCount,
                now: Date()
            )
            notice = nil
        case .corruptedPreserved(let backupURL, let corruption):
            storedRecords = []
            notice = .corruptedDataPreserved(
                backupURL: backupURL,
                reason: corruption.summary
            )
        case .failed(.protectionFailed(let detail)):
            storedRecords = []
            notice = .privacyMigrationFailed(reason: .detail(detail))
        case .failed(.readFailed(let detail)):
            storedRecords = []
            notice = .writeFailed(
                reason: "History data could not be read safely: \(detail)"
            )
        case .failed(.preservationFailed(_, let detail)):
            storedRecords = []
            notice = .writeFailed(
                reason: "History data is corrupt and could not be preserved: \(detail)"
            )
        }
        // Pruning never fails a load, but a directory that cannot be bounded
        // is the user's problem the next time it fills up, so say so when no
        // stronger notice already describes the same file.
        if notice == nil, !load.pruning.isComplete {
            notice = .recoveryArchivePruneFailed(
                reason: load.pruning.failures.joined(separator: "; ")
            )
        }
    }

    /// This table is the migration seam: future schemas decode into their
    /// own DTO and migrate to the current domain record here.
    private static let schema = VersionedDocumentSchema<[VoiceInputHistoryRecord]>(
        currentVersion: currentSchemaVersion,
        versionKey: .schemaVersion,
        decoders: [
            1: { data in
                try decoder.decode(HistoryDocumentV1.self, from: data)
                    .records.map { try $0.domainRecord }
            }
        ]
    )

    public static func defaultFileURL(
        fileManager: FileManager = .default,
        applicationDirectoryName: String = "Speaker"
    ) -> URL {
        let baseDirectory =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser

        return
            baseDirectory
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    public func save(_ record: VoiceInputHistoryRecord) async {
        let existingIndex = storedRecords.firstIndex(where: {
            $0.sessionID == record.sessionID
        })
        guard SessionHistoryRecordPolicy.shouldRetain(record) else {
            guard let existingIndex else { return }
            storedRecords.remove(at: existingIndex)
            if persistCurrentRecords() {
                NotificationCenter.default.post(
                    name: .speakerHistoryDidChange,
                    object: nil
                )
            }
            return
        }
        guard retentionPolicy.savesNewRecords || existingIndex != nil else {
            return
        }
        if let index = existingIndex {
            storedRecords[index] = record
        } else {
            storedRecords.append(record)
        }
        storedRecords = SessionHistoryRecordPolicy.retained(
            storedRecords,
            policy: retentionPolicy,
            maximumCount: maximumRecordCount,
            now: Date()
        )
        if persistCurrentRecords() {
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
        }
    }

    public func allRecords() async -> [VoiceInputHistoryRecord] {
        storedRecords
    }

    public func currentRetentionPolicy() async -> HistoryRetentionPolicy {
        retentionPolicy
    }

    @discardableResult
    public func applyRetentionPolicy(
        _ policy: HistoryRetentionPolicy,
        now: Date = Date()
    ) async -> Bool {
        let previousPolicy = retentionPolicy
        let previousRecords = storedRecords
        let retainedRecords = SessionHistoryRecordPolicy.retained(
            storedRecords,
            policy: policy,
            maximumCount: maximumRecordCount,
            now: now
        )
        guard policy != retentionPolicy || retainedRecords != storedRecords else {
            return true
        }
        retentionPolicy = policy
        storedRecords = retainedRecords
        guard persistCurrentRecords() else {
            retentionPolicy = previousPolicy
            storedRecords = previousRecords
            return false
        }
        NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
        return true
    }

    public func record(sessionID: VoiceInputSessionID) async -> VoiceInputHistoryRecord? {
        storedRecords.first { $0.sessionID == sessionID }
    }

    @discardableResult
    public func delete(sessionID: VoiceInputSessionID) async -> Bool {
        let previousRecords = storedRecords
        let originalCount = storedRecords.count
        storedRecords.removeAll { $0.sessionID == sessionID }
        guard storedRecords.count != originalCount else { return false }
        guard persistCurrentRecords() else {
            storedRecords = previousRecords
            return false
        }
        NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
        return true
    }

    @discardableResult
    public func clear() async -> Bool {
        let previousRecords = storedRecords
        storedRecords.removeAll(keepingCapacity: false)
        guard persistCurrentRecords() else {
            storedRecords = previousRecords
            return false
        }
        do {
            try removeRecoveryArtifacts()
            notice = nil
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            return false
        }
    }

    public func persistenceStatus() async -> LocalHistoryPersistenceStatus {
        LocalHistoryPersistenceStatus(
            recordCount: storedRecords.count,
            notice: notice
        )
    }

    public func persistenceFailureNotice() async -> LocalHistoryPersistenceNotice? {
        guard case .writeFailed = notice else { return nil }
        return notice
    }

    /// Notices remain visible across later successful writes so the UI cannot
    /// silently hide a recovered corruption event. The user may dismiss it.
    public func clearPersistenceNotice() async {
        notice = nil
    }

    private func persistCurrentRecords() -> Bool {
        do {
            let document = HistoryDocumentV1(
                schemaVersion: Self.currentSchemaVersion,
                records: storedRecords.map(HistoryRecordV1.init)
            )
            try documents.write(try Self.encoder.encode(document))
            return true
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            return false
        }
    }

    private func removeRecoveryArtifacts() throws {
        try documents.removeBackups()
    }
}

extension VersionedLocalSessionHistory {
    fileprivate static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    fileprivate static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct HistoryDocumentV1: Codable {
    let schemaVersion: Int
    let records: [HistoryRecordV1]
}

package struct HistoryRecordV1: Codable {
    let sessionID: UUID
    let startedAt: Date
    let applicationName: String?
    let transcription: String?
    let finalText: String?
    let transcriptionProvider: String?
    let providerRequestID: String?
    let providerErrorCode: String?
    let providerOperation: String?
    let providerStatusCode: String?
    let providerMessage: String?
    let deliveryDiagnosticCode: String?
    let deepSeekText: String?
    let deepSeekRequestID: String?
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
    let outcome: HistoryOutcomeV1

    init(_ record: VoiceInputHistoryRecord) {
        sessionID = record.sessionID.rawValue
        startedAt = record.startedAt
        applicationName = nil
        transcription = record.transcription
        finalText = record.finalText
        transcriptionProvider = record.transcriptionProvider
        providerRequestID = record.providerRequestID
        providerErrorCode = record.providerErrorCode
        providerOperation = record.providerOperation
        providerStatusCode = record.providerStatusCode
        providerMessage = nil
        deliveryDiagnosticCode = record.deliveryDiagnosticCode
        deepSeekText = record.deepSeekText
        deepSeekRequestID = record.deepSeekRequestID
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
        outcome = HistoryOutcomeV1(record.outcome)
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
                providerRequestID: providerRequestID,
                providerErrorCode: providerErrorCode,
                providerOperation: providerOperation,
                providerStatusCode: providerStatusCode,
                providerMessage: nil,
                deliveryDiagnosticCode: deliveryDiagnosticCode,
                deepSeekText: deepSeekText,
                deepSeekRequestID: deepSeekRequestID,
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
                outcome: try outcome.domainOutcome
            )
        }
    }
}

package struct HistoryOutcomeV1: Codable {
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
                    throw HistoryRecordDecodingError.missingField("processingStage")
                }
                return .processing(
                    try requiredSessionID(),
                    try Self.decodeStage(processingStage),
                    applicationName: applicationName
                )
            case .delivered:
                guard let text else {
                    throw HistoryRecordDecodingError.missingField("text")
                }
                return .delivered(
                    try requiredSessionID(),
                    // Legacy records predate the application-name field; the
                    // placeholder is part of the on-disk decoding contract.
                    applicationName: applicationName ?? "当前输入框",
                    text: text
                )
            case .pendingCopy:
                guard let text else {
                    throw HistoryRecordDecodingError.missingField("text")
                }
                guard
                    let pendingCopyReason,
                    let reason = PendingCopyReason(rawValue: pendingCopyReason)
                else {
                    throw HistoryRecordDecodingError.invalidField("pendingCopyReason")
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
                    throw HistoryRecordDecodingError.invalidField("failure")
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
        default: throw HistoryRecordDecodingError.invalidField("processingStage")
        }
    }

    private func requiredSessionID() throws -> VoiceInputSessionID {
        guard let sessionID else {
            throw HistoryRecordDecodingError.missingField("sessionID")
        }
        return VoiceInputSessionID(rawValue: sessionID)
    }
}

package enum HistoryRecordDecodingError: Error {
    case missingField(String)
    case invalidField(String)
}
