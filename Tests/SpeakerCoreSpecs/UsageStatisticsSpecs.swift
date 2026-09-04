import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum UsageStatisticsSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        run("usage statistics aggregate recognized characters and speaking time per local day", failures: &failures) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            func day(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
                calendar.date(from: DateComponents(
                    year: y, month: mo, day: d, hour: h
                ))!
            }
            let records = [
                usageRecord(startedAt: day(2026, 7, 18, 10), text: "你好世界", recordingMs: 3_000),
                usageRecord(startedAt: day(2026, 7, 18, 22), text: "早", recordingMs: 1_500),
                usageRecord(startedAt: day(2026, 7, 19, 9), text: "测试", recordingMs: 2_000),
                // Redacted/secure session: no body text, but its recording still counts.
                usageRecord(startedAt: day(2026, 7, 19, 11), text: nil, recordingMs: 500),
            ]
            let summary = VoiceInputUsageStatistics.summarize(records, calendar: calendar)
            try expect(summary.totalRecognizedCharacterCount == 7)
            try expect(summary.totalSpeakingMilliseconds == 7_000)
            try expect(summary.totalSessionCount == 4)
            try expect(summary.daily.count == 2)

            let first = summary.daily[0]
            try expect(first.day == calendar.startOfDay(for: day(2026, 7, 18, 10)))
            try expect(first.recognizedCharacterCount == 5)
            try expect(first.speakingMilliseconds == 4_500)
            try expect(first.sessionCount == 2)

            let second = summary.daily[1]
            try expect(second.day == calendar.startOfDay(for: day(2026, 7, 19, 9)))
            try expect(second.recognizedCharacterCount == 2)
            try expect(second.speakingMilliseconds == 2_500)
            try expect(second.sessionCount == 2)
        }

        await runAsync("SQLite usage statistics stream to the same result as folding every record", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-usage-stats-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let history = SQLiteSessionHistory(fileURL: fileURL)

            let empty = await history.usageStatistics()
            try expect(empty == .empty)

            let now = Date()
            await history.save(usageRecord(
                startedAt: now,
                text: "语音输入",
                recordingMs: 2_400
            ))
            await history.save(usageRecord(
                startedAt: now.addingTimeInterval(-3_600),
                text: "键盘",
                recordingMs: 1_100
            ))

            let streamed = await history.usageStatistics()
            let folded = VoiceInputUsageStatistics.summarize(
                await history.allRecords()
            )
            try expect(streamed == folded)
            try expect(streamed.totalRecognizedCharacterCount == 6)
            try expect(streamed.totalSpeakingMilliseconds == 3_500)
            try expect(streamed.totalSessionCount == 2)
        }
    }
}
