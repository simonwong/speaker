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
/// `isLoaded` is false only until the first snapshot of a launch arrives; the
/// charts play their entrance on that change and nowhere else.
package struct OverviewDashboardState: Equatable, Sendable {
    package let summary: VoiceInputUsageSummary
    package let referenceDate: Date
    package let isLoaded: Bool

    package init(
        summary: VoiceInputUsageSummary,
        referenceDate: Date,
        isLoaded: Bool = true
    ) {
        self.summary = summary
        self.referenceDate = referenceDate
        self.isLoaded = isLoaded
    }

    /// Whether the hero invites a first sentence. An empty summary before the
    /// first read is not a first use, and a setup banner already says what
    /// to do first.
    package func showsFirstUseHint(setupGap: VoiceInputSetupGap?) -> Bool {
        isLoaded && summary.totalSessionCount == 0 && setupGap == nil
    }
}

/// The complete overview presentation surface. App composition supplies one
/// usage snapshot; product copy, visual hierarchy, and motion policy stay here.
package struct OverviewDashboard: View {
    let state: OverviewDashboardState
    let setupGap: VoiceInputSetupGap?
    let openSetup: (VoiceInputSetupGap) -> Void
    let whatsNewVersion: String?
    let openWhatsNew: () -> Void
    let dismissWhatsNew: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(
        state: OverviewDashboardState,
        setupGap: VoiceInputSetupGap? = nil,
        openSetup: @escaping (VoiceInputSetupGap) -> Void = { _ in },
        whatsNewVersion: String? = nil,
        openWhatsNew: @escaping () -> Void = {},
        dismissWhatsNew: @escaping () -> Void = {}
    ) {
        self.state = state
        self.setupGap = setupGap
        self.openSetup = openSetup
        self.whatsNewVersion = whatsNewVersion
        self.openWhatsNew = openWhatsNew
        self.dismissWhatsNew = dismissWhatsNew
    }

    package var body: some View {
        let summary = state.summary
        let now = state.referenceDate

        SpeakerPage {
            if let setupGap {
                VoiceInputSetupBanner(gap: setupGap) { openSetup(setupGap) }
                    .padding(.bottom, SpeakerSurfaceMetrics.sectionSpacing)
            }
            if let whatsNewVersion {
                WhatsNewBanner(
                    version: whatsNewVersion,
                    open: openWhatsNew,
                    dismiss: dismissWhatsNew
                )
                .padding(.bottom, SpeakerSurfaceMetrics.sectionSpacing)
            }
            OverviewHero(
                summary: summary,
                now: now,
                isLoaded: state.isLoaded,
                showsFirstUseHint: state.showsFirstUseHint(setupGap: setupGap),
                reduceMotion: reduceMotion
            )
            OverviewMetrics(summary: summary, now: now)
                .padding(.top, SpeakerSurfaceMetrics.sectionSpacing)
            OverviewHeatmapCard(
                summary: summary,
                now: now,
                isLoaded: state.isLoaded,
                reduceMotion: reduceMotion
            )
            .padding(.top, SpeakerSurfaceMetrics.sectionSpacing)
            OverviewCostCard(
                estimate: OverviewServicePresentation.costEstimate(summary.services)
            )
            .padding(.top, SpeakerSurfaceMetrics.sectionSpacing)
            OverviewLatencyCard(
                lines: OverviewServicePresentation.latencyLines(summary.services),
                reduceMotion: reduceMotion
            )
            .padding(.top, SpeakerSurfaceMetrics.cardSpacing)
        }
    }
}

/// A card title on the left and its qualifier on the right, the qualifier
/// wrapping under the title when the window is narrow.
private struct OverviewCardHeader: View {
    let title: String
    let detail: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleText
                Spacer(minLength: 0)
                detailText
            }
            VStack(alignment: .leading, spacing: 4) {
                titleText
                detailText
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(SpeakerTypography.sectionHeader)
            .tracking(1)
            .foregroundStyle(.secondary)
    }

    private var detailText: some View {
        Text(detail)
            .font(SpeakerTypography.footnote)
            .foregroundStyle(.tertiary)
    }
}

