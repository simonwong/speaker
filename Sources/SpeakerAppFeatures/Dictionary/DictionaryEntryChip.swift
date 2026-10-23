import AppKit
import SpeakerCore
import SwiftUI

/// One Entry on the dictionary page: a single-line `SpeakerChip`. An Entry
/// past the provider's capacity is marked omitted; a quality hint is a
/// trailing glyph whose sentence lives in the tooltip and in the accessibility
/// text, so the chip never grows a second line.
package struct DictionaryEntryChip: View {
    private let word: String
    private let isOmitted: Bool
    private let qualityHint: DictionaryEntryQualityHint
    private let onDelete: () -> Void

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

    private static let omittedText = "不会发送"

    /// Every sentence the chip's glyphs stand for, in reading order.
    private var statusText: String? {
        let parts = [
            isOmitted ? Self.omittedText : nil,
            qualityHint.presentation?.text,
        ]
        .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    private var deleteLabel: String { "删除词条 \(word)" }

    package var body: some View {
        SpeakerChip(
            word,
            isOmitted: isOmitted,
            hintSymbol: qualityHint.presentation?.symbol,
            help: statusText,
            deleteLabel: deleteLabel,
            onDelete: onDelete
        )
        // SwiftUI's own elements can drop out of AppKit's accessibility tree,
        // so the chip speaks through two bridged elements instead: the word
        // with its status, and the delete button over the chip's trailing
        // glyph.
        .accessibilityHidden(true)
        .overlay {
            DictionaryEntryStatusAccessibilityElement(
                label: [word, statusText].compactMap { $0 }.joined(separator: "，")
            )
        }
        .overlay(alignment: .trailing) {
            AccessibilityButtonBridge(
                label: deleteLabel,
                hint: "删除这个个人词库词条",
                action: onDelete
            )
            .frame(
                width: SpeakerControlMetrics.compactHeight,
                height: SpeakerControlMetrics.compactHeight
            )
            .padding(.trailing, SpeakerSpacing.xs)
        }
    }
}

extension DictionaryEntryQualityHint {
    fileprivate var presentation: (text: String, symbol: String)? {
        switch self {
        case .none:
            nil
        case .tooLong:
            ("建议少于 10 个字符", "exclamationmark.circle")
        case .singleCharacter:
            ("单字效果可能较弱", "exclamationmark.circle")
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
