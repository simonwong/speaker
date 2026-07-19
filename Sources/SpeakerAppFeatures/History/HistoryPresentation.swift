import Foundation
import SpeakerCore

package struct HistoryDaySection: Equatable, Sendable {
    package let day: Date
    package let title: String
    package let records: [VoiceInputHistoryRecord]

    package init(
        day: Date,
        title: String,
        records: [VoiceInputHistoryRecord]
    ) {
        self.day = day
        self.title = title
        self.records = records
    }
}

package struct HistoryRecordRowPresentation: Equatable, Sendable {
    package let time: String
    package let applicationName: String
    package let text: String
    package let canCopy: Bool

    package init(
        time: String,
        applicationName: String,
        text: String,
        canCopy: Bool
    ) {
        self.time = time
        self.applicationName = applicationName
        self.text = text
        self.canCopy = canCopy
    }
}

/// Presentation policy for the History tab. Calendar grouping belongs here,
/// outside `SpeakerCore`, because labels such as Today are interface language.
package enum HistoryPresentation {
    package static func filteredRecords(
        _ records: [VoiceInputHistoryRecord],
        query: String
    ) -> [VoiceInputHistoryRecord] {
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else { return records }

        return records.filter { record in
            [retainedText(for: record), record.applicationName]
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

    package static func retainedText(
        for record: VoiceInputHistoryRecord
    ) -> String? {
        [record.finalText, record.transcription]
            .compactMap { $0 }
            .first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    package static func row(
        for record: VoiceInputHistoryRecord,
        calendar: Calendar = .current
    ) -> HistoryRecordRowPresentation {
        let retainedText = retainedText(for: record)
        let applicationName = record.applicationName.flatMap { name in
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : name
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"

        return HistoryRecordRowPresentation(
            time: formatter.string(from: record.startedAt),
            applicationName: applicationName ?? "未指定应用",
            text: retainedText ?? "此会话未保留正文",
            canCopy: retainedText != nil
        )
    }

    package static func sections(
        records: [VoiceInputHistoryRecord],
        now: Date,
        calendar: Calendar = .current
    ) -> [HistoryDaySection] {
        let today = calendar.startOfDay(for: now)
        let recordsByDay = Dictionary(grouping: records) { record in
            calendar.startOfDay(for: record.startedAt)
        }

        return recordsByDay.keys.sorted(by: >).map { day in
            let records = recordsByDay[day, default: []].sorted {
                if $0.startedAt == $1.startedAt {
                    return $0.sessionID.rawValue.uuidString
                        > $1.sessionID.rawValue.uuidString
                }
                return $0.startedAt > $1.startedAt
            }
            return HistoryDaySection(
                day: day,
                title: sectionTitle(
                    for: day,
                    today: today,
                    calendar: calendar
                ),
                records: records
            )
        }
    }

    private static func sectionTitle(
        for day: Date,
        today: Date,
        calendar: Calendar
    ) -> String {
        if day == today {
            return "今天"
        }
        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: today
        ), day == yesterday {
            return "昨天"
        }

        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: day
        )
        let year = components.year ?? 0
        let month = components.month ?? 0
        let dayOfMonth = components.day ?? 0
        if year == calendar.component(.year, from: today) {
            return "\(month)月\(dayOfMonth)日"
        }
        return "\(year)年\(month)月\(dayOfMonth)日"
    }
}
