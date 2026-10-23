import SpeakerCore
import SwiftUI

struct DictionarySettingsPage: View {
    @ObservedObject var model: DictionarySettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tab already names the page, so the field, the capacity, and the
    /// Entries sit on the page ground the way History's search and records
    /// do, with no card of their own; an empty dictionary is just the field.
    var body: some View {
        VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.rowSpacing) {
            HStack(spacing: 8) {
                TextField(
                    "输入词条，回车添加",
                    text: $model.draftWord
                )
                .textFieldStyle(SpeakerTextFieldStyle())
                .onSubmit { Task { await model.add() } }

                Button("添加") {
                    Task { await model.add() }
                }
                .buttonStyle(SpeakerButtonStyle(prominent: true))
                .disabled(
                    model.draftWord
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }

            capacityRow

            if !model.entries.isEmpty {
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
                        .transition(chipTransition)
                    }
                }
            }

            if let deleted = model.recentlyDeleted {
                undoRow(for: deleted)
            }

            if let notice = model.notice {
                SpeakerNotice(text: notice)
            }
        }
        .animation(
            reduceMotion ? nil : SpeakerMotion.change,
            value: model.entries.map(\.id)
        )
    }

    /// Chips grow in from 90 %, never from nothing; Reduce Motion keeps only
    /// the fade.
    private var chipTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity)
    }

    private func undoRow(for entry: DictionaryEntry) -> some View {
        HStack(spacing: 10) {
            Text("已删除「\(entry.word)」")
                .font(SpeakerTypography.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button("撤销") {
                Task { await model.undoDelete() }
            }
            .buttonStyle(SpeakerButtonStyle())
            .accessibilityLabel("撤销删除 \(entry.word)")
            Button {
                model.dismissUndo()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭")
        }
        .transition(.opacity)
    }

    private var hasOmittedEntries: Bool {
        !model.omittedEntryIDs.isEmpty
    }

    private var capacityRow: some View {
        HStack(spacing: 10) {
            Text(model.sendingCountText)
                .font(SpeakerTypography.detail)
                .foregroundStyle(hasOmittedEntries ? SpeakerTone.warning.color : Color.secondary)

            Spacer(minLength: 12)

            DictionaryCapacityBar(
                filledRatio: capacityRatio,
                isAtCapacity: capacityRatio >= 1 && hasOmittedEntries
            )
        }
        .frame(height: 20)
        // Inset like a section header, so the count does not sit flush
        // against the field's curve above it.
        .padding(.horizontal, 4)
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
        if isAtCapacity { return SpeakerTone.warning.color }
        return colorScheme == .dark
            ? SpeakerVisualIdentity.warmGold
            : SpeakerVisualIdentity.warmGoldDeep
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
