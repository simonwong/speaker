import SpeakerCore
import SwiftUI

/// The 整理 page: one card with mode selection first, then at most one
/// editor below it — the inspected built-in mode's prompt, or the Custom Mode
/// list with the editor for one entry.
package struct RefinementSettingsPage: View {
    @ObservedObject var model: RefinementSettingsModel

    package init(model: RefinementSettingsModel) { self.model = model }

    package var body: some View {
        // The 整理 section already names this card, so it carries no header.
        SpeakerCard {
            modeGrid

            if let promptEditor = model.promptEditorState,
                !model.isEditingCustomMode
            {
                SpeakerRowDivider()
                RefinementPromptEditor(
                    model: model,
                    promptEditor: promptEditor
                )
            }

            if model.isEditingCustomMode || model.choice == .custom {
                SpeakerRowDivider()
                CustomRefinementModeEditor(model: model)
            }
        }
        .disabled(model.isMutating)
    }

    @ViewBuilder
    private var modeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: SpeakerSpacing.s)],
            spacing: SpeakerSpacing.s
        ) {
            ForEach(RefinementChoice.allCases) { choice in
                RefinementModeButton(
                    choice: choice,
                    highlight: highlight(for: choice),
                    locked: choice != .defaultSmooth && !model.hasStoredKey
                ) {
                    Task { await model.select(choice) }
                }
            }
        }

        // A pending notice already says what the key unlocks.
        if !model.hasStoredKey, model.notice == nil {
            SpeakerNotice(text: "保存 \(model.providerName) Key 后解锁其他模式")
        }

        if let notice = model.notice {
            SpeakerNotice(
                text: notice,
                glyph: model.isConnectionVerified ? .symbol(SpeakerTone.ok.symbol) : .tone
            )
        }
    }

    /// Coral marks the mode new sessions use; gold marks the card whose
    /// editor is open below while another mode stays in use.
    private func highlight(for choice: RefinementChoice) -> SpeakerHighlight? {
        if model.choice == choice { return .selected }
        if model.isEditingCustomMode { return choice == .custom ? .editing : nil }
        guard let builtInMode = choice.builtInMode else { return nil }
        return model.promptEditorState?.mode == builtInMode ? .editing : nil
    }
}

/// A titled block inside the 整理 card, below the mode grid.
private struct RefinementEditorSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(SpeakerTypography.emphasis)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The built-in mode prompt editor. The prompt is saved on this Mac only and
/// takes effect for new sessions.
private struct RefinementPromptEditor: View {
    @ObservedObject var model: RefinementSettingsModel
    let promptEditor: RefinementPromptEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.rowSpacing) {
            RefinementEditorSectionTitle(title: "“\(promptEditor.title)”提示词")

            RefinementPromptTextEditor(
                text: $model.promptDraft,
                label: "“\(promptEditor.title)”提示词",
                placeholder: "输入该模式的整理提示词……",
                minHeight: 110
            )

            HStack(spacing: SpeakerSpacing.s) {
                RefinementCharacterCount(
                    count: model.promptDraft.count,
                    limit: TextRefinementMode.maximumCustomPromptLength
                )
                Spacer()
                Button("恢复默认") {
                    Task { await model.restoreDefaultPrompt() }
                }
                .disabled(
                    !promptEditor.canRestoreDefault(draft: model.promptDraft)
                )
                Button("保存") {
                    Task { await model.savePromptOverride() }
                }
                .buttonStyle(SpeakerButtonStyle(prominent: true))
                .disabled(!promptEditor.canSave(draft: model.promptDraft))
            }
        }
    }
}

/// A draft's length against its limit, red once it is over.
private struct RefinementCharacterCount: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text("\(count) / \(limit)")
            .font(SpeakerTypography.detail.monospacedDigit())
            .foregroundStyle(count > limit ? SpeakerTone.error.color : .secondary)
    }
}

/// The Custom Mode list and the editor for one entry. List order is the order
/// the menu uses. The save conditions live on the model as `canSaveCustomMode`
/// and `canSaveCustomModeDraft`, so this view only renders them.
private struct CustomRefinementModeEditor: View {
    @ObservedObject var model: RefinementSettingsModel
    @State private var pendingDeletion: CustomRefinementMode?

    var body: some View {
        VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: SpeakerSpacing.s) {
                RefinementEditorSectionTitle(title: "自定义模式")
                Text("\(model.customModes.count) / \(CustomRefinementMode.maximumCount)")
                    .font(SpeakerTypography.detail.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.beginNewCustomMode()
                } label: {
                    Label("新建模式", systemImage: "plus")
                }
                .disabled(!model.canAddCustomMode)
            }

