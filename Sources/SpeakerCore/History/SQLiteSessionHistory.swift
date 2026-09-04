import Foundation

/// The on-disk history format: one schema version and the payload codec.
///
/// The store writes payloads and the privacy migration rewrites them, so both
/// cross the same encoder pair and compare against the same version.
enum SQLiteHistorySchema {
    static let version: Int32 = 1

    static var payloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static var payloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// Incremental, crash-safe production history store. Each meaningful session
/// update is one SQLite upsert instead of a rewrite of the entire history.
/// `secure_delete`, WAL truncation on destructive operations, owner-only file
/// permissions, age retention and a hard row cap define its privacy boundary.
///
/// It owns Session Record reads and writes, retention, interrupted-session
/// reconciliation, and WAL convergence. `SQLiteConnection` owns every call into
/// SQLite, `SQLiteHistoryPrivacyMigration` the legacy provider-message scrub,
/// and `SQLiteHistoryCorruptionRecovery` the preserved evidence of a damaged
/// database.
public actor SQLiteSessionHistory: LocalSessionHistoryStoring {
    public static let defaultMaximumRecordCount = 10_000

    private let fileURL: URL
    private var connection: SQLiteConnection?
    private let maximumRecordCount: Int
    private var retentionPolicy: HistoryRetentionPolicy
    private var notice: LocalHistoryPersistenceNotice?
    private var privacyMigrationFailureReason: LocalHistoryFailureReason?
    private var destructiveCheckpointPending = false

    public init(
        fileURL: URL,
        retentionPolicy: HistoryRetentionPolicy = .forever,
        maximumRecordCount: Int = SQLiteSessionHistory.defaultMaximumRecordCount
    ) {
        self.fileURL = fileURL
        self.retentionPolicy = retentionPolicy
        self.maximumRecordCount = max(1, maximumRecordCount)
        var pruning = SQLiteHistoryCorruptionRecovery.pruneRecoveryArtifacts(for: fileURL)
        var resolvedConnection: SQLiteConnection?
        var resolvedNotice: LocalHistoryPersistenceNotice?
        do {
            resolvedConnection = try Self.openStore(at: fileURL)
        } catch let error as SQLiteHistoryError where error.isRecoverableCorruption {
            do {
                let preserved = try SQLiteHistoryCorruptionRecovery
                    .preserveCorruptedDatabase(at: fileURL)
                pruning = preserved.pruning
                resolvedConnection = try Self.openStore(at: fileURL)
                resolvedNotice = .corruptedDataPreserved(
                    backupURL: preserved.backupURL,
                    reason: PrivacySafeText.reason(for: error)
                )
            } catch {
                resolvedNotice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            }
        } catch {
            resolvedNotice = .writeFailed(reason: PrivacySafeText.reason(for: error))
        }
        // Pruning cannot fail an open, but an archive directory that refuses to
        // shrink is worth saying out loud once nothing more urgent is pending.
        if resolvedNotice == nil, !pruning.isComplete {
            resolvedNotice = .recoveryArchivePruneFailed(
                reason: pruning.failures.joined(separator: "; ")
            )
        }
        connection = resolvedConnection
        notice = resolvedNotice
        if resolvedNotice == nil, let resolvedConnection {
            do {
                // A process may have terminated after committing a destructive
                // transaction but before truncating WAL. Reconcile that gap at
                // every clean open before the store is used.
                try resolvedConnection.truncateCheckpoint()
            } catch {
                notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
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
        guard let connection = openConnection else { return }
        guard SessionHistoryRecordPolicy.shouldRetain(record) else {
            if !loadRecords(
                whereClause: "WHERE session_id = ?",
                binding: record.sessionID.rawValue.uuidString
            ).isEmpty {
                _ = await delete(sessionID: record.sessionID)
            }
            return
        }
        guard retentionPolicy.savesNewRecords
                || !loadRecords(
                    whereClause: "WHERE session_id = ?",
                    binding: record.sessionID.rawValue.uuidString
                ).isEmpty
        else { return }
        do {
            let payload = try SQLiteHistorySchema.payloadEncoder.encode(
                HistoryRecordV1(record)
            )
            let pruned: Bool
            try connection.beginImmediateTransaction()
            do {
                try upsert(record, payload: payload, on: connection)
                pruned = try prune(now: Date(), on: connection)
                try connection.commitTransaction()
            } catch {
                connection.rollbackTransaction()
                throw error
            }
            destructiveCheckpointPending = destructiveCheckpointPending || pruned
            if destructiveCheckpointPending {
                try checkpoint(connection)
            }
            try connection.protectDatabaseFiles()
            clearOperationalNotice()
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
        }
    }

    public func allRecords() async -> [VoiceInputHistoryRecord] {
        loadRecords(whereClause: nil, binding: nil)
    }

    /// Streams every row through a `VoiceInputUsageAccumulator` so the overview's
    /// totals and per-day buckets never require the whole table in memory. Rows
    /// with an unknown schema or an undecodable payload are skipped, matching how
    /// `loadRecords` treats them.
    public func usageStatistics() async -> VoiceInputUsageSummary {
        guard let connection = openConnection else { return .empty }
        var accumulator = VoiceInputUsageAccumulator()
        do {
            let statement = try connection.prepare(
                "SELECT payload, payload_schema FROM history_records"
            )
            defer { statement.finalize() }
            while try statement.step() {
                guard statement.int32(at: 1) == SQLiteHistorySchema.version,
                      let payload = statement.blob(at: 0)
                else { continue }
                guard let stored = try? SQLiteHistorySchema.payloadDecoder.decode(
                    HistoryRecordV1.self,
                    from: payload
                ), let record = try? stored.domainRecord else { continue }
                guard SessionHistoryRecordPolicy.shouldRetain(record)
                else { continue }
                accumulator.add(record)
            }
            return accumulator.summary()
        } catch {
            return accumulator.summary()
        }
    }

    public func record(sessionID: VoiceInputSessionID) async -> VoiceInputHistoryRecord? {
        loadRecords(
            whereClause: "WHERE session_id = ?",
            binding: sessionID.rawValue.uuidString
        ).first
    }

    public func delete(sessionID: VoiceInputSessionID) async -> Bool {
        guard let connection = openConnection else { return false }
        do {
            try connection.beginImmediateTransaction()
            let deleted: Bool
            do {
                let statement = try connection.prepare(
                    "DELETE FROM history_records WHERE session_id = ?"
                )
                defer { statement.finalize() }
                try statement.bind(sessionID.rawValue.uuidString, at: 1)
                try statement.stepDone()
                deleted = connection.changeCount > 0
                try connection.commitTransaction()
            } catch {
                connection.rollbackTransaction()
                throw error
            }
            guard deleted else { return false }
            destructiveCheckpointPending = true
            try checkpoint(connection)
            try connection.protectDatabaseFiles()
            clearOperationalNotice()
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            return false
        }
    }

    public func clear() async -> Bool {
        guard let connection = openConnection else { return false }
        do {
            try connection.execute("DELETE FROM history_records")
            destructiveCheckpointPending = true
            try checkpoint(connection)
            try connection.execute("VACUUM")
            // VACUUM can write a fresh transaction while WAL mode is active.
            // Truncate again so a user-requested clear leaves no stale pages
            // behind in the sidecar.
            try checkpoint(connection)
            try connection.protectDatabaseFiles()
            try SQLiteHistoryCorruptionRecovery.removeLegacyArtifacts(around: fileURL)
            notice = nil
            privacyMigrationFailureReason = nil
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
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
        guard connection.isOpen else {
            self.connection = nil
            return true
        }
        do {
            try checkpoint(connection)
            try connection.close()
            self.connection = nil
            return true
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            return false
        }
    }

    /// Removes response text from records written by older builds. Provider
    /// messages are not a stable diagnostic contract and may echo credentials
    /// or user context, so only structured provider metadata is retained.
    @discardableResult
    public func scrubUntrustedProviderMessages() async -> Bool {
        guard let connection = openConnection else {
            privacyMigrationFailureReason = .databaseUnavailable
            return false
        }
        do {
            let outcome = try SQLiteHistoryPrivacyMigration.scrubUntrustedProviderMessages(
                on: connection,
                checkpoint: { try checkpoint(connection) }
            )
            try connection.protectDatabaseFiles()
            privacyMigrationFailureReason = nil
            if outcome.corruptedRecordCount > 0 {
                notice = .corruptedRecordsSkipped(
                    count: outcome.corruptedRecordCount
                )
            } else {
                clearOperationalNotice()
            }
            return true
        } catch {
            privacyMigrationFailureReason = .detail(PrivacySafeText.reason(for: error))
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
        guard let connection = openConnection else { return nil }
        let interrupted = loadRecords(
            whereClause: nil,
            binding: nil
        ).compactMap(Self.interruptedRecord)
        guard !interrupted.isEmpty else { return 0 }

        do {
            try connection.beginImmediateTransaction()
            do {
                for record in interrupted {
                    try upsert(
                        record,
                        payload: SQLiteHistorySchema.payloadEncoder.encode(
                            HistoryRecordV1(record)
                        ),
                        on: connection
                    )
                }
                try connection.commitTransaction()
            } catch {
                connection.rollbackTransaction()
                throw error
            }
            try checkpoint(connection)
            try connection.protectDatabaseFiles()
            clearOperationalNotice()
            NotificationCenter.default.post(
                name: .speakerHistoryDidChange,
                object: nil
            )
            return interrupted.count
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            return nil
        }
    }

    public func persistenceFailureNotice() async -> LocalHistoryPersistenceNotice? {
        switch visibleNotice {
        case let .privacyMigrationFailed(reason):
            return .privacyMigrationFailed(reason: reason)
        case let .writeFailed(reason):
            return .writeFailed(reason: reason)
        case let .corruptedRecordsSkipped(count):
            return .corruptedRecordsSkipped(count: count)
        // Preserved evidence and an unpruned archive directory are both
        // reported through the History page instead of this urgent surface.
        case .corruptedDataPreserved, .recoveryArchivePruneFailed, nil:
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
        guard let connection = openConnection else { return false }
        // The policy is user intent and governs every later save even when
        // immediate cleanup cannot finish. A transaction may commit before a
        // WAL checkpoint reports busy, so pretending to roll the policy back
        // would contradict data that has already been deleted.
        retentionPolicy = policy
        do {
            let pruned: Bool
            try connection.beginImmediateTransaction()
            do {
                pruned = try prune(now: now, on: connection)
                try connection.commitTransaction()
            } catch {
                connection.rollbackTransaction()
                throw error
            }
            destructiveCheckpointPending = destructiveCheckpointPending || pruned
            try checkpoint(connection)
            try connection.protectDatabaseFiles()
            clearOperationalNotice()
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            return false
        }
    }

    public func importLegacyRecords(_ records: [VoiceInputHistoryRecord]) async -> Bool {
        guard let connection = openConnection else { return false }
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
            try connection.beginImmediateTransaction()
            do {
                for record in expected {
                    try upsert(
                        record,
                        payload: SQLiteHistorySchema.payloadEncoder.encode(
                            HistoryRecordV1(record)
                        ),
                        on: connection
                    )
                }
                pruned = try prune(now: now, on: connection)
                try connection.commitTransaction()
            } catch {
                connection.rollbackTransaction()
                throw error
            }
            destructiveCheckpointPending = destructiveCheckpointPending || pruned
            try checkpoint(connection)
            try connection.protectDatabaseFiles()
            for expectedRecord in expected {
                let expectedPayload = try SQLiteHistorySchema.payloadEncoder.encode(
                    HistoryRecordV1(expectedRecord)
                )
                guard try storedPayload(
                    sessionID: expectedRecord.sessionID,
                    on: connection
                ) == expectedPayload else {
                    throw SQLiteHistoryError.encoding
                }
            }
            clearOperationalNotice()
            NotificationCenter.default.post(name: .speakerHistoryDidChange, object: nil)
            return true
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            return false
        }
    }

    /// The live handle, or `nil` once opening failed or erasure closed it.
    private var openConnection: SQLiteConnection? {
        guard let connection, connection.isOpen else { return nil }
        return connection
    }

    private static func openStore(at fileURL: URL) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(fileURL: fileURL)
        do {
            try createSchema(on: connection)
            try connection.protectDatabaseFiles()
        } catch {
            connection.closeIgnoringFailure()
            throw error
        }
        return connection
    }

    private static func createSchema(on connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS history_records (
                session_id TEXT PRIMARY KEY NOT NULL,
                started_at REAL NOT NULL,
                payload BLOB NOT NULL,
                payload_schema INTEGER NOT NULL DEFAULT 1
            )
            """
        )
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS history_started_at ON history_records(started_at DESC)"
        )
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS history_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value INTEGER NOT NULL
            )
            """
        )
        if try !connection.table("history_records", containsColumn: "payload_schema") {
            try connection.execute(
                "ALTER TABLE history_records ADD COLUMN payload_schema INTEGER NOT NULL DEFAULT 1"
            )
        }
        let userVersion = try connection.integerValue("PRAGMA user_version")
        guard userVersion <= SQLiteHistorySchema.version else {
            throw SQLiteHistoryError.unsupportedSchema(userVersion)
        }
        if userVersion == 0 {
            try connection.execute("PRAGMA user_version=\(SQLiteHistorySchema.version)")
        }
        let integrity = try connection.textValue("PRAGMA quick_check(1)")
        guard integrity == "ok" else {
            throw SQLiteHistoryError.integrityCheckFailed(integrity ?? "unknown")
        }
    }

    private func loadRecords(
        whereClause: String?,
        binding: String?
    ) -> [VoiceInputHistoryRecord] {
        guard let connection = openConnection else { return [] }
        do {
            let sql = "SELECT payload, payload_schema FROM history_records \(whereClause ?? "") ORDER BY started_at DESC, session_id DESC"
            let statement = try connection.prepare(sql)
            defer { statement.finalize() }
            if let binding { try statement.bind(binding, at: 1) }
            var records: [VoiceInputHistoryRecord] = []
            var corruptedRecordCount = 0
            while try statement.step() {
                guard statement.int32(at: 1) == SQLiteHistorySchema.version else {
                    corruptedRecordCount += 1
                    continue
                }
                guard let payload = statement.blob(at: 0) else {
                    throw SQLiteHistoryError.encoding
                }
                do {
                    records.append(
                        try SQLiteHistorySchema.payloadDecoder.decode(
                            HistoryRecordV1.self,
                            from: payload
                        ).domainRecord
                    )
                } catch {
                    // One malformed payload must not hide every healthy session.
                    // Keep the row untouched for diagnosis and surface an exact
                    // persistence notice until the user clears or exports it.
                    corruptedRecordCount += 1
                }
            }
            if corruptedRecordCount > 0 {
                notice = .corruptedRecordsSkipped(count: corruptedRecordCount)
            }
            return records
        } catch {
            notice = .writeFailed(reason: PrivacySafeText.reason(for: error))
            return []
        }
    }

    private func storedPayload(
        sessionID: VoiceInputSessionID,
        on connection: SQLiteConnection
    ) throws -> Data? {
        let statement = try connection.prepare(
            "SELECT payload FROM history_records WHERE session_id = ?"
        )
        defer { statement.finalize() }
        try statement.bind(sessionID.rawValue.uuidString, at: 1)
        guard try statement.step() else { return nil }
        guard let payload = statement.blob(at: 0) else {
            throw connection.lastError()
        }
        return payload
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

    private var visibleNotice: LocalHistoryPersistenceNotice? {
        if let privacyMigrationFailureReason {
            return .privacyMigrationFailed(
                reason: privacyMigrationFailureReason
            )
        }
        return notice
    }

    private func count() -> Int {
        guard let connection = openConnection,
              let statement = try? connection.prepare("SELECT COUNT(*) FROM history_records")
        else { return 0 }
        defer { statement.finalize() }
        guard (try? statement.step()) == true else { return 0 }
        return Int(statement.int64(at: 0))
    }

    private func prune(now: Date, on connection: SQLiteConnection) throws -> Bool {
        var deletedRecord = false
        if let days = retentionPolicy.maximumAgeDays,
           let cutoff = Calendar(identifier: .gregorian).date(
               byAdding: .day,
               value: -days,
               to: now
           ) {
            let statement = try connection.prepare(
                "DELETE FROM history_records WHERE started_at < ?"
            )
            statement.bind(cutoff.timeIntervalSince1970, at: 1)
            defer { statement.finalize() }
            try statement.stepDone()
            deletedRecord = connection.changeCount > 0
        }
        let capStatement = try connection.prepare(
            """
            DELETE FROM history_records
            WHERE session_id IN (
                SELECT session_id FROM history_records
                ORDER BY started_at DESC, session_id DESC
                LIMIT -1 OFFSET ?
            )
            """
        )
        capStatement.bind(Int64(maximumRecordCount), at: 1)
        defer { capStatement.finalize() }
        try capStatement.stepDone()
        return deletedRecord || connection.changeCount > 0
    }

    private func checkpoint(_ connection: SQLiteConnection) throws {
        try connection.truncateCheckpoint()
        destructiveCheckpointPending = false
    }

    private func upsert(
        _ record: VoiceInputHistoryRecord,
        payload: Data,
        on connection: SQLiteConnection
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO history_records(session_id, started_at, payload, payload_schema)
            VALUES(?, ?, ?, 1)
            ON CONFLICT(session_id) DO UPDATE SET
                started_at=excluded.started_at,
                payload=excluded.payload,
                payload_schema=excluded.payload_schema
            """
        )
        defer { statement.finalize() }
        try statement.bind(record.sessionID.rawValue.uuidString, at: 1)
        statement.bind(record.startedAt.timeIntervalSince1970, at: 2)
        try statement.bind(payload, at: 3)
        try statement.stepDone()
    }

    private func clearOperationalNotice() {
        if case .writeFailed = notice {
            notice = nil
        }
    }
}
