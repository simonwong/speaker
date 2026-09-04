import AppKit
import Foundation
import SpeakerCore
import SwiftUI

private enum OverviewConstants {
    /// The voiceprint row and its trailing note always describe the same span.
    static let voiceprintDays = 18
}

/// One overview snapshot: the usage totals and the moment they describe. The
/// reference date travels with the state so week, voiceprint, and heatmap
/// windows stay pinned instead of reading the wall clock while rendering.
package struct OverviewDashboardState: Equatable, Sendable {
    package let summary: VoiceInputUsageSummary
    package let referenceDate: Date

    package init(summary: VoiceInputUsageSummary, referenceDate: Date) {
        self.summary = summary
        self.referenceDate = referenceDate
    }
}

/// The complete overview presentation surface. App composition supplies one
/// usage snapshot; product copy, visual hierarchy, and motion policy stay here.
package struct OverviewDashboard: View {
    let state: OverviewDashboardState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(state: OverviewDashboardState) {
        self.state = state
    }

    package var body: some View {
        let summary = state.summary
        let now = state.referenceDate

        SpeakerPage {
            OverviewHero(
                summary: summary,
                now: now,
                reduceMotion: reduceMotion
            )
            OverviewMetrics(summary: summary, now: now)
                .padding(.top, 28)
            OverviewHeatmapCard(
                summary: summary,
                now: now,
                reduceMotion: reduceMotion
            )
            .padding(.top, 32)
        }
    }
}

private struct OverviewHero: View {
    let summary: VoiceInputUsageSummary
    let now: Date
    let reduceMotion: Bool
    @ScaledMetric(relativeTo: .largeTitle)
    private var heroNumberSize = SpeakerTypography.heroNumberBaseSize

    private var characterCount: Int {
        max(0, summary.totalRecognizedCharacterCount)
    }

    private var voiceprintCounts: [Int] {
        VoiceInputUsagePresentation.recentRecognizedCharacterCounts(
            summary: summary,
            now: now,
            days: OverviewConstants.voiceprintDays
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("累计说出")
                .font(SpeakerTypography.sectionHeader)
                .tracking(1)
                .foregroundStyle(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(characterCount.formatted(.number.grouping(.automatic)))
                    .font(SpeakerTypography.heroNumber(size: heroNumberSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .contentTransition(.numericText())

                Text("字")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.7),
                value: characterCount
            )

            HStack(alignment: .center, spacing: 10) {
                OverviewVoiceprint(
                    counts: voiceprintCounts,
                    reduceMotion: reduceMotion
                )
                Text("近 \(OverviewConstants.voiceprintDays) 天")
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 14)

            if summary.totalSessionCount == 0 {
                Text("按住快捷键，说出第一句话。")
                    .font(SpeakerTypography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewVoiceprint: View {
    let counts: [Int]
    let reduceMotion: Bool
    @State private var isPresented = false

    private var peak: Double {
        Double(max(1, counts.max() ?? 0))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(counts.enumerated()), id: \.offset) { index, count in
                let ratio = Double(max(0, count)) / peak
                Capsule()
                    .fill(
                        count == 0
                            ? Color.primary.opacity(0.07)
                            : SpeakerVisualIdentity.warmAccent
                    )
                    .frame(
                        width: 5,
                        height: 6 + 18 * pow(ratio, 0.7)
                    )
                    .scaleEffect(
                        x: 1,
                        y: reduceMotion || isPresented ? 1 : 0.1
                    )
                    .opacity(count == 0 ? 1 : 0.55 + 0.45 * ratio)
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.45, dampingFraction: 0.74)
                                .delay(0.2 + Double(index) * 0.028),
                        value: isPresented
                    )
            }
        }
        .frame(height: 26)
        .task(id: counts) {
            if reduceMotion {
                isPresented = true
                return
            }
            isPresented = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            isPresented = true
        }
        .accessibilityHidden(true)
    }
}

private struct OverviewMetrics: View {
    let summary: VoiceInputUsageSummary
    let now: Date
    @Environment(\.mainWindowLayout) private var mainWindowLayout

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            OverviewMetric(label: "累计说话", value: speakingValue)
            MetricDivider(
                horizontalPadding: mainWindowLayout.overviewMetricDividerPadding
            )
            OverviewMetric(label: "省下的打字", value: keyboardSavedValue)
            MetricDivider(
                horizontalPadding: mainWindowLayout.overviewMetricDividerPadding
            )
            OverviewMetric(label: "本周说出", value: weeklyValue)
        }
    }

    private var speakingValue: Text {
        let duration = VoiceInputUsagePresentation.speakingDuration(
            milliseconds: summary.totalSpeakingMilliseconds
        )
        if duration.hours > 0 {
            return number(duration.hours) + unit("时")
                + number(duration.minutes) + unit("分")
        }
        return number(duration.minutes) + unit("分")
    }

    private var keyboardSavedValue: Text {
        let hours = VoiceInputUsagePresentation.keyboardSavedHours(
            recognizedCharacterCount: summary.totalRecognizedCharacterCount
        )
        let formatted = String(format: "%.1f", hours)
        return unit("约 ")
            + Text(formatted).font(SpeakerTypography.metricNumber)
            + unit("小时")
    }

