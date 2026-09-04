import SpeakerCore
import SwiftUI

/// The 整理 page: mode selection first, then at most one editor card — the
/// inspected built-in mode's prompt, or Custom Mode's own name and prompt.
struct RefinementSettingsPage: View {
    @ObservedObject var model: RefinementSettingsModel

    var body: some View {
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
    }

    private var modeCard: some View {
        SettingsCard(
            "整理模式",
            subtitle: "默认顺滑只用豆包；其他模式需要先验证 DeepSeek Key",
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
                        inspected: model.inspectedPromptMode
                            == choice.builtInMode,
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
            subtitle: "提示词只保存在本机，修改后对新会话生效",
            icon: "text.quote"
        ) {
            RefinementPromptTextEditor(
                text: $model.promptDraft,
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
                .buttonStyle(.borderedProminent)
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
            subtitle: "说清楚希望保留、删除和重组的内容",
            icon: "slider.horizontal.3"
        ) {
            TextField("模式名称", text: $model.customName)

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

            RefinementPromptTextEditor(
                text: $model.customPrompt,
                placeholder: "例如：整理成简洁的工作邮件，保留所有数字和专有名词……",
                minHeight: 130
            )

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
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSaveCustomMode)
            }
        }
    }
}

/// The shared prompt text area: both editor cards show the same surface, only
/// the placeholder and height differ.
private struct RefinementPromptTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let minHeight: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(SpeakerTypography.body)
                .scrollContentBackground(.hidden)
                .padding(8)

            if text.isEmpty {
                Text(placeholder)
                    .font(SpeakerTypography.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(Color.primary.opacity(0.04), in: shape)
        .overlay {
            shape.stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct RefinementModeButton: View {
    let choice: RefinementChoice
    let selected: Bool
    let inspected: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: choice.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(
                            selected || inspected ? Color.accentColor : .secondary
                        )
                    Spacer()
                    Image(
                        systemName: selected
                            ? "checkmark.circle.fill" : locked ? "lock.fill" : "circle"
                    )
                    .foregroundStyle(
                        selected ? Color.accentColor : Color.secondary.opacity(0.55)
                    )
                }
                Text(choice.title)
                    .font(SpeakerTypography.bodyEmphasis)
                    .foregroundStyle(.primary)
                Text(choice.subtitle)
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(
                selected || inspected
                    ? Color.accentColor.opacity(0.10)
                    : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected || inspected
                            ? Color.accentColor.opacity(0.8)
                            : Color.primary.opacity(0.08),
                        lineWidth: selected || inspected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}
