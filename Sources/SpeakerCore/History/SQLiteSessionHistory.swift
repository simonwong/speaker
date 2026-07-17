import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

private final class SQLiteHistoryConnection: @unchecked Sendable {
    static let schemaVersion: Int32 = 1

    private(set) var raw: OpaquePointer?

    init(fileURL: URL) throws {
        try OwnerOnlyFilePersistence.protectExistingFile(at: fileURL)
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection
        else {
            if let connection { sqlite3_close(connection) }
            throw SQLiteHistoryError.openFailed
        }
        raw = connection
        do {
            try Self.execute("PRAGMA journal_mode=WAL", on: connection)
            try Self.execute("PRAGMA synchronous=FULL", on: connection)
            try Self.execute("PRAGMA secure_delete=ON", on: connection)
            try Self.execute("PRAGMA busy_timeout=3000", on: connection)
            try Self.execute(
                """
                CREATE TABLE IF NOT EXISTS history_records (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    payload_schema INTEGER NOT NULL DEFAULT 1
                )
                """,
                on: connection
            )
            try Self.execute(
                "CREATE INDEX IF NOT EXISTS history_started_at ON history_records(started_at DESC)",
                on: connection
            )
            try Self.execute(
                """
                CREATE TABLE IF NOT EXISTS history_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value INTEGER NOT NULL
                )
                """,
                on: connection
            )
            if try !Self.table(
                "history_records",
                containsColumn: "payload_schema",
                on: connection
            ) {
                try Self.execute(
                    "ALTER TABLE history_records ADD COLUMN payload_schema INTEGER NOT NULL DEFAULT 1",
                    on: connection
                )
            }
            let userVersion = try Self.integerValue("PRAGMA user_version", on: connection)
            guard userVersion <= Self.schemaVersion else {
                throw SQLiteHistoryError.unsupportedSchema(userVersion)
            }
            if userVersion == 0 {
                try Self.execute(
                    "PRAGMA user_version=\(Self.schemaVersion)",
                    on: connection
                )
            }
            let integrity = try Self.textValue("PRAGMA quick_check(1)", on: connection)
            guard integrity == "ok" else {
                throw SQLiteHistoryError.integrityCheckFailed(integrity ?? "unknown")
            }
            try Self.protectDatabaseFiles(at: fileURL)
        } catch {
            sqlite3_close(connection)
            throw error
        }
    }

    deinit {
        if let raw {
            sqlite3_close(raw)
        }
    }

    func close() throws {
        guard let raw else { return }
        let status = sqlite3_close(raw)
        guard status == SQLITE_OK else {
            throw SQLiteHistoryError.sqlite(
                code: status,
                message: Self.errorMessage(raw)
            )
        }
        self.raw = nil
    }

    static func execute(_ sql: String, on connection: OpaquePointer) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(connection),
                message: errorMessage(connection)
            )
        }
    }

    static func integerValue(_ sql: String, on connection: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(connection),
                message: errorMessage(connection)
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(connection),
                message: errorMessage(connection)
            )
        }
        return sqlite3_column_int(statement, 0)
    }

    static func textValue(_ sql: String, on connection: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(connection),
                message: errorMessage(connection)
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(connection),
                message: errorMessage(connection)
            )
        }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    static func table(
        _ tableName: String,
        containsColumn columnName: String,
        on connection: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            "PRAGMA table_info(\(tableName))",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(connection),
                message: errorMessage(connection)
            )
        }
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1),
               String(cString: value) == columnName {
                return true
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(connection),
                message: errorMessage(connection)
            )
        }
        return false
    }

    static func protectDatabaseFiles(at fileURL: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try OwnerOnlyFilePersistence.protectExistingFile(
                at: URL(fileURLWithPath: fileURL.path + suffix)
            )
        }
    }

    static func errorMessage(_ connection: OpaquePointer) -> String {
        sqlite3_errmsg(connection).map(String.init(cString:)) ?? "unknown sqlite error"
    }
}

private enum SQLiteHistoryError: Error {
    case openFailed
    case sqlite(code: Int32, message: String)
    case encoding
    case integrityCheckFailed(String)
    case unsupportedSchema(Int32)

