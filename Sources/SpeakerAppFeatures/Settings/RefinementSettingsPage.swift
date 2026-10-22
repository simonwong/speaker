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
        SettingsCard {
            modeGrid

            if let promptEditor = model.promptEditorState,
                !model.isEditingCustomMode
            {
                SettingsRowDivider()
                RefinementPromptEditor(
                    model: model,
                    promptEditor: promptEditor
                )
            }

            if model.isEditingCustomMode || model.choice == .custom {
                SettingsRowDivider()
                CustomRefinementModeEditor(model: model)
            }
        }
        .disabled(model.isMutating)
    }

    @ViewBuilder
    private var modeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
            spacing: 10
        ) {
            ForEach(RefinementChoice.allCases) { choice in
                RefinementModeButton(
                    choice: choice,
                    selected: model.choice == choice,
                    highlighted: model.isEditingCustomMode
                        ? choice == .custom : model.choice == choice,
                    locked: choice != .defaultSmooth && !model.hasStoredKey
                ) {
                    Task { await model.select(choice) }
                }
            }
        }

        // A pending notice already says what the key unlocks.
        if !model.hasStoredKey, model.notice == nil {
            Text("在下方配置整理服务后解锁其他模式")
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.secondary)
        }

        if let notice = model.notice {
            SettingsNotice(
                text: notice,
                icon: model.isConnectionVerified ? "checkmark.circle.fill" : nil
            )
        }
    }
}

/// A titled block inside the 整理 card, below the mode grid.
private struct RefinementEditorSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(SpeakerTypography.bodyEmphasis)
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

            HStack {
                Text(
                    "\(model.promptDraft.count) / \(TextRefinementMode.maximumCustomPromptLength)"
                )
                .font(SpeakerTypography.footnote.monospacedDigit())
                .foregroundStyle(
                    model.promptDraft.count
                        > TextRefinementMode.maximumCustomPromptLength
                        ? Color.red
                        : .secondary
                )
                Text(promptEditor.isOverridden ? "当前为自定义提示词" : "当前为内置提示词")
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
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
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .disabled(!promptEditor.canSave(draft: model.promptDraft))
            }
        }
    }
}

/// The Custom Mode list and the editor for one entry. List order is the order
/// the menu and the Refinement Mode shortcut use. The save conditions live on
/// the model as `canSaveCustomMode` and `canSaveCustomModeDraft`, so this view
/// only renders them.
private struct CustomRefinementModeEditor: View {
    @ObservedObject var model: RefinementSettingsModel
    @State private var pendingDeletion: CustomRefinementMode?

