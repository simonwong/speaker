import Foundation
import SQLite3
import SpeakerCore
import SpeakerSpecSupport

enum SessionHistorySpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "versioned local history omits empty records and excludes sensitive fields",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.json")
            let firstID = VoiceInputSessionID()
            let secondID = VoiceInputSessionID()
            let snapshotID = UUID()
            let dictionaryEntry = DictionaryEntry(word: "豆包")
            let store = VersionedLocalSessionHistory(fileURL: fileURL)
            await store.save(
                .init(
                    sessionID: firstID,
                    startedAt: Date(timeIntervalSince1970: 100),
                    applicationName: "TextEdit",
                    transcription: "豆包原文 alpha",
                    finalText: "最终文本",
                    transcriptionProvider: "doubao",
                    providerRequestID: "request-log-1",
                    providerErrorCode: nil,
                    deliveryDiagnosticCode:
                        "pasteReceipt.unconfirmed",
                    deepSeekText: "DeepSeek 结果 beta",
                    deepSeekRequestID: "deepseek-log-1",
                    refinementModeName: "精简清理",
                    refinementPrompt: "只清理口语杂质",
                    refinementStatus: "succeeded",
                    dictionarySnapshotID: snapshotID,
                    dictionarySnapshotEntries: [RecordedDictionaryEntry(dictionaryEntry)],
                    dictionaryRequestContext: .init(
                        snapshotID: snapshotID,
                        hotwords: ["豆包"],
                        includedEntryIDs: [dictionaryEntry.id],
                        omissions: []
                    ),
                    dictionaryReplacements: [
                        .init(
                            entryID: UUID(),
                            alias: "豆宝",
                            canonicalTerm: "豆包",
                            matchedText: "豆宝",
                            utf16Location: 0,
                            utf16Length: 2
                        )
                    ],
                    durationMilliseconds: 1_234,
                    stageDurationsMilliseconds: ["doubao": 500, "deepseek": 300],
                    outcome: .delivered(firstID, applicationName: "TextEdit", text: "最终文本")
                ))
            await store.save(
                .init(
                    sessionID: secondID,
                    startedAt: Date(timeIntervalSince1970: 200),
                    applicationName: "Notes",
                    transcription: " \n ",
                    finalText: "\t",
                    providerRequestID: "request-log-2",
                    providerErrorCode: "invalidCredential",
                    outcome: .failed(secondID, .providerNotConfigured)
                ))

            let reloaded = VersionedLocalSessionHistory(fileURL: fileURL)
            let allRecords = await reloaded.allRecords()
            let encoded = try String(contentsOf: fileURL, encoding: .utf8)
            let historyAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(
                (historyAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "history file is not owner-only"
            )
            try expect(allRecords.map(\.sessionID) == [firstID])
            try expect(allRecords.first?.transcription == "豆包原文 alpha")
            try expect(allRecords.last?.deepSeekText == "DeepSeek 结果 beta")
            try expect(allRecords.last?.transcriptionProvider == "doubao")
            try expect(
                allRecords.last?.deliveryDiagnosticCode
                    == "pasteReceipt.unconfirmed"
            )
            try expect(allRecords.last?.refinementPrompt == "只清理口语杂质")
            try expect(
                allRecords.last?.dictionarySnapshotEntries
                    == [RecordedDictionaryEntry(dictionaryEntry)]
            )
            try expect(allRecords.last?.dictionaryRequestContext?.hotwords == ["豆包"])
            try expect(allRecords.last?.dictionaryReplacements.count == 1)
            try expect(allRecords.last?.stageDurationsMilliseconds["doubao"] == 500)
            try expect(!encoded.contains("apiKey"))
            try expect(!encoded.contains("audio"))
            try expect(!encoded.contains("clipboard"))
            try expect(!encoded.contains("TextEdit"))
            try expect(!encoded.contains("Notes"))

            let deleted = await reloaded.delete(sessionID: firstID)
            try expect(deleted)
            await reloaded.clear()
            let recordsAfterClear = await reloaded.allRecords()
            try expect(recordsAfterClear.isEmpty)
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
            let writer = VersionedLocalSessionHistory(fileURL: legacyURL)
            await writer.save(
                .init(
                    sessionID: sessionID,
                    startedAt: Date(timeIntervalSince1970: 100),
                    applicationName: "TextEdit",
                    transcription: "旧记录",
                    finalText: "旧记录",
                    dictionarySnapshotEntries: [
                        RecordedDictionaryEntry(
                            id: entryID,
                            word: "豆包",
                            legacyAliases: ["豆宝"]
                        )
                    ],
                    outcome: .delivered(
                        sessionID,
                        applicationName: "TextEdit",
                        text: "旧记录"
                    )
                ))

            guard
                var document = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: legacyURL)
                ) as? [String: Any],
                var records = document["records"] as? [[String: Any]],
                !records.isEmpty,
                var entries = records[0]["dictionarySnapshotEntries"]
                    as? [[String: Any]],
                !entries.isEmpty
            else {
                throw SpecFailure(message: "legacy history fixture was not encoded")
            }
            entries[0]["canonicalTerm"] = entries[0].removeValue(forKey: "word")
            entries[0]["isEnabled"] = true
            records[0]["dictionarySnapshotEntries"] = entries
            document["records"] = records
            try JSONSerialization.data(withJSONObject: document).write(to: legacyURL)

            let legacy = VersionedLocalSessionHistory(fileURL: legacyURL)
            let importedRecords = await legacy.allRecords()
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
                    applicationName: "TextEdit",
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
            let store = SQLiteSessionHistory(fileURL: fileURL)
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    applicationName: "TextEdit",
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
                    applicationName: nil,
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
                    applicationName: "TextEdit",
                    transcription: "第一阶段",
                    finalText: nil,
                    providerRequestID: "sqlite-request",
                    outcome: .processing(id, .transcribing, applicationName: "TextEdit")
                ))
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    applicationName: "TextEdit",
                    transcription: "豆包增量结果",
                    finalText: "最终增量结果",
                    providerRequestID: "sqlite-request",
                    deepSeekText: "最终增量结果",
                    outcome: .delivered(id, applicationName: "TextEdit", text: "最终增量结果")
                ))

            let reloaded = SQLiteSessionHistory(fileURL: fileURL)
            let records = await reloaded.allRecords()
            let status = await reloaded.persistenceStatus()
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(records.count == 1)
            try expect(records.first?.finalText == "最终增量结果")
            try expect(records.first?.applicationName == nil)
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
                    applicationName: "TextEdit",
                    transcription: "已经确认的豆包文字",
                    finalText: nil,
                    transcriptionProvider: "doubao",
                    providerRequestID: "interrupted-request",
                    outcome: .processing(
                        interruptedID,
                        .refining,
                        applicationName: "TextEdit"
                    )
                ))
            await store.save(
                .init(
                    sessionID: deliveredID,
                    startedAt: Date().addingTimeInterval(-1),
                    applicationName: "Notes",
                    transcription: "完成",
                    finalText: "完成",
                    outcome: .delivered(
                        deliveredID,
                        applicationName: "Notes",
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
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let id = VoiceInputSessionID()
            let secret = "speaker-sensitive-clear-marker-\(UUID().uuidString)"
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    applicationName: nil,
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
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let now = Date()
            let oldID = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: oldID,
                    startedAt: now.addingTimeInterval(-90 * 86_400),
                    applicationName: "TextEdit",
                    transcription: "old",
                    finalText: "old",
                    outcome: .delivered(
                        oldID,
                        applicationName: "TextEdit",
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
                maximumRecordCount: 1
            )
            let secret = "pruned-history-secret-\(UUID().uuidString)"
            let oldID = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: oldID,
                    startedAt: Date(timeIntervalSince1970: 1),
                    applicationName: "TextEdit",
                    transcription: secret,
                    finalText: secret,
                    outcome: .delivered(
                        oldID,
                        applicationName: "TextEdit",
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
                applicationName: "TextEdit",
                transcription: "replacement",
                finalText: "replacement",
                outcome: .delivered(
                    replacementID,
                    applicationName: "TextEdit",
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
                    applicationName: "TextEdit",
                    transcription: "must not return",
                    finalText: "must not return",
                    outcome: .delivered(
                        id,
                        applicationName: "TextEdit",
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
                    applicationName: nil,
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
                    applicationName: nil,
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
                applicationName: "TextEdit",
                transcription: "healthy",
                finalText: "healthy",
                outcome: .delivered(
                    healthyID,
                    applicationName: "TextEdit",
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
                        applicationName: nil,
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
            "corrupt history is preserved with a recoverable notice", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-corrupt-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            try Data("not-json".utf8).write(to: fileURL)

            let store = VersionedLocalSessionHistory(fileURL: fileURL)
            let status = await store.persistenceStatus()
            if case .corruptedDataPreserved(let backupURL, _) = status.notice {
                try expect(FileManager.default.fileExists(atPath: backupURL.path))
                let cleared = await store.clear()
                try expect(cleared)
                try expect(!FileManager.default.fileExists(atPath: backupURL.path))
                let clearedStatus = await store.persistenceStatus()
                try expect(clearedStatus.notice == nil)
            } else {
                throw SpecFailure(
                    message: "corrupt history did not produce a preserved recovery notice")
            }
            let recoveredRecords = await store.allRecords()
            try expect(recoveredRecords.isEmpty)
        }

        await runAsync(
            "history retention prunes by age and enforces a hard safety cap", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-retention-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let capped = VersionedLocalSessionHistory(
                fileURL: directory.appendingPathComponent("capped.json"),
                maximumRecordCount: 3
            )
            let now = Date()
            for offset in 0..<4 {
                let id = VoiceInputSessionID()
                await capped.save(
                    .init(
                        sessionID: id,
                        startedAt: now.addingTimeInterval(Double(offset)),
                        applicationName: nil,
                        transcription: "record-\(offset)",
                        finalText: "record-\(offset)",
                        outcome: .pendingCopy(id, text: "record-\(offset)", reason: .missingTarget)
                    ))
            }
            let cappedRecords = await capped.allRecords()
            try expect(cappedRecords.count == 3)
            try expect(cappedRecords.first?.finalText == "record-3")

            let aged = VersionedLocalSessionHistory(
                fileURL: directory.appendingPathComponent("aged.json")
            )
            let oldID = VoiceInputSessionID()
            let currentID = VoiceInputSessionID()
            await aged.save(
                .init(
                    sessionID: oldID,
                    startedAt: now.addingTimeInterval(-100 * 86_400),
                    applicationName: nil,
                    transcription: "old",
                    finalText: "old",
                    outcome: .pendingCopy(oldID, text: "old", reason: .missingTarget)
                ))
            await aged.save(
                .init(
                    sessionID: currentID,
                    startedAt: now,
                    applicationName: nil,
                    transcription: "current",
                    finalText: "current",
                    outcome: .pendingCopy(currentID, text: "current", reason: .missingTarget)
                ))
            let appliedRetention = await aged.applyRetentionPolicy(.thirtyDays, now: now)
            try expect(appliedRetention)
            let agedRecords = await aged.allRecords()
            try expect(agedRecords.map(\.sessionID) == [currentID])
        }

        await runAsync(
            "disabled history preserves existing records and skips new saves", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-disabled-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let stores: [any LocalSessionHistoryStoring] = [
                VersionedLocalSessionHistory(
                    fileURL: directory.appendingPathComponent("history.json")
                ),
                SQLiteSessionHistory(
                    fileURL: directory.appendingPathComponent("history.sqlite3")
                ),
            ]

            for store in stores {
                let existingID = VoiceInputSessionID()
                await store.save(
                    .init(
                        sessionID: existingID,
                        startedAt: Date(),
                        applicationName: nil,
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
                        applicationName: nil,
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
                        applicationName: nil,
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
            "history delete and clear roll back when disk write fails", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-write-failure-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("blocks-directory".utf8).write(to: directory)
            let store = VersionedLocalSessionHistory(
                fileURL: directory.appendingPathComponent("history.json")
            )
            let id = VoiceInputSessionID()
            await store.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    applicationName: nil,
                    transcription: "需要保留",
                    finalText: "需要保留",
                    outcome: .pendingCopy(id, text: "需要保留", reason: .missingTarget)
                ))

            let deleted = await store.delete(sessionID: id)
            let cleared = await store.clear()
            let records = await store.allRecords()
            try expect(!deleted)
            try expect(!cleared)
            try expect(records.map(\.sessionID) == [id])
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
            let writer = VersionedLocalSessionHistory(fileURL: fileURL)
            let id = VoiceInputSessionID()
            await writer.save(
                .init(
                    sessionID: id,
                    startedAt: Date(),
                    applicationName: nil,
                    transcription: "private history",
                    finalText: "private history",
                    outcome: .pendingCopy(
                        id,
                        text: "private history",
                        reason: .missingTarget
                    )
                ))

            let protected = VersionedLocalSessionHistory(
                fileURL: fileURL,
                fileProtection: LocalFileProtection { _ in
                    throw FileProtectionFailure()
                }
            )
            let records = await protected.allRecords()
            let status = await protected.persistenceStatus()

            try expect(records.isEmpty)
            guard case .privacyMigrationFailed = status.notice else {
                throw SpecFailure(message: "history protection failure was hidden")
            }
        }
    }
}
