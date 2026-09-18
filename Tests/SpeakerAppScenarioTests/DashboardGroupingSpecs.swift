import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport

/// History and Overview group by calendar day. The reference date travels in
/// the dashboard state rather than being read while a view renders, so these
/// cases pin the 今天/昨天 boundary instead of depending on the wall clock.
enum DashboardGroupingSpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        for suspendedRead in [DashboardHistoryStoreFake.Read.records, .status] {
            await runAsync(
                "history refresh discards superseded \(suspendedRead) responses",
                failures: &failures
            ) {
                let initial = Date(timeIntervalSince1970: 1_000)
                let latest = initial.addingTimeInterval(86_400)
                var now = initial
                let oldRecord = record(startedAt: initial)
                let store = DashboardHistoryStoreFake(
                    records: [oldRecord], summary: .empty, suspendedRead: suspendedRead
                )
                let model = HistoryModel(
                    store: store, clipboard: DashboardClipboardFake(),
                    announce: { _ in }, now: { now }
                )
                let first = Task { await model.refresh() }
                guard await eventually(before: .seconds(2), condition: { await store.isSuspended })
                else {
                    first.cancel()
                    throw SpecFailure(message: "first history read did not suspend")
                }
                let publishedIncompleteRecords = !model.records.isEmpty
                now = latest
                _ = await model.clear()
                await store.resumeRead()
                await first.value
                try expect(!publishedIncompleteRecords, "an incomplete refresh published records")
                try expect(model.records.isEmpty, "a cleared record reappeared")
                try expect(model.totalRecordCount == 0, "a stale count replaced the clear result")
                try expect(model.referenceDate == latest)
            }
        }

        await runAsync("overview refresh discards superseded usage responses", failures: &failures)
        {
            let initial = Date(timeIntervalSince1970: 1_000)
            let latest = initial.addingTimeInterval(86_400)
            var now = initial
            let oldSummary = VoiceInputUsageSummary(
                totalRecognizedCharacterCount: 10, totalSpeakingMilliseconds: 100,
                totalSessionCount: 1, daily: []
            )
            let store = DashboardHistoryStoreFake(
                records: [], summary: oldSummary, suspendedRead: .usage
            )
            let model = OverviewModel(store: store, now: { now })
            let first = Task { await model.refresh() }
            guard await eventually(before: .seconds(2), condition: { await store.isSuspended })
            else {
                first.cancel()
                throw SpecFailure(message: "first usage read did not suspend")
            }
            now = latest
            await store.setSummary(.empty)
            await model.refresh()
            await store.resumeRead()
            await first.value
            try expect(model.summary == .empty, "older usage replaced the latest summary")
            try expect(model.referenceDate == latest)
        }

        await runAsync(
            "history dashboard state carries the refresh moment",
            failures: &failures
        ) {
            let calendar = shanghaiCalendar()
            let pinned = calendar.date(
                from: DateComponents(
                    year: 2026, month: 7, day: 20, hour: 15
                ))!
            let model = makeHistoryModel(
                records: [
                    record(startedAt: pinned.addingTimeInterval(-3_600))
                ],
                now: pinned
            )

            try expect(
                model.referenceDate == pinned,
                "the model started from \(model.referenceDate)"
            )
            await model.refresh()
            try expect(model.dashboardState.referenceDate == pinned)
            try expect(model.dashboardState.records.count == 1)
        }

        await runAsync(
            "history sections name today and yesterday from the pinned state",
            failures: &failures
        ) {
            let calendar = shanghaiCalendar()
            let pinned = calendar.date(
                from: DateComponents(
                    year: 2026, month: 7, day: 20, hour: 15
                ))!
            let model = makeHistoryModel(
                records: [
                    record(
                        startedAt: calendar.date(
                            from: DateComponents(
                                year: 2026, month: 7, day: 20, hour: 9
                            ))!),
                    record(
                        startedAt: calendar.date(
                            from: DateComponents(
                                year: 2026, month: 7, day: 19, hour: 20
                            ))!),
                    record(
                        startedAt: calendar.date(
                            from: DateComponents(
                                year: 2026, month: 7, day: 17, hour: 10
                            ))!),
                ],
                now: pinned
            )
            await model.refresh()

            let titles = model.dashboardState
                .sections(calendar: calendar)
                .map(\.title)
            try expect(
                titles == [
                    HistoryPresentation.todaySectionTitle,
                    HistoryPresentation.yesterdaySectionTitle,
                    "7月17日",
                ],
                "pinned grouping produced \(titles)"
            )
        }

        SpeakerSpecSupport.run(
            "history grouping follows the state, not the clock, as the day turns",
            failures: &failures
        ) {
            let calendar = shanghaiCalendar()
            let records = [
                record(
                    startedAt: calendar.date(
                        from: DateComponents(
                            year: 2026, month: 7, day: 20, hour: 9
                        ))!),
                record(
                    startedAt: calendar.date(
                        from: DateComponents(
                            year: 2026, month: 7, day: 19, hour: 20
                        ))!),
            ]
            let sameDay = dashboardState(
                records: records,
                referenceDate: calendar.date(
                    from: DateComponents(
                        year: 2026, month: 7, day: 20, hour: 23, minute: 59
                    ))!
            )
            let nextDay = dashboardState(
                records: records,
                referenceDate: calendar.date(
                    from: DateComponents(
                        year: 2026, month: 7, day: 21, hour: 0, minute: 1
                    ))!
            )

            try expect(
                sameDay.sections(calendar: calendar).map(\.title)
                    == [
                        HistoryPresentation.todaySectionTitle,
                        HistoryPresentation.yesterdaySectionTitle,
                    ]
            )
            try expect(
                nextDay.sections(calendar: calendar).map(\.title)
                    == [
                        HistoryPresentation.yesterdaySectionTitle,
                        "7月19日",
                    ],
                "the same records did not re-group when the state moved on"
            )
        }

        await runAsync(
            "overview dashboard state pins the usage window to the refresh moment",
            failures: &failures
        ) {
            let calendar = shanghaiCalendar()
            let pinned = calendar.date(
                from: DateComponents(
                    year: 2026, month: 7, day: 20, hour: 15
                ))!
            let today = calendar.startOfDay(for: pinned)
            let store = DashboardHistoryStoreFake(
                records: [],
                summary: VoiceInputUsageSummary(
                    totalRecognizedCharacterCount: 1_000,
                    totalSpeakingMilliseconds: 0,
                    totalSessionCount: 1,
                    daily: [
                        VoiceInputDailyUsage(
                            day: today,
                            recognizedCharacterCount: 1_000,
                            speakingMilliseconds: 0,
                            sessionCount: 1
                        )
                    ]
                )
            )
            let model = OverviewModel(store: store, now: { pinned })
            await model.refresh()
            let state = model.dashboardState

            try expect(state.referenceDate == pinned)
            let heatmap = ContributionHeatmap.build(
                summary: state.summary,
                now: state.referenceDate,
                calendar: calendar
            )
            let todayCell = heatmap.columns
                .flatMap { $0 }
                .first { $0.date == today }
            try expect(
                todayCell?.recognizedCharacterCount == 1_000,
                "the pinned day is not the heatmap's last recorded cell"
            )
            try expect(
                heatmap.columns.flatMap { $0 }
                    .allSatisfy { $0.date <= today || $0.isFuture }
            )
        }
    }

    @MainActor
    private static func makeHistoryModel(
        records: [VoiceInputHistoryRecord],
        now: Date
    ) -> HistoryModel {
        HistoryModel(
            store: DashboardHistoryStoreFake(records: records, summary: .empty),
            clipboard: DashboardClipboardFake(),
            announce: { _ in },
            now: { now }
        )
    }

    private static func dashboardState(
        records: [VoiceInputHistoryRecord],
        referenceDate: Date
    ) -> HistoryDashboardState {
        HistoryDashboardState(
            records: records,
            totalRecordCount: records.count,
            notice: nil,
            feedback: nil,
            isBusy: false,
            referenceDate: referenceDate
        )
    }

    private static func shanghaiCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func record(startedAt: Date) -> VoiceInputHistoryRecord {
        let id = VoiceInputSessionID()
        return VoiceInputHistoryRecord(
            sessionID: id,
            startedAt: startedAt,
            applicationName: "备忘录",
            transcription: "测试文字",
            finalText: "测试文字",
            outcome: .delivered(
                id,
                applicationName: "备忘录",
                text: "测试文字"
            )
        )
    }
}

