import Foundation
import SpeakerCore

/// Session Records whose stored payload bytes are pinned. Moving or renaming
/// the payload codec must leave every byte of these strings unchanged, because
/// existing `history.sqlite3` rows and legacy `history.json` records are read
/// back through the same codec.
enum SessionRecordPayloadFixtures {
    struct Fixture {
        let record: VoiceInputHistoryRecord
        /// What reading the payload back yields: target-application identity
        /// and free-text provider messages are dropped on encode.
        let decoded: VoiceInputHistoryRecord
        let payload: String
    }

    static let startedAt = Date(timeIntervalSince1970: 1_700_000_000.123)
    static let snapshotID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let entryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    static var all: [Fixture] {
        [delivered, pendingCopy, failed, cancelled, processing]
    }

    static func sessionID(_ digit: Character) -> VoiceInputSessionID {
        VoiceInputSessionID(
            rawValue: UUID(
                uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA\(digit)"
            )!
        )
    }

    static var delivered: Fixture {
        let id = sessionID("1")
        func record(
            applicationName: String?,
            providerMessage: String?,
            refinementFailureMessage: String?,
            outcomeApplicationName: String
        ) -> VoiceInputHistoryRecord {
            VoiceInputHistoryRecord(
                sessionID: id,
                startedAt: startedAt,
                applicationName: applicationName,
                transcription: "豆包原文",
                finalText: "最终文本",
                transcriptionProvider: "doubao",
                transcriptionModelID: "bigmodel",
                providerRequestID: "request-1",
                providerErrorCode: "partial",
                providerOperation: "transcribe",
                providerStatusCode: "200",
                providerMessage: providerMessage,
                deliveryDiagnosticCode: "pasteReceipt.unconfirmed",
                deepSeekText: "整理结果",
                deepSeekRequestID: "refine-1",
                refinementProviderID: .deepSeek,
                refinementModelID: "deepseek-chat",
                refinementModeName: "精简清理",
                refinementPrompt: "只清理口语杂质",
                refinementStatus: "succeeded",
                refinementFailureCode: "none",
                refinementFailureStatusCode: "0",
                refinementFailureMessage: refinementFailureMessage,
                cancelledAtStage: nil,
                dictionarySnapshotID: snapshotID,
                dictionarySnapshotEntries: [
                    RecordedDictionaryEntry(id: entryID, word: "豆包", legacyAliases: ["豆宝"])
                ],
                dictionaryRequestContext: DictionaryRequestContext(
                    snapshotID: snapshotID,
                    hotwords: ["豆包"],
                    includedEntryIDs: [entryID],
                    omissions: []
                ),
                dictionaryReplacements: [
                    DictionaryReplacement(
                        entryID: entryID,
                        alias: "豆宝",
                        canonicalTerm: "豆包",
                        matchedText: "豆宝",
                        utf16Location: 0,
                        utf16Length: 2
                    )
                ],
                durationMilliseconds: 1_234,
                stageDurationsMilliseconds: ["capture": 10, "doubao": 500, "deepseek": 300],
                outcome: .delivered(id, applicationName: outcomeApplicationName, text: "最终文本")
            )
        }
        return Fixture(
            record: record(
                applicationName: "TextEdit",
                providerMessage: "provider-free-text",
                refinementFailureMessage: "refinement-free-text",
                outcomeApplicationName: "TextEdit"
            ),
            decoded: record(
                applicationName: nil,
                providerMessage: nil,
                refinementFailureMessage: nil,
                outcomeApplicationName: decodedDeliveredApplicationName
            ),
            payload:
                #"{"deepSeekRequestID":"refine-1","deepSeekText":"整理结果","deliveryDiagnosticCode":"pasteReceipt.unconfirmed","dictionaryReplacements":[{"alias":"豆宝","canonicalTerm":"豆包","entryID":"22222222-2222-2222-2222-222222222222","matchedText":"豆宝","utf16Length":2,"utf16Location":0}],"dictionaryRequestContext":{"hotwords":["豆包"],"includedEntryIDs":["22222222-2222-2222-2222-222222222222"],"omissions":[],"snapshotID":"11111111-1111-1111-1111-111111111111"},"dictionarySnapshotEntries":[{"aliases":["豆宝"],"id":"22222222-2222-2222-2222-222222222222","word":"豆包"}],"dictionarySnapshotID":"11111111-1111-1111-1111-111111111111","durationMilliseconds":1234,"finalText":"最终文本","outcome":{"kind":"delivered","sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1","text":"最终文本"},"providerErrorCode":"partial","providerOperation":"transcribe","providerRequestID":"request-1","providerStatusCode":"200","refinementFailureCode":"none","refinementFailureStatusCode":"0","refinementModeName":"精简清理","refinementModelID":"deepseek-chat","refinementPrompt":"只清理口语杂质","refinementProviderID":"deepseek","refinementStatus":"succeeded","sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1","stageDurationsMilliseconds":{"capture":10,"deepseek":300,"doubao":500},"startedAt":1700000000123,"transcription":"豆包原文","transcriptionModelID":"bigmodel","transcriptionProvider":"doubao"}"#
        )
    }

