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

/// The delivery state a Session Record row communicates. Read-back
/// verification in the delivery layer already distinguishes a confirmed
/// mutation from a posted-but-unconfirmed paste; the record keeps that fact
/// in `deliveryDiagnosticCode`.
package enum HistoryRecordStatus: Equatable, Sendable {
    case delivered
    case deliveryUnconfirmed
    case refinementFellBack
    case pendingCopy
    case failed(VoiceInputFailure)

    package var label: String {
        switch self {
        case .delivered: "已送达"
        case .deliveryUnconfirmed: "已发送·未确认"
        case .refinementFellBack: "已送达·整理回退"
        case .pendingCopy: "待复制结果"
        case let .failed(failure): failure.userTitle
        }
    }

    package var icon: String {
        switch self {
        case .delivered: "checkmark.circle.fill"
        case .deliveryUnconfirmed: "questionmark.circle"
        case .refinementFellBack: "exclamationmark.triangle"
        case .pendingCopy: "doc.on.clipboard"
        case let .failed(failure): failure.userIcon
        }
    }

    /// Successful deliveries stay quiet in the list; every other state earns
    /// a trailing status icon on the row.
    package var showsStatusIcon: Bool {
        self != .delivered
    }

    package var color: Color {
        switch self {
        case .delivered: .green
        case .deliveryUnconfirmed, .refinementFellBack: .orange
        case .pendingCopy: .blue
        case .failed: .red
        }
    }
}

package struct HistoryRecordRowPresentation: Equatable, Sendable {
    package let time: String
    package let text: String
    package let canCopy: Bool
    package let status: HistoryRecordStatus

    package init(
        time: String,
        text: String,
        canCopy: Bool,
        status: HistoryRecordStatus
    ) {
        self.time = time
        self.text = text
        self.canCopy = canCopy
        self.status = status
    }
}

/// Presentation policy for the History tab. Calendar grouping belongs here,
/// outside `SpeakerCore`, because labels such as Today are interface language.
package enum HistoryPresentation {
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
            rowText(for: record).range(
                of: normalizedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) != nil
        }
    }

    /// The list only contains records that produced text. Cancelled sessions
    /// and textless records stay persisted but never appear.
    package static func isVisible(
        _ record: VoiceInputHistoryRecord
    ) -> Bool {
        if case .cancelled = record.outcome { return false }
        return retainedText(for: record) != nil
    }

    package static func retainedText(
        for record: VoiceInputHistoryRecord
    ) -> String? {
        SessionHistoryRecordPolicy.retainedText(record)
    }

    /// An unconfirmed delivery outranks a refinement fallback: the badge must
    /// not claim 已送达 when the paste receipt was never verified.
    package static func status(
        for record: VoiceInputHistoryRecord
    ) -> HistoryRecordStatus {
        switch record.outcome {
        case .delivered:
            if let code = record.deliveryDiagnosticCode, !code.isEmpty {
                return .deliveryUnconfirmed
            }
            if record.refinementStatus
                == DeepSeekRefinementStatus.fellBack.rawValue
            {
                return .refinementFellBack
            }
            return .delivered
        case .pendingCopy:
            return .pendingCopy
        case let .failed(_, failure):
            return .failed(failure)
        case .idle, .preparing, .recording, .processing, .cancelled:
            return .failed(.sessionInterrupted)
        }
    }

    package static func row(
        for record: VoiceInputHistoryRecord,
        calendar: Calendar = .current
    ) -> HistoryRecordRowPresentation {
        let retainedText = retainedText(for: record)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"

        return HistoryRecordRowPresentation(
            time: formatter.string(from: record.startedAt),
            text: retainedText ?? rowText(for: record),
            canCopy: retainedText != nil,
            status: status(for: record)
        )
    }

    private static func rowText(for record: VoiceInputHistoryRecord) -> String {
        retainedText(for: record) ?? "此会话未保留正文"
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

/// Interface labels for the retention picker; the policy's single home is
/// 设置-通用.
package extension HistoryRetentionPolicy {
    var displayName: String {
        switch self {
        case .disabled: "不保存"
        case .thirtyDays: "最近 30 天"
        case .ninetyDays: "最近 90 天"
        case .oneYear: "最近一年"
        case .forever: "不按日期清理"
        }
    }
}
