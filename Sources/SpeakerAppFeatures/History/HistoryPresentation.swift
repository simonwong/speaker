import Foundation
import SpeakerCore
import SwiftUI

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

package enum HistoryRecordProblem: Equatable, Sendable {
    case refinementFailed
    case failed(VoiceInputFailure)

    package var label: String {
        switch self {
        case .refinementFailed: "整理失败，已保留转录"
        case .failed(let failure): failure.userTitle
        }
    }

    package var icon: String {
        switch self {
        case .refinementFailed: "exclamationmark.triangle"
        case .failed(let failure): failure.userIcon
        }
    }

    package var color: Color {
        switch self {
        case .refinementFailed: .orange
        case .failed: .red
        }
    }
}

package struct HistoryRecordRowPresentation: Equatable, Sendable {
    package let time: String
    package let text: String
    package let previewText: String
    package let canCopy: Bool
    package let problem: HistoryRecordProblem?

    package init(
        time: String,
        text: String,
        canCopy: Bool,
        problem: HistoryRecordProblem?
    ) {
        self.time = time
        self.text = text
        // A two-line limit still lays out the full string, so bound the collapsed preview first.
        if let end = text.index(text.startIndex, offsetBy: 512, limitedBy: text.endIndex),
            end < text.endIndex
        {
            self.previewText = String(text[..<end]) + "…"
        } else {
            self.previewText = text
        }
        self.canCopy = canCopy
        self.problem = problem
    }
}

/// Presentation policy for the History tab. Calendar grouping belongs here,
/// outside `SpeakerCore`, because labels such as Today are interface language.
package enum HistoryPresentation {
    /// The two relative day-section titles. Every other section is the
    /// formatted date itself.
    package static let todaySectionTitle = "今天"
    package static let yesterdaySectionTitle = "昨天"

    package static func filteredRecords(
        _ records: [VoiceInputHistoryRecord],
        query: String
    ) -> [VoiceInputHistoryRecord] {
        let visibleRecords = records.filter(isVisible)
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else { return visibleRecords }

        return visibleRecords.filter { record in
            (SessionHistoryRecordPolicy.searchableValues(record)
                + [problem(for: record)?.label].compactMap { $0 }).contains {
                    $0.range(
                        of: normalizedQuery,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    ) != nil
                }
        }
    }

    package static func isVisible(
        _ record: VoiceInputHistoryRecord
    ) -> Bool {
        if case .cancelled = record.outcome { return false }
        return retainedText(for: record) != nil
            || SessionHistoryRecordPolicy.retainedFailure(record) != nil
    }

    package static func retainedText(
        for record: VoiceInputHistoryRecord
    ) -> String? {
        SessionHistoryRecordPolicy.retainedText(record)
    }

    package static func problem(
        for record: VoiceInputHistoryRecord
    ) -> HistoryRecordProblem? {
        if let failure = SessionHistoryRecordPolicy.retainedFailure(record) {
            return .failed(failure)
        }
        if record.refinementStatus == TextRefinementStatus.fellBack.rawValue {
            return .refinementFailed
        }
        return nil
    }

    package static func row(
        for record: VoiceInputHistoryRecord,
        calendar: Calendar = .current
    ) -> HistoryRecordRowPresentation {
        let retainedText = retainedText(for: record)
        let timeStyle = Date.VerbatimFormatStyle(
            format:
                "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: calendar.timeZone,
            calendar: calendar
        )

        return HistoryRecordRowPresentation(
            time: record.startedAt.formatted(timeStyle),
            text: retainedText ?? rowText(for: record),
            canCopy: retainedText != nil,
            problem: problem(for: record)
        )
    }

    private static func rowText(for record: VoiceInputHistoryRecord) -> String {
        retainedText(for: record) ?? problem(for: record)?.label ?? "此会话未保留正文"
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
            return todaySectionTitle
        }
        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: today
        ), day == yesterday {
            return yesterdaySectionTitle
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

/// Interface labels for the retention picker; the policy's single home is
/// 设置-通用.
extension HistoryRetentionPolicy {
    package static let disabledDisplayName = "不保存"
    package static let thirtyDaysDisplayName = "最近 30 天"
    package static let ninetyDaysDisplayName = "最近 90 天"
    package static let oneYearDisplayName = "最近一年"
    package static let foreverDisplayName = "不按日期清理"

    package var displayName: String {
        switch self {
        case .disabled: Self.disabledDisplayName
        case .thirtyDays: Self.thirtyDaysDisplayName
        case .ninetyDays: Self.ninetyDaysDisplayName
        case .oneYear: Self.oneYearDisplayName
        case .forever: Self.foreverDisplayName
        }
    }
}

extension VoiceInputHistoryRecord {
    package var transcriptionProviderLabel: String {
        switch transcriptionProvider {
        case "doubao": "豆包语音"
        case "openai": "OpenAI"
        case "qwen": "阿里千问"
        case "local": "本机录音"
        default: "语音识别"
        }
    }

    package var refinementProviderLabel: String {
        if let refinementProviderID { return refinementProviderID.displayName }
        return deepSeekText != nil || deepSeekRequestID != nil
            || refinementStatus == "succeeded" || refinementStatus == "fellBack"
            ? "DeepSeek" : "文字整理"
    }
}
