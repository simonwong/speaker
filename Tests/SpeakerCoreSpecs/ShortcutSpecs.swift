import Foundation
import ApplicationServices
@preconcurrency import Carbon
import SpeakerCore
import SpeakerSpecSupport

enum ShortcutSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        run("short press latches recording until the next press", failures: &failures) {
            var gesture = VoiceShortcutGestureStateMachine()

            try expect(gesture.handle(.pressed, at: 1_000_000_000) == [.pressed])
            try expect(gesture.handle(.released, at: 1_100_000_000).isEmpty)
            try expect(gesture.handle(.pressed, at: 2_000_000_000) == [.released])
            try expect(gesture.handle(.released, at: 2_050_000_000).isEmpty)
            try expect(gesture.handle(.pressed, at: 3_000_000_000) == [.pressed])
        }

        run("long press records only while held", failures: &failures) {
            var gesture = VoiceShortcutGestureStateMachine()

            try expect(gesture.handle(.pressed, at: 1_000_000_000) == [.pressed])
            try expect(gesture.handle(.released, at: 1_300_000_000) == [.released])
        }

        run("cancel clears a latched shortcut gesture", failures: &failures) {
            var gesture = VoiceShortcutGestureStateMachine()

            _ = gesture.handle(.pressed, at: 1_000_000_000)
            _ = gesture.handle(.released, at: 1_050_000_000)
            try expect(gesture.handle(.cancel, at: 1_100_000_000) == [.cancel])
            try expect(gesture.handle(.released, at: 1_150_000_000).isEmpty)
            try expect(gesture.handle(.pressed, at: 1_200_000_000) == [.pressed])
        }

        run("Esc is reserved for cancelling voice input", failures: &failures) {
            let escape = CustomHotKey(
                keyCode: 53,
                modifiers: 2_048,
                displayName: "⌥ Esc"
            )
            try expect(escape.isReservedForCancellation)
            try expect(!CustomHotKey.optionSpace.isReservedForCancellation)
        }

        run("Command menu shortcuts cannot become a global voice trigger", failures: &failures) {
            let commandC = CustomHotKey(
                keyCode: 8,
                modifiers: 256,
                displayName: "⌘ C"
            )
            let optionC = CustomHotKey(
                keyCode: 8,
                modifiers: 2_048,
                displayName: "⌥ C"
            )
            try expect(commandC.conflictsWithCommonEditingShortcut)
            try expect(!optionC.conflictsWithCommonEditingShortcut)

            let commandMenuCases: [(UInt32, UInt32)] = [
                (4, 256),       // Command-H
                (46, 256),      // Command-M
                (31, 256),      // Command-O
                (15, 256),      // Command-R
                (43, 256),      // Command-comma
                (6, 256 | 512), // Command-Shift-Z
            ]
            for (keyCode, modifiers) in commandMenuCases {
                try expect(CustomHotKey(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    displayName: "menu shortcut"
                ).conflictsWithCommonEditingShortcut)
            }
        }

        run("global voice triggers cannot overlap ordinary modified typing", failures: &failures) {
            let unsafeCases: [(UInt32, UInt32)] = [
                (0, 512),         // Shift-A
                (0, 2_048),       // Option-A / dead-key and symbol input
                (0, 4_096),       // Control-A / terminal input
                (0, 512 | 4_096), // Control-Shift-A still has one intent modifier
                (49, 512),        // Shift-Space
            ]
            for (keyCode, modifiers) in unsafeCases {
                try expect(!CustomHotKey(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    displayName: "unsafe typing chord"
                ).isSafeForGlobalVoiceInput)
            }

            try expect(CustomHotKey.optionSpace.isSafeForGlobalVoiceInput)
            try expect(CustomHotKey(
                keyCode: 40,
                modifiers: 2_048 | 4_096,
                displayName: "⌃⌥ K"
            ).isSafeForGlobalVoiceInput)
        }

        run("a selected physical Option Control or Shift key is a safe exclusive trigger", failures: &failures) {
            let supportedModifiers: [CustomHotKey.PhysicalModifier] = [
                .leftOption, .rightOption,
                .leftControl, .rightControl,
                .leftShift, .rightShift,
            ]
            for modifier in supportedModifiers {
                let hotKey = CustomHotKey.modifierOnly(
                    modifier,
                    displayName: "modifier"
                )
                try expect(hotKey.trigger == .modifierOnly(modifier))
                try expect(hotKey.isModifierOnly)
                try expect(hotKey.isSafeForGlobalVoiceInput)
            }
            try expect(
                CustomHotKey.optionSpace.trigger
                    == .keyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
            )
            try expect(
                CustomHotKey.PhysicalModifier(
                    keyCode: UInt32(kVK_Command)
                ) == nil
            )
            try expect(
                CustomHotKey.PhysicalModifier(
                    keyCode: UInt32(kVK_RightCommand)
                ) == nil
            )

            let rightOption = CustomHotKey.modifierOnly(
                .rightOption,
                displayName: "right Option"
            )
            guard var policy = ModifierOnlyFlagEventPolicy(
                hotKey: rightOption
            ) else {
                throw SpecFailure(message: "right Option policy was unavailable")
            }
            try expect(
                policy.handle(
                    keyCode: Int64(kVK_Option),
                    flags: .maskAlternate
                ) == .passThrough
            )
            try expect(
                policy.handle(
                    keyCode: Int64(kVK_RightOption),
                    flags: .maskAlternate
                ) == .consume(.pressed)
            )
            try expect(
                policy.handle(
                    keyCode: Int64(kVK_RightOption),
                    flags: .maskAlternate
                ) == .consume(.released)
            )
        }

        await runAsync("shortcut feature waits for Accessibility and activates the saved choice later", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let accessibility = AccessibilityStateFake(granted: false)
            let custom = CustomHotKey.optionSpace
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { accessibility.granted },
                persistPreference: { preference in
                    await persistence.save(preference)
                }
            )

            feature.select(.init(customHotKey: custom))
            await feature.flushPersistence()
            try expect(feature.preference == .init(customHotKey: custom))
            try expect(customMonitor.registeredKeys.isEmpty)
            try expect(feature.notice?.kind == .accessibilityRequired)
            try expect(
                feature.activation == .waitingForAccessibility(.init(customHotKey: custom))
            )
            let persistedWhileDenied = await persistence.values
            try expect(persistedWhileDenied == [.init(customHotKey: custom)])

            accessibility.granted = true
            feature.synchronize()
            try expect(customMonitor.registeredKeys == [custom])
            try expect(feature.notice == nil)
            try expect(feature.activation == .active(.init(customHotKey: custom)))
        }

        await runAsync("shortcut feature rejects editing conflicts and persists its Fn fallback", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    await persistence.save(preference)
                }
            )
            let commandC = CustomHotKey(
                keyCode: 8,
                modifiers: 256,
                displayName: "⌘ C"
            )

            feature.select(.init(customHotKey: commandC))
            await feature.flushPersistence()
            try expect(feature.preference == .functionKey)
            try expect(functionMonitor.startCount == 1)
            try expect(customMonitor.registeredKeys.isEmpty)
            try expect(
                feature.notice?.kind == .fellBackToFunctionKey(.editingConflict)
            )
            try expect(feature.notice?.level == .warning)
            let persistedFallback = await persistence.values
            try expect(persistedFallback == [.functionKey])
        }

        await runAsync("shortcut feature rejects unsafe single-modifier typing chords", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    await persistence.save(preference)
                }
            )
            let shiftA = CustomHotKey(
                keyCode: 0,
                modifiers: 512,
                displayName: "⇧ A"
            )

            feature.select(.init(customHotKey: shiftA))
            await feature.flushPersistence()

            try expect(feature.preference == .functionKey)
            try expect(functionMonitor.startCount == 1)
            try expect(customMonitor.registeredKeys.isEmpty)
            try expect(
                feature.notice?.kind == .fellBackToFunctionKey(.unsafeShortcut)
            )
            let persistedFallback = await persistence.values
            try expect(persistedFallback == [.functionKey])
        }

        await runAsync("shortcut feature reports when both a custom key and Fn cannot activate", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake(
                startResult: .eventTapUnavailable
            )
            let customMonitor = CustomShortcutMonitorFake(
                registerResult: .hotKeyRegistrationUnavailable(status: -9876)
            )
            let persistence = ShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    await persistence.save(preference)
                }
            )

            feature.select(.init(customHotKey: .optionSpace))
            await feature.flushPersistence()
            try expect(feature.preference == .functionKey)
            try expect(customMonitor.registeredKeys == [.optionSpace])
            try expect(functionMonitor.startCount == 1)
            try expect(
                feature.notice?.kind == .fallbackUnavailable(
                    .activationFailed(
                        .hotKeyRegistrationUnavailable(status: -9876)
                    ),
                    .eventTapUnavailable
                )
            )
            try expect(feature.activation == .unavailable(.functionKey))
            let persistedFallback = await persistence.values
            try expect(persistedFallback == [.functionKey])
        }

        await runAsync("shortcut feature load and synchronization never rewrite a valid preference", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    await persistence.save(preference)
                }
            )

            feature.restore(.functionKey)
            feature.synchronize()
            await feature.flushPersistence()
            try expect(functionMonitor.startCount == 1)
            let persistedPreferences = await persistence.values
            try expect(persistedPreferences.isEmpty)
        }

        await runAsync("shortcut feature stops every trigger source before shutdown", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    await persistence.save(preference)
                }
            )

            feature.restore(.init(customHotKey: .optionSpace))
            try expect(customMonitor.isRegistered)
            feature.beginShutdown()
            try expect(!functionMonitor.isRunning)
            try expect(!customMonitor.isRegistered)
            try expect(functionMonitor.stopCount >= 1)
            try expect(customMonitor.unregisterCount >= 1)
            feature.restore(.functionKey)
            feature.retryActivation()
            try expect(feature.activation == .stopped)
            try expect(!functionMonitor.isRunning)
        }

        await runAsync("shortcut feature persists rapid selections in command order", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    if case .custom = preference {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    await persistence.save(preference)
                }
            )
            let customPreference = VoiceShortcutPreference(
                customHotKey: .optionSpace
            )

            feature.select(customPreference)
            feature.select(.functionKey)
            await feature.flushPersistence()

            let persistedPreferences = await persistence.values
            try expect(persistedPreferences == [customPreference, .functionKey])
            try expect(feature.preference == .functionKey)
        }

        await runAsync("shortcut feature ignores a late settings restore after user selection", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    await persistence.save(preference)
                }
            )
            let selected = VoiceShortcutPreference(customHotKey: .optionSpace)

            feature.select(selected)
            feature.restore(.functionKey)
            await feature.flushPersistence()

            try expect(feature.preference == selected)
            try expect(feature.activation == .active(selected))
            try expect(customMonitor.registeredKeys == [.optionSpace])
            let persistedPreferences = await persistence.values
            try expect(persistedPreferences == [selected])
        }

        await runAsync("shortcut feature persists an explicit Fn choice even when activation fails", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake(
                startResult: .eventTapUnavailable
            )
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    await persistence.save(preference)
                }
            )

            feature.select(.functionKey)
            await feature.flushPersistence()

            try expect(feature.activation == .unavailable(.functionKey))
            try expect(
                feature.notice?.kind
                    == .functionKeyActivationFailed(.eventTapUnavailable)
            )
            let persistedPreferences = await persistence.values
            try expect(persistedPreferences == [.functionKey])
        }

        await runAsync("shortcut feature retries the failed settings write instead of only restarting monitors", failures: &failures) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = FailOnceShortcutPersistenceFake()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    try await persistence.save(preference)
                }
            )

            feature.select(.functionKey)
            await feature.flushPersistence()
            try expect(feature.notice?.recovery == .retryPersistence)

            feature.retryPersistence()
            await feature.flushPersistence()
            try expect(feature.notice == nil)
            try expect(
                feature.persistenceConfirmation == .functionKey
            )
            let persistedPreferences = await persistence.values
            try expect(persistedPreferences == [.functionKey])
        }

        run("Fn trigger ignores secondary-function flags from navigation keys", failures: &failures) {
            var policy = FunctionKeyFlagEventPolicy()

            for modifier in [CGEventFlags.maskCommand, .maskAlternate] {
                for keyCode in [kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow] {
                    try expect(
                        policy.handle(
                            keyCode: Int64(keyCode),
                            flags: modifier.union(.maskSecondaryFn)
                        ) == .passThrough
                    )
                    try expect(
                        policy.handle(
                            keyCode: Int64(keyCode),
                            flags: modifier
                        ) == .passThrough
                    )
                }
            }

            try expect(
                policy.handle(
                    keyCode: Int64(kVK_Function),
                    flags: .maskSecondaryFn
                ) == .consume(.pressed)
            )
            try expect(
                policy.handle(
                    keyCode: Int64(kVK_Function),
                    flags: []
                ) == .consume(.released)
            )
        }

        run("Escape is consumed only during an active Speaker interaction", failures: &failures) {
            var policy = EscapeKeyEventPolicy()
            try expect(policy.handle(.keyDown, speakerIsActive: false) == .passThrough)
            try expect(policy.handle(.keyUp, speakerIsActive: false) == .passThrough)

            try expect(policy.handle(.keyDown, speakerIsActive: true) == .consumeAndCancel)
            try expect(policy.handle(.keyDown, speakerIsActive: false) == .consume)
            try expect(policy.handle(.keyUp, speakerIsActive: false) == .consume)
            try expect(policy.handle(.keyDown, speakerIsActive: false) == .passThrough)
        }

        run("Escape ownership resets when its event monitor recovers", failures: &failures) {
            var policy = EscapeKeyEventPolicy()
            try expect(
                policy.handle(.keyDown, speakerIsActive: true)
                    == .consumeAndCancel
            )
            policy.reset()
            try expect(
                policy.handle(.keyDown, speakerIsActive: false)
                    == .passThrough
            )
        }
    }
}
