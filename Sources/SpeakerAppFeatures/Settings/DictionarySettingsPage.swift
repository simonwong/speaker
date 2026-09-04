import SpeakerCore
import SwiftUI

struct DictionarySettingsPage: View {
    @ObservedObject var model: DictionarySettingsModel

    var body: some View {
        SettingsCard(
            "个人词库",
            subtitle: "人名、术语、产品名，让豆包更准确地认出它们",
            icon: "text.book.closed"
        ) {
            HStack(spacing: 8) {
                TextField(
                    "输入词条，回车添加",
                    text: $model.draftWord
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.add() } }

                Button("添加") {
                    Task { await model.add() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.draftWord
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }

            capacityRow

            if model.entries.isEmpty {
                SpeakerEmptyState(
                    title: "还没有词条",
                    description: "在上方输入一个词，回车即可添加。",
                    systemImage: "text.book.closed"
                )
            } else {
                let omittedEntryIDs = model.omittedEntryIDs
                DictionaryChipFlowLayout(spacing: 8) {
                    ForEach(model.entries) { entry in
                        DictionaryEntryChip(
                            word: entry.word,
                            isOmitted: omittedEntryIDs.contains(entry.id),
                            qualityHint: model.qualityHint(for: entry)
                        ) {
                            Task { await model.delete(entry.id) }
                        }
                    }
                }
            }

            Text("只有词条文本会随识别请求发送给豆包；启用需要 DeepSeek 的整理模式时，词条文本也会一并发送给 DeepSeek。")
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.tertiary)

            if let notice = model.notice {
                SettingsNotice(text: notice)
            }
        }
    }

    private var hasOmittedEntries: Bool {
        !model.omittedEntryIDs.isEmpty
    }

    private var capacityRow: some View {
        HStack(spacing: 10) {
            Label {
                Text(model.sendingCountText)
            } icon: {
                Image(systemName: "paperplane.fill")
            }
            .font(SpeakerTypography.footnote.weight(.medium))
            .foregroundStyle(hasOmittedEntries ? Color.orange : Color.secondary)

            Spacer(minLength: 12)

            DictionaryCapacityBar(
                filledRatio: capacityRatio,
                isAtCapacity: capacityRatio >= 1 && hasOmittedEntries
            )
        }
        .frame(height: 20)
    }

    private var capacityRatio: Double {
        let maximum = DictionaryProviderCapacity.doubao.maximumHotwordCount
        guard maximum > 0 else { return 0 }
        return min(1, Double(model.sentEntryCount) / Double(maximum))
    }
}

/// A silent companion to `sendingCountText`; the numbers stay in that text.
private struct DictionaryCapacityBar: View {
    let filledRatio: Double
    let isAtCapacity: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color {
        if isAtCapacity { return .orange }
        return colorScheme == .dark
            ? SpeakerVisualIdentity.warmAccent
            : SpeakerVisualIdentity.warmAccentDeep
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(fillColor)
                    .frame(
                        width: geometry.size.width
                            * max(0, min(1, filledRatio))
                    )
            }
        }
        .frame(width: 120, height: 4)
        .accessibilityHidden(true)
    }
}

private struct DictionaryChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > availableWidth {
                totalHeight += rowHeight + spacing
                contentWidth = max(contentWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
        }

        contentWidth = max(contentWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(
            width: proposal.width ?? contentWidth,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX,
                point.x + size.width > bounds.maxX
            {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: point,
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

package struct DictionaryTabView: View {
    @ObservedObject var model: DictionarySettingsModel

    package init(model: DictionarySettingsModel) {
        self.model = model
    }

    package var body: some View {
        SpeakerPage {
            DictionarySettingsPage(model: model)
        }
    }
}
