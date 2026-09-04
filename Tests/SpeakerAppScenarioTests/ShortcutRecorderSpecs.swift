import AppKit
@preconcurrency import Carbon
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport

/// The shortcut recorder turns raw key events into one of four decisions:
/// consume, cancel, capture, or reject with the notice the Settings page
/// shows. These cases pin the accepted chords, the reserved keys the recorder
/// refuses, the common-editing conflict prompt, and when a held modifier
/// counts as a finished recording.
enum ShortcutRecorderSpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "shortcut recorder accepts a chord carrying two intent modifiers",
            failures: &failures
        ) {
            var policy = ShortcutRecorderPolicy()

            let decision = policy.handle(.keyDown(
                keyCode: UInt16(kVK_ANSI_D),
                flags: [.control, .option],
                charactersIgnoringModifiers: "d"
            ))

            try expect(
                decision == .capture(CustomHotKey(
                    keyCode: UInt32(kVK_ANSI_D),
                    modifiers: UInt32(controlKey | optionKey),
                    displayName: "⌃⌥D"
                )),
                "a safe two-modifier chord was not captured: \(decision)"
            )
        }

        await runAsync(
            "shortcut recorder rejects a chord without any modifier",
            failures: &failures
        ) {
            var policy = ShortcutRecorderPolicy()

            let decision = policy.handle(.keyDown(
                keyCode: UInt16(kVK_ANSI_D),
                flags: [],
                charactersIgnoringModifiers: "d"
            ))

            try expect(
                decision == .reject("组合键必须包含至少一个修饰键。"),
                "a bare key produced \(decision)"
            )
        }

        await runAsync(
            "shortcut recorder rejects a single-modifier chord with the recording prompt",
            failures: &failures
        ) {
            var policy = ShortcutRecorderPolicy()

            let decision = policy.handle(.keyDown(
                keyCode: UInt16(kVK_ANSI_D),
                flags: [.option],
                charactersIgnoringModifiers: "d"
            ))

            try expect(
                decision == .reject(ShortcutRecorderPolicy.recordingPrompt),
                "an unsafe single-modifier chord produced \(decision)"
            )
        }

        await runAsync(
            "shortcut recorder rejects a common editing chord with its own prompt",
            failures: &failures
        ) {
            let conflictPrompt = "这个组合键是常用编辑命令，请换一个组合键。"
            var policy = ShortcutRecorderPolicy()

            let copyDecision = policy.handle(.keyDown(
                keyCode: UInt16(kVK_ANSI_C),
                flags: [.command],
                charactersIgnoringModifiers: "c"
            ))
            let redoDecision = policy.handle(.keyDown(
                keyCode: UInt16(kVK_ANSI_Z),
                flags: [.command, .shift],
                charactersIgnoringModifiers: "z"
            ))

            try expect(
                copyDecision == .reject(conflictPrompt),
                "⌘C produced \(copyDecision)"
            )
            try expect(
                redoDecision == .reject(conflictPrompt),
                "⇧⌘Z produced \(redoDecision)"
            )
            try expect(
                conflictPrompt != ShortcutRecorderPolicy.recordingPrompt,
                "the conflict notice repeats the generic recording prompt"
            )
        }

        await runAsync(
            "shortcut recorder refuses either Command key on its own",
            failures: &failures
        ) {
            let commandPrompt = "不支持单独使用 Command；请选择左/右 ⌥、⌃ 或 ⇧。"
            for keyCode in [kVK_Command, kVK_RightCommand] {
                var policy = ShortcutRecorderPolicy()

                let held = policy.handle(.flagsChanged(
                    keyCode: UInt16(keyCode),
                    flags: [.command]
                ))
                let released = policy.handle(.flagsChanged(
                    keyCode: UInt16(keyCode),
                    flags: []
                ))

                try expect(
                    held == .consume,
                    "holding Command \(keyCode) produced \(held)"
                )
                try expect(
                    released == .reject(commandPrompt),
                    "releasing Command \(keyCode) produced \(released)"
                )
            }
        }

        await runAsync(
            "shortcut recorder keeps Escape reserved for cancelling the recording",
            failures: &failures
        ) {
            var policy = ShortcutRecorderPolicy()

            let bare = policy.handle(.keyDown(
                keyCode: UInt16(kVK_Escape),
                flags: [],
                charactersIgnoringModifiers: nil
            ))
            let modified = policy.handle(.keyDown(
                keyCode: UInt16(kVK_Escape),
                flags: [.command, .option],
                charactersIgnoringModifiers: nil
            ))

            try expect(bare == .cancel, "bare Escape produced \(bare)")
            try expect(
                modified == .cancel,
                "a modified Escape was recorded instead of cancelling: \(modified)"
            )
        }

        await runAsync(
            "shortcut recorder finishes a modifier recording only on a clean release",
            failures: &failures
        ) {
            var policy = ShortcutRecorderPolicy()

            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Control),
                    flags: [.control]
                )) == .consume
            )
            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Control),
                    flags: [.control, .shift]
                )) == .consume,
                "a second modifier did not abandon the candidate"
            )
            let releasedWithShiftHeld = policy.handle(.flagsChanged(
                keyCode: UInt16(kVK_Control),
                flags: [.shift]
            ))
            try expect(
                releasedWithShiftHeld == .consume,
                "an unclean release captured \(releasedWithShiftHeld)"
            )
            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Shift),
                    flags: []
                )) == .consume,
                "the trailing Shift release captured a shortcut"
            )

            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Control),
                    flags: [.control]
                )) == .consume
            )
            let captured = policy.handle(.flagsChanged(
                keyCode: UInt16(kVK_Control),
                flags: []
            ))
            try expect(
                captured == .capture(CustomHotKey.modifierOnly(
                    .leftControl,
                    displayName: "左 ⌃"
                )),
                "a clean modifier release produced \(captured)"
            )
        }

        await runAsync(
            "shortcut recorder drops a held modifier once a key chord is recorded",
            failures: &failures
        ) {
            var policy = ShortcutRecorderPolicy()

            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Option),
                    flags: [.option]
                )) == .consume
            )
            let captured = policy.handle(.keyDown(
                keyCode: UInt16(kVK_ANSI_D),
                flags: [.control, .option],
                charactersIgnoringModifiers: "d"
            ))
            try expect(
                captured == .capture(CustomHotKey(
                    keyCode: UInt32(kVK_ANSI_D),
                    modifiers: UInt32(controlKey | optionKey),
                    displayName: "⌃⌥D"
                )),
                "the chord following a held modifier produced \(captured)"
            )

            let release = policy.handle(.flagsChanged(
                keyCode: UInt16(kVK_Option),
                flags: []
            ))
            try expect(
                release == .consume,
                "releasing the modifier recorded a second shortcut: \(release)"
            )
        }
    }
}