            if !model.customModes.isEmpty {
                VStack(spacing: SpeakerSpacing.s) {
                    ForEach(Array(model.customModes.enumerated()), id: \.element.id) {
                        index, mode in
                        CustomRefinementModeRow(
                            mode: mode,
                            isActive: model.selection == .custom(mode.id),
                            isEditing: model.editingCustomModeID == mode.id,
                            canUse: model.hasStoredKey,
                            canMoveUp: index > 0,
                            canMoveDown: index < model.customModes.count - 1,
                            use: { Task { await model.selectCustomMode(mode.id) } },
                            edit: { model.editCustomMode(mode.id) },
                            moveUp: { Task { await model.moveCustomMode(mode.id, by: -1) } },
                            moveDown: { Task { await model.moveCustomMode(mode.id, by: 1) } },
                            delete: { pendingDeletion = mode }
                        )
                    }
                }
            }

            SpeakerRowDivider()

            RefinementEditorSectionTitle(
                title: model.editingCustomModeID == nil ? "新建模式" : "编辑“\(model.customName)”"
            )

            VStack(alignment: .leading, spacing: SpeakerSpacing.xs) {
                HStack(spacing: SpeakerSpacing.s) {
                    Text("模式名称").font(SpeakerTypography.detail)
                    Spacer()
                    RefinementCharacterCount(
                        count: model.customName.count,
                        limit: TextRefinementMode.maximumCustomNameLength
                    )
                }
                TextField("模式名称", text: $model.customName, prompt: Text("例如：工作邮件"))
            }

            VStack(alignment: .leading, spacing: SpeakerSpacing.xs) {
                Text("提示词").font(SpeakerTypography.detail)
                RefinementPromptTextEditor(
                    text: $model.customPrompt,
                    label: "自定义模式提示词",
                    placeholder: "例如：整理成简洁的工作邮件，保留所有数字和专有名词……",
                    minHeight: 130
                )
            }

            HStack(spacing: SpeakerSpacing.s) {
                RefinementCharacterCount(
                    count: model.customPrompt.count,
                    limit: TextRefinementMode.maximumCustomPromptLength
                )
                Spacer()
                if !model.isEditingActiveCustomMode {
                    Button("保存") {
                        Task { await model.saveCustomMode(enabling: false) }
                    }
                    .disabled(!model.canSaveCustomModeDraft)
                }
                Button(model.isEditingActiveCustomMode ? "保存" : "保存并启用") {
                    Task { await model.saveCustomMode() }
                }
                .buttonStyle(SpeakerButtonStyle(prominent: true))
                .disabled(!model.canSaveCustomMode)
            }
        }
        .confirmationDialog(
            "删除“\(pendingDeletion?.name ?? "")”？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { mode in
            Button("删除模式", role: .destructive) {
                Task { await model.deleteCustomMode(mode.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { mode in
            Text(
                model.selection == .custom(mode.id)
                    ? "这是正在使用的模式。删除后，新的输入改用“默认顺滑”。"
                    : "删除后无法恢复。"
            )
        }
    }
}

/// One saved Custom Mode: a coral check marks the mode in use, a gold ring
/// the one open in the editor.
private struct CustomRefinementModeRow: View {
    let mode: CustomRefinementMode
    let isActive: Bool
    let isEditing: Bool
    let canUse: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let use: () -> Void
    let edit: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerRadius.inner,
            style: .continuous
        )
    }

    private var editing: SpeakerHighlight? {
        isEditing ? .editing : nil
    }

    @ViewBuilder
    private func surface(_ content: some View) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            content.glassEffect(.regular.tint(editing?.glassTint), in: shape)
        } else {
            content.background(editing?.fill ?? SpeakerFill.subtle, in: shape)
        }
    }

    var body: some View {
        surface(row)
            .overlay {
                if let editing {
                    shape.strokeBorder(editing.stroke, lineWidth: SpeakerStroke.focusWidth)
                } else {
                    shape.strokeBorder(
                        SpeakerStroke.hairline(increasedContrast: contrast == .increased),
                        lineWidth: 1
                    )
                }
            }
    }

    private var row: some View {
        HStack(spacing: SpeakerSpacing.s) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checkStyle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeakerSpacing.hairline) {
                Text(mode.name)
                    .font(SpeakerTypography.emphasis)
                    .lineLimit(1)
                Text(mode.prompt)
                    .font(SpeakerTypography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(isActive ? "当前使用" : isEditing ? "正在编辑" : "")
            Spacer(minLength: SpeakerSpacing.s)
            if !isActive {
                Button("使用", action: use)
                    .disabled(!canUse)
                    .accessibilityLabel("使用“\(mode.name)”")
            }
            SpeakerIconButton(symbol: "pencil", label: "编辑“\(mode.name)”", action: edit)
            SpeakerIconButton(symbol: "chevron.up", label: "上移“\(mode.name)”", action: moveUp)
                .disabled(!canMoveUp)
            SpeakerIconButton(
                symbol: "chevron.down", label: "下移“\(mode.name)”", action: moveDown
            )
            .disabled(!canMoveDown)
            SpeakerIconButton(symbol: "trash", label: "删除“\(mode.name)”", action: delete)
        }
        .padding(.horizontal, SpeakerSpacing.m)
        .padding(.vertical, SpeakerSpacing.xs)
    }

    private var checkStyle: AnyShapeStyle {
        if isActive { return AnyShapeStyle(SpeakerHighlight.selected.accent) }
        return contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
    }
}

