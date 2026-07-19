import Foundation

public extension Notification.Name {
    static let speakerHistoryDidChange = Notification.Name(
        "com.local.speaker.history-did-change"
    )
}

public protocol LocalSessionHistoryStoring: SessionHistoryRecording {
    func allRecords() async -> [VoiceInputHistoryRecord]
    func record(sessionID: VoiceInputSessionID) async -> VoiceInputHistoryRecord?
    func search(_ query: String) async -> [VoiceInputHistoryRecord]
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

public extension LocalSessionHistoryStoring {
    func latestRecord() async -> VoiceInputHistoryRecord? {
        await allRecords().first
    }

    /// Aggregates every stored session into all-time totals and per-day buckets.
    ///
    /// The default implementation folds `allRecords()`; stores backed by a
    /// database should override it to stream rows instead of loading the whole
    /// table into memory.
    func usageStatistics() async -> VoiceInputUsageSummary {
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

public enum LocalHistoryPersistenceNotice: Equatable, Sendable {
    case corruptedDataPreserved(backupURL: URL, reason: String)
    case corruptedRecordsSkipped(count: Int)
    case privacyMigrationFailed(reason: String)
    case writeFailed(reason: String)
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

    private let fileURL: URL
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
        self.fileURL = fileURL
        self.retentionPolicy = retentionPolicy
        self.maximumRecordCount = resolvedMaximumRecordCount
        Self.pruneRecoveryArtifacts(for: fileURL)
        do {
            try fileProtection.protect(fileURL)
        } catch {
            storedRecords = []
            notice = .privacyMigrationFailed(
                reason: Self.safeReason(for: error)
            )
            return
        }

        switch Self.loadDocument(at: fileURL) {
        case let .success(records):
            storedRecords = SessionHistoryRecordPolicy.retained(
                records,
                policy: retentionPolicy,
                maximumCount: resolvedMaximumRecordCount,
                now: Date()
            )
            notice = nil
        case let .failure(failure):
            storedRecords = []
            notice = Self.preserveCorruptedDocument(at: fileURL, failure: failure)
        }
    }

    public static func defaultFileURL(
        fileManager: FileManager = .default,
        applicationDirectoryName: String = "Speaker"
    ) -> URL {
        let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser

        return baseDirectory
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    public func save(_ record: VoiceInputHistoryRecord) async {
        if let index = storedRecords.firstIndex(where: {
            $0.sessionID == record.sessionID
        }) {
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

    /// Searches all user-visible and diagnostic text retained by the history
    /// model. Matching is localized, case-insensitive, and diacritic-insensitive.
    public func search(_ query: String) async -> [VoiceInputHistoryRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return storedRecords }

        return storedRecords.filter { record in
            SessionHistoryRecordPolicy.searchableValues(record).contains { value in
                value.range(
                    of: normalizedQuery,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) != nil
            }
        }
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
            notice = .writeFailed(reason: Self.safeReason(for: error))
            return false
        }
    }

    public func persistenceStatus() async -> LocalHistoryPersistenceStatus {
        LocalHistoryPersistenceStatus(
            recordCount: storedRecords.count,
            notice: notice
        )
    }

    public func persistenceFailureNotice() async -> String? {
        guard case let .writeFailed(reason) = notice else { return nil }
        return "会话历史写入失败：\(reason)"
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
            let data = try Self.encoder.encode(document)
            try OwnerOnlyFilePersistence.write(data, to: fileURL)
            return true
        } catch {
            notice = .writeFailed(reason: Self.safeReason(for: error))
            return false
        }
    }

    private func removeRecoveryArtifacts() throws {
        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let prefix = "\(baseName).corrupt-"
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates where
            candidate.lastPathComponent.hasPrefix(prefix)
                && candidate.pathExtension == "json"
        {
            try FileManager.default.removeItem(at: candidate)
        }
    }
}

private extension VersionedLocalSessionHistory {
    enum LoadFailure: Error {
        case unreadable(Error)
        case malformed(Error)
        case unsupportedVersion(Int)
    }

