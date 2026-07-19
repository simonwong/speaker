import AppKit
import SwiftUI

package struct DictionaryEntryChip: View {
    private let word: String
    private let onDelete: () -> Void
    @State private var isHovered = false

    package init(word: String, onDelete: @escaping () -> Void) {
        self.word = word
        self.onDelete = onDelete
    }

    package var body: some View {
        HStack(spacing: 7) {
            Text(word)
                .font(.subheadline)

            Button(action: onDelete) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.12 : 0))
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(isHovered ? 1 : 0))
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityHidden(true)
            .overlay {
                DictionaryDeleteAccessibilityAction(
                    label: "删除词条 \(word)",
                    action: onDelete
                )
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.055), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
    }
}

private struct DictionaryDeleteAccessibilityAction: NSViewRepresentable {
    let label: String
    let action: () -> Void

    func makeNSView(context: Context) -> DictionaryDeleteAccessibilityActionView {
        DictionaryDeleteAccessibilityActionView(label: label, action: action)
    }

    func updateNSView(
        _ view: DictionaryDeleteAccessibilityActionView,
        context: Context
    ) {
        view.update(label: label, action: action)
    }
}

@MainActor
private final class DictionaryDeleteAccessibilityActionView:
    NSView,
    @preconcurrency NSAccessibilityButton
{
    private var accessibilityAction: () -> Void

    init(label: String, action: @escaping () -> Void) {
        accessibilityAction = action
        super.init(frame: .zero)
        update(label: label, action: action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(label: String, action: @escaping () -> Void) {
        accessibilityAction = action
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp("删除这个个人词库词条")
        setAccessibilityEnabled(true)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func accessibilityPerformPress() -> Bool {
        accessibilityAction()
        return true
    }
}
