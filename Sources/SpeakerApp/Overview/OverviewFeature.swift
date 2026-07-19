import Combine
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

@MainActor
final class OverviewModel: ObservableObject {
    @Published private(set) var summary: VoiceInputUsageSummary = .empty

    private let store: any LocalSessionHistoryStoring

    init(store: any LocalSessionHistoryStoring) {
        self.store = store
    }

    func refresh() async {
        summary = await store.usageStatistics()
    }
}

struct OverviewView: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader("累计")
                cards

                SectionHeader("过去半年 · 每日识别字数")
                OverviewHeatmapCard(summary: model.summary)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: .speakerHistoryDidChange)
        ) { _ in
            Task { await model.refresh() }
        }
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 12) {
            OverviewStatCard(label: "说话时长") {
                speakingValue
            }
            OverviewStatCard(label: "识别字数") {
                charactersValue
            }
            OverviewStatCard(label: "少敲的键盘") {
                keyboardSavedValue
            }
        }
    }

    private var speakingValue: Text {
        let duration = VoiceInputUsagePresentation.speakingDuration(
            milliseconds: model.summary.totalSpeakingMilliseconds
        )
        return number(duration.hours) + unit("时")
            + number(duration.minutes) + unit("分")
            + number(duration.seconds) + unit("秒")
    }

    private var charactersValue: Text {
        let formatted = model.summary.totalRecognizedCharacterCount
            .formatted(.number.grouping(.automatic))
        return Text(formatted).font(Self.valueFont) + unit("字")
    }

    private var keyboardSavedValue: Text {
        let hours = VoiceInputUsagePresentation.keyboardSavedHours(
            recognizedCharacterCount: model.summary.totalRecognizedCharacterCount
        )
        let formatted = String(format: "%.1f", hours)
        return unit("约 ") + Text(formatted).font(Self.valueFont) + unit(" 小时")
    }

    private static let valueFont = Font.system(
        size: 25,
        weight: .bold,
        design: .rounded
    ).monospacedDigit()

    private func number(_ value: Int) -> Text {
        Text("\(value)").font(Self.valueFont)
    }

    private func unit(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct OverviewStatCard: View {
    let label: String
    let value: Text
    @Environment(\.colorSchemeContrast) private var contrast

    init(label: String, @ViewBuilder value: () -> Text) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            value
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    Color.primary.opacity(contrast == .increased ? 0.32 : 0.07),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewHeatmapCard: View {
    let summary: VoiceInputUsageSummary
    @Environment(\.colorSchemeContrast) private var contrast

    private var heatmap: ContributionHeatmap {
        ContributionHeatmap.build(summary: summary, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let heatmap = heatmap
            if heatmap.hasData {
                ContributionHeatmapGrid(heatmap: heatmap)
                HeatmapLegend()
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    Color.primary.opacity(contrast == .increased ? 0.32 : 0.07),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.3x3")
                .font(.title2)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("还没有语音输入记录")
                    .font(.subheadline.weight(.medium))
                Text("完成第一次语音输入后，这里会按天显示识别字数的活跃度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}

private enum HeatmapMetrics {
    static let cell: CGFloat = 13
    static let gap: CGFloat = 3
    static let corner: CGFloat = 3
    static let columnStride = cell + gap
}

private struct ContributionHeatmapGrid: View {
    let heatmap: ContributionHeatmap

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            monthAxis
            HStack(alignment: .top, spacing: HeatmapMetrics.gap) {
                ForEach(Array(heatmap.columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: HeatmapMetrics.gap) {
                        ForEach(Array(column.enumerated()), id: \.offset) { _, cell in
                            HeatmapCellView(cell: cell)
                        }
                    }
                }
            }
        }
    }

    private var monthAxis: some View {
        let labels = Dictionary(
            heatmap.monthLabels.map { ($0.column, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )
        return HStack(spacing: HeatmapMetrics.gap) {
            ForEach(Array(heatmap.columns.indices), id: \.self) { column in
                Text(labels[column] ?? " ")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: HeatmapMetrics.cell, alignment: .leading)
            }
        }
    }
}

private struct HeatmapCellView: View {
    let cell: ContributionHeatmap.Cell

    var body: some View {
        RoundedRectangle(cornerRadius: HeatmapMetrics.corner, style: .continuous)
            .fill(HeatmapPalette.color(forLevel: cell.level))
            .frame(width: HeatmapMetrics.cell, height: HeatmapMetrics.cell)
            .opacity(cell.isFuture ? 0 : 1)
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
                RoundedRectangle(cornerRadius: HeatmapMetrics.corner, style: .continuous)
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
        case 1: Color.accentColor.opacity(0.28)
        case 2: Color.accentColor.opacity(0.5)
        case 3: Color.accentColor.opacity(0.72)
        case 4: Color.accentColor
        default: Color.primary.opacity(0.06)
        }
    }
}