    enum LoadResult {
        case success([VoiceInputHistoryRecord])
        case failure(LoadFailure)
    }

    struct DocumentVersion: Decodable {
        let schemaVersion: Int
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func loadDocument(at fileURL: URL) -> LoadResult {
        let data: Data
        do {
            guard let storedData = try OwnerOnlyFilePersistence.read(
                from: fileURL,
                maximumByteCount: maximumLegacyDocumentByteCount
            ) else {
                return .success([])
            }
            data = storedData
        } catch {
            return .failure(.unreadable(error))
        }

        let version: Int
        do {
            version = try decoder.decode(DocumentVersion.self, from: data).schemaVersion
        } catch {
            return .failure(.malformed(error))
        }

        // This switch is the migration seam: future schemas decode into their
        // own DTO and migrate to the current domain record before returning.
        switch version {
        case 1:
            do {
                let document = try decoder.decode(HistoryDocumentV1.self, from: data)
                return .success(try document.records.map { try $0.domainRecord })
            } catch {
                return .failure(.malformed(error))
            }
        default:
            return .failure(.unsupportedVersion(version))
        }
    }

    static func preserveCorruptedDocument(
        at fileURL: URL,
        failure: LoadFailure
    ) -> LocalHistoryPersistenceNotice {
        let reason: String
        switch failure {
        case let .unreadable(error), let .malformed(error):
            reason = safeReason(for: error)
        case let .unsupportedVersion(version):
            reason = "Unsupported history schema version \(version)."
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).json")

        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            pruneRecoveryArtifacts(for: fileURL, preserving: backupURL)
            return .corruptedDataPreserved(backupURL: backupURL, reason: reason)
        } catch {
            return .writeFailed(
                reason: "History data is corrupt and could not be preserved: \(safeReason(for: error))"
            )
        }
    }

    static func safeReason(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }

    static func pruneRecoveryArtifacts(
        for fileURL: URL,
        preserving preservedURL: URL? = nil
    ) {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        RecoveryArchivePruner.pruneRegularFiles(
            in: fileURL.deletingLastPathComponent(),
            prefix: "\(baseName).corrupt-",
            suffix: ".json",
            preserving: preservedURL
        )
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
    let dictionarySnapshotEntries: [DictionaryEntry]?
    let dictionaryRequestContext: DictionaryRequestContext?
    let dictionaryReplacements: [DictionaryReplacement]?
    let durationMilliseconds: Int?
    let stageDurationsMilliseconds: [String: Int]?
    let outcome: HistoryOutcomeV1

    init(_ record: VoiceInputHistoryRecord) {
        sessionID = record.sessionID.rawValue
        startedAt = record.startedAt
        applicationName = record.applicationName
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
        case let .preparing(id):
            self.init(kind: .preparing, sessionID: id.rawValue)
        case let .recording(id):
            self.init(kind: .recording, sessionID: id.rawValue)
        case let .processing(id, stage, applicationName):
            self.init(
                kind: .processing,
                sessionID: id.rawValue,
                processingStage: Self.encode(stage),
                applicationName: applicationName
            )
        case let .delivered(id, applicationName, text):
            self.init(
                kind: .delivered,
                sessionID: id.rawValue,
                applicationName: applicationName,
                text: text
            )
        case let .pendingCopy(id, text, reason):
            self.init(
                kind: .pendingCopy,
                sessionID: id.rawValue,
                text: text,
                pendingCopyReason: reason.rawValue
            )
        case let .cancelled(id):
            self.init(kind: .cancelled, sessionID: id.rawValue)
        case let .failed(id, failure):
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
                guard let applicationName else {
                    throw HistoryRecordDecodingError.missingField("applicationName")
                }
                guard let text else {
                    throw HistoryRecordDecodingError.missingField("text")
                }
                return .delivered(
                    try requiredSessionID(),
                    applicationName: applicationName,
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