    private var weeklyValue: Text {
        let count = VoiceInputUsagePresentation.recognizedCharacterCountThisWeek(
            summary: summary,
            now: now
        )
        let formatted = count.formatted(.number.grouping(.automatic))
        return Text(count > 0 ? "+\(formatted)" : formatted)
            .font(SpeakerTypography.metricNumber) + unit("字")
    }

    private func number(_ value: Int) -> Text {
        Text("\(value)").font(SpeakerTypography.metricNumber)
    }

    private func unit(_ text: String) -> Text {
        Text(text)
            .font(SpeakerTypography.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct OverviewMetric: View {
    let label: String
    let value: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            value
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(SpeakerTypography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MetricDivider: View {
    let horizontalPadding: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5, height: 32)
            .padding(.horizontal, horizontalPadding)
            .accessibilityHidden(true)
    }
}

private struct OverviewHeatmapCard: View {
    let summary: VoiceInputUsageSummary
    let now: Date
    let reduceMotion: Bool

    private var heatmap: ContributionHeatmap {
        ContributionHeatmap.build(summary: summary, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let heatmap = heatmap

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("每日说出 · 近 \(ContributionHeatmap.defaultWeekCount) 周")
                    .font(SpeakerTypography.sectionHeader)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HeatmapLegend()
            }

            ContributionHeatmapGrid(
                heatmap: heatmap,
                reduceMotion: reduceMotion
            )
            .id(heatmap.hasData)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .speakerCard()
    }
}

private enum HeatmapMetrics {
    static let gap = ContributionHeatmapLayout.gap
    static let corner: CGFloat = 3
    static let monthAxisHeight: CGFloat = 12
    static let legendSwatch: CGFloat = 10
}

private struct ContributionHeatmapGrid: View {
    let heatmap: ContributionHeatmap
    let reduceMotion: Bool
    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            monthAxis
            LazyVGrid(
                columns: gridColumns,
                alignment: .leading,
                spacing: HeatmapMetrics.gap
            ) {
                ForEach(Array(rowMajorCells.enumerated()), id: \.offset) { index, cell in
                    HeatmapCellView(
                        cell: cell,
                        column: index % max(1, heatmap.columns.count),
                        isPresented: isPresented,
                        reduceMotion: reduceMotion
                    )
                }
            }
        }
        .onAppear { isPresented = true }
    }

    private var monthAxis: some View {
        GeometryReader { geometry in
            let layout = ContributionHeatmapLayout(
                availableWidth: geometry.size.width,
                columnCount: heatmap.columns.count
            )
            ZStack(alignment: .topLeading) {
                ForEach(heatmap.monthLabels, id: \.column) { label in
                    Text(label.text)
                        .font(SpeakerTypography.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: layout.leadingOffset(forColumn: label.column))
                }
            }
        }
        .frame(height: HeatmapMetrics.monthAxisHeight)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(minimum: 0),
                spacing: HeatmapMetrics.gap
            ),
            count: heatmap.columns.count
        )
    }

    private var rowMajorCells: [ContributionHeatmap.Cell] {
        guard let rowCount = heatmap.columns.first?.count else { return [] }
        return (0 ..< rowCount).flatMap { row in
            heatmap.columns.map { $0[row] }
        }
    }
}

private struct HeatmapCellView: View {
    let cell: ContributionHeatmap.Cell
    let column: Int
    let isPresented: Bool
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: HeatmapMetrics.corner, style: .continuous)
            .fill(
                HeatmapPalette.color(
                    forLevel: cell.level,
                    colorScheme: colorScheme
                )
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(reduceMotion || isPresented ? 1 : 0.55)
            .opacity(
                cell.isFuture
                    ? 0
                    : (reduceMotion || isPresented ? 1 : 0)
            )
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: 0.24)
                        .delay(0.3 + Double(column) * 0.007),
                value: isPresented
            )
            .help(
                cell.isFuture
                    ? ""
                    : VoiceInputUsagePresentation.heatmapCellDescription(
                        date: cell.date,
                        recognizedCharacterCount: cell.recognizedCharacterCount
                    )
            )
    }
}

private struct HeatmapLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Text("少")
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.secondary)
            ForEach(0 ... 4, id: \.self) { level in
                RoundedRectangle(
                    cornerRadius: HeatmapMetrics.corner,
                    style: .continuous
                )
                .fill(
                    HeatmapPalette.color(
                        forLevel: level,
                        colorScheme: colorScheme
                    )
                )
                .frame(
                    width: HeatmapMetrics.legendSwatch,
                    height: HeatmapMetrics.legendSwatch
                )
            }
            Text("多")
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

private enum HeatmapPalette {
    static func color(forLevel level: Int, colorScheme: ColorScheme) -> Color {
        switch level {
        case 1: SpeakerVisualIdentity.warmAccent.opacity(0.28)
        case 2: SpeakerVisualIdentity.warmAccent.opacity(0.5)
        case 3: SpeakerVisualIdentity.warmAccent.opacity(0.74)
        case 4:
            colorScheme == .dark
                ? SpeakerVisualIdentity.warmAccent
                : SpeakerVisualIdentity.warmAccentDeep
        default: Color.primary.opacity(0.06)
        }
    }
}
