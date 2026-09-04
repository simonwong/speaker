import Foundation
import SpeakerCore

/// Editor state for one DeepSeek-backed built-in refinement mode's prompt row
/// in the settings 整理 group.
package struct RefinementPromptEditorState: Equatable, Sendable {
    package let mode: BuiltInRefinementMode
    /// The mode's built-in prompt; 恢复默认 returns the draft to this text.
    package let defaultPrompt: String
    /// The prompt new sessions currently use: the saved override or the default.
    package let effectivePrompt: String
    /// Whether a saved override currently replaces the built-in prompt.
    package let isOverridden: Bool

    package var title: String {
        switch mode {
        case .conciseCleanup: SpeakerCopy.RefinementMode.conciseCleanup
        case .fullRewrite: SpeakerCopy.RefinementMode.fullRewrite
        }
    }

    /// 恢复默认 is meaningful while the draft differs from the built-in prompt.
    package func canRestoreDefault(draft: String) -> Bool {
        draft != defaultPrompt
    }

    /// 保存 accepts a non-empty, in-limit draft that changes the prompt in effect.
    package func canSave(draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.count <= TextRefinementMode.maximumCustomPromptLength
            && draft != effectivePrompt
    }
}

package enum RefinementPromptPresentation {
    /// Maps a refinement mode to its prompt editor state. Default Smoothing is
    /// Doubao built-in and has no prompt; Custom Mode keeps its own
    /// name + prompt editor — both return nil.
    package static func editorState(
        for mode: TextRefinementMode
    ) -> RefinementPromptEditorState? {
        guard let builtInMode = mode.builtInMode else { return nil }
        return editorState(
            for: builtInMode,
            promptOverride: mode.promptOverride
        )
    }

    package static func editorState(
        for mode: BuiltInRefinementMode,
        promptOverride: String?
    ) -> RefinementPromptEditorState {
        RefinementPromptEditorState(
            mode: mode,
            defaultPrompt: mode.defaultPrompt,
            effectivePrompt: promptOverride ?? mode.defaultPrompt,
            isOverridden: promptOverride != nil
        )
    }
}
