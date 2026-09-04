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
        await runAsync(
            "history dashboard state carries the refresh moment",
            failures: &failures
        ) {
            let calendar = shanghaiCalendar()
            let pinned = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 20, hour: 15
            ))!
            let model = makeHistoryModel(
                records: [
                    record(startedAt: pinned.addingTimeInterval(-3_600)),
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
            let pinned = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 20, hour: 15
            ))!
            let model = makeHistoryModel(
                records: [
                    record(startedAt: calendar.date(from: DateComponents(
                        year: 2026, month: 7, day: 20, hour: 9
                    ))!),
                    record(startedAt: calendar.date(from: DateComponents(
                        year: 2026, month: 7, day: 19, hour: 20
                    ))!),
                    record(startedAt: calendar.date(from: DateComponents(
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
                titles == ["今天", "昨天", "7月17日"],
                "pinned grouping produced \(titles)"
            )
        }

        SpeakerSpecSupport.run(
            "history grouping follows the state, not the clock, as the day turns",
            failures: &failures
        ) {
            let calendar = shanghaiCalendar()
            let records = [
                record(startedAt: calendar.date(from: DateComponents(
                    year: 2026, month: 7, day: 20, hour: 9
                ))!),
                record(startedAt: calendar.date(from: DateComponents(
                    year: 2026, month: 7, day: 19, hour: 20
                ))!),
            ]
            let sameDay = dashboardState(
                records: records,
                referenceDate: calendar.date(from: DateComponents(
                    year: 2026, month: 7, day: 20, hour: 23, minute: 59
                ))!
            )
            let nextDay = dashboardState(
                records: records,
                referenceDate: calendar.date(from: DateComponents(
                    year: 2026, month: 7, day: 21, hour: 0, minute: 1
                ))!
            )

            try expect(
                sameDay.sections(calendar: calendar).map(\.title)
                    == ["今天", "昨天"]
            )
            try expect(
                nextDay.sections(calendar: calendar).map(\.title)
                    == ["昨天", "7月19日"],
                "the same records did not re-group when the state moved on"
            )
        }

        await runAsync(
            "overview dashboard state pins the usage window to the refresh moment",
            failures: &failures
        ) {
            let calendar = shanghaiCalendar()
            let pinned = calendar.date(from: DateComponents(
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
                        ),
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
            dictionary: DictionarySettingsModel(
                store: DashboardDictionaryStoreFake(),
                configuration: VoiceInputConfigurationController()
            ),
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

/// A read-only history store: the dashboards only ever read from it here.
private actor DashboardHistoryStoreFake: LocalSessionHistoryStoring {
    private var records: [VoiceInputHistoryRecord]
    private let summary: VoiceInputUsageSummary

    init(records: [VoiceInputHistoryRecord], summary: VoiceInputUsageSummary) {
        self.records = records
        self.summary = summary
    }

    func save(_ record: VoiceInputHistoryRecord) {
        records.append(record)
    }

    func allRecords() -> [VoiceInputHistoryRecord] {
        records
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

    func persistenceStatus() -> LocalHistoryPersistenceStatus {
        LocalHistoryPersistenceStatus(recordCount: records.count, notice: nil)
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

    func usageStatistics() -> VoiceInputUsageSummary {
        summary
    }
}

private struct DashboardClipboardFake: ClipboardWriting {
    @discardableResult
    func copy(_ text: String) async -> Bool {
        true
    }
}

private actor DashboardDictionaryStoreFake: PersonalDictionaryStoring {
    private var stored: PersonalDictionary = .empty

    func load() -> PersonalDictionaryLoadResult {
        PersonalDictionaryLoadResult(dictionary: stored)
    }

    func save(_ dictionary: PersonalDictionary) {
        stored = dictionary
    }
}
