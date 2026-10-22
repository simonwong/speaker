import Foundation
import SQLite3
import SpeakerCore
import SpeakerSpecSupport

enum SessionHistorySpecs: CoreSpecDomain {
    /// The cases that hold a reader open across a write or checkpoint expect
    /// SQLite to report busy; a short wait reaches the same outcome as the
    /// three-second production default without spending it.
    private static let busyReaderTimeout: Duration = .milliseconds(50)

    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "Session Record payload bytes stay fixed for every outcome kind",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-payload-lock-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            for (index, fixture) in SessionRecordPayloadFixtures.all.enumerated() {
                let fileURL = directory.appendingPathComponent("history-\(index).sqlite3")
                let store = SQLiteSessionHistory(fileURL: fileURL)
                await store.save(fixture.record)
                let payload = try readHistoryPayload(from: fileURL)
                try expect(
                    payload == fixture.payload,
                    "payload \(index) changed: \(payload)"
                )
                let decoded = await store.record(sessionID: fixture.record.sessionID)
                try expect(
                    decoded == fixture.decoded,
                    "payload \(index) decoded to a different record"
                )
            }
        }

        await runAsync(
            "history keeps its stored keys and reads records older builds wrote",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-stored-keys-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let id = VoiceInputSessionID()
            let store = SQLiteSessionHistory(fileURL: fileURL)
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    transcription: "识别原文",
                    finalText: "整理后的正文",
                    providerRequestID: "recognition-log-1",
                    refinedText: "整理后的正文",
                    refinementRequestID: "refinement-log-1",
                    outcome: .delivered(id, text: "整理后的正文")
                ))

            let payload = try readHistoryPayload(from: fileURL)
            let stored = try JSONSerialization.jsonObject(with: Data(payload.utf8))
            guard let stored = stored as? [String: Any],
                let outcome = stored["outcome"] as? [String: Any]
            else { throw SpecFailure(message: "history payload is not a JSON record") }
            try expect(stored["deepSeekText"] as? String == "整理后的正文")
            try expect(stored["deepSeekRequestID"] as? String == "refinement-log-1")
            try expect(
                stored["refinedText"] == nil && stored["refinementRequestID"] == nil,
                "in-memory names reached disk"
            )
            try expect(
                stored["applicationName"] == nil && outcome["applicationName"] == nil,
                "an application name reached disk"
            )

            try injectLegacyApplicationNames(into: fileURL)
            let records = await SQLiteSessionHistory(fileURL: fileURL).allRecords()
            try expect(records.map(\.sessionID) == [id], "a legacy record did not decode")
            try expect(records.first?.refinedText == "整理后的正文")
            try expect(records.first?.refinementRequestID == "refinement-log-1")
            try expect(records.first?.outcome == .delivered(id, text: "整理后的正文"))
        }

        await runAsync(
            "legacy history reader returns the document's records without rewriting it",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-legacy-history-reader-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let legacyURL = directory.appendingPathComponent("history.json")
            let sqliteURL = directory.appendingPathComponent("history.sqlite3")
            let olderBuildID = SessionRecordPayloadFixtures.sessionID("6")
            let olderBuildRecord = """
                {"sessionID":"\(olderBuildID.rawValue.uuidString)","startedAt":1600000000000,\
                "applicationName":"TextEdit","transcription":"旧版记录",\
                "providerMessage":"older-provider-text",\
                "refinementFailureMessage":"older-refinement-text",\
                "outcome":{"kind":"delivered","sessionID":"\(olderBuildID.rawValue.uuidString)",\
                "applicationName":"TextEdit","text":"旧版记录"}}
                """
            let document = Data(
                legacyHistoryDocument(
                    records: SessionRecordPayloadFixtures.all.map(\.payload) + [olderBuildRecord]
                ).utf8
            )
            try writeLegacyHistoryFixture(document, to: legacyURL)

            let reader = LegacyHistoryReader(fileURL: legacyURL)
            guard case .records(let records) = reader.read() else {
                throw SpecFailure(message: "legacy history fixture did not load")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
            try expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "legacy history was not protected as owner-only"
            )
            try expect(
                (try? Data(contentsOf: legacyURL)) == document,
                "reading legacy history rewrote the document"
            )
            try expect(
                records.map(\.sessionID)
                    == ["5", "4", "3", "2", "1", "6"].map {
                        SessionRecordPayloadFixtures.sessionID(Character($0))
                    }
            )
            try expect(
                Array(records.prefix(5))
                    == SessionRecordPayloadFixtures.all.reversed().map(\.decoded)
            )
            let olderBuild = records.last
            try expect(olderBuild?.transcription == "旧版记录")
            try expect(olderBuild?.providerMessage == nil)
            try expect(olderBuild?.refinementFailureMessage == nil)
            try expect(olderBuild?.dictionarySnapshotEntries == [])
            try expect(olderBuild?.durationMilliseconds == 0)

            let sqlite = SQLiteSessionHistory(fileURL: sqliteURL)
            let imported = await sqlite.importLegacyRecords(records)
            try expect(imported)
            for marker in ["TextEdit", "older-provider-text", "older-refinement-text"] {
                try expect(
                    !sqliteFilesContain(Data(marker.utf8), at: sqliteURL),
                    "\(marker) reached the SQLite history"
                )
            }

            try reader.removeDocument()
            try expect(!FileManager.default.fileExists(atPath: legacyURL.path))
            guard case .records(let afterRemoval) = reader.read(), afterRemoval.isEmpty else {
                throw SpecFailure(message: "a removed legacy document still produced records")
            }
        }

        await runAsync(
            "legacy history aliases survive JSON import and SQLite rewrite", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-dictionary-v1-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let legacyURL = directory.appendingPathComponent("history.json")
            let sqliteURL = directory.appendingPathComponent("history.sqlite3")
            let sessionID = VoiceInputSessionID()
            let entryID = UUID()
            // Builds that predate Entry words stored the term as
            // `canonicalTerm` beside an `isEnabled` flag.
            let record = """
                {"sessionID":"\(sessionID.rawValue.uuidString)","startedAt":100000,\
                "transcription":"旧记录","finalText":"旧记录",\
                "dictionarySnapshotEntries":[{"aliases":["豆宝"],"canonicalTerm":"豆包",\
                "id":"\(entryID.uuidString)","isEnabled":true}],\
                "outcome":{"kind":"delivered","sessionID":"\(sessionID.rawValue.uuidString)",\
                "text":"旧记录"}}
                """
            try writeLegacyHistoryFixture(
                Data(legacyHistoryDocument(records: [record]).utf8),
                to: legacyURL
            )

            guard
                case .records(let importedRecords) = LegacyHistoryReader(fileURL: legacyURL)
                    .read()
            else {
                throw SpecFailure(message: "legacy history fixture did not load")
            }
            let sqlite = SQLiteSessionHistory(fileURL: sqliteURL)
            let imported = await sqlite.importLegacyRecords(importedRecords)
            let rewritten = await sqlite.record(sessionID: sessionID)

            try expect(
                importedRecords.first?.dictionarySnapshotEntries.first?.word
                    == "豆包"
            )
            try expect(
                importedRecords.first?.dictionarySnapshotEntries.first?.legacyAliases
                    == ["豆宝"]
            )
            try expect(imported)
            try expect(
                rewritten?.dictionarySnapshotEntries.first?.legacyAliases
                    == ["豆宝"]
            )
        }

        await runAsync(
            "SQLite history scrubs provider response text written by older builds",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-message-scrub-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let id = VoiceInputSessionID()
            let store = SQLiteSessionHistory(fileURL: fileURL)
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    transcription: "诊断记录",
                    finalText: nil,
                    providerErrorCode: "authentication",
                    providerMessage: "future-api-key-secret",
                    refinementFailureMessage: "private-refinement-context",
                    outcome: .failed(id, .providerAuthenticationFailed)
                ))
            try injectLegacyProviderMessages(into: fileURL)

            let scrubbed = await store.scrubUntrustedProviderMessages()
            let payload = try readHistoryPayload(from: fileURL)
            let record = await store.record(sessionID: id)

            try expect(scrubbed)
            try expect(record?.providerMessage == nil)
            try expect(record?.refinementFailureMessage == nil)
            try expect(
                !payload.contains("future-api-key-secret")
                    && !payload.contains("private-refinement-context"),
                "provider response text remained in SQLite payload"
            )
        }

        await runAsync(
            "SQLite history drops malformed legacy rows that cannot be safely scrubbed",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-malformed-message-scrub-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let secret = "malformed-provider-secret-\(UUID().uuidString)"
            try injectMalformedProviderMessageRow(
                into: fileURL,
                secret: secret
            )

            let scrubbed = await store.scrubUntrustedProviderMessages()
            let status = await store.persistenceStatus()

            try expect(scrubbed)
            try expect(status.recordCount == 0)
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "malformed provider response text remained in SQLite storage"
            )
        }

        await runAsync(
            "SQLite privacy scrub failure survives later writes and retries physical sanitization",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-message-scrub-retry-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let id = VoiceInputSessionID()
            let secret = "retry-provider-secret-\(UUID().uuidString)"
            let store = SQLiteSessionHistory(fileURL: fileURL, busyTimeout: busyReaderTimeout)
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    transcription: "诊断记录",
                    finalText: nil,
                    outcome: .failed(id, .providerAuthenticationFailed)
                ))
            try injectProviderMessage(
                secret,
                into: fileURL
            )

            var reader: OpaquePointer?
            try expect(
                sqlite3_open_v2(
                    fileURL.path,
                    &reader,
                    SQLITE_OPEN_READONLY,
                    nil
                ) == SQLITE_OK
            )
            guard let reader else {
                throw SpecFailure(message: "could not open privacy scrub reader")
            }
            defer { sqlite3_close(reader) }
            try expect(
                sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK
            )
            var statement: OpaquePointer?
            try expect(
                sqlite3_prepare_v2(
                    reader,
                    "SELECT payload FROM history_records LIMIT 1",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            )
            guard let statement else {
                throw SpecFailure(message: "could not prepare privacy scrub reader")
            }
            try expect(sqlite3_step(statement) == SQLITE_ROW)

            let firstScrub = await store.scrubUntrustedProviderMessages()
            let failedStatus = await store.persistenceStatus()
            try expect(!firstScrub)
            guard case .privacyMigrationFailed = failedStatus.notice else {
                throw SpecFailure(
                    message: "privacy scrub failure was not reported explicitly"
                )
            }

            sqlite3_finalize(statement)
            try expect(
                sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK
            )
            let retentionApplied = await store.applyRetentionPolicy(
                .thirtyDays,
                now: Date()
            )
            let statusAfterWrite = await store.persistenceStatus()
            try expect(retentionApplied)
            guard case .privacyMigrationFailed = statusAfterWrite.notice else {
                throw SpecFailure(
                    message: "later successful write hid the privacy scrub failure"
                )
            }

            let retryScrub = await store.scrubUntrustedProviderMessages()
            let completedStatus = await store.persistenceStatus()
            try expect(retryScrub)
            try expect(completedStatus.notice == nil)
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "retry did not remove provider text from physical SQLite pages"
            )
        }

        await runAsync(
            "SQLite history retains textless recording and provider errors but omits quiet outcomes",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-errors-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: url)
            var retainedIDs: [VoiceInputSessionID] = []
            for (index, failure) in [
                VoiceInputFailure.recordingFailed, .providerAuthenticationFailed,
                .recordingTooShort, .providerReturnedNoText,
            ].enumerated() {
                let id = VoiceInputSessionID()
                if index < 2 { retainedIDs.append(id) }
                await store.save(
                    .init(
                        sessionID: id, startedAt: Date().addingTimeInterval(Double(index)),
                        transcription: nil, finalText: nil,
                        providerErrorCode: failure.rawValue,
                        outcome: .failed(id, failure)
                    ))
            }
            let reloaded = SQLiteSessionHistory(fileURL: url)
            let records = await reloaded.allRecords()
            try expect(Set(records.map(\.sessionID)) == Set(retainedIDs))
            try expect(records.allSatisfy { $0.transcription == nil && $0.finalText == nil })
            _ = await reloaded.closeForErasure()
            _ = await store.closeForErasure()
        }

        await runAsync(
            "SQLite history incrementally upserts reloads searches and securely clears",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-history-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(
                fileURL: fileURL,
                maximumRecordCount: 3
            )
            let emptyID = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: emptyID,
                    startedAt: Date().addingTimeInterval(1),
                    transcription: " \n",
                    finalText: nil,
                    outcome: .failed(emptyID, .providerReturnedNoText)
                ))
            let recordsAfterEmptySave = await store.allRecords()
            try expect(recordsAfterEmptySave.isEmpty)

            let id = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    transcription: "第一阶段",
                    finalText: nil,
                    providerRequestID: "sqlite-request",
                    outcome: .processing(id, .transcribing)
                ))
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    transcription: "豆包增量结果",
                    finalText: "最终增量结果",
                    providerRequestID: "sqlite-request",
                    refinedText: "最终增量结果",
                    refinementProviderID: .kimi,
                    refinementModelID: "kimi-k2.6",
                    outcome: .delivered(id, text: "最终增量结果")
                ))

            let reloaded = SQLiteSessionHistory(fileURL: fileURL)
            let records = await reloaded.allRecords()
            let status = await reloaded.persistenceStatus()
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(records.count == 1)
            try expect(records.first?.finalText == "最终增量结果")
            try expect(records.first?.refinementProviderID == .kimi)
            try expect(records.first?.refinementModelID == "kimi-k2.6")
                        try expect(status.recordCount == 1)
            try expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "SQLite history file is not owner-only"
            )
            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )
            try expect(
                (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                "SQLite history directory is not owner-only"
            )
            let sqliteFiles = ["", "-wal", "-shm"].map {
                URL(fileURLWithPath: fileURL.path + $0)
            }.filter { FileManager.default.fileExists(atPath: $0.path) }
            try expect(
                sqliteFiles.count >= 2,
                "SQLite sidecars were not created for permission verification")
            for sqliteFile in sqliteFiles {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: sqliteFile.path
                )
            }
            if let record = records.first {
                await reloaded.save(record)
            }
            for sqliteFile in sqliteFiles {
                let protectedAttributes = try FileManager.default.attributesOfItem(
                    atPath: sqliteFile.path
                )
                try expect(
                    (protectedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                    "SQLite main or sidecar permission was not repaired"
                )
            }

            let legacyFile = directory.appendingPathComponent("history.json")
            let recoveryFile = directory.appendingPathComponent("history.corrupt-1.json")
            try Data("legacy".utf8).write(to: legacyFile)
            try Data("recovery".utf8).write(to: recoveryFile)
            let cleared = await reloaded.clear()
            let afterClear = await reloaded.allRecords()
            try expect(cleared)
            try expect(afterClear.isEmpty)
            try expect(!FileManager.default.fileExists(atPath: legacyFile.path))
            try expect(!FileManager.default.fileExists(atPath: recoveryFile.path))

            let migrationStore = SQLiteSessionHistory(
                fileURL: directory.appendingPathComponent("migration.sqlite3")
            )
            let imported = await migrationStore.importLegacyRecords(records)
            let importedRecord = await migrationStore.record(sessionID: id)
            try expect(imported)
            try expect(importedRecord?.finalText == "最终增量结果")
        }

        await runAsync(
            "SQLite startup recovery terminates sessions left active by a previous process",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-interrupted-session-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let interruptedID = VoiceInputSessionID()
            let deliveredID = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: interruptedID,
                    startedAt: Date(),
                    transcription: "已经确认的豆包文字",
                    finalText: nil,
                    transcriptionProvider: "doubao",
                    providerRequestID: "interrupted-request",
                    outcome: .processing(
                        interruptedID,
                        .refining)
                ))
            await store.save(
                .init(
                    sessionID: deliveredID,
                    startedAt: Date().addingTimeInterval(-1),
                    transcription: "完成",
                    finalText: "完成",
                    outcome: .delivered(
                        deliveredID,
                        text: "完成"
                    )
                ))

            let reconciledCount =
                await store.reconcileInterruptedSessions()
            let interrupted = await store.record(
                sessionID: interruptedID
            )
            let delivered = await store.record(sessionID: deliveredID)

            try expect(reconciledCount == 1)
            try expect(
                interrupted?.outcome
                    == .failed(interruptedID, .sessionInterrupted)
            )
            try expect(
                interrupted?.providerErrorCode
                    == "application.interrupted.refining"
            )
            try expect(
                interrupted?.transcription == "已经确认的豆包文字"
            )
            try expect(delivered?.outcome.isDelivered == true)
        }

        await runAsync(
            "SQLite clear reports a busy checkpoint and completes sanitization after the reader releases",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-busy-clear-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            try expect(SQLiteSessionHistory.defaultBusyTimeout == .seconds(3))
            let store = SQLiteSessionHistory(fileURL: fileURL, busyTimeout: busyReaderTimeout)
            let id = VoiceInputSessionID()
            let secret = "speaker-sensitive-clear-marker-\(UUID().uuidString)"
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    transcription: secret,
                    finalText: secret,
                    outcome: .pendingCopy(id, text: secret, reason: .missingTarget)
                ))

            var reader: OpaquePointer?
            try expect(
                sqlite3_open_v2(fileURL.path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            guard let reader else { throw SpecFailure(message: "could not open SQLite reader") }
            defer { sqlite3_close(reader) }
            try expect(sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK)
            var statement: OpaquePointer?
            try expect(
                sqlite3_prepare_v2(
                    reader, "SELECT payload FROM history_records LIMIT 1", -1, &statement, nil)
                    == SQLITE_OK
            )
            guard let statement else {
                throw SpecFailure(message: "could not prepare SQLite reader")
            }
            try expect(sqlite3_step(statement) == SQLITE_ROW)

            let firstClear = await store.clear()
            let firstStatus = await store.persistenceStatus()
            try expect(!firstClear, "busy checkpoint was reported as a completed clear")
            try expect(firstStatus.notice != nil)

            sqlite3_finalize(statement)
            try expect(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            let completedClear = await store.clear()
            let recordsAfterClear = await store.allRecords()
            try expect(completedClear)
            try expect(recordsAfterClear.isEmpty)

            let marker = Data(secret.utf8)
            for suffix in ["", "-wal", "-journal"] {
                let candidate = URL(fileURLWithPath: fileURL.path + suffix)
                guard let data = try? Data(contentsOf: candidate) else { continue }
                try expect(
                    data.range(of: marker) == nil, "cleared SQLite file retained plaintext marker")
            }
        }

        await runAsync(
            "SQLite retention keeps the committed policy when a later checkpoint is busy",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-sqlite-busy-retention-\(UUID().uuidString)"
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL, busyTimeout: busyReaderTimeout)
            let now = Date()
            let oldID = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: oldID,
                    startedAt: now.addingTimeInterval(-90 * 86_400),
                    transcription: "old",
                    finalText: "old",
                    outcome: .delivered(
                        oldID,
                        text: "old"
                    )
                ))

            var reader: OpaquePointer?
            try expect(
                sqlite3_open_v2(
                    fileURL.path,
                    &reader,
                    SQLITE_OPEN_READONLY,
                    nil
                ) == SQLITE_OK
            )
            guard let reader else {
                throw SpecFailure(message: "could not open retention reader")
            }
            defer { sqlite3_close(reader) }
            try expect(
                sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK
            )
            var statement: OpaquePointer?
            try expect(
                sqlite3_prepare_v2(
                    reader,
                    "SELECT payload FROM history_records LIMIT 1",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            )
            guard let statement else {
                throw SpecFailure(message: "could not prepare retention reader")
            }
            try expect(sqlite3_step(statement) == SQLITE_ROW)

            let fullyApplied = await store.applyRetentionPolicy(
                .thirtyDays,
                now: now
            )
            let currentPolicy = await store.currentRetentionPolicy()
            let records = await store.allRecords()

            try expect(!fullyApplied)
            try expect(
                currentPolicy == .thirtyDays,
                "post-commit checkpoint failure rewound the applied policy"
            )
            try expect(
                records.isEmpty,
                "committed retention deletion was unexpectedly restored"
            )

            sqlite3_finalize(statement)
            try expect(
                sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK
            )
        }

        await runAsync(
            "SQLite cap pruning retries physical WAL sanitization after a busy reader",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-sqlite-cap-sanitization-\(UUID().uuidString)"
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(
                fileURL: fileURL,
                maximumRecordCount: 1,
                busyTimeout: busyReaderTimeout
            )
            let secret = "pruned-history-secret-\(UUID().uuidString)"
            let oldID = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: oldID,
                    startedAt: Date(timeIntervalSince1970: 1),
                    transcription: secret,
                    finalText: secret,
                    outcome: .delivered(
                        oldID,
                        text: secret
                    )
                ))

            var reader: OpaquePointer?
            try expect(
                sqlite3_open_v2(
                    fileURL.path,
                    &reader,
                    SQLITE_OPEN_READONLY,
                    nil
                ) == SQLITE_OK
            )
            guard let reader else {
                throw SpecFailure(message: "could not open cap-pruning reader")
            }
            defer { sqlite3_close(reader) }
            try expect(sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK)
            var statement: OpaquePointer?
            try expect(
                sqlite3_prepare_v2(
                    reader,
                    "SELECT payload FROM history_records LIMIT 1",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            )
            guard let statement else {
                throw SpecFailure(message: "could not prepare cap-pruning reader")
            }
            try expect(sqlite3_step(statement) == SQLITE_ROW)

            let replacementID = VoiceInputSessionID()
            let replacement = VoiceInputHistoryRecord(
                sessionID: replacementID,
                startedAt: Date(timeIntervalSince1970: 2),
                transcription: "replacement",
                finalText: "replacement",
                outcome: .delivered(
                    replacementID,
                    text: "replacement"
                )
            )
            await store.save(replacement)
            let pendingStatus = await store.persistenceStatus()
            guard case .writeFailed = pendingStatus.notice else {
                throw SpecFailure(message: "busy cap sanitization was hidden")
            }

            sqlite3_finalize(statement)
            try expect(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            await store.save(replacement)
            let completedStatus = await store.persistenceStatus()
            try expect(completedStatus.notice == nil)
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "cap-pruned history remained in physical SQLite/WAL pages"
            )
        }

        await runAsync(
            "SQLite history closes explicitly before owned files are erased", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-sqlite-erasure-close-\(UUID().uuidString)"
                )
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let id = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    transcription: "must not return",
                    finalText: "must not return",
                    outcome: .delivered(
                        id,
                        text: "must not return"
                    )
                ))

            let firstClose = await store.closeForErasure()
            let secondClose = await store.closeForErasure()
            try expect(firstClose)
            try expect(secondClose)
            try FileManager.default.removeItem(at: directory)
            let lateID = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: lateID,
                    startedAt: Date(),
                    transcription: "late write",
                    finalText: "late write",
                    outcome: .failed(
                        lateID,
                        .recordingFailed
                    )
                ))
            try expect(!FileManager.default.fileExists(atPath: directory.path))
            let status = await store.persistenceStatus()
            try expect(status.recordCount == 0)
        }

        await runAsync(
            "SQLite recovers a corrupt database as one protected recovery set", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-corrupt-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            try Data("not-a-sqlite-database".utf8).write(to: fileURL)

            let store = SQLiteSessionHistory(fileURL: fileURL)
            let status = await store.persistenceStatus()
            guard case .corruptedDataPreserved(let backupURL, _) = status.notice else {
                throw SpecFailure(message: "corrupt SQLite database was not preserved")
            }
            try expect(FileManager.default.fileExists(atPath: backupURL.path))
            let id = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    transcription: "recovered",
                    finalText: "recovered",
                    outcome: .pendingCopy(id, text: "recovered", reason: .missingTarget)
                ))
            let recoveredRecord = await store.record(sessionID: id)
            try expect(recoveredRecord != nil)
            let cleared = await store.clear()
            try expect(cleared)
            try expect(!FileManager.default.fileExists(atPath: backupURL.path))
        }

        await runAsync(
            "SQLite skips malformed rows without misreporting a write failure", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-malformed-row-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let healthyID = VoiceInputSessionID()
            let healthyRecord = VoiceInputHistoryRecord(
                sessionID: healthyID,
                startedAt: Date(),
                transcription: "healthy",
                finalText: "healthy",
                outcome: .delivered(
                    healthyID,
                    text: "healthy"
                )
            )
            await store.save(healthyRecord)

            var writer: OpaquePointer?
            try expect(
                sqlite3_open_v2(fileURL.path, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
            )
            guard let writer else { throw SpecFailure(message: "could not open SQLite writer") }
            defer { sqlite3_close(writer) }
            try expect(
                sqlite3_exec(
                    writer,
                    "INSERT INTO history_records(session_id, started_at, payload, payload_schema) VALUES('00000000-0000-0000-0000-000000000001', 1, X'FF', 1)",
                    nil,
                    nil,
                    nil
                ) == SQLITE_OK
            )

            let records = await store.allRecords()
            let status = await store.persistenceStatus()
            try expect(records.map(\.sessionID) == [healthyID])
            try expect(status.recordCount == 2)
            guard case .corruptedRecordsSkipped(count: 1) = status.notice else {
                throw SpecFailure(message: "malformed history row was not reported precisely")
            }

            await store.save(healthyRecord)
            let statusAfterSuccessfulWrite = await store.persistenceStatus()
            guard case .corruptedRecordsSkipped(count: 1) = statusAfterSuccessfulWrite.notice else {
                throw SpecFailure(message: "successful write hid a persistent malformed row")
            }

            let cleared = await store.clear()
            try expect(cleared)
            let statusAfterClear = await store.persistenceStatus()
            try expect(statusAfterClear.notice == nil)
        }

        await runAsync(
            "SQLite legacy import applies retention and cap before verifying the final set",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-import-retention-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let now = Date()
            let store = SQLiteSessionHistory(
                fileURL: directory.appendingPathComponent("history.sqlite3"),
                retentionPolicy: .thirtyDays,
                maximumRecordCount: 3
            )
            var records: [VoiceInputHistoryRecord] = []
            for offset in 0..<5 {
                let id = VoiceInputSessionID()
                let date =
                    offset == 0
                    ? now.addingTimeInterval(-100 * 86_400)
                    : now.addingTimeInterval(Double(offset))
                records.append(
                    .init(
                        sessionID: id,
                        startedAt: date,
                        transcription: "legacy-\(offset)",
                        finalText: "legacy-\(offset)",
                        outcome: .pendingCopy(id, text: "legacy-\(offset)", reason: .missingTarget)
                    ))
            }
            let imported = await store.importLegacyRecords(records)
            let retained = await store.allRecords()
            try expect(imported)
            try expect(retained.count == 3)
            try expect(retained.map(\.finalText) == ["legacy-4", "legacy-3", "legacy-2"])
        }

        await runAsync(
            "corrupt legacy history is preserved and reported instead of read",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-corrupt-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            try Data("not-json".utf8).write(to: fileURL)

            guard
                case .corruptedPreserved(let backupURL) = LegacyHistoryReader(fileURL: fileURL)
                    .read()
            else {
                throw SpecFailure(
                    message: "corrupt history did not produce a preserved recovery outcome")
            }
            try expect(FileManager.default.fileExists(atPath: backupURL.path))
            try expect((try? Data(contentsOf: backupURL)) == Data("not-json".utf8))
            try expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }

        await runAsync(
            "history clear removes legacy archives without following symbolic links",
            failures: &failures
        ) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-legacy-artifacts-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("Speaker", isDirectory: true)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            let outsideNested = outside.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outsideNested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let outsideFile = outside.appendingPathComponent("keep.txt")
            let outsideNestedFile = outsideNested.appendingPathComponent("keep.txt")
            try Data("outside".utf8).write(to: outsideFile)
            try Data("outside-nested".utf8).write(to: outsideNestedFile)

            let store = SQLiteSessionHistory(
                fileURL: directory.appendingPathComponent("history.sqlite3"))
            try Data("{}".utf8).write(to: directory.appendingPathComponent("history.json"))
            try Data("old".utf8).write(
                to: directory.appendingPathComponent("history.corrupt-1-a.json"))
            try Data("old".utf8).write(
                to: directory.appendingPathComponent("history.migrated-1.json"))
            let preserved = directory.appendingPathComponent(
                "history.corrupt-1-b", isDirectory: true)
            let preservedNested = preserved.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(
                at: preservedNested, withIntermediateDirectories: true)
            try Data("damaged".utf8).write(
                to: preserved.appendingPathComponent("history.sqlite3"))
            try FileManager.default.createSymbolicLink(
                at: preserved.appendingPathComponent("file-link"),
                withDestinationURL: outsideFile
            )
            try FileManager.default.createSymbolicLink(
                at: preservedNested.appendingPathComponent("directory-link"),
                withDestinationURL: outsideNested
            )

            let cleared = await store.clear()
            try expect(cleared)
            let remaining = try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).filter { !$0.hasPrefix("history.sqlite3") }
            try expect(remaining.isEmpty, "legacy artifacts remained: \(remaining)")
            try expect((try? Data(contentsOf: outsideFile)) == Data("outside".utf8))
            try expect(
                (try? Data(contentsOf: outsideNestedFile)) == Data("outside-nested".utf8)
            )
        }

        await runAsync(
            "disabled history preserves existing records and skips new saves", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-disabled-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let stores: [any LocalSessionHistoryStoring] = [
                SQLiteSessionHistory(
                    fileURL: directory.appendingPathComponent("history.sqlite3")
                )
            ]

            for store in stores {
                let existingID = VoiceInputSessionID()
                await store.save(
                    .init(
                        sessionID: existingID,
                        startedAt: Date(),
                        transcription: "existing",
                        finalText: "existing",
                        outcome: .pendingCopy(
                            existingID,
                            text: "existing",
                            reason: .missingTarget
                        )
                    ))
                let disabled = await store.applyRetentionPolicy(
                    .disabled,
                    now: Date()
                )
                try expect(disabled)

                await store.save(
                    .init(
                        sessionID: existingID,
                        startedAt: Date(),
                        transcription: "updated",
                        finalText: "updated",
                        outcome: .pendingCopy(
                            existingID,
                            text: "updated",
                            reason: .missingTarget
                        )
                    ))

                let skippedID = VoiceInputSessionID()
                await store.save(
                    .init(
                        sessionID: skippedID,
                        startedAt: Date(),
                        transcription: "skipped",
                        finalText: "skipped",
                        outcome: .pendingCopy(
                            skippedID,
                            text: "skipped",
                            reason: .missingTarget
                        )
                    ))

                let policy = await store.currentRetentionPolicy()
                let records = await store.allRecords()
                try expect(policy == .disabled)
                try expect(records.map(\.sessionID) == [existingID])
                try expect(records.first?.finalText == "updated")
            }
        }

        await runAsync(
            "legacy history refuses to load when owner-only protection fails", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-protection-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.json")
            let document = Data(
                legacyHistoryDocument(
                    records: [SessionRecordPayloadFixtures.pendingCopy.payload]
                ).utf8
            )
            try writeLegacyHistoryFixture(document, to: fileURL)

            let protected = LegacyHistoryReader(
                fileURL: fileURL,
                fileProtection: LocalFileProtection { _ in
                    throw FileProtectionFailure()
                }
            )

            try expect(protected.read() == .protectionFailed)
            try expect(
                (try? Data(contentsOf: fileURL)) == document,
                "a protection failure changed the legacy document"
            )
        }

        await runAsync(
            "recent records with text read newest first and skip text-free sessions",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-recent-records-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SQLiteSessionHistory(
                fileURL: directory.appendingPathComponent("history.sqlite3"))
            var expected: [VoiceInputSessionID] = []
            for index in 0..<8 {
                let id = VoiceInputSessionID()
                let hasText = index % 3 != 0
                let text = hasText ? "第 \(index) 条" : nil
                await store.save(
                    .init(
                        sessionID: id,
                        startedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                        transcription: text,
                        finalText: text,
                        outcome: hasText
                            ? .delivered(id, text: text ?? "")
                            : .failed(id, .providerAuthenticationFailed)
                    ))
                if hasText { expected.insert(id, at: 0) }
            }

            let recent = await store.recentRecordsWithText(limit: 3)
            try expect(recent.map(\.sessionID) == Array(expected.prefix(3)))
            let none = await store.recentRecordsWithText(limit: 0)
            try expect(none.isEmpty)
        }
    }
}

/// A legacy `history.json` document holding the given record payloads.
private func legacyHistoryDocument(records: [String]) -> String {
    #"{"records":["# + records.joined(separator: ",") + #"],"schemaVersion":1}"#
}

private func writeLegacyHistoryFixture(_ document: Data, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try document.write(to: fileURL)
}
