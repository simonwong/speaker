import Foundation

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
    case writeFailed(reason: String)
}

/// A permanent, local history store whose on-disk representation contains only
/// an explicit allow-list of `VoiceInputHistoryRecord` fields.
///
/// Audio, credentials, accessibility objects, the target's original value, and
/// clipboard contents are not accepted by this API and cannot be encoded by its
/// persistence DTOs.
public actor VersionedLocalSessionHistory: SessionHistoryRecording {
    public static let currentSchemaVersion = 1

    private let fileURL: URL
    private var storedRecords: [VoiceInputHistoryRecord]
    private var notice: LocalHistoryPersistenceNotice?

    public init(fileURL: URL) {
        self.fileURL = fileURL

        switch Self.loadDocument(at: fileURL) {
        case let .success(records):
            storedRecords = Self.sort(records)
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
        storedRecords = Self.sort(storedRecords)
        persistCurrentRecords()
    }

    public func allRecords() -> [VoiceInputHistoryRecord] {
        storedRecords
    }

    public func record(sessionID: VoiceInputSessionID) -> VoiceInputHistoryRecord? {
        storedRecords.first { $0.sessionID == sessionID }
    }

    /// Searches all user-visible and diagnostic text retained by the history
    /// model. Matching is localized, case-insensitive, and diacritic-insensitive.
    public func search(_ query: String) -> [VoiceInputHistoryRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return storedRecords }

        return storedRecords.filter { record in
            [
                record.transcription,
                record.finalText,
                record.applicationName,
                record.providerErrorCode,
                record.providerRequestID,
                record.deepSeekText,
                record.deepSeekRequestID,
                record.refinementModeName,
                record.refinementFailureCode,
            ]
            .compactMap { $0 }
            .contains { value in
                value.range(
                    of: normalizedQuery,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) != nil
            }
        }
    }

    @discardableResult
    public func delete(sessionID: VoiceInputSessionID) -> Bool {
        let originalCount = storedRecords.count
        storedRecords.removeAll { $0.sessionID == sessionID }
        guard storedRecords.count != originalCount else { return false }
        persistCurrentRecords()
        return true
    }

    public func clear() {
        storedRecords.removeAll(keepingCapacity: false)
        persistCurrentRecords()
    }

    public func persistenceStatus() -> LocalHistoryPersistenceStatus {
        LocalHistoryPersistenceStatus(
            recordCount: storedRecords.count,
            notice: notice
        )
    }

    /// Notices remain visible across later successful writes so the UI cannot
    /// silently hide a recovered corruption event. The user may dismiss it.
    public func clearPersistenceNotice() {
        notice = nil
    }

    private func persistCurrentRecords() {
        do {
            let document = HistoryDocumentV1(
                schemaVersion: Self.currentSchemaVersion,
                records: storedRecords.map(HistoryRecordV1.init)
            )
            let data = try Self.encoder.encode(document)
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            notice = .writeFailed(reason: Self.safeReason(for: error))
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .success([])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
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

    static func sort(_ records: [VoiceInputHistoryRecord]) -> [VoiceInputHistoryRecord] {
        records.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.sessionID.rawValue.uuidString > $1.sessionID.rawValue.uuidString
            }
            return $0.startedAt > $1.startedAt
        }
    }
}

private struct HistoryDocumentV1: Codable {
    let schemaVersion: Int
    let records: [HistoryRecordV1]
}

private struct HistoryRecordV1: Codable {
    let sessionID: UUID
    let startedAt: Date
    let applicationName: String?
    let transcription: String?
    let finalText: String?
    let providerRequestID: String?
    let providerErrorCode: String?
    let deepSeekText: String?
    let deepSeekRequestID: String?
    let refinementModeName: String?
    let refinementStatus: String?
    let refinementFailureCode: String?
    let dictionarySnapshotID: UUID?
    let dictionaryReplacements: [DictionaryReplacement]?
    let outcome: HistoryOutcomeV1

    init(_ record: VoiceInputHistoryRecord) {
        sessionID = record.sessionID.rawValue
        startedAt = record.startedAt
        applicationName = record.applicationName
        transcription = record.transcription
        finalText = record.finalText
        providerRequestID = record.providerRequestID
        providerErrorCode = record.providerErrorCode
        deepSeekText = record.deepSeekText
        deepSeekRequestID = record.deepSeekRequestID
        refinementModeName = record.refinementModeName
        refinementStatus = record.refinementStatus
        refinementFailureCode = record.refinementFailureCode
        dictionarySnapshotID = record.dictionarySnapshotID
        dictionaryReplacements = record.dictionaryReplacements
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
                providerRequestID: providerRequestID,
                providerErrorCode: providerErrorCode,
                deepSeekText: deepSeekText,
                deepSeekRequestID: deepSeekRequestID,
                refinementModeName: refinementModeName,
                refinementStatus: refinementStatus,
                refinementFailureCode: refinementFailureCode,
                dictionarySnapshotID: dictionarySnapshotID,
                dictionaryReplacements: dictionaryReplacements ?? [],
                outcome: try outcome.domainOutcome
            )
        }
    }
}

private struct HistoryOutcomeV1: Codable {
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
        case .delivering: "delivering"
        }
    }

    private static func decodeStage(_ value: String) throws -> VoiceInputProcessingStage {
        switch value {
        case "capturingTarget": .capturingTarget
        case "transcribing": .transcribing
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

private enum HistoryRecordDecodingError: Error {
    case missingField(String)
    case invalidField(String)
}