    var isRecoverableCorruption: Bool {
        switch self {
        case let .sqlite(code, _):
            code == SQLITE_CORRUPT || code == SQLITE_NOTADB
        case .integrityCheckFailed:
            true
        case .openFailed, .encoding, .unsupportedSchema:
            false
        }
    }
}

/// Incremental, crash-safe production history store. Each meaningful session
/// update is one SQLite upsert instead of a rewrite of the entire history.
/// `secure_delete`, WAL truncation on destructive operations, owner-only file
/// permissions, age retention and a hard row cap define its privacy boundary.
public actor SQLiteSessionHistory: LocalSessionHistoryStoring {
    public static let defaultMaximumRecordCount = 10_000

    private let fileURL: URL
    private var connection: SQLiteHistoryConnection?
    private let maximumRecordCount: Int
    private var retentionPolicy: HistoryRetentionPolicy
    private var notice: LocalHistoryPersistenceNotice?
    private var privacyMigrationFailureReason: String?
    private var destructiveCheckpointPending = false

    public init(
        fileURL: URL,
        retentionPolicy: HistoryRetentionPolicy = .forever,
        maximumRecordCount: Int = SQLiteSessionHistory.defaultMaximumRecordCount
    ) {
        self.fileURL = fileURL
        self.retentionPolicy = retentionPolicy
        self.maximumRecordCount = max(1, maximumRecordCount)
        Self.pruneRecoveryArtifacts(for: fileURL)
        var resolvedConnection: SQLiteHistoryConnection?
        var resolvedNotice: LocalHistoryPersistenceNotice?
        do {
            resolvedConnection = try SQLiteHistoryConnection(fileURL: fileURL)
        } catch let error as SQLiteHistoryError where error.isRecoverableCorruption {
            do {
                let backupURL = try Self.preserveCorruptedDatabase(at: fileURL)
                resolvedConnection = try SQLiteHistoryConnection(fileURL: fileURL)
                resolvedNotice = .corruptedDataPreserved(
                    backupURL: backupURL,
                    reason: Self.safeReason(error)
                )
            } catch {
                resolvedNotice = .writeFailed(reason: Self.safeReason(error))
            }
        } catch {
            resolvedNotice = .writeFailed(reason: Self.safeReason(error))
        }
        connection = resolvedConnection
        notice = resolvedNotice
        if resolvedNotice == nil, let db = resolvedConnection?.raw {
            do {
                // A process may have terminated after committing a destructive
                // transaction but before truncating WAL. Reconcile that gap at
                // every clean open before the store is used.
                try Self.truncateCheckpoint(db, fileURL: fileURL)
            } catch {
                notice = .writeFailed(reason: Self.safeReason(error))
            }
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
            .appendingPathComponent("history.sqlite3", isDirectory: false)
    }

    public func save(_ record: VoiceInputHistoryRecord) async {
        guard let db = connection?.raw else { return }
        do {
            let payload = try Self.encoder.encode(HistoryRecordV1(record))
            let pruned: Bool
            try beginTransaction(db)
            do {
                try upsert(record, payload: payload, db: db)
                pruned = try prune(now: Date(), db: db)
                try commitTransaction(db)
            } catch {
                rollbackTransaction(db)
                throw error
            }
            destructiveCheckpointPending = destructiveCheckpointPending || pruned
            if destructiveCheckpointPending {
                try checkpoint(db)
            }
            try protectSQLiteFiles()
            clearOperationalNotice()
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
        } catch {
            notice = .writeFailed(reason: Self.safeReason(error))
        }
    }

    public func allRecords() async -> [VoiceInputHistoryRecord] {
        loadRecords(whereClause: nil, binding: nil)
    }

    public func record(sessionID: VoiceInputSessionID) async -> VoiceInputHistoryRecord? {
        loadRecords(
            whereClause: "WHERE session_id = ?",
            binding: sessionID.rawValue.uuidString
        ).first
    }

    public func search(_ query: String) async -> [VoiceInputHistoryRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return loadRecords(whereClause: nil, binding: nil) }
        return loadRecords(whereClause: nil, binding: nil).filter { record in
            SessionHistoryRecordPolicy.searchableValues(record).contains { value in
                value.range(
                    of: normalized,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) != nil
            }
        }
    }

    public func delete(sessionID: VoiceInputSessionID) async -> Bool {
        guard let db = connection?.raw else { return false }
        do {
            try beginTransaction(db)
            let deleted: Bool
            do {
                let statement = try prepare(
                    "DELETE FROM history_records WHERE session_id = ?",
                    db: db
                )
                defer { sqlite3_finalize(statement) }
                try bind(sessionID.rawValue.uuidString, at: 1, to: statement, db: db)
                try stepDone(statement, db: db)
                deleted = sqlite3_changes(db) > 0
                try commitTransaction(db)
            } catch {
                rollbackTransaction(db)
                throw error
            }
            guard deleted else { return false }
            destructiveCheckpointPending = true
            try checkpoint(db)
            try protectSQLiteFiles()
            clearOperationalNotice()
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: Self.safeReason(error))
            return false
        }
    }

    public func clear() async -> Bool {
        guard let db = connection?.raw else { return false }
        do {
            try SQLiteHistoryConnection.execute("DELETE FROM history_records", on: db)
            destructiveCheckpointPending = true
            try checkpoint(db)
            try SQLiteHistoryConnection.execute("VACUUM", on: db)
            // VACUUM can write a fresh transaction while WAL mode is active.
            // Truncate again so a user-requested clear leaves no stale pages
            // behind in the sidecar.
            try checkpoint(db)
            try protectSQLiteFiles()
            try removeLegacyRecoveryArtifacts()
            notice = nil
            privacyMigrationFailureReason = nil
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: Self.safeReason(error))
            return false
        }
    }

    /// Closes the live SQLite handle before Speaker-owned files are removed.
    ///
    /// An erasure flow must call this only after voice input and every history
    /// writer have quiesced. A busy close is a hard failure: deleting an open
    /// database would make the result impossible to verify.
    public func closeForErasure() async -> Bool {
        guard let connection else { return true }
        guard let db = connection.raw else {
            self.connection = nil
            return true
        }
        do {
            try checkpoint(db)
            try connection.close()
            self.connection = nil
            return true
        } catch {
            notice = .writeFailed(reason: Self.safeReason(error))
            return false
        }
    }

    /// Removes response text from records written by older builds. Provider
    /// messages are not a stable diagnostic contract and may echo credentials
    /// or user context, so only structured provider metadata is retained.
    @discardableResult
    public func scrubUntrustedProviderMessages() async -> Bool {
        guard let db = connection?.raw else {
            privacyMigrationFailureReason = "本地历史数据库不可用。"
            return false
        }
        do {
            let plan = try privacyScrubPlan(db: db)
            let completedVersion = try privacyScrubVersion(db: db)
            let requiresPhysicalSanitization = plan.hasChanges
                || completedVersion < Self.currentPrivacyScrubVersion

            if plan.hasChanges {
                try beginTransaction(db)
                do {
                    for rewrite in plan.rewrites {
                        try rewritePayload(
                            rewrite.payload,
                            sessionID: rewrite.sessionID,
                            db: db
                        )
                    }
                    for sessionID in plan.deletions {
                        try deleteRow(sessionID: sessionID, db: db)
                    }
                    try commitTransaction(db)
                } catch {
                    rollbackTransaction(db)
                    throw error
                }
            }

            if requiresPhysicalSanitization {
                try checkpoint(db)
                try SQLiteHistoryConnection.execute("VACUUM", on: db)
                try checkpoint(db)
                try markPrivacyScrubCompleted(db: db)
                try checkpoint(db)
            }

            try verifyPrivacyScrub(db: db)
            try protectSQLiteFiles()
            privacyMigrationFailureReason = nil
            if !plan.deletions.isEmpty {
                notice = .corruptedRecordsSkipped(
                    count: plan.deletions.count
                )
            } else {
                clearOperationalNotice()
            }
            return true
        } catch {
            privacyMigrationFailureReason = Self.safeReason(error)
            return false
        }
    }

    public func persistenceStatus() async -> LocalHistoryPersistenceStatus {
        LocalHistoryPersistenceStatus(
            recordCount: count(),
            notice: visibleNotice
        )
    }

    /// Converts nonterminal records left by a previous process into an exact
    /// terminal fact. The current process cannot resume their recorder,
    /// provider connection, target snapshot, or delivery transaction.
    @discardableResult
    public func reconcileInterruptedSessions() async -> Int? {
        guard let db = connection?.raw else { return nil }
        let interrupted = loadRecords(
            whereClause: nil,
            binding: nil
        ).compactMap(Self.interruptedRecord)
        guard !interrupted.isEmpty else { return 0 }

        do {
            try beginTransaction(db)
            do {
                for record in interrupted {
                    try upsert(
                        record,
                        payload: Self.encoder.encode(
                            HistoryRecordV1(record)
                        ),
                        db: db
                    )
                }
                try commitTransaction(db)
            } catch {
                rollbackTransaction(db)
                throw error
            }
            try checkpoint(db)
            try protectSQLiteFiles()
            clearOperationalNotice()
            NotificationCenter.default.post(
                name: .speakerHistoryDidChange,
                object: nil
            )
            return interrupted.count
        } catch {
            notice = .writeFailed(reason: Self.safeReason(error))
            return nil
        }
    }

    public func persistenceFailureNotice() async -> String? {
        switch visibleNotice {
        case let .privacyMigrationFailed(reason):
            return "旧版会话历史的隐私清理失败：\(reason)"
        case let .writeFailed(reason):
            return "会话历史写入失败：\(reason)"
        case let .corruptedRecordsSkipped(count):
            return "有 \(count) 条本地历史记录已损坏，其他记录仍可使用。"
        case .corruptedDataPreserved, nil:
            return nil
        }
    }

    public func clearPersistenceNotice() async {
        notice = nil
    }

    public func currentRetentionPolicy() async -> HistoryRetentionPolicy {
        retentionPolicy
    }

    public func applyRetentionPolicy(
        _ policy: HistoryRetentionPolicy,
        now: Date = Date()
    ) async -> Bool {
        guard let db = connection?.raw else { return false }
        // The policy is user intent and governs every later save even when
        // immediate cleanup cannot finish. A transaction may commit before a
        // WAL checkpoint reports busy, so pretending to roll the policy back
        // would contradict data that has already been deleted.
        retentionPolicy = policy
        do {
            let pruned: Bool
            try beginTransaction(db)
            do {
                pruned = try prune(now: now, db: db)
                try commitTransaction(db)
            } catch {
                rollbackTransaction(db)
                throw error
            }
            destructiveCheckpointPending = destructiveCheckpointPending || pruned
            try checkpoint(db)
            try protectSQLiteFiles()
            clearOperationalNotice()
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: Self.safeReason(error))
            return false
        }
    }

    public func importLegacyRecords(_ records: [VoiceInputHistoryRecord]) async -> Bool {
        guard let db = connection?.raw else { return false }
        do {
            let now = Date()
            var merged = Dictionary(
                uniqueKeysWithValues: loadRecords(whereClause: nil, binding: nil)
                    .map { ($0.sessionID, $0) }
            )
            for record in records {
                merged[record.sessionID] = record
            }
            let expected = SessionHistoryRecordPolicy.retained(
                Array(merged.values),
                policy: retentionPolicy,
                maximumCount: maximumRecordCount,
                now: now
            )
            let pruned: Bool
            try beginTransaction(db)
            do {
                for record in expected {
                    try upsert(
                        record,
                        payload: Self.encoder.encode(HistoryRecordV1(record)),
                        db: db
                    )
                }
                pruned = try prune(now: now, db: db)
                try commitTransaction(db)
            } catch {
                rollbackTransaction(db)
                throw error
            }
            destructiveCheckpointPending = destructiveCheckpointPending || pruned
            try checkpoint(db)
            try protectSQLiteFiles()
            for expectedRecord in expected {
                let expectedPayload = try Self.encoder.encode(HistoryRecordV1(expectedRecord))
                guard try storedPayload(
                    sessionID: expectedRecord.sessionID,
                    db: db
                ) == expectedPayload else {
                    throw SQLiteHistoryError.encoding
                }
            }
            clearOperationalNotice()
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: Self.safeReason(error))
            return false
        }
    }

    private func loadRecords(
        whereClause: String?,
        binding: String?
    ) -> [VoiceInputHistoryRecord] {
        guard let db = connection?.raw else { return [] }
        do {
            let sql = "SELECT payload, payload_schema FROM history_records \(whereClause ?? "") ORDER BY started_at DESC, session_id DESC"
            let statement = try prepare(sql, db: db)
            defer { sqlite3_finalize(statement) }
            if let binding { try bind(binding, at: 1, to: statement, db: db) }
            var records: [VoiceInputHistoryRecord] = []
            var stepStatus = sqlite3_step(statement)
            var corruptedRecordCount = 0
            while stepStatus == SQLITE_ROW {
                guard sqlite3_column_int(statement, 1) == SQLiteHistoryConnection.schemaVersion else {
                    corruptedRecordCount += 1
                    stepStatus = sqlite3_step(statement)
                    continue
                }
                guard let bytes = sqlite3_column_blob(statement, 0) else {
                    throw SQLiteHistoryError.encoding
                }
                let count = Int(sqlite3_column_bytes(statement, 0))
                let data = Data(bytes: bytes, count: count)
                do {
                    records.append(
                        try Self.decoder.decode(HistoryRecordV1.self, from: data).domainRecord
                    )
                } catch {
                    // One malformed payload must not hide every healthy session.
                    // Keep the row untouched for diagnosis and surface an exact
                    // persistence notice until the user clears or exports it.
                    corruptedRecordCount += 1
                }
                stepStatus = sqlite3_step(statement)
            }
            guard stepStatus == SQLITE_DONE else {
                throw SQLiteHistoryError.sqlite(
                    code: sqlite3_extended_errcode(db),
                    message: SQLiteHistoryConnection.errorMessage(db)
                )
            }
            if corruptedRecordCount > 0 {
                notice = .corruptedRecordsSkipped(count: corruptedRecordCount)
            }
            return records
        } catch {
            notice = .writeFailed(reason: Self.safeReason(error))
            return []
        }
    }

    private func storedPayload(
        sessionID: VoiceInputSessionID,
        db: OpaquePointer
    ) throws -> Data? {
        let statement = try prepare(
            "SELECT payload FROM history_records WHERE session_id = ?",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID.rawValue.uuidString, at: 1, to: statement, db: db)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(db),
                message: SQLiteHistoryConnection.errorMessage(db)
            )
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private static func interruptedRecord(
        _ record: VoiceInputHistoryRecord
    ) -> VoiceInputHistoryRecord? {
        let stage: String
        switch record.outcome {
        case .preparing:
            stage = "preparing"
        case .recording:
            stage = "recording"
        case let .processing(_, processingStage, _):
            stage = switch processingStage {
            case .capturingTarget: "capturingTarget"
            case .transcribing: "transcribing"
            case .refining: "refining"
            case .delivering: "delivering"
            }
        case .idle, .delivered, .pendingCopy, .cancelled, .failed:
            return nil
        }

        return VoiceInputHistoryRecord(
            sessionID: record.sessionID,
            startedAt: record.startedAt,
            applicationName: record.applicationName,
            transcription: record.transcription,
            finalText: record.finalText,
            transcriptionProvider: record.transcriptionProvider,
            providerRequestID: record.providerRequestID,
            providerErrorCode: "application.interrupted.\(stage)",
            providerOperation: record.providerOperation,
            providerStatusCode: record.providerStatusCode,
            providerMessage: nil,
            deepSeekText: record.deepSeekText,
            deepSeekRequestID: record.deepSeekRequestID,
            refinementModeName: record.refinementModeName,
            refinementPrompt: record.refinementPrompt,
            refinementStatus: record.refinementStatus,
            refinementFailureCode: record.refinementFailureCode,
            refinementFailureStatusCode:
                record.refinementFailureStatusCode,
            refinementFailureMessage: nil,
            cancelledAtStage: nil,
            dictionarySnapshotID: record.dictionarySnapshotID,
            dictionarySnapshotEntries:
                record.dictionarySnapshotEntries,
            dictionaryRequestContext: record.dictionaryRequestContext,
            dictionaryReplacements: record.dictionaryReplacements,
            durationMilliseconds: record.durationMilliseconds,
            stageDurationsMilliseconds:
                record.stageDurationsMilliseconds,
            outcome: .failed(
                record.sessionID,
                .sessionInterrupted
            )
        )
    }

    private struct PrivacyScrubPlan {
        struct Rewrite {
            let sessionID: String
            let payload: Data
        }

        var rewrites: [Rewrite] = []
        var deletions: [String] = []

        var hasChanges: Bool {
            !rewrites.isEmpty || !deletions.isEmpty
        }
    }

    private static let currentPrivacyScrubVersion: Int32 = 1
    private static let privacyScrubMetadataKey = "provider_message_scrub"

    private var visibleNotice: LocalHistoryPersistenceNotice? {
        if let privacyMigrationFailureReason {
            return .privacyMigrationFailed(
                reason: privacyMigrationFailureReason
            )
        }
        return notice
    }

    private func privacyScrubPlan(
        db: OpaquePointer
    ) throws -> PrivacyScrubPlan {
        let statement = try prepare(
            """
            SELECT session_id, payload, payload_schema
            FROM history_records
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        var plan = PrivacyScrubPlan()
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            guard let sessionIDBytes = sqlite3_column_text(statement, 0) else {
                throw SQLiteHistoryError.encoding
            }
            let sessionID = String(cString: sessionIDBytes)
            guard sqlite3_column_int(statement, 2)
                    == SQLiteHistoryConnection.schemaVersion,
                  let payloadBytes = sqlite3_column_blob(statement, 1)
            else {
                plan.deletions.append(sessionID)
                stepStatus = sqlite3_step(statement)
                continue
            }

            let payload = Data(
                bytes: payloadBytes,
                count: Int(sqlite3_column_bytes(statement, 1))
            )
            guard var object = try? JSONSerialization.jsonObject(
                with: payload
            ) as? [String: Any] else {
                plan.deletions.append(sessionID)
                stepStatus = sqlite3_step(statement)
                continue
            }

            let containedUntrustedText =
                object.keys.contains("providerMessage")
                || object.keys.contains("refinementFailureMessage")
            object.removeValue(forKey: "providerMessage")
            object.removeValue(forKey: "refinementFailureMessage")

            guard let sanitizedPayload = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ), let stored = try? Self.decoder.decode(
                HistoryRecordV1.self,
                from: sanitizedPayload
            ), (try? stored.domainRecord) != nil else {
                plan.deletions.append(sessionID)
                stepStatus = sqlite3_step(statement)
                continue
            }

            if containedUntrustedText {
                plan.rewrites.append(.init(
                    sessionID: sessionID,
                    payload: sanitizedPayload
                ))
            }
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(db),
                message: SQLiteHistoryConnection.errorMessage(db)
            )
        }
        return plan
    }

    private func verifyPrivacyScrub(db: OpaquePointer) throws {
        let verification = try privacyScrubPlan(db: db)
        guard !verification.hasChanges else {
            throw SQLiteHistoryError.encoding
        }
    }

    private func rewritePayload(
        _ payload: Data,
        sessionID: String,
        db: OpaquePointer
    ) throws {
        let statement = try prepare(
            "UPDATE history_records SET payload = ? WHERE session_id = ?",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(payload, at: 1, to: statement, db: db)
        try bind(sessionID, at: 2, to: statement, db: db)
        try stepDone(statement, db: db)
    }

    private func deleteRow(
        sessionID: String,
        db: OpaquePointer
    ) throws {
        let statement = try prepare(
            "DELETE FROM history_records WHERE session_id = ?",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, to: statement, db: db)
        try stepDone(statement, db: db)
    }

    private func privacyScrubVersion(db: OpaquePointer) throws -> Int32 {
        let statement = try prepare(
            "SELECT value FROM history_metadata WHERE key = ?",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            Self.privacyScrubMetadataKey,
            at: 1,
            to: statement,
            db: db
        )
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return 0 }
        guard status == SQLITE_ROW else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(db),
                message: SQLiteHistoryConnection.errorMessage(db)
            )
        }
        return sqlite3_column_int(statement, 0)
    }

    private func markPrivacyScrubCompleted(db: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO history_metadata(key, value)
            VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            Self.privacyScrubMetadataKey,
            at: 1,
            to: statement,
            db: db
        )
        sqlite3_bind_int(
            statement,
            2,
            Self.currentPrivacyScrubVersion
        )
        try stepDone(statement, db: db)
    }

    private func count() -> Int {
        guard let db = connection?.raw,
              let statement = try? prepare("SELECT COUNT(*) FROM history_records", db: db)
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prune(now: Date, db: OpaquePointer) throws -> Bool {
        var deletedRecord = false
        if let days = retentionPolicy.maximumAgeDays,
           let cutoff = Calendar(identifier: .gregorian).date(
               byAdding: .day,
               value: -days,
               to: now
           ) {
            let statement = try prepare(
                "DELETE FROM history_records WHERE started_at < ?",
                db: db
            )
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            defer { sqlite3_finalize(statement) }
            try stepDone(statement, db: db)
            deletedRecord = sqlite3_changes(db) > 0
        }
        let capStatement = try prepare(
            """
            DELETE FROM history_records
            WHERE session_id IN (
                SELECT session_id FROM history_records
                ORDER BY started_at DESC, session_id DESC
                LIMIT -1 OFFSET ?
            )
            """,
            db: db
        )
        sqlite3_bind_int64(capStatement, 1, Int64(maximumRecordCount))
        defer { sqlite3_finalize(capStatement) }
        try stepDone(capStatement, db: db)
        return deletedRecord || sqlite3_changes(db) > 0
    }

    private func checkpoint(_ db: OpaquePointer) throws {
        try Self.truncateCheckpoint(db, fileURL: fileURL)
        destructiveCheckpointPending = false
    }

    private static func truncateCheckpoint(
        _ db: OpaquePointer,
        fileURL: URL
    ) throws {
        var logFrameCount: Int32 = -1
        var checkpointedFrameCount: Int32 = -1
        let result = sqlite3_wal_checkpoint_v2(
            db,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrameCount,
            &checkpointedFrameCount
        )
        guard result == SQLITE_OK else {
            throw SQLiteHistoryError.sqlite(
                code: result,
                message: SQLiteHistoryConnection.errorMessage(db)
            )
        }
        let walURL = URL(fileURLWithPath: fileURL.path + "-wal")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: walURL.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value != 0
        {
            throw SQLiteHistoryError.sqlite(
                code: SQLITE_BUSY,
                message: "The local history write-ahead log is still in use."
            )
        }
    }

    private func beginTransaction(_ db: OpaquePointer) throws {
        try SQLiteHistoryConnection.execute("BEGIN IMMEDIATE", on: db)
    }

    private func commitTransaction(_ db: OpaquePointer) throws {
        try SQLiteHistoryConnection.execute("COMMIT", on: db)
    }

    private func rollbackTransaction(_ db: OpaquePointer) {
        try? SQLiteHistoryConnection.execute("ROLLBACK", on: db)
    }

    private func upsert(
        _ record: VoiceInputHistoryRecord,
        payload: Data,
        db: OpaquePointer
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO history_records(session_id, started_at, payload, payload_schema)
            VALUES(?, ?, ?, 1)
            ON CONFLICT(session_id) DO UPDATE SET
                started_at=excluded.started_at,
                payload=excluded.payload,
                payload_schema=excluded.payload_schema
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(record.sessionID.rawValue.uuidString, at: 1, to: statement, db: db)
        sqlite3_bind_double(statement, 2, record.startedAt.timeIntervalSince1970)
        try bind(payload, at: 3, to: statement, db: db)
        try stepDone(statement, db: db)
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(db),
                message: SQLiteHistoryConnection.errorMessage(db)
            )
        }
        return statement
    }

    private func bind(
        _ value: String,
        at index: Int32,
        to statement: OpaquePointer,
        db: OpaquePointer
    ) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(db),
                message: SQLiteHistoryConnection.errorMessage(db)
            )
        }
    }

    private func bind(
        _ value: Data,
        at index: Int32,
        to statement: OpaquePointer,
        db: OpaquePointer
    ) throws {
        let status = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement,
                index,
                buffer.baseAddress,
                Int32(buffer.count),
                sqliteTransient
            )
        }
        guard status == SQLITE_OK else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(db),
                message: SQLiteHistoryConnection.errorMessage(db)
            )
        }
    }

    private func stepDone(_ statement: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteHistoryError.sqlite(
                code: sqlite3_extended_errcode(db),
                message: SQLiteHistoryConnection.errorMessage(db)
            )
        }
    }

    private func removeLegacyRecoveryArtifacts() throws {
        let directory = fileURL.deletingLastPathComponent()
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates {
            let name = candidate.lastPathComponent
            if name == "history.json"
                || name.hasPrefix("history.corrupt-")
                || name.hasPrefix("history.migrated-")
            {
                try FileManager.default.removeItem(at: candidate)
            }
        }
    }

    private func protectSQLiteFiles() throws {
        try SQLiteHistoryConnection.protectDatabaseFiles(at: fileURL)
    }

    private func clearOperationalNotice() {
        if case .writeFailed = notice {
            notice = nil
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func preserveCorruptedDatabase(at fileURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        let backupDirectory = parent.appendingPathComponent(
            "history.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            var preservedAnyFile = false
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let source = URL(fileURLWithPath: fileURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = backupDirectory.appendingPathComponent(
                    fileURL.lastPathComponent + suffix,
                    isDirectory: false
                )
                try fileManager.moveItem(at: source, to: destination)
                try OwnerOnlyFilePersistence.protectExistingFile(at: destination)
                preservedAnyFile = true
            }
            guard preservedAnyFile else {
                throw SQLiteHistoryError.openFailed
            }
            pruneRecoveryArtifacts(for: fileURL, preserving: backupDirectory)
            return backupDirectory
        } catch {
            // Do not leave a half-moved recovery set. Restore anything that was
            // already moved before surfacing the failure. If even one restore
            // cannot complete, keep the recovery directory: deleting it here
            // could destroy the only remaining copy of a user's history.
            var restoredEveryCandidate = true
            if let candidates = try? fileManager.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: nil
            ) {
                for candidate in candidates {
                    let destination = parent.appendingPathComponent(candidate.lastPathComponent)
                    if !fileManager.fileExists(atPath: destination.path) {
                        do {
                            try fileManager.moveItem(at: candidate, to: destination)
                        } catch {
                            restoredEveryCandidate = false
                        }
                    } else {
                        restoredEveryCandidate = false
                    }
                }
            } else {
                restoredEveryCandidate = false
            }
            if restoredEveryCandidate {
                try? fileManager.removeItem(at: backupDirectory)
            }
            throw error
        }
    }

    private static func pruneRecoveryArtifacts(
        for fileURL: URL,
        preserving preservedURL: URL? = nil
    ) {
        RecoveryArchivePruner.pruneFlatDirectories(
            in: fileURL.deletingLastPathComponent(),
            prefix: "history.corrupt-",
            preserving: preservedURL
        )
    }

    private static func safeReason(_ error: Error) -> String {
        switch error {
        case let SQLiteHistoryError.sqlite(_, message):
            return message
        case SQLiteHistoryError.openFailed:
            return "Unable to open the local history database."
        case SQLiteHistoryError.encoding:
            return "A local history record could not be decoded."
        case let SQLiteHistoryError.integrityCheckFailed(message):
            return "The local history database failed its integrity check: \(message)"
        case let SQLiteHistoryError.unsupportedSchema(version):
            return "The local history database uses unsupported schema version \(version)."
        default:
            let nsError = error as NSError
            return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
        }
    }
}