    var body: some View {
        VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                RefinementEditorSectionTitle(title: "自定义模式")
                Text("\(model.customModes.count) / \(CustomRefinementMode.maximumCount)")
                    .font(SpeakerTypography.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.beginNewCustomMode()
                } label: {
                    Label("新建模式", systemImage: "plus")
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(!model.canAddCustomMode)
            }

            if model.customModes.isEmpty {
                Text("还没有自定义模式。填写名称和提示词后保存。")
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
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
                Text("菜单栏和“切换整理模式”快捷键按内置模式、再按此列表的顺序排列。")
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
            }

            SettingsRowDivider()

            RefinementEditorSectionTitle(
                title: model.editingCustomModeID == nil ? "新建模式" : "编辑“\(model.customName)”"
            )

            if model.isEditingActiveCustomMode {
                Text("这是正在使用的模式，保存后从下一次输入开始生效。")
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
            } else if model.choice != .custom || model.editingCustomModeID == nil {
                Text("保存并启用后生效；当前使用「\(model.mode.displayName)」。")
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("模式名称").font(SpeakerTypography.caption)
                TextField("模式名称", text: $model.customName, prompt: Text("例如：工作邮件"))
            }

            HStack {
                Spacer()
                Text(
                    "\(model.customName.count) / \(TextRefinementMode.maximumCustomNameLength)"
                )
                .font(SpeakerTypography.footnote.monospacedDigit())
                .foregroundStyle(
                    model.customName.count
                        > TextRefinementMode.maximumCustomNameLength
                        ? Color.red
                        : .secondary
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("提示词").font(SpeakerTypography.caption)
                RefinementPromptTextEditor(
                    text: $model.customPrompt,
                    label: "自定义模式提示词",
                    placeholder: "例如：整理成简洁的工作邮件，保留所有数字和专有名词……",
                    minHeight: 130
                )
            }

            HStack {
                Text(
                    "\(model.customPrompt.count) / \(TextRefinementMode.maximumCustomPromptLength)"
                )
                .font(SpeakerTypography.footnote.monospacedDigit())
                .foregroundStyle(
                    model.customPrompt.count
                        > TextRefinementMode.maximumCustomPromptLength
                        ? Color.red
                        : .secondary
                )
                Spacer()
                if !model.isEditingActiveCustomMode {
                    Button("保存") {
                        Task { await model.saveCustomMode(enabling: false) }
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!model.canSaveCustomModeDraft)
                }
                Button(model.isEditingActiveCustomMode ? "保存" : "保存并启用") {
                    Task { await model.saveCustomMode() }
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
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

/// One saved Custom Mode: coral marks the mode in use, gold the one open in
/// the editor.
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
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    private var strokeColor: Color {
        if isEditing { return SpeakerVisualIdentity.warmGoldDeep.opacity(0.7) }
        return Color.primary.opacity(contrast == .increased ? 0.4 : 0.08)
    }

    @ViewBuilder
    private func surface(_ content: some View) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            content.glassEffect(
                .regular.tint(isEditing ? SpeakerVisualIdentity.warmGold.opacity(0.14) : nil),
                in: shape
            )
        } else {
            content.background(
                isEditing
                    ? SpeakerVisualIdentity.warmGold.opacity(0.10) : Color.primary.opacity(0.03),
                in: shape
            )
        }
    }

    var body: some View {
        surface(row)
            .overlay { shape.strokeBorder(strokeColor, lineWidth: 1) }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                    isActive
                        ? SpeakerVisualIdentity.controlTint
                        : Color.secondary.opacity(contrast == .increased ? 1 : 0.55)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.name)
                    .font(SpeakerTypography.bodyEmphasis)
                    .lineLimit(1)
                Text(mode.prompt)
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(isActive ? "当前使用" : isEditing ? "正在编辑" : "")
            Spacer(minLength: 8)
            if isActive {
                Text("使用中")
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(SpeakerVisualIdentity.controlTint)
            } else {
                Button("使用", action: use)
                    .buttonStyle(SettingsButtonStyle())
                    .controlSize(.small)
                    .disabled(!canUse)
                    .accessibilityLabel("使用“\(mode.name)”")
            }
            iconButton("pencil", label: "编辑“\(mode.name)”", action: edit)
            iconButton("chevron.up", label: "上移“\(mode.name)”", action: moveUp)
                .disabled(!canMoveUp)
            iconButton("chevron.down", label: "下移“\(mode.name)”", action: moveDown)
                .disabled(!canMoveDown)
            iconButton("trash", label: "删除“\(mode.name)”", action: delete)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func iconButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .focused($focused)
                .font(SpeakerTypography.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .accessibilityLabel(label)

            if text.isEmpty {
                Text(placeholder)
                    .font(SpeakerTypography.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: minHeight)
        .speakerEditorField(focused: focused)
    }
}

private struct RefinementModeButton: View {
    let choice: RefinementChoice
    let selected: Bool
    let highlighted: Bool
    let locked: Bool
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    private var fillColor: Color {
        highlighted ? SpeakerVisualIdentity.controlTint.opacity(0.10) : Color.primary.opacity(0.03)
    }

    @ViewBuilder
    private func surface(_ content: some View) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            content.glassEffect(
                .regular.tint(highlighted ? SpeakerVisualIdentity.controlTint.opacity(0.16) : nil)
                    .interactive(),
                in: shape
            )
        } else {
            content.background(fillColor, in: shape)
        }
    }

    private var strokeColor: Color {
        if highlighted { return SpeakerVisualIdentity.controlTint.opacity(0.8) }
        return Color.primary.opacity(contrast == .increased ? 0.4 : 0.08)
    }

    var body: some View {
        Button(action: action) {
            surface(label)
                .overlay {
                    shape.strokeBorder(strokeColor, lineWidth: highlighted ? 1.5 : 1)
                }
                .contentShape(shape)
                .animation(reduceMotion ? nil : SpeakerMotion.change, value: highlighted)
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
        if selected { return "当前使用" }
        if highlighted { return "正在编辑，尚未启用" }
        if locked { return "需要先保存 API Key" }
        return "未启用"
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: choice.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(
                        highlighted ? SpeakerVisualIdentity.controlTint : .secondary
                    )
                Spacer()
                Image(
                    systemName: selected
                        ? "checkmark.circle.fill"
                        : highlighted ? "pencil.circle" : locked ? "lock.fill" : "circle"
                )
                .foregroundStyle(
                    highlighted
                        ? SpeakerVisualIdentity.controlTint
                        : Color.secondary.opacity(contrast == .increased ? 1 : 0.55)
                )
            }
            Text(choice.title)
                .font(SpeakerTypography.bodyEmphasis)
                .foregroundStyle(.primary)
            Text(choice.subtitle)
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                // Every card keeps two lines, so a row never mixes heights.
                .lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
    }
}
