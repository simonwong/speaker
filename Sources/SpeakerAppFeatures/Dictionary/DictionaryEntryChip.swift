import AppKit
import SpeakerCore
import SwiftUI

package struct DictionaryEntryChip: View {
    private let word: String
    private let isOmitted: Bool
    private let qualityHint: DictionaryEntryQualityHint
    private let onDelete: () -> Void
    @State private var isHovered = false

    package init(
        word: String,
        isOmitted: Bool = false,
        qualityHint: DictionaryEntryQualityHint = .none,
        onDelete: @escaping () -> Void
    ) {
        self.word = word
        self.isOmitted = isOmitted
        self.qualityHint = qualityHint
        self.onDelete = onDelete
    }

    private var showsStatusRow: Bool {
        isOmitted || qualityHint != .none
    }

    /// A plain Entry stays a pill; one carrying guidance squares off so the
    /// second line reads as part of the same chip.
    private var shape: AnyShape {
        showsStatusRow
            ? AnyShape(
                RoundedRectangle(
                    cornerRadius: SpeakerSurfaceMetrics.chipCornerRadius,
                    style: .continuous
                )
            )
            : AnyShape(Capsule())
    }

    private var fillColor: Color {
        isOmitted ? Color.orange.opacity(0.08) : Color.primary.opacity(0.05)
    }

    private var strokeColor: Color {
        isOmitted ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)
    }

    package var body: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 3) {
                Text(word)
                    .font(SpeakerTypography.bodyEmphasis)
                    .foregroundStyle(isOmitted ? .secondary : .primary)

                if showsStatusRow {
                    HStack(spacing: 8) {
                        if isOmitted {
                            Label(
                                "不会发送",
                                systemImage: "exclamationmark.circle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                        if let presentation = qualityHint.presentation {
                            Label(
                                presentation.text,
                                systemImage: presentation.symbol
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(SpeakerTypography.footnote)
                    .overlay {
                        DictionaryEntryStatusAccessibilityElement(
                            label: statusAccessibilityLabel
                        )
                    }
                }
            }

            Button(action: onDelete) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
                    Image(systemName: "xmark")
                        // A glyph centred in a fixed 20pt hit circle.
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary)
                        .opacity(isHovered ? 1 : 0.35)
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityHidden(true)
            .overlay {
                AccessibilityButtonBridge(
                    label: "删除词条 \(word)",
                    hint: "删除这个个人词库词条",
                    action: onDelete
                )
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, showsStatusRow ? 6 : 5)
        .background(fillColor, in: shape)
        .overlay { shape.stroke(strokeColor, lineWidth: 1) }
        .onHover { isHovered = $0 }
    }

    private var statusAccessibilityLabel: String {
        [
            isOmitted ? "不会发送" : nil,
            qualityHint.presentation?.text,
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

private extension DictionaryEntryQualityHint {
    var presentation: (text: String, symbol: String)? {
        switch self {
        case .none:
            nil
        case .tooLong:
            ("建议少于 10 个字符", "text.badge.exclamationmark")
        case .singleCharacter:
            ("单字效果可能较弱", "text.badge.exclamationmark")
        }
    }
}

private struct DictionaryEntryStatusAccessibilityElement: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> DictionaryEntryStatusAccessibilityView {
        DictionaryEntryStatusAccessibilityView(label: label)
    }

    func updateNSView(
        _ view: DictionaryEntryStatusAccessibilityView,
        context: Context
    ) {
        view.update(label: label)
    }
}

private final class DictionaryEntryStatusAccessibilityView: NSView {
    init(label: String) {
        super.init(frame: .zero)
        update(label: label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(label: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
