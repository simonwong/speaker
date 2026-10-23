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
            HStack(spacing: SpeakerSpacing.s) {
                TextField("添加词条", text: $model.draftWord)
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
                DictionaryChipFlowLayout(spacing: SpeakerSpacing.s) {
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
                undoNotice(for: deleted)
            }

            if let notice = model.notice {
                SpeakerNotice(tone: noticeTone(for: notice), text: notice)
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

    private func undoNotice(for entry: DictionaryEntry) -> some View {
        SpeakerNotice(
            text: "已删除「\(entry.word)」",
            action: .init("撤销", hint: "撤销删除 \(entry.word)") {
                Task { await model.undoDelete() }
            },
            onDismiss: .init(label: "关闭") { model.dismissUndo() }
        )
        .transition(.opacity)
    }

    /// A recovered dictionary still works, so its notice is a warning; every
    /// other dictionary notice reports a load or save that failed.
    private func noticeTone(for notice: String) -> SpeakerTone {
        if let recovery = model.recovery,
            notice == DictionarySettingsModel.recoveryNotice(for: recovery)
        {
            return .warning
        }
        return .error
    }

    private var hasOmittedEntries: Bool {
        !model.omittedEntryIDs.isEmpty
    }

    /// The count and its bar read as one measurement, inset to line up with
    /// the field's text above.
    private var capacityRow: some View {
        HStack(spacing: SpeakerSpacing.s) {
            Text(model.sendingCountText)
                .font(SpeakerTypography.detail.monospacedDigit())
                .foregroundStyle(hasOmittedEntries ? SpeakerTone.warning.color : Color.secondary)

            DictionaryCapacityBar(filledRatio: capacityRatio)
        }
        .padding(.horizontal, SpeakerSpacing.m)
    }

    private var capacityRatio: Double {
        let maximum = DictionaryProviderCapacity.doubao.maximumHotwordCount
        guard maximum > 0 else { return 0 }
        return min(1, Double(model.sentEntryCount) / Double(maximum))
    }
}

/// A silent companion to `sendingCountText`; the numbers stay in that text.
/// Gold while there is room, orange once the provider's capacity is full.
private struct DictionaryCapacityBar: View {
    let filledRatio: Double
    @Environment(\.colorScheme) private var colorScheme

    private static let width: CGFloat = 120
    private static let height: CGFloat = 4

    private var fillColor: Color {
        if filledRatio >= 1 { return SpeakerTone.warning.color }
        return colorScheme == .dark
            ? SpeakerVisualIdentity.warmGold
            : SpeakerVisualIdentity.warmGoldDeep
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(SpeakerFill.control)
            Capsule()
                .fill(fillColor)
                .frame(width: Self.width * max(0, min(1, filledRatio)))
        }
        .frame(width: Self.width, height: Self.height)
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
