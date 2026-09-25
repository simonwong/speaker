import SpeakerCore
import SwiftUI

/// The 整理 page: mode selection first, then at most one editor card — the
/// inspected built-in mode's prompt, or Custom Mode's own name and prompt.
package struct RefinementSettingsPage: View {
    @ObservedObject var model: RefinementSettingsModel

    package init(model: RefinementSettingsModel) { self.model = model }

    package var body: some View {
        VStack(spacing: SpeakerSurfaceMetrics.cardSpacing) {
            modeCard

            if let promptEditor = model.promptEditorState,
                !model.isEditingCustomMode
            {
                RefinementPromptEditorCard(
                    model: model,
                    promptEditor: promptEditor
                )
            }

            if model.isEditingCustomMode || model.choice == .custom {
                CustomRefinementModeCard(model: model)
            }
        }
        .disabled(model.isMutating)
    }

    private var modeCard: some View {
        SettingsCard(
            "整理模式",
            subtitle: model.hasStoredKey ? nil : "配置文字整理 Key 后解锁其他模式",
            icon: "text.alignleft"
        ) {
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

            if let notice = model.notice {
                SettingsNotice(
                    text: notice,
                    color: model.isConnectionVerified ? .green : .secondary
                )
            }
        }
    }
}

/// The built-in mode prompt editor. The prompt is saved on this Mac only and
/// takes effect for new sessions.
private struct RefinementPromptEditorCard: View {
    @ObservedObject var model: RefinementSettingsModel
    let promptEditor: RefinementPromptEditorState

    var body: some View {
        SettingsCard(
            "“\(promptEditor.title)”提示词",
            icon: "text.quote"
        ) {
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

/// Custom Mode's own name and prompt. The save condition lives on the model as
/// `canSaveCustomMode`, so this card only renders it.
private struct CustomRefinementModeCard: View {
    @ObservedObject var model: RefinementSettingsModel

    var body: some View {
        SettingsCard(
            "自定义模式",
            icon: "slider.horizontal.3"
        ) {
            if model.choice != .custom {
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
                Button("保存并启用") {
                    Task { await model.saveCustomMode() }
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .disabled(!model.canSaveCustomMode)
            }
        }
    }
}

/// The shared prompt text area: both editor cards show the same surface, only
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
        highlighted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03)
    }

    @ViewBuilder
    private func surface(_ content: some View) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            content.glassEffect(
                .regular.tint(highlighted ? Color.accentColor.opacity(0.16) : nil).interactive(),
                in: shape
            )
        } else {
            content.background(fillColor, in: shape)
        }
    }

    private var strokeColor: Color {
        if highlighted { return Color.accentColor.opacity(0.8) }
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
                        highlighted ? Color.accentColor : .secondary
                    )
                Spacer()
                Image(
                    systemName: selected
                        ? "checkmark.circle.fill"
                        : highlighted ? "pencil.circle" : locked ? "lock.fill" : "circle"
                )
                .foregroundStyle(
                    highlighted
                        ? Color.accentColor
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