/// Estimated cost per currency, then per service. Each currency is totalled
/// on its own; nothing is converted.
private struct OverviewCostCard: View {
    let estimate: ServiceCostEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.cardHeaderSpacing) {
            OverviewCardHeader(
                title: OverviewServicePresentation.costTitle,
                detail: OverviewServicePresentation.costDisclaimer
            )
            if estimate.lines.isEmpty {
                Text(OverviewServicePresentation.noUsageText)
                    .font(SpeakerTypography.caption)
                    .foregroundStyle(.secondary)
            } else {
                if !estimate.totalTexts.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        ForEach(estimate.totalTexts, id: \.self) { total in
                            Text(total)
                                .font(SpeakerTypography.metricNumber)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(OverviewServicePresentation.costTitle)
                }
                VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.rowSpacing) {
                    ForEach(Array(estimate.lines.enumerated()), id: \.offset) { _, line in
                        OverviewCostRow(line: line)
                    }
                }
            }
            Text(OverviewServicePresentation.priceDateText)
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .speakerCard()
    }
}

private struct OverviewCostRow: View {
    let line: ServiceCostLine

    private var markerColor: Color {
        switch line.amount {
        case .free: SpeakerVisualIdentity.settledGreen
        case .unknown: Color.primary.opacity(0.18)
        case .estimate: SpeakerVisualIdentity.warmGoldDeep
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(markerColor)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.service)
                    .font(SpeakerTypography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(line.usage)
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(line.amountText)
                .font(SpeakerTypography.bodyEmphasis.monospacedDigit())
                .foregroundStyle(line.amount == .unknown ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Release-to-delivery time per Speech Recognition Provider. The coral bar
/// reaches the median and the gold bar behind it the 90th percentile, both
/// on one scale shared by every provider.
private struct OverviewLatencyCard: View {
    let lines: [ServiceLatencyLine]
    let reduceMotion: Bool

    private var scaleMilliseconds: Int {
        max(
            1,
            lines.compactMap { $0.ninetiethPercentileMilliseconds ?? $0.medianMilliseconds }
                .max() ?? 1
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.cardHeaderSpacing) {
            OverviewCardHeader(
                title: OverviewServicePresentation.latencyTitle,
                detail: OverviewServicePresentation.latencyDefinition
            )
            if lines.isEmpty {
                Text(OverviewServicePresentation.noLatencyText)
                    .font(SpeakerTypography.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.rowSpacing) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        OverviewLatencyRow(
                            line: line,
                            scaleMilliseconds: scaleMilliseconds,
                            reduceMotion: reduceMotion
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .speakerCard()
    }
}

private struct OverviewLatencyRow: View {
    let line: ServiceLatencyLine
    let scaleMilliseconds: Int
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(line.service)
                    .font(SpeakerTypography.body)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(line.summary)
                    .font(SpeakerTypography.footnote.monospacedDigit())
                    .foregroundStyle(line.medianMilliseconds == nil ? .tertiary : .secondary)
                    .multilineTextAlignment(.trailing)
            }
            if let median = line.medianMilliseconds {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        if let tail = line.ninetiethPercentileMilliseconds {
                            Capsule()
                                .fill(SpeakerVisualIdentity.warmGold)
                                .frame(width: barWidth(tail, in: width))
                        }
                        Capsule()
                            .fill(SpeakerVisualIdentity.warmCoral(for: colorScheme))
                            .frame(width: barWidth(median, in: width))
                    }
                    .animation(reduceMotion ? nil : SpeakerMotion.change, value: median)
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func barWidth(_ milliseconds: Int, in width: CGFloat) -> CGFloat {
        max(6, width * CGFloat(milliseconds) / CGFloat(scaleMilliseconds))
    }
}

private struct OverviewHero: View {
    let summary: VoiceInputUsageSummary
    let now: Date
    let isLoaded: Bool
    let showsFirstUseHint: Bool
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
                    isLoaded: isLoaded,
                    reduceMotion: reduceMotion
                )
                Text("近 \(OverviewConstants.voiceprintDays) 天")
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.tertiary)
                    // The bars are hidden from VoiceOver; this line carries
                    // what they show.
                    .accessibilityLabel(
                        "近 \(OverviewConstants.voiceprintDays) 天说出 \(voiceprintCounts.reduce(0, +).formatted(.number.grouping(.automatic))) 字"
                    )
            }
            .padding(.top, 14)

            if showsFirstUseHint {
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

/// The last 18 days as bars. They rise once, when the first snapshot of a
/// launch arrives; later visits and new sessions only retarget bar heights.
private struct OverviewVoiceprint: View {
    let counts: [Int]
    let isLoaded: Bool
    let reduceMotion: Bool
    @State private var isPresented: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(counts: [Int], isLoaded: Bool, reduceMotion: Bool) {
        self.counts = counts
        self.isLoaded = isLoaded
        self.reduceMotion = reduceMotion
        _isPresented = State(initialValue: isLoaded)
    }

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
                            : SpeakerVisualIdentity.usageTrace(
                                ratio,
                                colorScheme: colorScheme
                            )
                    )
                    .frame(
                        width: 5,
                        height: 6 + 18 * pow(ratio, 0.7)
                    )
                    .scaleEffect(
                        x: 1,
                        y: reduceMotion || isPresented ? 1 : 0.1
                    )
                    .animation(
                        reduceMotion ? nil : SpeakerMotion.change,
                        value: ratio
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : SpeakerMotion.easeOut(duration: 0.25)
                                .delay(Double(index) * 0.03),
                        value: isPresented
                    )
            }
        }
        .frame(height: 26)
        .onChange(of: isLoaded) { _, loaded in
            if loaded, !isPresented { isPresented = true }
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
                .foregroundStyle(.tertiary)
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
    let isLoaded: Bool
    let reduceMotion: Bool

    private var heatmap: ContributionHeatmap {
        ContributionHeatmap.build(summary: summary, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let heatmap = heatmap

            ContributionHeatmapGrid(
                heatmap: heatmap,
                isLoaded: isLoaded,
                reduceMotion: reduceMotion
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("每日说出 · 近 \(ContributionHeatmap.defaultWeekCount) 周")
            .accessibilityValue(
                VoiceInputUsagePresentation.heatmapAccessibilitySummary(heatmap)
            )

            HStack {
                Spacer(minLength: 0)
                HeatmapLegend()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .speakerCard()
    }
}

private enum HeatmapMetrics {
    static let gap = ContributionHeatmapLayout.gap
    static let corner: CGFloat = 3
    static let monthAxisHeight: CGFloat = 12
    static let legendSwatch: CGFloat = 9
}

private struct ContributionHeatmapGrid: View {
    let heatmap: ContributionHeatmap
    let isLoaded: Bool
    let reduceMotion: Bool
    /// Like the voiceprint, the grid sweeps in once per launch, on the first
    /// snapshot, and is already in place on every later visit.
    @State private var isPresented: Bool

    init(heatmap: ContributionHeatmap, isLoaded: Bool, reduceMotion: Bool) {
        self.heatmap = heatmap
        self.isLoaded = isLoaded
        self.reduceMotion = reduceMotion
        _isPresented = State(initialValue: isLoaded)
    }

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
        .onChange(of: isLoaded) { _, loaded in
            if loaded, !isPresented { isPresented = true }
        }
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
        return (0..<rowCount).flatMap { row in
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
            .scaleEffect(reduceMotion || isPresented ? 1 : 0.94)
            .opacity(
                cell.isFuture
                    ? 0
                    : (reduceMotion || isPresented ? 1 : 0)
            )
            .animation(
                reduceMotion
                    ? nil
                    : SpeakerMotion.easeOut(duration: 0.25)
                        .delay(Double(column) * 0.005),
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

/// Reads the shades below the grid; the help on each cell gives the exact
/// count, and VoiceOver hears the summary instead.
private struct HeatmapLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            Text("少")
                .padding(.trailing, 2)
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(HeatmapPalette.color(forLevel: level, colorScheme: colorScheme))
                    .frame(
                        width: HeatmapMetrics.legendSwatch,
                        height: HeatmapMetrics.legendSwatch
                    )
            }
            Text("多")
                .padding(.leading, 2)
        }
        .font(SpeakerTypography.footnote)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
}

private enum HeatmapPalette {
    static func color(forLevel level: Int, colorScheme: ColorScheme) -> Color {
        switch level {
        case 1...4:
            SpeakerVisualIdentity.usageTrace(
                Double(level - 1) / 3,
                colorScheme: colorScheme
            )
        default: Color.primary.opacity(0.06)
        }
    }
}