/// The shared prompt text area: both editors show the same surface, only
/// the placeholder and height differ.
private struct RefinementPromptTextEditor: View {
    @Binding var text: String
    let label: String
    let placeholder: String
    let minHeight: CGFloat

    @FocusState private var focused: Bool

    /// Where `TextEditor`'s text view starts drawing inside its frame: the
    /// line fragment padding across, the text container inset down. The
    /// placeholder adds it so it sits exactly where typed text appears.
    private static let textViewInset = CGSize(width: 5, height: 8)

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .focused($focused)
                .font(SpeakerTypography.body)
                .scrollContentBackground(.hidden)
                .padding(SpeakerSpacing.s)
                .accessibilityLabel(label)

            if text.isEmpty {
                Text(placeholder)
                    .font(SpeakerTypography.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, SpeakerSpacing.s + Self.textViewInset.width)
                    .padding(.vertical, SpeakerSpacing.s + Self.textViewInset.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: minHeight)
        .speakerEditorField(focused: focused)
    }
}

/// One card in the mode grid. Coral marks the mode in use; gold the card
/// whose editor is open below while another mode stays in use.
private struct RefinementModeButton: View {
    let choice: RefinementChoice
    let highlight: SpeakerHighlight?
    let locked: Bool
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerRadius.inner,
            style: .continuous
        )
    }

    @ViewBuilder
    private func surface(_ content: some View) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            content.glassEffect(
                .regular.tint(highlight?.glassTint).interactive(),
                in: shape
            )
        } else {
            content.background(highlight?.fill ?? SpeakerFill.subtle, in: shape)
        }
    }

    var body: some View {
        Button(action: action) {
            surface(label)
                .overlay {
                    if let highlight {
                        shape.strokeBorder(highlight.stroke, lineWidth: SpeakerStroke.focusWidth)
                    } else {
                        shape.strokeBorder(
                            SpeakerStroke.hairline(increasedContrast: contrast == .increased),
                            lineWidth: 1
                        )
                    }
                }
                .contentShape(shape)
                .animation(reduceMotion ? nil : SpeakerMotion.change, value: highlight)
        }
        .buttonStyle(SpeakerPressableButtonStyle())
        .accessibilityHidden(true)
        .overlay {
            AccessibilityButtonBridge(
                label: choice.title,
                hint: choice.subtitle,
                value: accessibilityState,
                action: action
            )
        }
    }

    private var accessibilityState: String {
        switch highlight {
        case .selected: return "当前使用"
        case .editing: return "正在编辑，尚未启用"
        case nil: return locked ? "需要先保存 API Key" : "未启用"
        }
    }

    private var stateSymbol: String {
        switch highlight {
        case .selected: "checkmark.circle.fill"
        case .editing: "pencil.circle"
        case nil: locked ? "lock.fill" : "circle"
        }
    }

    /// Unmarked glyphs recede to tertiary, except under Increase Contrast.
    private var glyphStyle: AnyShapeStyle {
        if let highlight { return AnyShapeStyle(highlight.accent) }
        return contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: SpeakerSpacing.s) {
            HStack {
                Image(systemName: choice.icon)
                    .font(SpeakerTypography.emphasis)
                    .foregroundStyle(highlight?.accent ?? .secondary)
                Spacer()
                Image(systemName: stateSymbol)
                    .foregroundStyle(glyphStyle)
            }
            Text(choice.title)
                .font(SpeakerTypography.emphasis)
                .foregroundStyle(.primary)
            Text(choice.subtitle)
                .font(SpeakerTypography.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                // Every card keeps two lines, so a row never mixes heights.
                .lineLimit(2, reservesSpace: true)
        }
        .padding(SpeakerSpacing.m)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
    }
}