    static var pendingCopy: Fixture {
        let id = sessionID("2")
        let record = VoiceInputHistoryRecord(
            sessionID: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: "待复制",
            finalText: "待复制",
            outcome: .pendingCopy(id, text: "待复制", reason: .secureTarget)
        )
        return Fixture(
            record: record, decoded: record,
            payload:
                #"{"dictionaryReplacements":[],"dictionarySnapshotEntries":[],"durationMilliseconds":0,"finalText":"待复制","outcome":{"kind":"pendingCopy","pendingCopyReason":"secureTarget","sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2","text":"待复制"},"sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2","stageDurationsMilliseconds":{},"startedAt":1700000000123,"transcription":"待复制"}"#
        )
    }

    static var failed: Fixture {
        let id = sessionID("3")
        let record = VoiceInputHistoryRecord(
            sessionID: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: nil,
            finalText: nil,
            providerErrorCode: "authentication",
            outcome: .failed(id, .providerAuthenticationFailed)
        )
        return Fixture(
            record: record, decoded: record,
            payload:
                #"{"dictionaryReplacements":[],"dictionarySnapshotEntries":[],"durationMilliseconds":0,"outcome":{"failure":"providerAuthenticationFailed","kind":"failed","sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA3"},"providerErrorCode":"authentication","sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA3","stageDurationsMilliseconds":{},"startedAt":1700000000123}"#
        )
    }

    static var cancelled: Fixture {
        let id = sessionID("4")
        let record = VoiceInputHistoryRecord(
            sessionID: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: "取消前的识别",
            finalText: nil,
            cancelledAtStage: "refining",
            outcome: .cancelled(id)
        )
        return Fixture(
            record: record, decoded: record,
            payload:
                #"{"cancelledAtStage":"refining","dictionaryReplacements":[],"dictionarySnapshotEntries":[],"durationMilliseconds":0,"outcome":{"kind":"cancelled","sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA4"},"sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA4","stageDurationsMilliseconds":{},"startedAt":1700000000123,"transcription":"取消前的识别"}"#
        )
    }

    static var processing: Fixture {
        let id = sessionID("5")
        let record = VoiceInputHistoryRecord(
            sessionID: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: "整理中",
            finalText: nil,
            outcome: .processing(id, .refining, applicationName: nil)
        )
        return Fixture(
            record: record, decoded: record,
            payload:
                #"{"dictionaryReplacements":[],"dictionarySnapshotEntries":[],"durationMilliseconds":0,"outcome":{"kind":"processing","processingStage":"refining","sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA5"},"sessionID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA5","stageDurationsMilliseconds":{},"startedAt":1700000000123,"transcription":"整理中"}"#
        )
    }

    /// Payloads never carry target-application identity, so a delivered
    /// outcome read back from disk has no application name to restore.
    static let decodedDeliveredApplicationName = ""
}
