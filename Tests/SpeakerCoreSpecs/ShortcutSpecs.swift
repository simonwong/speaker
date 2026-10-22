import ApplicationServices
@preconcurrency import Carbon
import Foundation
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
                (4, 256),  // Command-H
                (46, 256),  // Command-M
                (31, 256),  // Command-O
                (15, 256),  // Command-R
                (43, 256),  // Command-comma
                (6, 256 | 512),  // Command-Shift-Z
            ]
            for (keyCode, modifiers) in commandMenuCases {
                try expect(
                    CustomHotKey(
                        keyCode: keyCode,
                        modifiers: modifiers,
                        displayName: "menu shortcut"
                    ).conflictsWithCommonEditingShortcut)
            }
        }

        run("global voice triggers cannot overlap ordinary modified typing", failures: &failures) {
            let unsafeCases: [(UInt32, UInt32)] = [
                (0, 512),  // Shift-A
                (0, 2_048),  // Option-A / dead-key and symbol input
                (0, 4_096),  // Control-A / terminal input
                (0, 512 | 4_096),  // Control-Shift-A still has one intent modifier
                (49, 512),  // Shift-Space
            ]
            for (keyCode, modifiers) in unsafeCases {
                try expect(
                    !CustomHotKey(
                        keyCode: keyCode,
                        modifiers: modifiers,
                        displayName: "unsafe typing chord"
                    ).isSafeForGlobalVoiceInput)
            }

            try expect(CustomHotKey.optionSpace.isSafeForGlobalVoiceInput)
            try expect(
                CustomHotKey(
                    keyCode: 40,
                    modifiers: 2_048 | 4_096,
                    displayName: "⌃⌥ K"
                ).isSafeForGlobalVoiceInput)
        }

        run(
            "a selected physical Option Control or Shift key is a safe exclusive trigger",
            failures: &failures
        ) {
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
            guard
                var policy = ModifierOnlyFlagEventPolicy(
                    hotKey: rightOption
                )
            else {
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

        await runAsync(
            "shortcut feature waits for Accessibility and activates the saved choice later",
            failures: &failures
        ) {
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

        await runAsync(
            "shortcut feature rejects editing conflicts and persists its Fn fallback",
            failures: &failures
        ) {
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

        await runAsync(
            "shortcut feature rejects unsafe single-modifier typing chords", failures: &failures
        ) {
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

        await runAsync(
            "shortcut feature reports when both a custom key and Fn cannot activate",
            failures: &failures
        ) {
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
                feature.notice?.kind
                    == .fallbackUnavailable(
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

        await runAsync(
            "shortcut feature load and synchronization never rewrite a valid preference",
            failures: &failures
        ) {
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

        await runAsync(
            "shortcut feature stops every trigger source before shutdown", failures: &failures
        ) {
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

        await runAsync(
            "shortcut feature persists rapid selections in command order", failures: &failures
        ) {
            let functionMonitor = FunctionKeyMonitorFake()
            let customMonitor = CustomShortcutMonitorFake()
            let persistence = ShortcutPersistenceFake()
            let customPersistence = OneShotGate()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: customMonitor,
                accessibilityGranted: { true },
                persistPreference: { preference in
                    if case .custom = preference {
                        await customPersistence.wait()
                    }
                    await persistence.save(preference)
                }
            )
            let customPreference = VoiceShortcutPreference(
                customHotKey: .optionSpace
            )

            feature.select(customPreference)
            feature.select(.functionKey)
            await customPersistence.open()
            await feature.flushPersistence()

            let persistedPreferences = await persistence.values
            try expect(persistedPreferences == [customPreference, .functionKey])
            try expect(feature.preference == .functionKey)
        }

        await runAsync(
            "shortcut feature ignores a late settings restore after user selection",
            failures: &failures
        ) {
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

        await runAsync(
            "shortcut feature persists an explicit Fn choice even when activation fails",
            failures: &failures
        ) {
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

        await runAsync(
            "shortcut feature retries the failed settings write instead of only restarting monitors",
            failures: &failures
        ) {
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

        run("Fn trigger ignores secondary-function flags from navigation keys", failures: &failures)
        {
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

        run(
            "idle shortcut taps observe key events only after a shortcut press", failures: &failures
        ) {
            var state = ShortcutEventTapState(
                flagTrigger: .functionKey(FunctionKeyFlagEventPolicy())
            )
            try expect(state.observesModifierFlags)
            try expect(!state.observesKeyEvents)

            let press = state.modifierFlagsChanged(
                keyCode: Int64(kVK_Function),
                flags: .maskSecondaryFn,
                secureInputEnabled: { false }
            )
            try expect(
                press
                    == .init(
                        consumesEvent: true,
                        effects: [.send(.pressed), .startSecureInputPolling]
                    )
            )
            try expect(state.observesKeyEvents, "Escape was not armed by the press")

            let typing = state.keyEvent(
                keyCode: Int64(kVK_ANSI_A),
                isKeyDown: true,
                speakerIsActive: { true }
            )
            try expect(typing == .init(consumesEvent: false, effects: []))
            try expect(state.observesKeyEvents)

            let escapeDown = state.keyEvent(
                keyCode: Int64(kVK_Escape),
                isKeyDown: true,
                speakerIsActive: { true }
            )
            try expect(
                escapeDown
                    == .init(
                        consumesEvent: true,
                        effects: [.stopSecureInputPolling, .send(.cancel)]
                    )
            )
            // The session ends before Escape is released; its key-up still
            // belongs to Speaker, so the key tap stays armed for it.
            let escapeUp = state.keyEvent(
                keyCode: Int64(kVK_Escape),
                isKeyDown: false,
                speakerIsActive: { false }
            )
            try expect(escapeUp == .init(consumesEvent: true, effects: []))
            try expect(!state.observesKeyEvents, "Escape stayed armed after the session")
        }

        run(
            "Escape stays armed while Speaker owns it and disarms on the next key",
            failures: &failures
        ) {
            var state = ShortcutEventTapState(flagTrigger: .none)
            try expect(!state.observesModifierFlags)
            try expect(
                state.shortcutPressed(secureInputEnabled: false)
                    == [.send(.pressed), .startSecureInputPolling]
            )
            try expect(state.shortcutReleased() == [.stopSecureInputPolling, .send(.released)])

            // A retained result still owns Escape after the press ends.
            _ = state.keyEvent(
                keyCode: Int64(kVK_ANSI_A), isKeyDown: true, speakerIsActive: { true })
            try expect(state.observesKeyEvents)

            let afterDismissal = state.keyEvent(
                keyCode: Int64(kVK_Escape),
                isKeyDown: true,
                speakerIsActive: { false }
            )
            try expect(afterDismissal == .init(consumesEvent: false, effects: []))
            try expect(!state.observesKeyEvents)
        }

        run(
            "a shortcut press refused by Secure Event Input does not arm Escape",
            failures: &failures
        ) {
            var state = ShortcutEventTapState(
                flagTrigger: .functionKey(FunctionKeyFlagEventPolicy())
            )
            let press = state.modifierFlagsChanged(
                keyCode: Int64(kVK_Function),
                flags: .maskSecondaryFn,
                secureInputEnabled: { true }
            )
            try expect(
                press == .init(consumesEvent: true, effects: [.reportSecureInputBlockedPress])
            )
            try expect(!state.observesKeyEvents)
            let release = state.modifierFlagsChanged(
                keyCode: Int64(kVK_Function),
                flags: [],
                secureInputEnabled: { false }
            )
            try expect(release == .init(consumesEvent: true, effects: [.stopSecureInputPolling]))
        }

        run("Secure Event Input during a held shortcut cancels the press once", failures: &failures)
        {
            var state = ShortcutEventTapState(flagTrigger: .none)
            _ = state.shortcutPressed(secureInputEnabled: false)
            try expect(state.secureInputPollFired(secureInputEnabled: { false }).isEmpty)
            try expect(
                state.secureInputPollFired(secureInputEnabled: { true })
                    == [.stopSecureInputPolling, .send(.cancel)]
            )
            try expect(state.secureInputPollFired(secureInputEnabled: { true }).isEmpty)
            try expect(state.shortcutReleased() == [.stopSecureInputPolling])
        }

        run("a shortcut tap disabled by macOS cancels the press and recovers", failures: &failures)
        {
            var state = ShortcutEventTapState(
                flagTrigger: .functionKey(FunctionKeyFlagEventPolicy())
            )
            _ = state.modifierFlagsChanged(
                keyCode: Int64(kVK_Function),
                flags: .maskSecondaryFn,
                secureInputEnabled: { false }
            )
            try expect(
                state.tapDisabled(.modifierFlags)
                    == [
                        .stopSecureInputPolling,
                        .send(.cancel),
                        .reenableModifierFlagTap,
                        .send(.monitorRecovered),
                    ]
            )
            try expect(!state.observesKeyEvents)
            // The release that follows belongs to the cancelled press.
            let release = state.modifierFlagsChanged(
                keyCode: Int64(kVK_Function),
                flags: [],
                secureInputEnabled: { false }
            )
            try expect(release == .init(consumesEvent: false, effects: []))
        }

        run("the key tap Speaker disarmed itself is not a lost monitor", failures: &failures) {
            var state = ShortcutEventTapState(
                flagTrigger: .functionKey(FunctionKeyFlagEventPolicy())
            )
            try expect(state.tapDisabled(.keys).isEmpty)
        }

        run("stopping shortcut taps cancels only a press in progress", failures: &failures) {
            var idle = ShortcutEventTapState(flagTrigger: .none)
            try expect(idle.stop() == [.stopSecureInputPolling])

            var pressed = ShortcutEventTapState(flagTrigger: .none)
            _ = pressed.shortcutPressed(secureInputEnabled: false)
            try expect(pressed.stop() == [.stopSecureInputPolling, .send(.cancel)])
            try expect(!pressed.observesKeyEvents)
        }

        run("shortcut event taps run on their own user-interactive thread", failures: &failures) {
            let thread = ShortcutEventTapThread.shared
            let observed = thread.performAndWait {
                (Thread.isMainThread, Thread.current.qualityOfService, thread.isCurrent)
            }
            try expect(!observed.0, "the tap thread is the main thread")
            try expect(observed.1 == .userInteractive)
            try expect(observed.2)
            try expect(!thread.isCurrent)

            // Work reaches the tap thread while the main thread is blocked,
            // so a busy main thread cannot hold global key events.
            let reached = DispatchSemaphore(value: 0)
            thread.perform { reached.signal() }
            try expect(
                reached.wait(timeout: .now() + 5) == .success,
                "the tap thread waited for the main thread"
            )
        }
    }
}