private actor DashboardHistoryStoreFake: LocalSessionHistoryStoring {
    private var records: [VoiceInputHistoryRecord]
    enum Read { case records, status, usage }

    private var summary: VoiceInputUsageSummary
    private var suspendedRead: Read?
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }

    init(
        records: [VoiceInputHistoryRecord], summary: VoiceInputUsageSummary,
        suspendedRead: Read? = nil
    ) {
        self.records = records
        self.summary = summary
        self.suspendedRead = suspendedRead
    }

    func save(_ record: VoiceInputHistoryRecord) {
        records.append(record)
    }

    func allRecords() async -> [VoiceInputHistoryRecord] {
        let snapshot = records
        await suspendIfNeeded(.records)
        return snapshot
    }

    func record(sessionID: VoiceInputSessionID) -> VoiceInputHistoryRecord? {
        records.first { $0.sessionID == sessionID }
    }

    @discardableResult
    func delete(sessionID: VoiceInputSessionID) -> Bool {
        let remaining = records.filter { $0.sessionID != sessionID }
        defer { records = remaining }
        return remaining.count != records.count
    }

    @discardableResult
    func clear() -> Bool {
        records = []
        return true
    }

    func persistenceStatus() async -> LocalHistoryPersistenceStatus {
        let snapshot = LocalHistoryPersistenceStatus(recordCount: records.count, notice: nil)
        await suspendIfNeeded(.status)
        return snapshot
    }

    func clearPersistenceNotice() {}

    func currentRetentionPolicy() -> HistoryRetentionPolicy {
        .forever
    }

    @discardableResult
    func applyRetentionPolicy(
        _ policy: HistoryRetentionPolicy,
        now: Date
    ) -> Bool {
        true
    }

    func usageStatistics() async -> VoiceInputUsageSummary {
        let snapshot = summary
        await suspendIfNeeded(.usage)
        return snapshot
    }

    func setSummary(_ summary: VoiceInputUsageSummary) {
        self.summary = summary
    }

    func resumeRead() {
        continuation?.resume()
        continuation = nil
    }

    private func suspendIfNeeded(_ read: Read) async {
        guard suspendedRead == read else { return }
        suspendedRead = nil
        await withCheckedContinuation { continuation = $0 }
    }
}

private struct DashboardClipboardFake: ClipboardWriting {
    @discardableResult
    func copy(_ text: String) async -> Bool {
        true
    }
}
