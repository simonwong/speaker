import Foundation
import SpeakerCore
import SpeakerSpecSupport

/// Per-service usage and release-to-delivery latency, which the overview turns
/// into an estimated cost and per-provider response times.
enum ServiceUsageSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        run(
            "service usage counts recording time per model, successful refinement, and delivered latency only",
            failures: &failures
        ) {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let records = [
                serviceRecord(
                    startedAt: start, provider: "doubao", model: "bigmodel_async",
                    recordingMs: 60_000, latencyMs: 800, outcome: .delivered,
                    refinement: (.deepSeek, "deepseek-flash", "succeeded")
                ),
                serviceRecord(
                    startedAt: start, provider: "doubao", model: "bigmodel_async",
                    recordingMs: 30_000, latencyMs: nil, outcome: .cancelled
                ),
                // A failed session that somehow carries a latency is still not
                // a delivered sample.
                serviceRecord(
                    startedAt: start, provider: "openai", model: "gpt-transcribe",
                    recordingMs: 10_000, latencyMs: 5_000, outcome: .failed,
                    refinement: (.deepSeek, "deepseek-flash", "fellBack")
                ),
                serviceRecord(
                    startedAt: start, provider: "apple", model: "speech-transcriber",
                    recordingMs: 5_000, latencyMs: 300, outcome: .delivered,
                    refinement: (.custom, "private-custom-model", "succeeded")
                ),
            ]

            let services = VoiceInputUsageStatistics.summarize(records).services

            try expect(
                services.recognition == [
                    SpeechRecognitionServiceUsage(
                        provider: "apple", modelID: "speech-transcriber",
                        sessionCount: 1, recordingMilliseconds: 5_000),
                    SpeechRecognitionServiceUsage(
                        provider: "doubao", modelID: "bigmodel_async",
                        sessionCount: 2, recordingMilliseconds: 90_000),
                    SpeechRecognitionServiceUsage(
                        provider: "openai", modelID: "gpt-transcribe",
                        sessionCount: 1, recordingMilliseconds: 10_000),
                ],
                "recognition usage was \(services.recognition)"
            )
            let expectedInput = ChatCompletionRefinementClient.requestMessageCharacterCount(
                text: "原始转录", instruction: "只清理口语杂质", dictionaryWords: []
            )
            let expectedOutput = ChatCompletionRefinementClient.responseCharacterCount(
                text: "整理结果")
            try expect(
                services.refinement == [
                    RefinementServiceUsage(
                        provider: .custom, modelID: "", requestCount: 1,
                        inputCharacterCount: expectedInput,
                        outputCharacterCount: expectedOutput),
                    RefinementServiceUsage(
                        provider: .deepSeek, modelID: "deepseek-flash", requestCount: 1,
                        inputCharacterCount: expectedInput,
                        outputCharacterCount: expectedOutput),
                ],
                "refinement usage was \(services.refinement)"
            )
            try expect(
                expectedInput > ChatCompletionRefinementClient.fixedSystemPrompt.count,
                "the request estimate left out the user prompt"
            )
            try expect(
                services.releaseToDeliveryMilliseconds == ["doubao": [800], "apple": [300]],
                "latency samples were \(services.releaseToDeliveryMilliseconds)"
            )
        }

        await runAsync(
            "release-to-delivery latency is stored as a duration and absent from older payloads",
            failures: &failures
        ) {
            let directory = temporaryDirectory("speaker-latency-payload")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let history = SQLiteSessionHistory(fileURL: fileURL)
            let record = serviceRecord(
                startedAt: Date(), provider: "doubao", model: "bigmodel_async",
                recordingMs: 1_000, latencyMs: 812, outcome: .delivered
            )

            await history.save(record)
            let payload = try readHistoryPayload(from: fileURL)
            let stored = await history.record(sessionID: record.sessionID)

            try expect(payload.contains(#""releaseToDeliveryMilliseconds":812"#), payload)
            try expect(stored?.releaseToDeliveryMilliseconds == 812)
            try expect(
                !SessionRecordPayloadFixtures.all.contains {
                    $0.payload.contains("releaseToDeliveryMilliseconds")
                },
                "a pinned older payload gained the latency key"
            )
        }

        await runAsync(
            "service usage survives deleting, clearing, and evicting history without text or custom model names",
            failures: &failures
        ) {
            let directory = temporaryDirectory("speaker-service-archive")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let history = SQLiteSessionHistory(fileURL: fileURL, maximumRecordCount: 2)
            let now = Date()
            let records = [
                serviceRecord(
                    startedAt: now.addingTimeInterval(-120), provider: "qwen",
                    model: "qwen3-asr-flash", recordingMs: 4_000, latencyMs: 900,
                    outcome: .delivered,
                    refinement: (.custom, "private-custom-model", "succeeded")
                ),
                serviceRecord(
                    startedAt: now.addingTimeInterval(-60), provider: "doubao",
                    model: "bigmodel_async", recordingMs: 2_000, latencyMs: 700,
                    outcome: .delivered,
                    refinement: (.glm, "glm-5.3-flash", "succeeded")
                ),
                serviceRecord(
                    startedAt: now, provider: "doubao", model: "bigmodel_async",
                    recordingMs: 1_000, latencyMs: 600, outcome: .delivered
                ),
            ]
            for record in records { await history.save(record) }
            let expected = VoiceInputUsageStatistics.summarize(records).services

            let afterEviction = await history.usageStatistics().services
            _ = await history.delete(sessionID: records[2].sessionID)
            let afterDelete = await history.usageStatistics().services
            _ = await history.clear()
            let afterClear = await history.usageStatistics().services

            for (label, services) in [
                ("eviction", afterEviction), ("deletion", afterDelete), ("clear", afterClear),
            ] {
                try expect(
                    services.recognition == expected.recognition,
                    "\(label) changed recognition usage to \(services.recognition)"
                )
                try expect(
                    services.refinement == expected.refinement,
                    "\(label) changed refinement usage to \(services.refinement)"
                )
            }
            try expect(
                afterEviction.releaseToDeliveryMilliseconds == ["doubao": [600, 700]],
                "evicted sessions kept latency samples: \(afterEviction.releaseToDeliveryMilliseconds)"
            )
            try expect(afterClear.releaseToDeliveryMilliseconds.isEmpty)
            try expect(
                !sqliteFilesContain(Data("private-custom-model".utf8), at: fileURL),
                "the archive kept a Custom Refinement Provider model name"
            )
            try expect(
                !sqliteFilesContain(Data("原始转录".utf8), at: fileURL),
                "the archive kept transcript text"
            )
        }

        await runAsync(
            "a schema 1 database written before service usage opens with its rows and no latency",
            failures: &failures
        ) {
            let directory = temporaryDirectory("speaker-service-migration")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let fixture = SessionRecordPayloadFixtures.delivered
            let payloadHex = Data(fixture.payload.utf8)
                .map { String(format: "%02x", $0) }.joined()
            try executeSQLite(
                """
                CREATE TABLE history_records (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    payload_schema INTEGER NOT NULL DEFAULT 1
                );
                CREATE INDEX history_started_at ON history_records(started_at DESC);
                CREATE TABLE history_metadata (
                    key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL
                );
                CREATE TABLE usage_archive (
                    day REAL PRIMARY KEY NOT NULL,
                    characters INTEGER NOT NULL,
                    milliseconds INTEGER NOT NULL,
                    sessions INTEGER NOT NULL
                );
                INSERT INTO history_records(session_id, started_at, payload, payload_schema)
                VALUES(
                    '\(fixture.record.sessionID.rawValue.uuidString)',
                    \(fixture.record.startedAt.timeIntervalSince1970),
                    X'\(payloadHex)',
                    1
                );
                PRAGMA user_version=1;
                """,
                at: fileURL
            )

            let history = SQLiteSessionHistory(fileURL: fileURL)
            let opened = await history.usageStatistics().services
            let stored = await history.record(sessionID: fixture.record.sessionID)
            let tables = try sqliteTextColumn(
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
                at: fileURL
            )
            let version = try sqliteTextColumn("PRAGMA user_version", at: fileURL)
            _ = await history.delete(sessionID: fixture.record.sessionID)
            let afterDelete = await history.usageStatistics().services

            try expect(stored?.releaseToDeliveryMilliseconds == nil)
            try expect(opened.releaseToDeliveryMilliseconds.isEmpty, "an old row became a sample")
            try expect(
                opened.recognition == [
                    SpeechRecognitionServiceUsage(
                        provider: "doubao", modelID: "bigmodel",
                        sessionCount: 1, recordingMilliseconds: 0)
                ],
                "old recognition usage was \(opened.recognition)"
            )
            try expect(opened.refinement.map(\.requestCount) == [1])
            try expect(
                tables.contains("recognition_usage_archive")
                    && tables.contains("refinement_usage_archive"),
                "the archive tables were not created: \(tables)"
            )
            try expect(version == ["1"], "the additive migration changed user_version: \(version)")
            try expect(afterDelete.recognition == opened.recognition)
            try expect(afterDelete.refinement == opened.refinement)
        }
    }

    private enum Outcome {
        case delivered, cancelled, failed
    }

    private static func serviceRecord(
        startedAt: Date,
        provider: String,
        model: String,
        recordingMs: Int,
        latencyMs: Int?,
        outcome: Outcome,
        refinement: (RefinementProviderID, String, String)? = nil
    ) -> VoiceInputHistoryRecord {
        let id = VoiceInputSessionID(rawValue: UUID())
        let activity: VoiceInputActivity =
            switch outcome {
            case .delivered: .delivered(id, applicationName: "", text: "整理结果")
            case .cancelled: .cancelled(id)
            case .failed: .failed(id, .transcriptionFailed)
            }
        return VoiceInputHistoryRecord(
            sessionID: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: "原始转录",
            finalText: "整理结果",
            transcriptionProvider: provider,
            transcriptionModelID: model,
            deepSeekText: refinement == nil ? nil : "整理结果",
            refinementProviderID: refinement?.0,
            refinementModelID: refinement?.1,
            refinementPrompt: refinement == nil ? nil : "只清理口语杂质",
            refinementStatus: refinement?.2,
            stageDurationsMilliseconds: ["recording": recordingMs],
            releaseToDeliveryMilliseconds: latencyMs,
            outcome: activity
        )
    }

    private static func temporaryDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
