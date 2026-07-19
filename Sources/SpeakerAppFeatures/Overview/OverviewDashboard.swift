import AppKit
import Foundation
import SpeakerCore
import SwiftUI

/// The complete overview presentation surface. App composition supplies one
/// usage snapshot; product copy, visual hierarchy, and motion policy stay here.
package struct OverviewDashboard: View {
    let summary: VoiceInputUsageSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(summary: VoiceInputUsageSummary) {
        self.summary = summary
    }

    package var body: some View {
        GeometryReader { geometry in
            let horizontalPadding = min(
                60,
                max(30, geometry.size.width * 0.06)
            )
            let now = Date()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    OverviewHero(
                        summary: summary,
                        now: now,
                        reduceMotion: reduceMotion
                    )
                    OverviewMetrics(summary: summary, now: now)
                        .padding(.top, 38)
                    Spacer(minLength: 36)
                    OverviewHeatmap(
                        summary: summary,
                        now: now,
                        reduceMotion: reduceMotion
                    )
                }
                .frame(
                    minHeight: max(0, geometry.size.height - 56),
                    alignment: .top
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 28)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct OverviewHero: View {
    let summary: VoiceInputUsageSummary
    let now: Date
    let reduceMotion: Bool

    private var characterCount: Int {
        max(0, summary.totalRecognizedCharacterCount)
    }

    private var voiceprintCounts: [Int] {
        VoiceInputUsagePresentation.recentRecognizedCharacterCounts(
            summary: summary,
            now: now,
            days: 18
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("说出的文字 · 累计")
                .font(.system(size: 12, weight: .medium))
                .tracking(3)
                .foregroundStyle(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(characterCount.formatted(.number.grouping(.automatic)))
                    .font(.system(size: 76, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .contentTransition(.numericText())

                Text("字")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.7),
                value: characterCount
            )

            OverviewVoiceprint(
                counts: voiceprintCounts,
                reduceMotion: reduceMotion
            )
            .padding(.top, 15)

            if summary.totalSessionCount == 0 {
                Text("按住 Fn，说出第一句话。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 11)
            }
        }
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
            OverviewMetric(label: "说话时长", value: speakingValue)
            MetricDivider(
                horizontalPadding: mainWindowLayout.overviewMetricDividerPadding
            )
            OverviewMetric(label: "少敲的键盘", value: keyboardSavedValue)
            MetricDivider(
                horizontalPadding: mainWindowLayout.overviewMetricDividerPadding
            )
            OverviewMetric(label: "本周", value: weeklyValue)
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
        return unit("约 ") + Text(formatted).font(Self.valueFont) + unit("小时")
    }

    private var weeklyValue: Text {
        let count = VoiceInputUsagePresentation.recognizedCharacterCountThisWeek(
            summary: summary,
            now: now
        )
        let formatted = count.formatted(.number.grouping(.automatic))
        return Text(count > 0 ? "+\(formatted)" : formatted)
            .font(Self.valueFont) + unit("字")
    }

    private static let valueFont = Font.system(
        size: 21,
        weight: .semibold,
        design: .serif
    ).monospacedDigit()

    private func number(_ value: Int) -> Text {
        Text("\(value)").font(Self.valueFont)
    }

    private func unit(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct OverviewMetric: View {
    let label: String
    let value: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            value
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 11.5))
                .tracking(0.5)
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
            .frame(width: 0.5, height: 43)
            .padding(.horizontal, horizontalPadding)
            .accessibilityHidden(true)
    }
}

private struct OverviewHeatmap: View {
    let summary: VoiceInputUsageSummary
    let now: Date
    let reduceMotion: Bool

    private var heatmap: ContributionHeatmap {
        ContributionHeatmap.build(summary: summary, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let heatmap = heatmap
            ContributionHeatmapGrid(
                heatmap: heatmap,
                reduceMotion: reduceMotion
            )
            .id(heatmap.hasData)
            HeatmapLegend()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum HeatmapMetrics {
    static let gap = ContributionHeatmapLayout.gap
    static let corner: CGFloat = 3
    static let monthAxisHeight: CGFloat = 12
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
                        .font(.system(size: 9.5))
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

    var body: some View {
        RoundedRectangle(cornerRadius: HeatmapMetrics.corner, style: .continuous)
            .fill(HeatmapPalette.color(forLevel: cell.level))
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
    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("少")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            ForEach(0 ... 4, id: \.self) { level in
                RoundedRectangle(
                    cornerRadius: HeatmapMetrics.corner,
                    style: .continuous
                )
                .fill(HeatmapPalette.color(forLevel: level))
                .frame(width: 11, height: 11)
            }
            Text("多")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}

private enum HeatmapPalette {
    static func color(forLevel level: Int) -> Color {
        switch level {
        case 1: SpeakerVisualIdentity.warmAccent.opacity(0.24)
        case 2: SpeakerVisualIdentity.warmAccent.opacity(0.44)
        case 3: SpeakerVisualIdentity.warmAccent.opacity(0.68)
        case 4: SpeakerVisualIdentity.warmAccent.opacity(0.95)
        default: Color.primary.opacity(0.06)
        }
    }
}
