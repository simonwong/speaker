import CoreGraphics
import Foundation
import SpeakerCore

/// Presentation policy for the overview dashboard: how usage totals read as
/// numbers and how a day's recognized characters map onto heatmap shades. Kept
/// out of `SpeakerCore` because these are display heuristics, not domain facts.
public enum VoiceInputUsagePresentation {
    /// Assumed typing rate used to turn recognized characters into the keyboard
    /// time a Voice Input Session saved: ~240 characters per minute.
    public static let charactersTypedPerHour = 14_400

    public struct SpeakingDuration: Equatable, Sendable {
        public let hours: Int
        public let minutes: Int
        public let seconds: Int

        public init(hours: Int, minutes: Int, seconds: Int) {
            self.hours = hours
            self.minutes = minutes
            self.seconds = seconds
        }
    }

    public static func speakingDuration(milliseconds: Int) -> SpeakingDuration {
        let totalSeconds = max(0, milliseconds) / 1_000
        return SpeakingDuration(
            hours: totalSeconds / 3_600,
            minutes: (totalSeconds % 3_600) / 60,
            seconds: totalSeconds % 60
        )
    }

    /// Estimated hours of typing avoided for a recognized character count.
    public static func keyboardSavedHours(recognizedCharacterCount: Int) -> Double {
        guard recognizedCharacterCount > 0 else { return 0 }
        return Double(recognizedCharacterCount) / Double(charactersTypedPerHour)
    }

    /// GitHub-style shade level 0…4 for a day's recognized character count.
    public static func heatmapLevel(recognizedCharacterCount: Int) -> Int {
        switch recognizedCharacterCount {
        case ..<1: 0
        case ..<400: 1
        case ..<900: 2
        case ..<1_500: 3
        default: 4
        }
    }

    /// Hover text for a heatmap cell, e.g. `7月19日 · 1,204 字`.
    public static func heatmapCellDescription(
        date: Date,
        recognizedCharacterCount: Int,
        calendar: Calendar = .current
    ) -> String {
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let count = recognizedCharacterCount.formatted(.number.grouping(.automatic))
        return "\(month)月\(day)日 · \(count) 字"
    }
}

/// A GitHub-style contribution heatmap: the last `weeks` calendar weeks laid out
/// column-per-week (Monday…Sunday down each column) with today in the final
/// column. Deterministic given a `now` and `calendar`, so it can be unit-tested.
public struct ContributionHeatmap: Equatable, Sendable {
    public static let defaultWeekCount = 52

    public struct Cell: Equatable, Sendable {
        public let date: Date
        public let recognizedCharacterCount: Int
        public let level: Int
        public let isFuture: Bool

        public init(
            date: Date,
            recognizedCharacterCount: Int,
            level: Int,
            isFuture: Bool
        ) {
            self.date = date
            self.recognizedCharacterCount = recognizedCharacterCount
            self.level = level
            self.isFuture = isFuture
        }
    }

    public struct MonthLabel: Equatable, Sendable {
        public let column: Int
        public let text: String

        public init(column: Int, text: String) {
            self.column = column
            self.text = text
        }
    }

    /// `columns[week][weekday]`, where weekday 0 = Monday … 6 = Sunday.
    public let columns: [[Cell]]
    public let monthLabels: [MonthLabel]
    public let hasData: Bool

    public init(columns: [[Cell]], monthLabels: [MonthLabel], hasData: Bool) {
        self.columns = columns
        self.monthLabels = monthLabels
        self.hasData = hasData
    }

    public static func build(
        summary: VoiceInputUsageSummary,
        now: Date,
        calendar: Calendar = .current,
        weeks: Int = defaultWeekCount
    ) -> ContributionHeatmap {
        let today = calendar.startOfDay(for: now)
        // weekday: 1 = Sunday … 7 = Saturday. Shift so Monday is the first row.
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        guard weeks > 0,
              let currentMonday = calendar.date(
                  byAdding: .day,
                  value: -daysSinceMonday,
                  to: today
              ),
              let startMonday = calendar.date(
                  byAdding: .day,
                  value: -7 * (weeks - 1),
                  to: currentMonday
              )
        else {
            return ContributionHeatmap(columns: [], monthLabels: [], hasData: false)
        }

        var counts: [Date: Int] = [:]
        for day in summary.daily {
            counts[calendar.startOfDay(for: day.day)] = day.recognizedCharacterCount
        }

        var columns: [[Cell]] = []
        columns.reserveCapacity(weeks)
        var monthLabels: [MonthLabel] = []
        var lastObservedMonth = -1
        var lastLabelColumn: Int?

        for week in 0 ..< weeks {
            var column: [Cell] = []
            column.reserveCapacity(7)
            for weekdayIndex in 0 ..< 7 {
                let offset = week * 7 + weekdayIndex
                let date = calendar.date(
                    byAdding: .day,
                    value: offset,
                    to: startMonday
                ) ?? startMonday
                let isFuture = date > today
                let count = isFuture ? 0 : (counts[date] ?? 0)
                column.append(Cell(
                    date: date,
                    recognizedCharacterCount: count,
                    level: isFuture
                        ? 0
                        : VoiceInputUsagePresentation.heatmapLevel(
                            recognizedCharacterCount: count
                        ),
                    isFuture: isFuture
                ))
            }
            if let monday = column.first {
                let month = calendar.component(.month, from: monday.date)
                if month != lastObservedMonth {
                    lastObservedMonth = month
                    if lastLabelColumn.map({ week - $0 >= 4 }) ?? true {
                        monthLabels.append(MonthLabel(column: week, text: "\(month)月"))
                        lastLabelColumn = week
                    }
                }
            }
            columns.append(column)
        }

        return ContributionHeatmap(
            columns: columns,
            monthLabels: monthLabels,
            hasData: summary.totalSessionCount > 0
        )
    }
}

package struct ContributionHeatmapLayout: Equatable, Sendable {
    package static let gap: CGFloat = 3

    package let availableWidth: CGFloat
    package let columnCount: Int
    package let cellLength: CGFloat

    package init(availableWidth: CGFloat, columnCount: Int) {
        self.availableWidth = max(0, availableWidth)
        self.columnCount = max(0, columnCount)

        guard columnCount > 0 else {
            cellLength = 0
            return
        }

        let totalGap = CGFloat(columnCount - 1) * Self.gap
        cellLength = max(0, self.availableWidth - totalGap) / CGFloat(columnCount)
    }

    package var gridWidth: CGFloat {
        guard columnCount > 0 else { return 0 }
        return CGFloat(columnCount) * cellLength
            + CGFloat(columnCount - 1) * Self.gap
    }

    package func leadingOffset(forColumn column: Int) -> CGFloat {
        CGFloat(column) * (cellLength + Self.gap)
    }
}
