import Foundation
import Darwin
import AVFoundation
import SpeakerCore
import SQLite3

@main
struct SpeakerCoreSpecs {
    @MainActor
    static func main() async {
        var failures: [String] = []

        await runAsync("PCM streaming emits consecutive chunks without crashing", failures: &failures) {
            var buffer = PCMChunkBuffer(chunkSize: 6_400)
            let chunks = buffer.append(Data(repeating: 1, count: 12_800))
            try expect(chunks.count == 2)
            try expect(chunks.allSatisfy { $0.count == 6_400 })
        }

        await runAsync("audio stream terminates instead of silently dropping when its byte budget is exhausted", failures: &failures) {
            let exhaustion = LockedCounter()
            let buffer = BoundedAudioChunkStream(
                maximumBufferedBytes: 12,
                nominalChunkSize: 4,
                onBufferExhausted: { exhaustion.increment() }
            )
            try expect(buffer.yield(Data(repeating: 1, count: 4)) == .accepted)
            try expect(buffer.yield(Data(repeating: 2, count: 4)) == .accepted)
            try expect(buffer.yield(Data(repeating: 3, count: 4)) == .accepted)
            try expect(buffer.yield(Data(repeating: 4, count: 4)) == .bufferExhausted)
            try expect(buffer.yield(Data(repeating: 5, count: 4)) == .terminated)
            try expect(buffer.didExhaustBuffer)
            try expect(exhaustion.value == 1)

            var received: [Data] = []
            for await chunk in buffer.stream {
                received.append(chunk)
            }
            try expect(received.count == 3)
        }

        run("PID Unicode delivery is disabled unless the exact App was verified", failures: &failures) {
            try expect(!AccessibilityInputTargets.allowsUnicodeDelivery(
                to: "com.example.Editor",
                verifiedBundleIdentifiers: []
            ))
            try expect(!AccessibilityInputTargets.allowsUnicodeDelivery(
                to: nil,
                verifiedBundleIdentifiers: ["com.example.Editor"]
            ))
            try expect(AccessibilityInputTargets.allowsUnicodeDelivery(
                to: "com.example.Editor",
                verifiedBundleIdentifiers: ["com.example.Editor"]
            ))
        }

        await runAsync(
            "untrusted AX capture reports the permission boundary",
            failures: &failures
        ) {
            let system = LiveAccessibilityTargetSystem(
                isProcessTrusted: { false }
            )

            let capture = await system.captureFocusedTarget()

            guard case .unavailable(.accessibilityPermissionMissing) = capture
            else {
                throw SpecFailure(
                    message: "missing Accessibility permission was misreported as a target capability"
                )
            }
        }

        await runAsync("AX capture accepts the exact expected process", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                processID: 42,
                valueResponses: []
            )
            let targets = AccessibilityInputTargets(system: system)

            guard case .writable = await targets.capture(
                expectedProcessID: 42
            ) else {
                throw SpecFailure(
                    message: "the exact expected process was rejected"
                )
            }
        }

        await runAsync("AX capture rejects a focused target from another process", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                processID: 84,
                valueResponses: []
            )
            let targets = AccessibilityInputTargets(system: system)

            let capture = await targets.capture(expectedProcessID: 42)

            try expect(
                capture == .unavailable(.invalidatedTarget),
                "a different process crossed the exact-target capture seam"
            )
        }

        await runAsync(
            "release-time AX capture cannot follow focus to another field in the same process",
            failures: &failures
        ) {
            let releasedField = AccessibilityTargetReference()
            let system = AccessibilityTargetSystemFake(
                processID: 42,
                valueResponses: []
            )
            let targets = AccessibilityInputTargets(
                system: system,
                releaseCapture: {
                    .target(.init(
                        reference: releasedField,
                        processID: 42
                    ))
                }
            )
            guard let hint = targets.releaseCaptureHint() else {
                throw SpecFailure(message: "release target hint was not frozen")
            }

            let capture = await targets.capture(matching: hint)
            let focusedCaptureCount = await system.captureFocusedCallCount
            let exactCaptureCount = await system.captureTargetCallCount

            try expect(capture == .unavailable(.invalidatedTarget))
            try expect(
                focusedCaptureCount == 0,
                "capture followed the current focused element after release"
            )
            try expect(exactCaptureCount == 1)
        }

        await runAsync("AX accepted insertion is not downgraded by stale immediate readback", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )

            try expect(
                outcome == .delivered,
                "AX accepted the mutation but stale readback produced pending-copy"
            )
        }

        await runAsync("AX mutation without a receipt warns before manual copy", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )

            try expect(
                outcome.pendingCopyReason == .deliveryUnconfirmed
            )
            try expect(
                outcome.deliveryDiagnostic?.code
                    == "directReceipt.unconfirmed"
            )
        }

        await runAsync("normalized AX mutation remains unconfirmed instead of inviting duplicate copy", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world\n"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )

            try expect(
                outcome.pendingCopyReason == .deliveryUnconfirmed
            )
            try expect(
                outcome.deliveryDiagnostic?.code
                    == "directReceipt.unconfirmed"
            )
        }

        await runAsync("uncertain AX text mutation waits for a receipt instead of duplicating fallback", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ],
                setSelectedTextResponses: [
                    .failure(.cannotComplete),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let unicodePosts = await system.postUnicodeCallCount

            try expect(outcome == .delivered)
            try expect(
                unicodePosts == 0,
                "an uncertain direct mutation triggered a duplicate fallback"
            )
        }

        await runAsync("direct AX insertion never restores a stale release-time selection", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ],
                setSelectionResponses: [
                    .failure(.cannotComplete),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let selectionAttempts = await system.setSelectionCallCount

            try expect(outcome == .delivered)
            try expect(
                selectionAttempts == 0,
                "delivery rewrote the user's current selection before inserting text"
            )
        }

        await runAsync("unchanged AX selection can proceed when range setter is unsupported", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ],
                setSelectionResponses: [
                    .failure(.attributeUnsupported),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let directInsertions = await system.setSelectedTextCallCount
            let unicodePosts = await system.postUnicodeCallCount

            try expect(outcome == .delivered)
            try expect(directInsertions == 1)
            try expect(
                unicodePosts == 0,
                "unchanged selection unnecessarily fell through to key events"
            )
        }

        await runAsync(
            "moved AX selection fails closed before direct mutation",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                ],
                selectionResponses: [
                    .success(NSRange(location: 0, length: 0)),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let selectionWrites = await system.setSelectionCallCount
            let textWrites = await system.setSelectedTextCallCount

            try expect(outcome.pendingCopyReason == .changedTarget)
            try expect(selectionWrites == 0)
            try expect(
                textWrites == 0,
                "delivery restored an old cursor after the user moved it"
            )
        }

        await runAsync("changed AX target content is never overwritten", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [.success("User edited this")]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let insertionAttempts = await system.setSelectedTextCallCount

            try expect(outcome.pendingCopyReason == .changedTarget)
            try expect(
                outcome.deliveryDiagnostic?.code
                    == "valueRead.changed"
            )
            try expect(insertionAttempts == 0)
        }

        await runAsync("AX value IPC failure is reported as an unresponsive target instead of a focus change", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [.failure(.cannotComplete)]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let insertionAttempts = await system.setSelectedTextCallCount

            try expect(
                outcome.pendingCopyReason == .targetApplicationUnresponsive
            )
            try expect(outcome.deliveryDiagnostic?.code == "valueRead.cannotComplete")
            try expect(insertionAttempts == 0)
        }

        await runAsync("AX role and security IPC failures preserve their exact diagnostic stage", failures: &failures) {
            let securitySystem = AccessibilityTargetSystemFake(
                valueResponses: [],
                subroleResponses: [.failure(.cannotComplete)]
            )
            let securityTargets = AccessibilityInputTargets(system: securitySystem)
            guard case let .writable(securityTarget) = await securityTargets.capture()
            else {
                throw SpecFailure(message: "security fake target was not captured")
            }
            let securityOutcome = await securityTargets.deliver(
                " world",
                to: securityTarget,
                commitGate: DeliveryCommitGate()
            )
            try expect(
                securityOutcome.pendingCopyReason
                    == .targetApplicationUnresponsive
            )
            try expect(
                securityOutcome.deliveryDiagnostic?.code
                    == "securityRead.cannotComplete"
            )

            let roleSystem = AccessibilityTargetSystemFake(
                valueResponses: [],
                roleResponses: [.failure(.cannotComplete)]
            )
            let roleTargets = AccessibilityInputTargets(system: roleSystem)
            guard case let .writable(roleTarget) = await roleTargets.capture()
            else {
                throw SpecFailure(message: "role fake target was not captured")
            }
            let roleOutcome = await roleTargets.deliver(
                " world",
                to: roleTarget,
                commitGate: DeliveryCommitGate()
            )
            try expect(
                roleOutcome.pendingCopyReason
                    == .targetApplicationUnresponsive
            )
            try expect(
                roleOutcome.deliveryDiagnostic?.code
                    == "roleRead.cannotComplete"
            )
        }

        await runAsync("AX selection and fallback focus IPC failures are not called user edits", failures: &failures) {
            let selectionSystem = AccessibilityTargetSystemFake(
                valueResponses: [.success("Hello")],
                selectionResponses: [.failure(.cannotComplete)]
            )
            let selectionTargets = AccessibilityInputTargets(system: selectionSystem)
            guard case let .writable(selectionTarget) = await selectionTargets.capture()
            else {
                throw SpecFailure(message: "selection fake target was not captured")
            }
            let selectionOutcome = await selectionTargets.deliver(
                " world",
                to: selectionTarget,
                commitGate: DeliveryCommitGate()
            )
            try expect(
                selectionOutcome.pendingCopyReason
                    == .targetApplicationUnresponsive
            )
            try expect(
                selectionOutcome.deliveryDiagnostic?.code
                    == "directSelection.cannotComplete"
            )

            let focusSystem = AccessibilityTargetSystemFake(
                supportsDirectInsertion: false,
                valueResponses: [.success("Hello")],
                focusResponses: [.failure(.cannotComplete)]
            )
            let focusTargets = AccessibilityInputTargets(system: focusSystem)
            guard case let .writable(focusTarget) = await focusTargets.capture()
            else {
                throw SpecFailure(message: "focus fake target was not captured")
            }
            let focusOutcome = await focusTargets.deliver(
                " world",
                to: focusTarget,
                commitGate: DeliveryCommitGate()
            )
            try expect(
                focusOutcome.pendingCopyReason
                    == .targetApplicationUnresponsive
            )
            try expect(
                focusOutcome.deliveryDiagnostic?.code
                    == "focusRead.cannotComplete"
            )
        }

        await runAsync("frontmost exact AX target can use receipt-verified Unicode fallback", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                supportsDirectInsertion: false,
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let unicodePosts = await system.postUnicodeCallCount

            try expect(outcome == .delivered)
            try expect(
                unicodePosts == 1,
                "standard focused target never reached Unicode fallback"
            )
        }

        await runAsync("unverified background AX target never receives Unicode events", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                supportsDirectInsertion: false,
                isFrontmost: false,
                valueResponses: [.success("Hello")]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let unicodePosts = await system.postUnicodeCallCount

            try expect(
                outcome.pendingCopyReason == .unsupportedTarget
            )
            try expect(
                outcome.deliveryDiagnostic?.code
                    == "fallbackEligibility.notFrontmost"
            )
            try expect(unicodePosts == 0)
        }

        await runAsync("rejected direct AX insertion retains its exact delivery boundary", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                isFrontmost: false,
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello"),
                ],
                setSelectedTextResponses: [
                    .failure(.other),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )

            try expect(outcome.pendingCopyReason == .deliveryFailed)
            try expect(
                outcome.deliveryDiagnostic?.code
                    == "directWrite.other"
            )
        }

        await runAsync("rejected Unicode fallback retains its exact delivery boundary", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                supportsDirectInsertion: false,
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                ],
                postUnicodeSucceeds: false
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case let .writable(target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )

            try expect(outcome.pendingCopyReason == .deliveryFailed)
            try expect(
                outcome.deliveryDiagnostic?.code
                    == "unicodePost.rejected"
            )
        }

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
            try expect(feature.notice?.message.contains("辅助功能权限") == true)
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
                feature.notice?.message
                    == "这个组合键可能与 macOS 或当前 App 的菜单命令冲突，已继续使用 Fn。"
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
                feature.notice?.message.contains("单个修饰键可能干扰正常输入")
                    == true
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
            try expect(feature.notice?.message.contains("系统未接受这个自定义快捷键") == true)
            try expect(feature.notice?.message.contains("无法创建 Fn 键的系统事件监听") == true)
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
            try expect(feature.notice?.message == "无法创建 Fn 键的系统事件监听。")
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
                feature.persistenceConfirmation == "Fn 快捷键设置已保存。"
            )
            let persistedPreferences = await persistence.values
            try expect(persistedPreferences == [.functionKey])
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

        run("provider diagnostics remove controls and cap untrusted messages", failures: &failures) {
            let diagnostic = VoiceProviderDiagnostic(
                provider: "doubao\nspoofed",
                requestID: " request\t123 ",
                message: String(repeating: "x", count: 1_200) + "\u{0000}tail"
            )
            try expect(diagnostic.provider == "doubao spoofed")
            try expect(diagnostic.requestID == "request 123")
            try expect(diagnostic.message?.count == 1_000)
            try expect(!(diagnostic.message?.contains("\u{0000}") ?? true))
        }

        run("diagnostic refinement kind never includes a custom user label", failures: &failures) {
            let mode = TextRefinementMode.custom(
                name: "客户甲绝密项目",
                prompt: "把内容写成内部项目更新"
            )
            try expect(mode.diagnosticKind == "custom")
            try expect(!mode.diagnosticKind.contains("客户甲"))
        }

        run("microphone denial is distinct from an unknown recording-device failure", failures: &failures) {
            let denied = VoiceInputProblem(
                audioCaptureError: .microphonePermissionDenied
            )
            let deviceFailure = VoiceInputProblem(
                audioCaptureError: .couldNotStart
            )
            try expect(denied.failure == .microphonePermissionDenied)
            try expect(deviceFailure.failure == .recordingFailed)
        }

        run("audio quality rejects only definite local silence", failures: &failures) {
            try AudioCaptureQualityPolicy.validate(
                duration: .seconds(1),
                peakPower: -50
            )
            do {
                try AudioCaptureQualityPolicy.validate(
                    duration: .seconds(1),
                    peakPower: -160
                )
                throw SpecFailure(message: "digital silence was accepted")
            } catch let failure as AudioCaptureError {
                try expect(failure == .silent)
            }
            do {
                try AudioCaptureQualityPolicy.validate(
                    duration: .milliseconds(299),
                    peakPower: -10
                )
                throw SpecFailure(message: "sub-300 ms recording was accepted")
            } catch let failure as AudioCaptureError {
                try expect(failure == .tooShort)
            }
        }

        run("provider networking does not persist cookies credentials or cache", failures: &failures) {
            let configuration = ProviderURLSessionFactory.ephemeralConfiguration()
            try expect(configuration.urlCache == nil)
            try expect(configuration.httpCookieStorage == nil)
            try expect(configuration.urlCredentialStorage == nil)
            try expect(!configuration.httpShouldSetCookies)
            try expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        }

        run("initial snapshot comes from permission access", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .notDetermined)
            )

            let model = PermissionModel(access: access)

            try expect(model.snapshot == .init(
                accessibility: .denied,
                microphone: .notDetermined
            ))
            try expect(!model.snapshot.allGranted)
        }

        run("refresh publishes current permission snapshot", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .denied)
            )
            let model = PermissionModel(access: access)
            access.snapshot = .init(accessibility: .granted, microphone: .granted)

            model.refresh()

            try expect(model.snapshot == .init(
                accessibility: .granted,
                microphone: .granted
            ))
            try expect(model.snapshot.allGranted)
        }

        run("restricted microphone authorization remains distinct from denial", failures: &failures) {
            try expect(
                SystemPermissionAccess.microphoneState(for: .restricted)
                    == .restricted
            )
            try expect(
                SystemPermissionAccess.microphoneState(for: .denied)
                    == .denied
            )
            let snapshot = PermissionSnapshot(
                accessibility: .granted,
                microphone: .restricted
            )
            try expect(!snapshot.allGranted)
        }

        run("permission requests resolve to one unambiguous system action", failures: &failures) {
            try expect(
                SystemPermissionAccess.requestPlan(
                    for: .accessibility,
                    state: .denied
                ) == .openSystemSettings(anchor: "Privacy_Accessibility")
            )
            try expect(
                SystemPermissionAccess.requestPlan(
                    for: .microphone,
                    state: .notDetermined
                ) == .requestMicrophone
            )
            try expect(
                SystemPermissionAccess.requestPlan(
                    for: .microphone,
                    state: .denied
                ) == .openSystemSettings(anchor: "Privacy_Microphone")
            )
            try expect(
                SystemPermissionAccess.requestPlan(
                    for: .microphone,
                    state: .restricted
                ) == .none
            )
        }

        await runAsync("request updates snapshot with provider result", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .granted)
            )
            access.requestResults[.accessibility] = .init(
                accessibility: .granted,
                microphone: .granted
            )
            let model = PermissionModel(access: access)

            await model.request(.accessibility)

            try expect(access.requestedPermissions == [.accessibility])
            try expect(model.snapshot == .init(
                accessibility: .granted,
                microphone: .granted
            ))
        }

        await runAsync("first launch requests an undetermined microphone once", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .notDetermined)
            )
            access.requestResults[.microphone] = .init(
                accessibility: .denied,
                microphone: .granted
            )
            let model = PermissionModel(access: access)

            await model.requestMicrophoneIfNeeded()
            await model.requestMicrophoneIfNeeded()

            try expect(access.requestedPermissions == [.microphone])
            try expect(model.snapshot.microphone == .granted)
        }

        await runAsync("first launch does not reprompt a denied microphone", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .denied)
            )
            let model = PermissionModel(access: access)

            await model.requestMicrophoneIfNeeded()

            try expect(access.requestedPermissions.isEmpty)
        }

        await runAsync("first launch requests missing accessibility for the active bundle", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .granted)
            )
            let model = PermissionModel(access: access)

            await model.requestAccessibilityIfNeeded()

            try expect(access.requestedPermissions == [.accessibility])
        }

        await runAsync("hold and release delivers deterministic transcript", failures: &failures) {
            let audio = AudioCaptureFake()
            let targets = TargetCaptureFake(
                result: .writable(.init(
                    id: UUID(),
                    applicationName: "TextEdit"
                ))
            )
            let transcriber = SpeechTranscriberFake(text: "你好，SwiftUI。")
            let delivery = TextDeliveryFake(result: .delivered)
            let clipboard = ClipboardFake()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                transcriber: transcriber,
                delivery: delivery,
                clipboard: clipboard,
                history: history
            )
            let presentations = await sessions.observe()
            let terminal = Task { () -> [VoiceInputPresentation] in
                var values: [VoiceInputPresentation] = []
                for await presentation in presentations {
                    values.append(presentation)
                    if presentation.activity.isTerminal {
                        break
                    }
                }
                return values
            }

            await sessions.send(.pressed)
            await sessions.send(.released)

            let values = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            let historyCommitted = await eventually(before: .seconds(1)) {
                await history.records.count == 1
            }
            let records = await history.records

            try expect(values.contains { $0.activity.isRecording })
            try expect(values.contains { $0.activity.stage == .transcribing })
            try expect(values.last?.activity.isDelivered == true)
            try expect(zip(values, values.dropFirst()).allSatisfy { $0.revision < $1.revision })
            try expect(deliveredTexts == ["你好，SwiftUI。"])
            try expect(
                historyCommitted,
                "terminal delivery was not committed to history"
            )
            try expect(records.count == 1)
            try expect(records.first?.finalText == "你好，SwiftUI。")
            try expect(records.first?.providerRequestID == "local-spec")
        }

        await runAsync("release during recorder startup still completes once", failures: &failures) {
            let audio = AudioCaptureFake(delaysStart: true)
            let targets = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
            )
            let transcriber = SpeechTranscriberFake(text: "短按也不会丢。")
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let press = Task { await sessions.send(.pressed) }
            while await audio.startCount == 0 {
                await Task.yield()
            }
            await sessions.send(.released)
            await audio.resumeStart()
            await press.value
            await Task.yield()

            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts

            try expect(stopCount == 1)
            try expect(deliveredTexts == ["短按也不会丢。"])
        }

        await runAsync("cancel during recorder startup cleans late recording", failures: &failures) {
            let audio = AudioCaptureFake(delaysStart: true)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "不应出现"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            let press = Task { await sessions.send(.pressed) }
            while await audio.startCount == 0 {
                await Task.yield()
            }
            await sessions.send(.cancel)
            await audio.resumeStart()
            await press.value

            let isActive = await audio.isActive
            try expect(!isActive)
        }

        await runAsync("recorder start failure preserves preparation timing", failures: &failures) {
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: DelayedFailingStartAudioCapture(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )

            await sessions.send(.pressed)
            await sessions.shutdown()

            let record = await history.records.last
            try expect(record?.outcome.isRecordingFailed == true)
            try expect((record?.durationMilliseconds ?? 0) > 0)
            try expect((record?.stageDurationsMilliseconds["preparing"] ?? 0) > 0)
        }

        await runAsync("missing target waits for explicit copy", failures: &failures) {
            let clipboard = ClipboardFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "请手动复制。"),
                delivery: delivery,
                clipboard: clipboard,
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            let copiedBefore = await clipboard.copiedTexts
            try expect(result?.activity.pendingCopyReason == .missingTarget)
            try expect(deliveredTexts.isEmpty)
            try expect(copiedBefore.isEmpty)
            while await history.records.last?.outcome.pendingCopyReason
                != .missingTarget
            {
                await Task.yield()
            }
            let record = await history.records.last
            try expect(
                record?.transcription == nil && record?.finalText == nil,
                "unclassified target persisted transcript body"
            )
            try expect(
                record?.outcome.pendingText == "",
                "unclassified target persisted body inside its outcome"
            )

            await sessions.send(.pressed)
            var retainedAfterNewPress: VoiceInputPresentation?
            for await presentation in await sessions.observe() {
                retainedAfterNewPress = presentation
                break
            }
            try expect(
                retainedAfterNewPress?.activity.pendingCopyReason
                    == .missingTarget,
                "a new recording discarded text awaiting explicit copy"
            )

            let hiddenAfterCopy = Task {
                for await presentation in await sessions.observe() {
                    if presentation.activity == .idle { return true }
                }
                return false
            }
            await sessions.send(.copyPendingResult)
            let copiedAfter = await clipboard.copiedTexts
            let didHideAfterCopy = await hiddenAfterCopy.value
            try expect(copiedAfter == ["请手动复制。"])
            try expect(didHideAfterCopy)
        }

        await runAsync("dismiss pending copy hides without changing clipboard", failures: &failures) {
            let clipboard = ClipboardFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "不要复制。"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)
            _ = await terminal.value

            let hiddenAfterDismiss = Task {
                for await presentation in await sessions.observe() {
                    if presentation.activity == .idle { return true }
                }
                return false
            }
            await sessions.send(.dismissResult)
            let didHideAfterDismiss = await hiddenAfterDismiss.value
            let copiedTexts = await clipboard.copiedTexts
            try expect(didHideAfterDismiss)
            try expect(copiedTexts.isEmpty)
        }

        await runAsync("failed clipboard write keeps the result visible for retry", failures: &failures) {
            let clipboard = ClipboardFake(succeeds: false)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "必须保留。"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            await sessions.send(.released)
            let clipboardFailure = Task<VoiceInputPresentation?, Never> {
                for await presentation in await sessions.observe() {
                    if presentation.activity.pendingCopyReason == .clipboardFailed {
                        return presentation
                    }
                }
                return nil
            }
            await sessions.send(.copyPendingResult)
            let presentation = await clipboardFailure.value

            try expect(presentation?.activity.pendingCopyReason == .clipboardFailed)
            try expect(presentation?.activity.pendingText == "必须保留。")
        }

        await runAsync("system clipboard reports success only after exact readback", failures: &failures) {
            let staleWriter = SystemClipboardWriter(
                pasteboard: ClipboardPasteboardAccess(
                    clearContents: {},
                    setString: { _ in true },
                    readString: { "previous clipboard value" }
                )
            )
            let confirmedWriter = SystemClipboardWriter(
                pasteboard: ClipboardPasteboardAccess(
                    clearContents: {},
                    setString: { _ in true },
                    readString: { "expected value" }
                )
            )

            let staleResult = await staleWriter.copy("expected value")
            let confirmedResult = await confirmedWriter.copy("expected value")
            try expect(!staleResult)
            try expect(confirmedResult)
        }

        await runAsync("secure target never receives automatic text", failures: &failures) {
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.secureTarget)),
                transcriber: SpeechTranscriberFake(text: "敏感文本"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            var record = await history.records.first
            while record?.outcome.pendingCopyReason != .secureTarget,
                  clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                record = await history.records.first
            }
            try expect(
                result?.activity.pendingCopyReason == .secureTarget,
                "secure-target terminal presentation was missing"
            )
            try expect(
                deliveredTexts.isEmpty,
                "secure text was sent to the delivery adapter"
            )
            try expect(
                record != nil,
                "secure-target history was not persisted"
            )
            try expect(
                record?.transcription == nil,
                "secure transcript was persisted"
            )
            try expect(
                record?.finalText == nil,
                "secure final text was persisted"
            )
            try expect(
                record?.providerRequestID == nil,
                "secure provider request identity was persisted"
            )
            try expect(
                record?.deepSeekRequestID == nil,
                "secure refinement request identity was persisted"
            )
            try expect(
                record?.outcome.pendingText == "",
                "secure text was persisted inside its outcome"
            )
            try expect(
                record?.deepSeekText == nil,
                "secure DeepSeek text was persisted"
            )
            try expect(
                record?.outcome.pendingText == "",
                "secure pending text was persisted"
            )
        }

        await runAsync(
            "secure target never persists confirmed text while refinement is pending",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-secure-inflight-history-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let refiner = CancellableDeepSeekRefinerFake()
            let history = SQLiteSessionHistory(fileURL: fileURL)
            let secret = "secure-inflight-sentinel-\(UUID().uuidString)"
            let processor = DefaultVoiceTextProcessor(
                configuration: VoiceInputConfigurationController(
                    refinementMode: .conciseCleanup
                ),
                doubao: ContextualTranscriberFake(text: secret),
                refinement: OptionalTextRefinementPipeline(refiner: refiner)
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .unavailable(.secureTarget)
                ),
                textProcessor: processor,
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )

            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await refiner.callCount == 0 { await Task.yield() }
            while await history.allRecords().last?.outcome.stage != .refining {
                await Task.yield()
            }

            let inFlightRecord = await history.allRecords().last
            try expect(
                inFlightRecord?.transcription == nil,
                "confirmed secure transcript reached non-terminal history"
            )
            try expect(
                inFlightRecord?.providerRequestID == nil,
                "secure request identity reached non-terminal history"
            )
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "confirmed secure transcript reached SQLite or WAL bytes"
            )

            await sessions.send(.cancel)
            await release.value
            while await history.allRecords().last?.outcome.isCancelled != true {
                await Task.yield()
            }
            let cancelledRecord = await history.allRecords().last
            try expect(
                cancelledRecord?.transcription == nil,
                "cancelling refinement persisted the secure transcript"
            )
            try expect(
                cancelledRecord?.providerRequestID == nil,
                "cancelling refinement persisted the secure request identity"
            )
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "cancelling refinement left the secure transcript in SQLite storage"
            )
        }

        await runAsync("delivery failure keeps transcript pending copy", failures: &failures) {
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "结果不能丢。"),
                delivery: TextDeliveryFake(
                    result: .pendingCopyDiagnosed(
                        .deliveryUnconfirmed,
                        .init(
                            stage: .directReceipt,
                            cause: .unconfirmed
                        )
                    )
                ),
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let persisted = await eventually(
                before: .milliseconds(300)
            ) {
                await history.records.first?
                    .deliveryDiagnosticCode != nil
            }
            let record = await history.records.first
            try expect(
                result?.activity.pendingCopyReason
                    == .deliveryUnconfirmed
            )
            try expect(result?.activity.pendingText == "结果不能丢。")
            try expect(persisted)
            try expect(
                record?.deliveryDiagnosticCode
                    == "directReceipt.unconfirmed"
            )
        }

        await runAsync("duplicate trigger edges submit only once", failures: &failures) {
            let audio = AudioCaptureFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "只提交一次。"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            await sessions.send(.pressed)
            await sessions.send(.released)
            await sessions.send(.released)

            let startCount = await audio.startCount
            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts
            try expect(startCount == 1)
            try expect(stopCount == 1)
            try expect(deliveredTexts == ["只提交一次。"])
        }

        await runAsync("input target is frozen when recording ends", failures: &failures) {
            let target = ReleaseTimeTargetCaptureFake(
                applicationName: "Before release"
            )
            let delivery = TargetRecordingDeliveryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: target,
                transcriber: SpeechTranscriberFake(text: "发往结束时的输入框"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            await target.update(applicationName: "Focused at release")
            let release = Task { await sessions.send(.released) }
            while await target.captureCallCount == 0 { await Task.yield() }
            await target.update(applicationName: "Focused after release")
            await target.resume()
            await release.value

            let deliveredApplicationNames = await delivery.applicationNames
            try expect(
                deliveredApplicationNames == ["Focused at release"],
                "focus changes after release replaced the captured delivery target"
            )
        }

        await runAsync(
            "global stop gesture freezes the target process before async capture",
            failures: &failures
        ) {
            let audio = AudioCaptureFake()
            let target = HintRecordingTargetCaptureFake(
                result: .unavailable(.missingTarget)
            )
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: target,
                transcriber: SpeechTranscriberFake(text: "不会送到后来切换的应用"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let hintSource = LockedCaptureHintSource(processID: 41)
            let dispatcher = VoiceInputTriggerDispatcher(
                sessions: sessions,
                releaseCaptureHint: { hintSource.hint }
            )

            dispatcher.send(.pressed, at: 0)
            while await audio.startCount == 0 { await Task.yield() }
            dispatcher.send(
                .released,
                at: VoiceShortcutGestureStateMachine
                    .defaultLongPressNanoseconds
            )
            hintSource.update(processID: 99)

            while await target.capturedProcessIDs.isEmpty {
                await Task.yield()
            }
            let capturedProcessIDs = await target.capturedProcessIDs
            try expect(
                capturedProcessIDs == [41],
                "target identity was read after the physical stop callback returned"
            )
            await dispatcher.shutdown()
        }

        await runAsync("global trigger dispatcher supports tap-to-start and tap-to-stop", failures: &failures) {
            let audio = AudioCaptureFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "顺序正确。"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)

            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_100_000_000)
            while await audio.startCount == 0 {
                await Task.yield()
            }
            let stopCountAfterFirstTap = await audio.stopCount
            dispatcher.send(.pressed, at: 2_000_000_000)
            dispatcher.send(.released, at: 2_050_000_000)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            dispatcher.finish()
            try expect(stopCountAfterFirstTap == 0)
            try expect(result?.activity.isDelivered == true)
            try expect(deliveredTexts == ["顺序正确。"])
        }

        await runAsync("terminal result is published before blocked history persistence", failures: &failures) {
            let history = BlockingSessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "先把结果交给用户"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)
            let presentation = await terminal.value

            try expect(
                presentation?.activity.pendingText == "先把结果交给用户",
                "history I/O blocked the user-visible terminal result"
            )

            let shutdown = Task { await sessions.shutdown() }
            await history.unblock()
            await shutdown.value
        }

        await runAsync("processing-time shortcut presses are rejected instead of delayed", failures: &failures) {
            let audio = AudioCaptureFake()
            let transcriber = SpeechTranscriberFake(
                text: "处理完成",
                delaysResponse: true
            )
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: transcriber,
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            let terminal = terminalPresentation(from: await sessions.observe())

            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_050_000_000)
            while await audio.startCount == 0 { await Task.yield() }
            dispatcher.send(.pressed, at: 2_000_000_000)
            dispatcher.send(.released, at: 2_050_000_000)
            while await transcriber.callCount == 0 { await Task.yield() }

            dispatcher.send(.pressed, at: 3_000_000_000)
            dispatcher.send(.released, at: 3_050_000_000)
            try? await Task.sleep(for: .milliseconds(30))
            let startCountDuringProcessing = await audio.startCount
            try expect(startCountDuringProcessing == 1)

            await transcriber.resume()
            _ = await terminal.value
            try? await Task.sleep(for: .milliseconds(30))
            let startCountAfterProcessing = await audio.startCount
            try expect(
                startCountAfterProcessing == 1,
                "a press made during processing started a delayed recording"
            )

            await sessions.send(.dismissResult)
            dispatcher.send(.pressed, at: 4_000_000_000)
            try? await Task.sleep(for: .milliseconds(50))
            let restartedCount = await audio.startCount
            try expect(
                restartedCount == 2,
                "the gesture did not reset after rejecting a processing-time press"
            )
            await dispatcher.shutdown()
        }

        await runAsync("provider processing has no business timeout and remains cancellable", failures: &failures) {
            let transcriber = SpeechTranscriberFake(
                text: "late result",
                delaysResponse: true
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: transcriber,
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let releaseCompleted = CompletionFlag()

            await sessions.send(.pressed)
            let release = Task {
                await sessions.send(.released)
                await releaseCompleted.markComplete()
            }
            while await transcriber.callCount == 0 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(120))

            let completedWithoutProviderResult = await releaseCompleted.isComplete
            var currentPresentation: VoiceInputPresentation?
            for await presentation in await sessions.observe() {
                currentPresentation = presentation
                break
            }
            try expect(!completedWithoutProviderResult)
            if case .processing = currentPresentation?.activity {
                // The provider still owns the in-flight result boundary.
            } else {
                throw SpecFailure(
                    message: "processing ended without a provider result or cancellation"
                )
            }

            await sessions.send(.cancel)
            await transcriber.resume()
            await release.value
            let cancellationCount = await transcriber.cancellationCount
            try expect(cancellationCount == 1)
        }

        await runAsync("pending-copy trigger rejection resets the next shortcut gesture", failures: &failures) {
            let audio = AudioCaptureFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "保留"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            let terminal = terminalPresentation(from: await sessions.observe())

            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_050_000_000)
            dispatcher.send(.pressed, at: 2_000_000_000)
            dispatcher.send(.released, at: 2_050_000_000)
            _ = await terminal.value

            dispatcher.send(.pressed, at: 3_000_000_000)
            dispatcher.send(.released, at: 3_050_000_000)
            try? await Task.sleep(for: .milliseconds(30))
            await sessions.send(.dismissResult)

            dispatcher.send(.pressed, at: 4_000_000_000)
            try? await Task.sleep(for: .milliseconds(50))
            let restartedCount = await audio.startCount
            try expect(
                restartedCount == 2,
                "pending-copy rejection left the shortcut gesture latched"
            )
            await dispatcher.shutdown()
        }

        await runAsync("shutdown permanently rejects later session starts", failures: &failures) {
            let audio = AudioCaptureFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.shutdown()
            await sessions.send(.pressed, triggerSequence: 1)

            let startCount = await audio.startCount
            try expect(
                startCount == 0,
                "a session started after shutdown completed"
            )
        }

        await runAsync("trigger dispatcher shutdown cancels in-flight processing before waiting", failures: &failures) {
            let transcriber = SpeechTranscriberFake(text: "不得送达", delaysResponse: true)
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_300_000_000)
            while await transcriber.callCount == 0 { await Task.yield() }

            let shutdown = Task { await dispatcher.shutdown() }
            while await transcriber.cancellationCount == 0 { await Task.yield() }
            await transcriber.resume()
            await shutdown.value

            let deliveredTexts = await delivery.deliveredTexts
            let record = await history.records.last
            try expect(deliveredTexts.isEmpty)
            try expect(record?.outcome.isCancelled == true)
            try expect(record?.applicationName == "TextEdit")
            try expect(record?.stageDurationsMilliseconds["doubao"] != nil)
        }

        await runAsync("trigger dispatcher shutdown flushes queued history writes", failures: &failures) {
            let history = BlockingSessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            dispatcher.send(.pressed, at: 1_000_000_000)
            while await history.saveCallCount == 0 { await Task.yield() }

            let completion = CompletionFlag()
            let shutdown = Task {
                await dispatcher.shutdown()
                await completion.markComplete()
            }
            try? await Task.sleep(for: .milliseconds(20))
            let completedPrematurely = await completion.isComplete
            try expect(completedPrematurely == false)

            await history.unblock()
            await shutdown.value
            let completedAfterFlush = await completion.isComplete
            let saveCallCount = await history.saveCallCount
            try expect(completedAfterFlush)
            try expect(saveCallCount >= 2)
        }

        await runAsync("queued trigger cancel preempts an in-flight provider request", failures: &failures) {
            let transcriber = SpeechTranscriberFake(text: "不得送达", delaysResponse: true)
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_300_000_000)
            while await transcriber.callCount == 0 { await Task.yield() }

            dispatcher.send(.cancel)
            while await transcriber.cancellationCount == 0 { await Task.yield() }
            while await history.records.last?.outcome.isCancelled != true { await Task.yield() }

            let deliveredTexts = await delivery.deliveredTexts
            try expect(deliveredTexts.isEmpty)
            await transcriber.resume()
            dispatcher.finish()
        }

        await runAsync("trigger cancellation fence cannot cancel a later session", failures: &failures) {
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "后续会话"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed, triggerSequence: 2)
            await sessions.cancel(triggeredAtSequence: 1)
            await sessions.send(.released)

            let deliveredTexts = await delivery.deliveredTexts
            try expect(deliveredTexts == ["后续会话"])
        }

        await runAsync("cancel wins over a late recorder stop failure and discards target", failures: &failures) {
            let audio = DelayedFailingStopAudioCapture()
            let target = DiscardingTargetCaptureFake(
                snapshot: .init(id: UUID(), applicationName: "TextEdit")
            )
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: target,
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await audio.stopCount == 0 { await Task.yield() }
            await sessions.send(.cancel)
            await audio.failStop()
            await release.value

            let outcome = await history.records.last?.outcome
            let discardedCount = await target.discardedCount
            try expect(outcome?.isCancelled == true)
            try expect(discardedCount == 1)
        }

        await runAsync("cancel wins delivery commit gate before any text mutation", failures: &failures) {
            let delivery = DelayedCommitDeliveryFake()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "不得提交"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await delivery.entered == false { await Task.yield() }
            await sessions.send(.cancel)
            await delivery.allowCommitAttempt()
            await release.value

            let deliveredTexts = await delivery.deliveredTexts
            let record = await history.records.last
            try expect(deliveredTexts.isEmpty)
            try expect(record?.outcome.isCancelled == true)
            try expect(record?.applicationName == "TextEdit")
            try expect(record?.stageDurationsMilliseconds["delivery"] != nil)
            try expect(record?.cancelledAtStage == "delivery")
        }

        await runAsync("cancel is visible before blocked history persistence completes", failures: &failures) {
            let history = BlockingSessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let stream = await sessions.observe()

            await sessions.send(.pressed)
            while await history.saveCallCount == 0 { await Task.yield() }
            await sessions.send(.cancel)
            let terminal = await firstTerminalPresentation(
                from: stream,
                before: .milliseconds(300)
            )

            try expect(terminal?.activity.isCancelled == true)
            await history.unblock()
        }

        await runAsync("cancel hides committed delivery while its truthful history finishes", failures: &failures) {
            let delivery = BlockingDeliveryFake(commitsBeforeBlocking: true)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "Slow App"))
                ),
                transcriber: SpeechTranscriberFake(text: "取消后不能迟到。"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let stream = await sessions.observe()

            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await delivery.isBlocking == false { await Task.yield() }
            await sessions.send(.cancel)
            let cancelledPresentation = await firstTerminalPresentation(
                from: stream,
                before: .milliseconds(80)
            )
            await delivery.finish(with: .delivered)
            await release.value
            let recordReady = await eventually(before: .milliseconds(300)) {
                await history.records.last?.outcome.isTerminal == true
            }
            let record = await history.records.last
            let currentStream = await sessions.observe()
            var currentIterator = currentStream.makeAsyncIterator()
            let currentPresentation = await currentIterator.next()
            let cancellationCount = await delivery.cancellationCount

            try expect(
                cancelledPresentation?.activity.isCancelled == true,
                "Esc did not hide a committed delivery immediately"
            )
            try expect(
                currentPresentation?.activity.isCancelled == true,
                "late delivery outcome resurfaced the HUD after cancellation"
            )
            try expect(recordReady)
            try expect(
                record?.outcome.isDelivered == true,
                "history did not retain the truthful committed delivery outcome"
            )
            try expect(
                cancellationCount == 0,
                "Esc cancelled receipt verification after delivery committed"
            )
        }

        await runAsync("cancelled late transcription cannot deliver", failures: &failures) {
            let transcriber = SpeechTranscriberFake(text: "迟到结果", delaysResponse: true)
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await transcriber.callCount == 0 {
                await Task.yield()
            }
            await sessions.send(.cancel)
            await transcriber.resume()
            await release.value

            let deliveredTexts = await delivery.deliveredTexts
            let cancellationCount = await transcriber.cancellationCount
            try expect(deliveredTexts.isEmpty)
            try expect(cancellationCount == 1, "active provider request was not cancelled")
        }

        await runAsync("cancel propagates through DeepSeek without fallback delivery", failures: &failures) {
            let refiner = CancellableDeepSeekRefinerFake()
            let history = SessionHistoryFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let processor = DefaultVoiceTextProcessor(
                configuration: VoiceInputConfigurationController(
                    refinementMode: .conciseCleanup
                ),
                doubao: ContextualTranscriberFake(text: "豆包已确认结果"),
                refinement: OptionalTextRefinementPipeline(refiner: refiner)
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let stream = await sessions.observe()

            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await refiner.callCount == 0 { await Task.yield() }
            await sessions.send(.cancel)
            let terminal = await firstTerminalPresentation(
                from: stream,
                before: .milliseconds(300)
            )
            await release.value

            let deliveredTexts = await delivery.deliveredTexts
            let cancellationCount = await refiner.cancellationCount
            try expect(terminal?.activity.isCancelled == true)
            try expect(deliveredTexts.isEmpty)
            try expect(cancellationCount == 1)
            while await history.records.last?.cancelledAtStage == nil { await Task.yield() }
            let record = await history.records.last
            try expect(record?.cancelledAtStage == "deepseek")
            try expect(record?.outcome.isCancelled == true)
            try expect(record?.transcription == "豆包已确认结果")
            try expect(record?.providerRequestID == "doubao-context-spec")
            try expect(record?.finalText == nil)
        }

        await runAsync("slow presentation observers receive the current terminal state", failures: &failures) {
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "最终状态"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let stream = await sessions.observe()

            await sessions.send(.pressed)
            await sessions.send(.released)

            var iterator = stream.makeAsyncIterator()
            let firstVisiblePresentation = await iterator.next()
            try expect(
                firstVisiblePresentation?.activity.isDelivered == true,
                "a delayed UI observer received stale queued states before the terminal state"
            )
        }

        await runAsync("live PCM reaches streaming processor before shortcut release", failures: &failures) {
            let audio = StreamingAudioCaptureFake()
            let processor = StreamingVoiceTextProcessorFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            await audio.emit(Data([1, 2, 3, 4]))
            while await processor.receivedChunkCount == 0 {
                await Task.yield()
            }
            let stopCountDuringRecording = await audio.stopCount
            try expect(stopCountDuringRecording == 0, "audio was not streamed during recording")

            await sessions.send(.released)

            let receivedChunkCount = await processor.receivedChunkCount
            let deliveredTexts = await delivery.deliveredTexts
            try expect(receivedChunkCount == 1)
            try expect(deliveredTexts == ["流式结果"])
        }

        await runAsync("definite local silence cancels streaming without delivering text", failures: &failures) {
            let audio = StreamingAudioCaptureFake(
                stoppedAudio: CapturedAudio(
                    data: Data(),
                    duration: .seconds(1),
                    peakPower: -160
                )
            )
            let history = SessionHistoryFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(
                        id: UUID(),
                        applicationName: "TextEdit"
                    ))
                ),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let presentations = await sessions.observe()

            await sessions.send(.pressed)
            await audio.emit(Data(repeating: 0, count: 6_400))
            await sessions.send(.released)
            let terminal = await firstTerminalPresentation(
                from: presentations,
                before: .milliseconds(300)
            )

            if case let .failed(_, failure) = terminal?.activity {
                try expect(failure == .localSilenceDetected)
            } else {
                throw SpecFailure(message: "local silence was not reported")
            }
            let deliveredTexts = await delivery.deliveredTexts
            try expect(deliveredTexts.isEmpty)
            while await history.records.last == nil { await Task.yield() }
            let record = await history.records.last
            try expect(record?.providerErrorCode == "audio.silent")
            try expect(record?.transcriptionProvider == "local")
        }

        await runAsync("definite streaming provider failure stops an active recording immediately", failures: &failures) {
            let audio = StreamingAudioCaptureFake()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: EarlyFailingStreamingProcessor(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let stream = await sessions.observe()

            await sessions.send(.pressed)
            let terminal = await firstTerminalPresentation(
                from: stream,
                before: .milliseconds(300)
            )

            if case let .failed(_, failure) = terminal?.activity {
                try expect(failure == .providerAuthenticationFailed)
            } else {
                throw SpecFailure(message: "recording ignored the provider's early failure")
            }
            await sessions.shutdown()
            let cancelCount = await audio.cancelCount
            let record = await history.records.last
            try expect(cancelCount == 1)
            try expect(record?.providerRequestID == "early-provider-failure")
        }

        await runAsync("an asynchronous terminal failure clears a latched short-press gesture", failures: &failures) {
            let audio = StreamingAudioCaptureFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: EarlyFailingStreamingProcessor(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            let presentations = await sessions.observe()

            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_050_000_000)
            _ = await firstTerminalPresentation(
                from: presentations,
                before: .milliseconds(300)
            )

            // The first press after the failure must start a new session; it
            // must not be consumed as the stale latch's stop gesture.
            dispatcher.send(.pressed, at: 2_000_000_000)
            try? await Task.sleep(for: .milliseconds(30))
            let startCount = await audio.startCount
            try expect(startCount == 2)
            await dispatcher.shutdown()
        }

        await runAsync("audio device changes stop recording with a local diagnostic", failures: &failures) {
            let audio = StreamingAudioCaptureFake()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let stream = await sessions.observe()

            await sessions.send(.pressed)
            await audio.emitFailure(.deviceConfigurationChanged)
            let terminal = await firstTerminalPresentation(
                from: stream,
                before: .milliseconds(300)
            )

            if case let .failed(_, failure) = terminal?.activity {
                try expect(failure == .audioDeviceChanged)
            } else {
                throw SpecFailure(message: "device change did not close the recording")
            }
            let cancelCount = await audio.cancelCount
            let record = await history.records.last
            try expect(cancelCount == 1)
            try expect(record?.providerErrorCode == "audio.device_configuration_changed")
            try expect(record?.transcriptionProvider == "local")
        }

        await runAsync("Doubao WebSocket uses streaming headers and binary frames", failures: &failures) {
            let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "  你好，世界。  ", isFinal: true)],
                metadata: .init(httpStatusCode: 101, providerRequestID: "log-12")
            )
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user",
                    hotwords: ["Speaker"]
                ),
                connector: connector,
                requestIDGenerator: { requestID }
            )

            let result = try await client.transcribe(
                makeAudioStream([Data([1, 2]), Data([3, 4])])
            )
            let request = try await connector.onlyRequest()
            let frames = await connection.sentFrames
            try expect(frames.count == 3)
            let fullRequest = try DoubaoStreamingFrameCodec.decode(frames[0])
            let firstAudio = try DoubaoStreamingFrameCodec.decode(frames[1])
            let finalAudio = try DoubaoStreamingFrameCodec.decode(frames[2])
            let body = try JSONSerialization.jsonObject(with: fullRequest.payload) as? [String: Any]
            let recognition = body?["request"] as? [String: Any]
            let audio = body?["audio"] as? [String: Any]

            try expect(request.url == DoubaoStreamingASRConfiguration.defaultEndpoint)
            try expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-api-key")
            try expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration")
            try expect(request.value(forHTTPHeaderField: "X-Api-Request-Id") == requestID.uuidString)
            try expect(request.value(forHTTPHeaderField: "X-Api-Connect-Id") == requestID.uuidString)
            try expect(request.value(forHTTPHeaderField: "X-Api-Sequence") == "-1")
            try expect(recognition?["enable_itn"] as? Bool == true)
            try expect(recognition?["enable_punc"] as? Bool == true)
            try expect(recognition?["enable_ddc"] as? Bool == true)
            try expect(audio?["format"] as? String == "pcm")
            try expect(audio?["rate"] as? Int == 16_000)
            try expect(fullRequest.messageType == 0x01)
            try expect(firstAudio.payload == Data([1, 2]) && !firstAudio.isFinal)
            try expect(finalAudio.payload == Data([3, 4]) && finalAudio.isFinal)
            try expect(result == .init(text: "你好，世界。", providerRequestID: "log-12"))
        }

        await runAsync("Doubao provider errors interrupt audio that is still being recorded", failures: &failures) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerError(code: 45000001, message: "invalid api key")],
                metadata: .init(httpStatusCode: 101, providerRequestID: "early-error-log")
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "bad-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(connection: connection)
            )
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            continuation.yield(Data([1, 2]))

            do {
                _ = try await client.transcribe(stream)
                throw SpecFailure(message: "provider error waited for the recording to finish")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .invalidCredential)
                try expect(failure.providerRequestID == "early-error-log")
            }
            continuation.finish()
            let closeCount = await connection.closeCount
            try expect(closeCount == 1)
        }

        await runAsync("Doubao provider errors outrank send failures caused by closing the socket", failures: &failures) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [
                    makeDoubaoServerError(
                        code: 45_000_001,
                        message: "resource not activated"
                    ),
                ],
                metadata: .init(
                    httpStatusCode: 101,
                    providerRequestID: "provider-error-priority"
                ),
                blockingSendFailureIndex: 1
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                )
            )

            do {
                _ = try await client.transcribe(
                    makeAudioStream([Data([1]), Data([2])])
                )
                throw SpecFailure(message: "provider error was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .resourceNotActivated)
                try expect(
                    failure.providerRequestID
                        == "provider-error-priority"
                )
            }
        }

        await runAsync("Doubao send failures close a receive that ignores task cancellation", failures: &failures) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [],
                failingSendIndex: 1,
                blocksReceiveUntilClose: true
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(connection: connection)
            )
            let completion = CompletionFlag()
            let request = Task {
                let result: Result<TranscriptionResult, Error>
                do {
                    result = .success(try await client.transcribe(
                        makeAudioStream([Data([1, 2])])
                    ))
                } catch {
                    result = .failure(error)
                }
                await completion.markComplete()
                return result
            }

            try? await Task.sleep(for: .milliseconds(50))
            let completedWithoutExternalCancellation = await completion.isComplete
            if !completedWithoutExternalCancellation {
                // Clean up the deliberately non-cooperative fake so a red test
                // reports normally instead of leaving the suite suspended.
                await connection.close()
            }
            let result = await request.value

            try expect(
                completedWithoutExternalCancellation,
                "send failure waited forever for a receive that ignores Task cancellation"
            )
            if case let .failure(failure as DoubaoASRFailure) = result {
                try expect(failure.kind == .network)
            } else {
                throw SpecFailure(message: "send failure did not become a Doubao network problem")
            }
            let closeCount = await connection.closeCount
            try expect(closeCount == 1)
        }

        await runAsync("Doubao cancellation never sends a final audio frame", failures: &failures) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [],
                blocksReceiveUntilClose: true
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                )
            )
            let probe = AudioChunkConsumptionProbe()
            let stream = AsyncStream<Data>(unfolding: {
                if await probe.takeFirstChunk() {
                    return Data([1, 2])
                }
                try? await Task.sleep(for: .seconds(10))
                return nil
            })
            let request = Task {
                try await client.transcribe(stream)
            }
            while !(await probe.firstChunkWasConsumed) {
                await Task.yield()
            }

            request.cancel()
            do {
                _ = try await request.value
                throw SpecFailure(message: "cancelled Doubao request succeeded")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .cancelled)
            }

            let frames = await connection.sentFrames
            let audioFrames = try frames.dropFirst().map(
                DoubaoStreamingFrameCodec.decode
            )
            try expect(
                audioFrames.allSatisfy { !$0.isFinal },
                "cancelled request sent a final audio frame"
            )
        }

        await runAsync("Doubao runtime diagnostics report the exact active transport phase", failures: &failures) {
            let requestID = UUID(
                uuidString: "00000000-0000-0000-0000-000000000099"
            )!
            let diagnostics = VoiceProviderRuntimeDiagnostics()
            let connection = DoubaoWebSocketConnectionFake(
                responses: [],
                metadata: .init(
                    httpStatusCode: 101,
                    providerRequestID: "server-request-99"
                ),
                blocksReceiveUntilClose: true
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                ),
                requestIDGenerator: { requestID },
                runtimeDiagnostics: diagnostics
            )
            let request = Task {
                try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
            }
            let reachedAwaitingFinal = await eventually(
                before: .milliseconds(300)
            ) {
                await diagnostics.activeSnapshot()?.phase
                    == .awaitingFinal
            }
            let snapshot = await diagnostics.activeSnapshot()

            try expect(reachedAwaitingFinal)
            try expect(snapshot?.operation == .voiceInput)
            try expect(
                snapshot?.requestID == requestID.uuidString
            )
            try expect(
                snapshot?.providerRequestID == "server-request-99"
            )
            try expect(snapshot?.httpStatusCode == 101)

            request.cancel()
            _ = try? await request.value
            let cleared = await eventually(
                before: .milliseconds(300)
            ) {
                await diagnostics.activeSnapshot() == nil
            }
            try expect(cleared)
        }

        await runAsync("Doubao diagnostics stay connecting until the first WebSocket send succeeds", failures: &failures) {
            let diagnostics = VoiceProviderRuntimeDiagnostics()
            let connection = DoubaoWebSocketConnectionFake(
                responses: [],
                hangingSendIndex: 0
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                ),
                runtimeDiagnostics: diagnostics
            )
            let request = Task {
                try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
            }
            let sendStarted = await eventually(before: .milliseconds(300)) {
                await connection.sendAttemptCount == 1
            }
            let snapshot = await diagnostics.activeSnapshot()

            try expect(sendStarted)
            try expect(snapshot?.phase == .connecting)

            request.cancel()
            _ = try? await request.value
        }

        await runAsync("Doubao response metadata cannot advance the audio transport phase", failures: &failures) {
            let diagnostics = VoiceProviderRuntimeDiagnostics()
            await diagnostics.beginDoubao(
                requestID: "request-early-response",
                operation: .voiceInput
            )
            await diagnostics.updateDoubao(
                requestID: "request-early-response",
                phase: .streamingAudio
            )
            await diagnostics.updateDoubaoMetadata(
                requestID: "request-early-response",
                metadata: .init(
                    httpStatusCode: 101,
                    providerRequestID: "server-early-response"
                )
            )
            let snapshot = await diagnostics.activeSnapshot()

            try expect(snapshot?.phase == .streamingAudio)
            try expect(
                snapshot?.providerRequestID == "server-early-response"
            )
            try expect(snapshot?.httpStatusCode == 101)
        }

        await runAsync("Doubao maps silence without exposing a transcript", failures: &failures) {
            let client = makeDoubaoClient(
                responses: [makeDoubaoServerResponse(text: nil, isFinal: true)],
                metadata: .init(httpStatusCode: 101, providerRequestID: "silent-log")
            )
            do {
                _ = try await client.transcribe(makeAudioStream([Data([0, 0])]))
                throw SpecFailure(message: "silence response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .emptyTranscript)
                try expect(failure.providerRequestID == "silent-log")
            }
        }

        await runAsync("Doubao silent error frame validates a credential connection probe", failures: &failures) {
            let credentials = ProviderCredentialStoreFake(
                values: [.doubao: "valid-key"]
            )
            let connection = DoubaoWebSocketConnectionFake(
                responses: [
                    makeDoubaoServerError(
                        code: 20_000_003,
                        message: "no speech detected"
                    ),
                ],
                metadata: .init(
                    httpStatusCode: 101,
                    providerRequestID: "silent-probe-request"
                )
            )
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                )
            )

            let requestID = try await transcriber.checkConnection()
            try expect(requestID == "silent-probe-request")
        }

        await runAsync("Doubao distinguishes inactive resource from bad credential", failures: &failures) {
            let inactive = makeDoubaoClient(responses: [
                makeDoubaoServerError(code: 45_000_001, message: "resource not activated")
            ])
            do {
                _ = try await inactive.transcribe(makeAudioStream([Data([1, 2])]))
                throw SpecFailure(message: "inactive resource response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .resourceNotActivated)
            }

            let unauthorized = makeDoubaoClient(
                receiveError: URLError(.badServerResponse),
                metadata: .init(httpStatusCode: 401, providerMessage: "unauthorized api key")
            )
            do {
                _ = try await unauthorized.transcribe(makeAudioStream([Data([1, 2])]))
                throw SpecFailure(message: "invalid credential response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .invalidCredential)
            }
        }

        await runAsync("Doubao preserves a remote WebSocket close code as structured diagnostics", failures: &failures) {
            let client = makeDoubaoClient(
                receiveError: URLError(.networkConnectionLost),
                metadata: .init(
                    providerRequestID: "closed-request",
                    webSocketCloseCode: 1006
                )
            )

            do {
                _ = try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
                throw SpecFailure(message: "closed WebSocket succeeded")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .network)
                try expect(
                    failure.providerStatusCode
                        == "websocket.close.1006"
                )
                try expect(
                    failure.providerRequestID == "closed-request"
                )
            }
        }

        await runAsync("Doubao classifies URL transport failures without raw error text", failures: &failures) {
            let client = makeDoubaoClient(
                receiveError: URLError(.cannotFindHost)
            )

            do {
                _ = try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
                throw SpecFailure(message: "DNS failure succeeded")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .network)
                try expect(
                    failure.providerStatusCode == "url.cannotFindHost"
                )
            }
        }

        await runAsync("Doubao classifies connection setup failures before a socket exists", failures: &failures) {
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoFailingWebSocketConnectorFake(
                    error: URLError(.secureConnectionFailed)
                )
            )

            do {
                _ = try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
                throw SpecFailure(message: "TLS setup failure succeeded")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .network)
                try expect(
                    failure.providerStatusCode
                        == "url.secureConnectionFailed"
                )
                try expect(failure.providerRequestID != nil)
            }
        }

        await runAsync("credential-backed Doubao transcriber loads the current stored value", failures: &failures) {
            let credentials = ProviderCredentialStoreFake(values: [.doubao: "first-key"])
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "第一条", isFinal: true)]
            )
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                connector: connector,
                requestUserID: { "request-user-1" }
            )

            _ = try await transcriber.transcribe(specAudio)
            let firstRequest = try await connector.onlyRequest()
            let sentFrames = await connection.sentFrames
            let fullRequest = try DoubaoStreamingFrameCodec.decode(
                sentFrames[0]
            )
            let body = try JSONSerialization.jsonObject(
                with: fullRequest.payload
            ) as? [String: Any]
            let user = body?["user"] as? [String: Any]
            try expect(firstRequest.value(forHTTPHeaderField: "X-Api-Key") == "first-key")
            try expect(user?["uid"] as? String == "request-user-1")
        }

        await runAsync("credential-backed Doubao transcriber fails before network when unconfigured", failures: &failures) {
            let credentials = ProviderCredentialStoreFake()
            let connection = DoubaoWebSocketConnectionFake(responses: [])
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                connector: connector
            )

            do {
                _ = try await transcriber.transcribe(specAudio)
                throw SpecFailure(message: "unconfigured transcriber sent a request")
            } catch let failure as ProviderCredentialStoreError {
                try expect(failure == .emptyAPIKey)
                let requestCount = await connector.requestCount
                try expect(requestCount == 0)
            }
        }

        await runAsync("Doubao failure becomes stable user state and diagnostic history", failures: &failures) {
            let history = SessionHistoryFake()
            let target = DiscardingTargetCaptureFake(
                snapshot: .init(id: UUID(), applicationName: "TextEdit")
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: target,
                textProcessor: NormalizedFailureProcessor(failure: .init(
                    userFailure: .providerNotConfigured,
                    providerDiagnostic: .init(
                        provider: "doubao",
                        requestID: "provider-log-id",
                        code: "invalidCredential",
                        statusCode: "401",
                        message: "invalid api key"
                    )
                )),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let presentation = await terminal.value
            await sessions.shutdown()
            let record = await history.records.first
            if case let .failed(_, failure) = presentation?.activity {
                try expect(failure == .providerNotConfigured)
            } else {
                throw SpecFailure(message: "provider failure did not reach terminal UI state")
            }
            try expect(record?.providerRequestID == "provider-log-id")
            try expect(record?.providerErrorCode == "invalidCredential")
            try expect(record?.providerOperation == "transcription")
            try expect(record?.providerStatusCode == "401")
            try expect(
                record?.providerMessage == nil,
                "untrusted provider response text entered session history"
            )
            try expect(record?.transcriptionProvider == "doubao")
            try expect(record?.applicationName == "TextEdit")
            let discardedCount = await target.discardedCount
            try expect(discardedCount == 1)
        }

        await runAsync("history persistence failure is visible on the terminal session", failures: &failures) {
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "仍可使用"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(failureNotice: "会话历史写入失败：磁盘不可用")
            )
            let noticePresentation = Task<VoiceInputPresentation?, Never> {
                for await presentation in await sessions.observe() {
                    if presentation.notice
                        == .persistenceFailure("会话历史写入失败：磁盘不可用")
                    {
                        return presentation
                    }
                }
                return nil
            }
            await sessions.send(.pressed)
            await sessions.send(.released)
            let presentation = await noticePresentation.value
            try expect(
                presentation?.notice
                    == .persistenceFailure("会话历史写入失败：磁盘不可用")
            )
            try expect(presentation?.activity.pendingText == "仍可使用")
        }

        await runAsync("voice text processing owns Doubao failure normalization", failures: &failures) {
            let cases: [(DoubaoASRFailureKind, VoiceInputFailure)] = [
                (.invalidCredential, .providerAuthenticationFailed),
                (.silence, .noSpeechDetected),
                (.emptyAudio, .providerReceivedNoAudio),
                (.emptyTranscript, .providerReturnedNoText),
                (.resourceNotActivated, .providerResourceUnavailable),
                (.rateLimited, .providerRateLimited),
                (.network, .networkUnavailable),
                (.serverBusy, .providerUnavailable),
                (.serviceUnavailable, .providerUnavailable),
                (.cancelled, .transcriptionFailed),
                (.invalidRequest, .transcriptionFailed),
                (.invalidAudioFormat, .transcriptionFailed),
                (.invalidResponse, .transcriptionFailed),
            ]

            for (kind, expectedFailure) in cases {
                let processor = DefaultVoiceTextProcessor(
                    configuration: VoiceInputConfigurationController(),
                    doubao: DoubaoFailureTranscriber(failure: .init(
                        kind: kind,
                        providerRequestID: "doubao-mapping-log"
                    )),
                    refinement: OptionalTextRefinementPipeline(
                        refiner: DeepSeekRefinerFake(result: .success(.init(text: "unused")))
                    )
                )
                do {
                    _ = try await processor.process(specAudio, snapshot: .empty) { _ in }
                    throw SpecFailure(message: "\(kind.rawValue) escaped the processing seam")
                } catch let failure as VoiceTextProcessingFailure {
                    try expect(failure.userFailure == expectedFailure)
                    try expect(failure.providerDiagnostic == .init(
                        provider: "doubao",
                        operation: .transcription,
                        requestID: "doubao-mapping-log",
                        code: kind.rawValue
                    ))
                }
            }
        }

        await runAsync("credential-store failures remain actionable provider diagnostics", failures: &failures) {
            let processor = DefaultVoiceTextProcessor(
                configuration: VoiceInputConfigurationController(),
                doubao: CredentialFailureTranscriber(error: .interactionUnavailable),
                refinement: OptionalTextRefinementPipeline(
                    refiner: DeepSeekRefinerFake(result: .success(.init(text: "unused")))
                )
            )
            do {
                _ = try await processor.process(specAudio, snapshot: .empty) { _ in }
                throw SpecFailure(message: "credential-store failure escaped the processing seam")
            } catch let failure as VoiceTextProcessingFailure {
                try expect(failure.userFailure == .providerCredentialUnavailable)
                try expect(failure.providerDiagnostic == .init(
                    provider: "doubao",
                    operation: .credentialAccess,
                    requestID: nil,
                    code: "credential.interactionUnavailable"
                ))
            }
        }

        await runAsync("default smooth refinement never calls DeepSeek", failures: &failures) {
            let refiner = DeepSeekRefinerFake(result: .success(.init(text: "不应采用")))
            let pipeline = OptionalTextRefinementPipeline(refiner: refiner)

            let outcome = try await pipeline.refine(
                doubaoText: "豆包默认顺滑",
                mode: .defaultSmooth
            )

            try expect(outcome.status == .notRequested)
            try expect(outcome.finalText == "豆包默认顺滑")
            let callCount = await refiner.callCount
            try expect(callCount == 0)
        }

        await runAsync("DeepSeek credential-store failures keep the transcript and preserve the exact boundary", failures: &failures) {
            let mappings: [
                (ProviderCredentialStoreError, DeepSeekRefinementFailureKind)
            ] = [
                (.accessDenied, .credentialAccessDenied),
                (.interactionUnavailable, .credentialInteractionUnavailable),
                (.malformedStoredValue, .credentialMalformed),
                (.storageUnavailable, .credentialStorageUnavailable),
            ]

            for (storeError, expectedKind) in mappings {
                let refiner = CredentialedDeepSeekTextRefiner(
                    credentials: ProviderCredentialStoreFake(
                        readError: storeError
                    ),
                    transport: DeepSeekTransportFake(response: .init(
                        statusCode: 200,
                        body: Data()
                    ))
                )
                let outcome = try await OptionalTextRefinementPipeline(
                    refiner: refiner
                ).refine(
                    doubaoText: "豆包文字仍应保留",
                    mode: .fullRewrite
                )

                try expect(outcome.status == .fellBack)
                try expect(outcome.finalText == "豆包文字仍应保留")
                try expect(outcome.failure?.kind == expectedKind)
                try expect(
                    outcome.failure?.providerDiagnostic.code
                        == expectedKind.rawValue
                )
            }
        }

        await runAsync("optional refinement succeeds or losslessly falls back to Doubao", failures: &failures) {
            let successfulRefiner = DeepSeekRefinerFake(
                result: .success(.init(text: "整理后的文本", providerRequestID: "ds-1"))
            )
            let successfulPipeline = OptionalTextRefinementPipeline(refiner: successfulRefiner)
            let success = try await successfulPipeline.refine(
                doubaoText: "嗯 原始文本",
                mode: .conciseCleanup
            )
            try expect(success.status == .succeeded)
            try expect(success.deepSeekText == "整理后的文本")
            try expect(success.finalText == "整理后的文本")

            let failingRefiner = DeepSeekRefinerFake(
                result: .failure(.init(kind: .rateLimited, httpStatusCode: 429))
            )
            let fallbackPipeline = OptionalTextRefinementPipeline(refiner: failingRefiner)
            let fallback = try await fallbackPipeline.refine(
                doubaoText: "豆包结果仍保留",
                mode: .fullRewrite
            )
            try expect(fallback.status == .fellBack)
            try expect(fallback.deepSeekText == nil)
            try expect(fallback.finalText == "豆包结果仍保留")
            try expect(fallback.failure?.kind == .rateLimited)
        }

        run("custom refinement modes reject empty and oversized prompts", failures: &failures) {
            do {
                _ = try TextRefinementMode.custom(name: "我的模式", prompt: " ").validated()
                throw SpecFailure(message: "empty custom prompt was accepted")
            } catch let error as TextRefinementModeValidationError {
                try expect(error == .emptyCustomPrompt)
            }

            do {
                _ = try TextRefinementMode.custom(
                    name: "我的模式",
                    prompt: String(repeating: "x", count: 4_001)
                ).validated()
                throw SpecFailure(message: "oversized custom prompt was accepted")
            } catch let error as TextRefinementModeValidationError {
                try expect(error == .customPromptTooLong)
            }
        }

        await runAsync("DeepSeek request disables thinking and requires strict JSON output", failures: &failures) {
            let transport = DeepSeekTransportFake(response: .init(
                statusCode: 200,
                headers: ["x-request-id": "ds-request-1"],
                body: Data(#"{"choices":[{"message":{"content":"{\"text\":\"  整理后  \"}"},"finish_reason":"stop"}]}"#.utf8)
            ))
            let client = DeepSeekRefinementClient(
                configuration: .init(apiKey: "deepseek-test-key"),
                transport: transport
            )

            let result = try await client.refine("嗯，原始文本。", using: .conciseCleanup)
            let request = try await transport.onlyRequest()
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let thinking = body?["thinking"] as? [String: Any]
            let responseFormat = body?["response_format"] as? [String: Any]

            try expect(request.url == DeepSeekRefinementConfiguration.defaultEndpoint)
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer deepseek-test-key")
            try expect(body?["model"] as? String == "deepseek-v4-flash")
            try expect(thinking?["type"] as? String == "disabled")
            try expect(responseFormat?["type"] as? String == "json_object")
            try expect(body?["stream"] as? Bool == false)
            try expect(result == .init(text: "整理后", providerRequestID: "ds-request-1"))
        }

        await runAsync("DeepSeek keeps the structured body request ID when trace headers are absent", failures: &failures) {
            let transport = DeepSeekTransportFake(response: .init(
                statusCode: 200,
                body: Data(
                    #"""
                    {
                      "id": "body-request-42",
                      "choices": [{
                        "message": {"content": "{\"text\":\"整理后\"}"},
                        "finish_reason": "stop"
                      }]
                    }
                    """#.utf8
                )
            ))
            let client = DeepSeekRefinementClient(
                configuration: .init(apiKey: "deepseek-test-key"),
                transport: transport
            )

            let result = try await client.refine(
                "原文",
                using: .conciseCleanup
            )

            try expect(
                result.providerRequestID == "body-request-42"
            )
        }

        await runAsync("production DeepSeek URLSession transport cancels its HTTP load", failures: &failures) {
            let probe = DeepSeekURLProtocolProbe()
            BlockingDeepSeekURLProtocol.install(probe)
            defer { BlockingDeepSeekURLProtocol.install(nil) }
            let configuration =
                ProviderURLSessionFactory.ephemeralConfiguration()
            configuration.protocolClasses = [
                BlockingDeepSeekURLProtocol.self,
            ]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = DeepSeekRefinementClient(
                configuration: .init(apiKey: "deepseek-test-key"),
                transport: URLSessionDeepSeekTransport(session: session)
            )
            let request = Task {
                try await client.refine(
                    "需要取消的文字",
                    using: .conciseCleanup
                )
            }
            let started = await eventually(
                before: .milliseconds(300)
            ) {
                probe.didStart
            }
            try expect(started)

            request.cancel()
            do {
                _ = try await request.value
                throw SpecFailure(
                    message: "cancelled DeepSeek request succeeded"
                )
            } catch let failure as DeepSeekRefinementFailure {
                try expect(failure.kind == .cancelled)
            }
            let stopped = await eventually(
                before: .milliseconds(300)
            ) {
                probe.didStop
            }
            try expect(
                stopped,
                "URLSession cancellation did not call URLProtocol.stopLoading"
            )
        }

        await runAsync("DeepSeek rejects extra JSON fields and abnormal expansion", failures: &failures) {
            let extraFieldClient = makeDeepSeekClient(content: #"{"text":"结果","extra":true}"#)
            do {
                _ = try await extraFieldClient.refine("原文", using: .fullRewrite)
                throw SpecFailure(message: "extra JSON field was accepted")
            } catch let failure as DeepSeekRefinementFailure {
                try expect(failure.kind == .unexpectedJSONShape)
            }

            let expanded = String(repeating: "扩", count: 4_097)
            let expandedJSONData = try JSONEncoder().encode(["text": expanded])
            let expandedJSON = String(decoding: expandedJSONData, as: UTF8.self)
            let expandedClient = makeDeepSeekClient(content: expandedJSON)
            do {
                _ = try await expandedClient.refine("短文本", using: .fullRewrite)
                throw SpecFailure(message: "abnormally expanded output was accepted")
            } catch let failure as DeepSeekRefinementFailure {
                try expect(failure.kind == .outputTooLarge)
            }
        }

        await runAsync("DeepSeek classifies production HTTP and response boundaries", failures: &failures) {
            let httpCases: [(Int, DeepSeekRefinementFailureKind)] = [
                (401, .authentication),
                (402, .insufficientBalance),
                (429, .rateLimited),
                (500, .serverError),
                (503, .serviceUnavailable),
            ]
            for (statusCode, expectedKind) in httpCases {
                let client = DeepSeekRefinementClient(
                    configuration: .init(apiKey: "deepseek-test-key"),
                    transport: DeepSeekTransportFake(response: .init(
                        statusCode: statusCode,
                        headers: ["x-request-id": "boundary-request"],
                        body: Data()
                    ))
                )
                do {
                    _ = try await client.refine("原文", using: .conciseCleanup)
                    throw SpecFailure(message: "HTTP \(statusCode) was accepted")
                } catch let failure as DeepSeekRefinementFailure {
                    try expect(failure.kind == expectedKind)
                    try expect(failure.httpStatusCode == statusCode)
                    try expect(failure.providerRequestID == "boundary-request")
                }
            }

            let responseCases: [(Data, DeepSeekRefinementFailureKind)] = [
                (
                    Data(#"{"choices":[{"message":{"content":"{\"text\":\"结果\"}"},"finish_reason":"length"}]}"#.utf8),
                    .truncated
                ),
                (Data(#"{"choices":[]}"#.utf8), .emptyOutput),
                (
                    Data(#"{"choices":[{"message":{"content":"not-json"},"finish_reason":"stop"}]}"#.utf8),
                    .malformedJSON
                ),
                (
                    Data(#"{"choices":[{"message":{"content":"{\"text\":\"   \"}"},"finish_reason":"stop"}]}"#.utf8),
                    .emptyText
                ),
            ]
            for (body, expectedKind) in responseCases {
                let client = DeepSeekRefinementClient(
                    configuration: .init(apiKey: "deepseek-test-key"),
                    transport: DeepSeekTransportFake(response: .init(
                        statusCode: 200,
                        body: body
                    ))
                )
                do {
                    _ = try await client.refine("原文", using: .conciseCleanup)
                    throw SpecFailure(message: "\(expectedKind.rawValue) response was accepted")
                } catch let failure as DeepSeekRefinementFailure {
                    try expect(failure.kind == expectedKind)
                }
            }
        }

        await runAsync("voice session freezes dictionary and refinement mode at press", failures: &failures) {
            let initialDictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "Swift", aliases: ["swift-lang"]),
            ])
            let configuration = VoiceInputConfigurationController(
                dictionary: initialDictionary,
                refinementMode: .conciseCleanup
            )
            let doubao = ContextualTranscriberFake(text: "Use swift-lang")
            let refiner = DeepSeekRefinerFake(result: .success(.init(text: "Use Swift.")))
            let processor = DefaultVoiceTextProcessor(
                configuration: configuration,
                doubao: doubao,
                refinement: OptionalTextRefinementPipeline(refiner: refiner)
            )
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )

            await sessions.send(.pressed)
            await configuration.replaceDictionary(.empty)
            try await configuration.selectRefinementMode(.fullRewrite)
            await sessions.send(.released)
            await sessions.shutdown()

            let hotwordCalls = await doubao.hotwordCalls
            let refinementModes = await refiner.modes
            let refinementInputs = await refiner.inputs
            let deliveredTexts = await delivery.deliveredTexts
            let record = await history.records.first
            try expect(hotwordCalls == [["Swift"]])
            try expect(refinementModes == [.conciseCleanup])
            try expect(refinementInputs == ["Use Swift"])
            try expect(deliveredTexts == ["Use Swift."])
            try expect(record?.transcription == "Use swift-lang")
            try expect(record?.deepSeekText == "Use Swift.")
            try expect(record?.refinementModeName == "精简清理")
            try expect(record?.refinementPrompt?.isEmpty == false)
            try expect(record?.refinementStatus == "succeeded")
            try expect(record?.dictionarySnapshotEntries.map(\.canonicalTerm) == ["Swift"])
            try expect(record?.dictionaryRequestContext?.hotwords == ["Swift"])
            try expect(record?.dictionaryReplacements.count == 1)
            try expect(record?.stageDurationsMilliseconds["targetCapture"] != nil)
            try expect(record?.stageDurationsMilliseconds["delivery"] != nil)
        }

        await runAsync("credential store rejects blank API keys", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-credentials-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = LocalFileProviderCredentialStore(
                fileURL: directory.appendingPathComponent("credentials.json")
            )
            do {
                try await store.save(apiKey: "  \n ", for: .doubao)
                throw SpecFailure(message: "blank API key was accepted")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .emptyAPIKey)
            }
        }

        await runAsync("credential store refuses oversized keys without replacing the saved key", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-credentials-size-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = LocalFileProviderCredentialStore(
                fileURL: directory.appendingPathComponent("credentials.json")
            )
            try await store.save(apiKey: "retained-key", for: .doubao)

            do {
                try await store.save(
                    apiKey: String(repeating: "a", count: 64 * 1_024 + 1),
                    for: .doubao
                )
                throw SpecFailure(message: "oversized API key was saved")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .apiKeyTooLarge)
            }
            let retainedKey = try await store.apiKey(for: .doubao)
            try expect(
                retainedKey == "retained-key",
                "oversized API key replaced the readable credential"
            )
        }

        await runAsync("credential store round trips and deletes isolated API key", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-credentials-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("credentials.json")
            let store = LocalFileProviderCredentialStore(fileURL: fileURL)

            try await store.save(apiKey: "  local-test-key  ", for: .doubao)
            let storedKey = try await store.apiKey(for: .doubao)
            try expect(storedKey == "local-test-key")
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            try expect(permissions == 0o600, "credential file is not owner-only")

            try await store.deleteAPIKey(for: .doubao)
            try await store.deleteAPIKey(for: .doubao)
            let deletedKey = try await store.apiKey(for: .doubao)
            try expect(deletedKey == nil)
            try expect(
                !FileManager.default.fileExists(atPath: fileURL.path),
                "empty plaintext credential container was left on disk"
            )
        }

        await runAsync("stable signed credential store migrates local keys then deletes plaintext", failures: &failures) {
            let keychain = ProviderCredentialStoreFake()
            let local = ProviderCredentialStoreFake(values: [.doubao: "legacy-key"])
            let store = MigratingProviderCredentialStore(
                primary: keychain,
                legacy: local
            )

            let migrated = try await store.apiKey(for: .doubao)
            let keychainValue = try await keychain.apiKey(for: .doubao)
            let localValue = try await local.apiKey(for: .doubao)
            try expect(migrated == "legacy-key")
            try expect(keychainValue == "legacy-key")
            try expect(localValue == nil)
        }

        await runAsync("credential migration verifies Keychain readback and does not block a valid primary on cleanup failure", failures: &failures) {
            let mismatchedPrimary = ProviderCredentialStoreFake(corruptsSavedValues: true)
            let retainedLegacy = ProviderCredentialStoreFake(values: [.doubao: "legacy-key"])
            let mismatchedStore = MigratingProviderCredentialStore(
                primary: mismatchedPrimary,
                legacy: retainedLegacy
            )
            do {
                _ = try await mismatchedStore.apiKey(for: .doubao)
                throw SpecFailure(message: "migration accepted a mismatched primary readback")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .storageUnavailable)
            }
            let retainedLegacyValue = try await retainedLegacy.apiKey(for: .doubao)
            try expect(retainedLegacyValue == "legacy-key")

            let validPrimary = ProviderCredentialStoreFake(values: [.doubao: "keychain-key"])
            let failingCleanup = ProviderCredentialStoreFake(
                values: [.doubao: "keychain-key"],
                deleteFails: true
            )
            let usableStore = MigratingProviderCredentialStore(
                primary: validPrimary,
                legacy: failingCleanup
            )
            let available = try await usableStore.apiKey(for: .doubao)
            let migrationNotice = await usableStore.migrationNotice()
            try expect(available == "keychain-key")
            try expect(migrationNotice != nil)
        }

        await runAsync("credential migration keeps a conflicting legacy key when primary already exists", failures: &failures) {
            let primary = ProviderCredentialStoreFake(
                values: [.doubao: "keychain-key"]
            )
            let legacy = ProviderCredentialStoreFake(
                values: [.doubao: "different-legacy-key"]
            )
            let store = MigratingProviderCredentialStore(
                primary: primary,
                legacy: legacy
            )

            let available = try await store.apiKey(for: .doubao)
            let primaryValue = try await primary.apiKey(for: .doubao)
            let legacyValue = try await legacy.apiKey(for: .doubao)
            let notice = await store.migrationNotice()

            try expect(available == "keychain-key")
            try expect(primaryValue == "keychain-key")
            try expect(
                legacyValue == "different-legacy-key",
                "a conflicting legacy credential was deleted"
            )
            try expect(notice?.contains("doubao") == true)
        }

        await runAsync("credential deletion keeps the primary key when legacy cleanup fails", failures: &failures) {
            let primary = ProviderCredentialStoreFake(
                values: [.doubao: "keychain-key"]
            )
            let legacy = ProviderCredentialStoreFake(
                values: [.doubao: "plaintext-key"],
                deleteFails: true
            )
            let store = MigratingProviderCredentialStore(
                primary: primary,
                legacy: legacy
            )

            do {
                try await store.deleteAPIKey(for: .doubao)
                throw SpecFailure(
                    message: "delete succeeded while plaintext cleanup failed"
                )
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .storageUnavailable)
            }

            let primaryValue = try await primary.apiKey(for: .doubao)
            let availableValue = try await store.apiKey(for: .doubao)
            try expect(
                primaryValue == "keychain-key",
                "primary key was deleted before legacy cleanup committed"
            )
            try expect(
                availableValue == "keychain-key",
                "legacy key replaced the retained primary after failed deletion"
            )
        }

        await runAsync("credential migration preserves every legacy source when values conflict", failures: &failures) {
            let primary = ProviderCredentialStoreFake()
            let oldKeychain = ProviderCredentialStoreFake(
                values: [.doubao: "old-keychain-key"]
            )
            let plaintext = ProviderCredentialStoreFake(
                values: [.doubao: "plaintext-key"]
            )
            let legacy = LegacyProviderCredentialStoreChain(
                stores: [oldKeychain, plaintext]
            )
            let store = MigratingProviderCredentialStore(
                primary: primary,
                legacy: legacy
            )

            do {
                _ = try await store.apiKey(for: .doubao)
                throw SpecFailure(message: "conflicting legacy credentials were migrated")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .conflictingStoredValues)
            }
            let primaryValue = try await primary.apiKey(for: .doubao)
            let oldKeychainValue = try await oldKeychain.apiKey(for: .doubao)
            let plaintextValue = try await plaintext.apiKey(for: .doubao)
            try expect(primaryValue == nil)
            try expect(oldKeychainValue == "old-keychain-key")
            try expect(plaintextValue == "plaintext-key")

            await store.migrateAllProviders()
            let notice = await store.migrationNotice()
            try expect(notice?.contains("doubao") == true)
        }

        await runAsync("credential migration never cleans readable legacy data when another source cannot be inspected", failures: &failures) {
            let primary = ProviderCredentialStoreFake()
            let unreadable = ProviderCredentialStoreFake(
                readError: .interactionUnavailable
            )
            let plaintext = ProviderCredentialStoreFake(
                values: [.deepSeek: "readable-key"]
            )
            let legacy = LegacyProviderCredentialStoreChain(
                stores: [unreadable, plaintext]
            )
            let store = MigratingProviderCredentialStore(
                primary: primary,
                legacy: legacy
            )

            do {
                _ = try await store.apiKey(for: .deepSeek)
                throw SpecFailure(message: "partially inspected legacy credentials were migrated")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .interactionUnavailable)
            }
            let primaryValue = try await primary.apiKey(for: .deepSeek)
            let plaintextValue = try await plaintext.apiKey(for: .deepSeek)
            try expect(primaryValue == nil)
            try expect(plaintextValue == "readable-key")
        }

        await runAsync("versioned local history persists searches deletes and excludes sensitive fields", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.json")
            let firstID = VoiceInputSessionID()
            let secondID = VoiceInputSessionID()
            let snapshotID = UUID()
            let dictionaryEntry = DictionaryEntry(canonicalTerm: "豆包", aliases: ["豆宝"])
            let store = VersionedLocalSessionHistory(fileURL: fileURL)
            await store.save(.init(
                sessionID: firstID,
                startedAt: Date(timeIntervalSince1970: 100),
                applicationName: "TextEdit",
                transcription: "豆包原文 alpha",
                finalText: "最终文本",
                transcriptionProvider: "doubao",
                providerRequestID: "request-log-1",
                providerErrorCode: nil,
                deliveryDiagnosticCode:
                    "directReceipt.unconfirmed",
                deepSeekText: "DeepSeek 结果 beta",
                deepSeekRequestID: "deepseek-log-1",
                refinementModeName: "精简清理",
                refinementPrompt: "只清理口语杂质",
                refinementStatus: "succeeded",
                dictionarySnapshotID: snapshotID,
                dictionarySnapshotEntries: [dictionaryEntry],
                dictionaryRequestContext: .init(
                    snapshotID: snapshotID,
                    hotwords: ["豆包"],
                    includedEntryIDs: [dictionaryEntry.id],
                    omissions: []
                ),
                dictionaryReplacements: [
                    .init(
                        entryID: UUID(),
                        alias: "豆宝",
                        canonicalTerm: "豆包",
                        matchedText: "豆宝",
                        utf16Location: 0,
                        utf16Length: 2
                    ),
                ],
                durationMilliseconds: 1_234,
                stageDurationsMilliseconds: ["doubao": 500, "deepseek": 300],
                outcome: .delivered(firstID, applicationName: "TextEdit", text: "最终文本")
            ))
            await store.save(.init(
                sessionID: secondID,
                startedAt: Date(timeIntervalSince1970: 200),
                applicationName: "Notes",
                transcription: nil,
                finalText: nil,
                providerRequestID: "request-log-2",
                providerErrorCode: "invalidCredential",
                outcome: .failed(secondID, .providerNotConfigured)
            ))

            let reloaded = VersionedLocalSessionHistory(fileURL: fileURL)
            let allRecords = await reloaded.allRecords()
            let transcriptMatches = await reloaded.search("ALPHA")
            let errorMatches = await reloaded.search("invalidcredential")
            let deliveryMatches = await reloaded.search(
                "directreceipt.unconfirmed"
            )
            let encoded = try String(contentsOf: fileURL, encoding: .utf8)
            let historyAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(
                (historyAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "history file is not owner-only"
            )
            try expect(allRecords.map(\.sessionID) == [secondID, firstID])
            try expect(transcriptMatches.map(\.sessionID) == [firstID])
            try expect(errorMatches.map(\.sessionID) == [secondID])
            try expect(deliveryMatches.map(\.sessionID) == [firstID])
            try expect(allRecords.last?.deepSeekText == "DeepSeek 结果 beta")
            try expect(allRecords.last?.transcriptionProvider == "doubao")
            try expect(
                allRecords.last?.deliveryDiagnosticCode
                    == "directReceipt.unconfirmed"
            )
            try expect(allRecords.last?.refinementPrompt == "只清理口语杂质")
            try expect(allRecords.last?.dictionarySnapshotEntries == [dictionaryEntry])
            try expect(allRecords.last?.dictionaryRequestContext?.hotwords == ["豆包"])
            try expect(allRecords.last?.dictionaryReplacements.count == 1)
            try expect(allRecords.last?.stageDurationsMilliseconds["doubao"] == 500)
            try expect(!encoded.contains("apiKey"))
            try expect(!encoded.contains("audio"))
            try expect(!encoded.contains("clipboard"))

            let deleted = await reloaded.delete(sessionID: firstID)
            try expect(deleted)
            await reloaded.clear()
            let recordsAfterClear = await reloaded.allRecords()
            try expect(recordsAfterClear.isEmpty)
        }

        await runAsync("SQLite history scrubs provider response text written by older builds", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-message-scrub-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let id = VoiceInputSessionID()
            let store = SQLiteSessionHistory(fileURL: fileURL)
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: "TextEdit",
                transcription: nil,
                finalText: nil,
                providerErrorCode: "authentication",
                providerMessage: "future-api-key-secret",
                refinementFailureMessage: "private-refinement-context",
                outcome: .failed(id, .providerAuthenticationFailed)
            ))
            try injectLegacyProviderMessages(into: fileURL)

            let scrubbed = await store.scrubUntrustedProviderMessages()
            let payload = try readHistoryPayload(from: fileURL)
            let record = await store.record(sessionID: id)

            try expect(scrubbed)
            try expect(record?.providerMessage == nil)
            try expect(record?.refinementFailureMessage == nil)
            try expect(
                !payload.contains("future-api-key-secret")
                    && !payload.contains("private-refinement-context"),
                "provider response text remained in SQLite payload"
            )
        }

        await runAsync("SQLite history drops malformed legacy rows that cannot be safely scrubbed", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-malformed-message-scrub-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let secret = "malformed-provider-secret-\(UUID().uuidString)"
            try injectMalformedProviderMessageRow(
                into: fileURL,
                secret: secret
            )

            let scrubbed = await store.scrubUntrustedProviderMessages()
            let status = await store.persistenceStatus()

            try expect(scrubbed)
            try expect(status.recordCount == 0)
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "malformed provider response text remained in SQLite storage"
            )
        }

        await runAsync("SQLite privacy scrub failure survives later writes and retries physical sanitization", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-message-scrub-retry-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let id = VoiceInputSessionID()
            let secret = "retry-provider-secret-\(UUID().uuidString)"
            let store = SQLiteSessionHistory(fileURL: fileURL)
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: "TextEdit",
                transcription: nil,
                finalText: nil,
                outcome: .failed(id, .providerAuthenticationFailed)
            ))
            try injectProviderMessage(
                secret,
                into: fileURL
            )

            var reader: OpaquePointer?
            try expect(
                sqlite3_open_v2(
                    fileURL.path,
                    &reader,
                    SQLITE_OPEN_READONLY,
                    nil
                ) == SQLITE_OK
            )
            guard let reader else {
                throw SpecFailure(message: "could not open privacy scrub reader")
            }
            defer { sqlite3_close(reader) }
            try expect(
                sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK
            )
            var statement: OpaquePointer?
            try expect(
                sqlite3_prepare_v2(
                    reader,
                    "SELECT payload FROM history_records LIMIT 1",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            )
            guard let statement else {
                throw SpecFailure(message: "could not prepare privacy scrub reader")
            }
            try expect(sqlite3_step(statement) == SQLITE_ROW)

            let firstScrub = await store.scrubUntrustedProviderMessages()
            let failedStatus = await store.persistenceStatus()
            try expect(!firstScrub)
            guard case .privacyMigrationFailed = failedStatus.notice else {
                throw SpecFailure(
                    message: "privacy scrub failure was not reported explicitly"
                )
            }

            sqlite3_finalize(statement)
            try expect(
                sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK
            )
            let retentionApplied = await store.applyRetentionPolicy(
                .thirtyDays,
                now: Date()
            )
            let statusAfterWrite = await store.persistenceStatus()
            try expect(retentionApplied)
            guard case .privacyMigrationFailed = statusAfterWrite.notice else {
                throw SpecFailure(
                    message: "later successful write hid the privacy scrub failure"
                )
            }

            let retryScrub = await store.scrubUntrustedProviderMessages()
            let completedStatus = await store.persistenceStatus()
            try expect(retryScrub)
            try expect(completedStatus.notice == nil)
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "retry did not remove provider text from physical SQLite pages"
            )
        }

        await runAsync("SQLite history incrementally upserts reloads searches and securely clears", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-history-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(
                fileURL: fileURL,
                maximumRecordCount: 3
            )
            let id = VoiceInputSessionID()
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: "TextEdit",
                transcription: "第一阶段",
                finalText: nil,
                providerRequestID: "sqlite-request",
                outcome: .processing(id, .transcribing, applicationName: "TextEdit")
            ))
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: "TextEdit",
                transcription: "豆包增量结果",
                finalText: "最终增量结果",
                providerRequestID: "sqlite-request",
                deepSeekText: "最终增量结果",
                outcome: .delivered(id, applicationName: "TextEdit", text: "最终增量结果")
            ))

            let reloaded = SQLiteSessionHistory(fileURL: fileURL)
            let records = await reloaded.allRecords()
            let matches = await reloaded.search("增量")
            let status = await reloaded.persistenceStatus()
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(records.count == 1)
            try expect(records.first?.finalText == "最终增量结果")
            try expect(matches.map(\.sessionID) == [id])
            try expect(status.recordCount == 1)
            try expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "SQLite history file is not owner-only"
            )
            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )
            try expect(
                (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                "SQLite history directory is not owner-only"
            )
            let sqliteFiles = ["", "-wal", "-shm"].map {
                URL(fileURLWithPath: fileURL.path + $0)
            }.filter { FileManager.default.fileExists(atPath: $0.path) }
            try expect(sqliteFiles.count >= 2, "SQLite sidecars were not created for permission verification")
            for sqliteFile in sqliteFiles {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: sqliteFile.path
                )
            }
            if let record = records.first {
                await reloaded.save(record)
            }
            for sqliteFile in sqliteFiles {
                let protectedAttributes = try FileManager.default.attributesOfItem(
                    atPath: sqliteFile.path
                )
                try expect(
                    (protectedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                    "SQLite main or sidecar permission was not repaired"
                )
            }

            let legacyFile = directory.appendingPathComponent("history.json")
            let recoveryFile = directory.appendingPathComponent("history.corrupt-1.json")
            try Data("legacy".utf8).write(to: legacyFile)
            try Data("recovery".utf8).write(to: recoveryFile)
            let cleared = await reloaded.clear()
            let afterClear = await reloaded.allRecords()
            try expect(cleared)
            try expect(afterClear.isEmpty)
            try expect(!FileManager.default.fileExists(atPath: legacyFile.path))
            try expect(!FileManager.default.fileExists(atPath: recoveryFile.path))

            let migrationStore = SQLiteSessionHistory(
                fileURL: directory.appendingPathComponent("migration.sqlite3")
            )
            let imported = await migrationStore.importLegacyRecords(records)
            let importedRecord = await migrationStore.record(sessionID: id)
            try expect(imported)
            try expect(importedRecord?.finalText == "最终增量结果")
        }

        await runAsync("SQLite startup recovery terminates sessions left active by a previous process", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-interrupted-session-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let interruptedID = VoiceInputSessionID()
            let deliveredID = VoiceInputSessionID()
            await store.save(.init(
                sessionID: interruptedID,
                startedAt: Date(),
                applicationName: "TextEdit",
                transcription: "已经确认的豆包文字",
                finalText: nil,
                transcriptionProvider: "doubao",
                providerRequestID: "interrupted-request",
                outcome: .processing(
                    interruptedID,
                    .refining,
                    applicationName: "TextEdit"
                )
            ))
            await store.save(.init(
                sessionID: deliveredID,
                startedAt: Date().addingTimeInterval(-1),
                applicationName: "Notes",
                transcription: "完成",
                finalText: "完成",
                outcome: .delivered(
                    deliveredID,
                    applicationName: "Notes",
                    text: "完成"
                )
            ))

            let reconciledCount =
                await store.reconcileInterruptedSessions()
            let interrupted = await store.record(
                sessionID: interruptedID
            )
            let delivered = await store.record(sessionID: deliveredID)

            try expect(reconciledCount == 1)
            try expect(
                interrupted?.outcome
                    == .failed(interruptedID, .sessionInterrupted)
            )
            try expect(
                interrupted?.providerErrorCode
                    == "application.interrupted.refining"
            )
            try expect(
                interrupted?.transcription == "已经确认的豆包文字"
            )
            try expect(delivered?.outcome.isDelivered == true)
        }

        await runAsync("SQLite clear reports a busy checkpoint and completes sanitization after the reader releases", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-busy-clear-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let id = VoiceInputSessionID()
            let secret = "speaker-sensitive-clear-marker-\(UUID().uuidString)"
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: nil,
                transcription: secret,
                finalText: secret,
                outcome: .pendingCopy(id, text: secret, reason: .missingTarget)
            ))

            var reader: OpaquePointer?
            try expect(sqlite3_open_v2(fileURL.path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            guard let reader else { throw SpecFailure(message: "could not open SQLite reader") }
            defer { sqlite3_close(reader) }
            try expect(sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK)
            var statement: OpaquePointer?
            try expect(
                sqlite3_prepare_v2(reader, "SELECT payload FROM history_records LIMIT 1", -1, &statement, nil) == SQLITE_OK
            )
            guard let statement else { throw SpecFailure(message: "could not prepare SQLite reader") }
            try expect(sqlite3_step(statement) == SQLITE_ROW)

            let firstClear = await store.clear()
            let firstStatus = await store.persistenceStatus()
            try expect(!firstClear, "busy checkpoint was reported as a completed clear")
            try expect(firstStatus.notice != nil)

            sqlite3_finalize(statement)
            try expect(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            let completedClear = await store.clear()
            let recordsAfterClear = await store.allRecords()
            try expect(completedClear)
            try expect(recordsAfterClear.isEmpty)

            let marker = Data(secret.utf8)
            for suffix in ["", "-wal", "-journal"] {
                let candidate = URL(fileURLWithPath: fileURL.path + suffix)
                guard let data = try? Data(contentsOf: candidate) else { continue }
                try expect(data.range(of: marker) == nil, "cleared SQLite file retained plaintext marker")
            }
        }

        await runAsync("SQLite retention keeps the committed policy when a later checkpoint is busy", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-sqlite-busy-retention-\(UUID().uuidString)"
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let now = Date()
            let oldID = VoiceInputSessionID()
            await store.save(.init(
                sessionID: oldID,
                startedAt: now.addingTimeInterval(-90 * 86_400),
                applicationName: "TextEdit",
                transcription: "old",
                finalText: "old",
                outcome: .delivered(
                    oldID,
                    applicationName: "TextEdit",
                    text: "old"
                )
            ))

            var reader: OpaquePointer?
            try expect(
                sqlite3_open_v2(
                    fileURL.path,
                    &reader,
                    SQLITE_OPEN_READONLY,
                    nil
                ) == SQLITE_OK
            )
            guard let reader else {
                throw SpecFailure(message: "could not open retention reader")
            }
            defer { sqlite3_close(reader) }
            try expect(
                sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK
            )
            var statement: OpaquePointer?
            try expect(
                sqlite3_prepare_v2(
                    reader,
                    "SELECT payload FROM history_records LIMIT 1",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            )
            guard let statement else {
                throw SpecFailure(message: "could not prepare retention reader")
            }
            try expect(sqlite3_step(statement) == SQLITE_ROW)

            let fullyApplied = await store.applyRetentionPolicy(
                .thirtyDays,
                now: now
            )
            let currentPolicy = await store.currentRetentionPolicy()
            let records = await store.allRecords()

            try expect(!fullyApplied)
            try expect(
                currentPolicy == .thirtyDays,
                "post-commit checkpoint failure rewound the applied policy"
            )
            try expect(
                records.isEmpty,
                "committed retention deletion was unexpectedly restored"
            )

            sqlite3_finalize(statement)
            try expect(
                sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK
            )
        }

        await runAsync("SQLite cap pruning retries physical WAL sanitization after a busy reader", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-sqlite-cap-sanitization-\(UUID().uuidString)"
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(
                fileURL: fileURL,
                maximumRecordCount: 1
            )
            let secret = "pruned-history-secret-\(UUID().uuidString)"
            let oldID = VoiceInputSessionID()
            await store.save(.init(
                sessionID: oldID,
                startedAt: Date(timeIntervalSince1970: 1),
                applicationName: "TextEdit",
                transcription: secret,
                finalText: secret,
                outcome: .delivered(
                    oldID,
                    applicationName: "TextEdit",
                    text: secret
                )
            ))

            var reader: OpaquePointer?
            try expect(
                sqlite3_open_v2(
                    fileURL.path,
                    &reader,
                    SQLITE_OPEN_READONLY,
                    nil
                ) == SQLITE_OK
            )
            guard let reader else {
                throw SpecFailure(message: "could not open cap-pruning reader")
            }
            defer { sqlite3_close(reader) }
            try expect(sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK)
            var statement: OpaquePointer?
            try expect(
                sqlite3_prepare_v2(
                    reader,
                    "SELECT payload FROM history_records LIMIT 1",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            )
            guard let statement else {
                throw SpecFailure(message: "could not prepare cap-pruning reader")
            }
            try expect(sqlite3_step(statement) == SQLITE_ROW)

            let replacementID = VoiceInputSessionID()
            let replacement = VoiceInputHistoryRecord(
                sessionID: replacementID,
                startedAt: Date(timeIntervalSince1970: 2),
                applicationName: "TextEdit",
                transcription: "replacement",
                finalText: "replacement",
                outcome: .delivered(
                    replacementID,
                    applicationName: "TextEdit",
                    text: "replacement"
                )
            )
            await store.save(replacement)
            let pendingStatus = await store.persistenceStatus()
            guard case .writeFailed = pendingStatus.notice else {
                throw SpecFailure(message: "busy cap sanitization was hidden")
            }

            sqlite3_finalize(statement)
            try expect(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            await store.save(replacement)
            let completedStatus = await store.persistenceStatus()
            try expect(completedStatus.notice == nil)
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "cap-pruned history remained in physical SQLite/WAL pages"
            )
        }

        await runAsync("SQLite history closes explicitly before owned files are erased", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-sqlite-erasure-close-\(UUID().uuidString)"
                )
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let id = VoiceInputSessionID()
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: "TextEdit",
                transcription: "must not return",
                finalText: "must not return",
                outcome: .delivered(
                    id,
                    applicationName: "TextEdit",
                    text: "must not return"
                )
            ))

            let firstClose = await store.closeForErasure()
            let secondClose = await store.closeForErasure()
            try expect(firstClose)
            try expect(secondClose)
            try FileManager.default.removeItem(at: directory)
            let lateID = VoiceInputSessionID()
            await store.save(.init(
                sessionID: lateID,
                startedAt: Date(),
                applicationName: nil,
                transcription: "late write",
                finalText: "late write",
                outcome: .failed(
                    lateID,
                    .recordingFailed
                )
            ))
            try expect(!FileManager.default.fileExists(atPath: directory.path))
            let status = await store.persistenceStatus()
            try expect(status.recordCount == 0)
        }

        await runAsync("SQLite recovers a corrupt database as one protected recovery set", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-corrupt-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            try Data("not-a-sqlite-database".utf8).write(to: fileURL)

            let store = SQLiteSessionHistory(fileURL: fileURL)
            let status = await store.persistenceStatus()
            guard case let .corruptedDataPreserved(backupURL, _) = status.notice else {
                throw SpecFailure(message: "corrupt SQLite database was not preserved")
            }
            try expect(FileManager.default.fileExists(atPath: backupURL.path))
            let id = VoiceInputSessionID()
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: nil,
                transcription: "recovered",
                finalText: "recovered",
                outcome: .pendingCopy(id, text: "recovered", reason: .missingTarget)
            ))
            let recoveredRecord = await store.record(sessionID: id)
            try expect(recoveredRecord != nil)
            let cleared = await store.clear()
            try expect(cleared)
            try expect(!FileManager.default.fileExists(atPath: backupURL.path))
        }

        await runAsync("SQLite skips malformed rows without misreporting a write failure", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-malformed-row-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.sqlite3")
            let store = SQLiteSessionHistory(fileURL: fileURL)
            let healthyID = VoiceInputSessionID()
            let healthyRecord = VoiceInputHistoryRecord(
                sessionID: healthyID,
                startedAt: Date(),
                applicationName: "TextEdit",
                transcription: "healthy",
                finalText: "healthy",
                outcome: .delivered(
                    healthyID,
                    applicationName: "TextEdit",
                    text: "healthy"
                )
            )
            await store.save(healthyRecord)

            var writer: OpaquePointer?
            try expect(
                sqlite3_open_v2(fileURL.path, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
            )
            guard let writer else { throw SpecFailure(message: "could not open SQLite writer") }
            defer { sqlite3_close(writer) }
            try expect(
                sqlite3_exec(
                    writer,
                    "INSERT INTO history_records(session_id, started_at, payload, payload_schema) VALUES('00000000-0000-0000-0000-000000000001', 1, X'FF', 1)",
                    nil,
                    nil,
                    nil
                ) == SQLITE_OK
            )

            let records = await store.allRecords()
            let status = await store.persistenceStatus()
            try expect(records.map(\.sessionID) == [healthyID])
            try expect(status.recordCount == 2)
            guard case .corruptedRecordsSkipped(count: 1) = status.notice else {
                throw SpecFailure(message: "malformed history row was not reported precisely")
            }

            await store.save(healthyRecord)
            let statusAfterSuccessfulWrite = await store.persistenceStatus()
            guard case .corruptedRecordsSkipped(count: 1) = statusAfterSuccessfulWrite.notice else {
                throw SpecFailure(message: "successful write hid a persistent malformed row")
            }

            let cleared = await store.clear()
            try expect(cleared)
            let statusAfterClear = await store.persistenceStatus()
            try expect(statusAfterClear.notice == nil)
        }

        await runAsync("SQLite legacy import applies retention and cap before verifying the final set", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-sqlite-import-retention-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let now = Date()
            let store = SQLiteSessionHistory(
                fileURL: directory.appendingPathComponent("history.sqlite3"),
                retentionPolicy: .thirtyDays,
                maximumRecordCount: 3
            )
            var records: [VoiceInputHistoryRecord] = []
            for offset in 0..<5 {
                let id = VoiceInputSessionID()
                let date = offset == 0
                    ? now.addingTimeInterval(-100 * 86_400)
                    : now.addingTimeInterval(Double(offset))
                records.append(.init(
                    sessionID: id,
                    startedAt: date,
                    applicationName: nil,
                    transcription: "legacy-\(offset)",
                    finalText: "legacy-\(offset)",
                    outcome: .pendingCopy(id, text: "legacy-\(offset)", reason: .missingTarget)
                ))
            }
            let imported = await store.importLegacyRecords(records)
            let retained = await store.allRecords()
            try expect(imported)
            try expect(retained.count == 3)
            try expect(retained.map(\.finalText) == ["legacy-4", "legacy-3", "legacy-2"])
        }

        await runAsync("corrupt history is preserved with a recoverable notice", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-corrupt-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            try Data("not-json".utf8).write(to: fileURL)

            let store = VersionedLocalSessionHistory(fileURL: fileURL)
            let status = await store.persistenceStatus()
            if case let .corruptedDataPreserved(backupURL, _) = status.notice {
                try expect(FileManager.default.fileExists(atPath: backupURL.path))
                let cleared = await store.clear()
                try expect(cleared)
                try expect(!FileManager.default.fileExists(atPath: backupURL.path))
                let clearedStatus = await store.persistenceStatus()
                try expect(clearedStatus.notice == nil)
            } else {
                throw SpecFailure(message: "corrupt history did not produce a preserved recovery notice")
            }
            let recoveredRecords = await store.allRecords()
            try expect(recoveredRecords.isEmpty)
        }

        await runAsync("history retention prunes by age and enforces a hard safety cap", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-retention-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let capped = VersionedLocalSessionHistory(
                fileURL: directory.appendingPathComponent("capped.json"),
                maximumRecordCount: 3
            )
            let now = Date()
            for offset in 0..<4 {
                let id = VoiceInputSessionID()
                await capped.save(.init(
                    sessionID: id,
                    startedAt: now.addingTimeInterval(Double(offset)),
                    applicationName: nil,
                    transcription: "record-\(offset)",
                    finalText: "record-\(offset)",
                    outcome: .pendingCopy(id, text: "record-\(offset)", reason: .missingTarget)
                ))
            }
            let cappedRecords = await capped.allRecords()
            try expect(cappedRecords.count == 3)
            try expect(cappedRecords.first?.finalText == "record-3")

            let aged = VersionedLocalSessionHistory(
                fileURL: directory.appendingPathComponent("aged.json")
            )
            let oldID = VoiceInputSessionID()
            let currentID = VoiceInputSessionID()
            await aged.save(.init(
                sessionID: oldID,
                startedAt: now.addingTimeInterval(-100 * 86_400),
                applicationName: nil,
                transcription: "old",
                finalText: "old",
                outcome: .pendingCopy(oldID, text: "old", reason: .missingTarget)
            ))
            await aged.save(.init(
                sessionID: currentID,
                startedAt: now,
                applicationName: nil,
                transcription: "current",
                finalText: "current",
                outcome: .pendingCopy(currentID, text: "current", reason: .missingTarget)
            ))
            let appliedRetention = await aged.applyRetentionPolicy(.thirtyDays, now: now)
            try expect(appliedRetention)
            let agedRecords = await aged.allRecords()
            try expect(agedRecords.map(\.sessionID) == [currentID])
        }

        await runAsync("history delete and clear roll back when disk write fails", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-write-failure-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("blocks-directory".utf8).write(to: directory)
            let store = VersionedLocalSessionHistory(
                fileURL: directory.appendingPathComponent("history.json")
            )
            let id = VoiceInputSessionID()
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: nil,
                transcription: "需要保留",
                finalText: "需要保留",
                outcome: .pendingCopy(id, text: "需要保留", reason: .missingTarget)
            ))

            let deleted = await store.delete(sessionID: id)
            let cleared = await store.clear()
            let records = await store.allRecords()
            try expect(!deleted)
            try expect(!cleared)
            try expect(records.map(\.sessionID) == [id])
        }

        await runAsync("legacy history refuses to load when owner-only protection fails", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-protection-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.json")
            let writer = VersionedLocalSessionHistory(fileURL: fileURL)
            let id = VoiceInputSessionID()
            await writer.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: nil,
                transcription: "private history",
                finalText: "private history",
                outcome: .pendingCopy(
                    id,
                    text: "private history",
                    reason: .missingTarget
                )
            ))

            let protected = VersionedLocalSessionHistory(
                fileURL: fileURL,
                fileProtection: LocalFileProtection { _ in
                    throw FileProtectionFailure()
                }
            )
            let records = await protected.allRecords()
            let status = await protected.persistenceStatus()

            try expect(records.isEmpty)
            guard case .privacyMigrationFailed = status.notice else {
                throw SpecFailure(message: "history protection failure was hidden")
            }
        }

        run("personal dictionary reports empty duplicate and conflicting enabled aliases", failures: &failures) {
            let emptyID = UUID()
            let duplicateOne = UUID()
            let duplicateTwo = UUID()
            let aliasOne = UUID()
            let aliasTwo = UUID()
            let issues = PersonalDictionaryValidator.validate([
                .init(id: emptyID, canonicalTerm: " "),
                .init(id: duplicateOne, canonicalTerm: "Speaker"),
                .init(id: duplicateTwo, canonicalTerm: "speaker"),
                .init(id: aliasOne, canonicalTerm: "Swift", aliases: ["斯威夫特"]),
                .init(id: aliasTwo, canonicalTerm: "SwiftUI", aliases: ["斯威夫特"]),
            ])

            try expect(issues.contains(.emptyCanonicalTerm(entryID: emptyID)))
            try expect(issues.contains { issue in
                if case .duplicateCanonicalTerm = issue { true } else { false }
            })
            try expect(issues.contains { issue in
                if case .conflictingEnabledAlias = issue { true } else { false }
            })
        }

        run("dictionary snapshot and provider truncation are deterministic", failures: &failures) {
            let alpha = DictionaryEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                canonicalTerm: "Alpha",
                aliases: ["A"]
            )
            let beta = DictionaryEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                canonicalTerm: "Beta"
            )
            let disabled = DictionaryEntry(canonicalTerm: "Disabled", isEnabled: false)
            let long = DictionaryEntry(canonicalTerm: "VeryLongTerm")
            let dictionary = try PersonalDictionary(entries: [long, disabled, beta, alpha])
            let snapshot = dictionary.snapshotEnabled(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                createdAt: Date(timeIntervalSince1970: 10)
            )
            let context = DictionaryRequestContextBuilder.makeContext(
                from: snapshot,
                capacity: .init(maximumHotwordCount: 1, maximumCharactersPerHotword: 6)
            )

            try expect(snapshot.entries.map(\.canonicalTerm) == ["Alpha", "Beta", "VeryLongTerm"])
            try expect(context.hotwords == ["Alpha"])
            try expect(context.includedEntryIDs == [alpha.id])
            try expect(context.omissions.contains { $0.reason == .providerCountLimit })
            try expect(context.omissions.contains { $0.reason == .providerTermLengthLimit })
        }

        run("dictionary alias normalization replaces only complete unambiguous tokens", failures: &failures) {
            let dictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "Swift", aliases: ["swift-lang"]),
                .init(canonicalTerm: "SwiftUI", aliases: ["swift-ui"]),
                .init(canonicalTerm: "豆包", aliases: ["豆宝"]),
            ])
            let result = DictionaryAliasNormalizer.normalize(
                "我用豆宝写字。Use swift-lang, not swift-language; then swift-ui.",
                using: dictionary.snapshotEnabled()
            )

            try expect(result.normalizedText == "我用豆包写字。Use Swift, not swift-language; then SwiftUI.")
            try expect(result.replacements.map(\.matchedText) == ["豆宝", "swift-lang", "swift-ui"])
            let ordinarySubstring = DictionaryAliasNormalizer.normalize(
                "豆宝贝",
                using: dictionary.snapshotEnabled()
            )
            try expect(ordinarySubstring.normalizedText == "豆宝贝")
        }

        await runAsync("versioned personal dictionary store round trips locally", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-dictionary-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("dictionary.json")
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)
            let dictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "豆包", aliases: ["豆宝"]),
                .init(canonicalTerm: "DeepSeek", aliases: ["deep seek"], isEnabled: false),
            ])

            try await store.save(dictionary)
            let loaded = try await store.load()
            try expect(loaded == dictionary)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "dictionary file is not owner-only"
            )
        }

        await runAsync("personal dictionary refuses an unreadable oversized save and retains the old file", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-dictionary-size-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("dictionary.json")
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)
            let retained = try PersonalDictionary(entries: [
                .init(canonicalTerm: "retained-term"),
            ])
            try await store.save(retained)
            let oversized = try PersonalDictionary(entries: [
                .init(canonicalTerm: String(repeating: "字", count: 3 * 1_024 * 1_024)),
            ])

            do {
                try await store.save(oversized)
                throw SpecFailure(message: "oversized dictionary was saved")
            } catch let error as PersonalDictionaryStoreError {
                try expect(error == .writeFailed)
            }
            let reloaded = try await store.load()
            try expect(
                reloaded == retained,
                "oversized dictionary replaced the readable file"
            )
        }

        await runAsync("personal dictionary refuses to load when owner-only protection fails", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-protection-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("dictionary.json")
            let writer = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)
            try await writer.save(
                PersonalDictionary(entries: [
                    .init(canonicalTerm: "private term"),
                ])
            )
            let protected = VersionedJSONPersonalDictionaryStore(
                fileURL: fileURL,
                fileProtection: LocalFileProtection { _ in
                    throw FileProtectionFailure()
                }
            )

            do {
                _ = try await protected.load()
                throw SpecFailure(message: "unprotected dictionary was loaded")
            } catch let failure as PersonalDictionaryStoreError {
                try expect(failure == .privacyProtectionFailed)
            }
        }

        await runAsync("personal dictionary migration verifies the stable copy before removing legacy data", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-migration-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let legacyURL = directory
                .appendingPathComponent("legacy/dictionary.json")
            let primaryURL = directory
                .appendingPathComponent("Speaker/personal-dictionary.json")
            let dictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "豆包", aliases: ["豆宝"]),
            ])
            try await VersionedJSONPersonalDictionaryStore(fileURL: legacyURL)
                .save(dictionary)

            let outcome = await VersionedJSONPersonalDictionaryStore
                .migrateLegacyFileIfNeeded(
                    from: legacyURL,
                    to: primaryURL
                )
            let migrated = try await VersionedJSONPersonalDictionaryStore(
                fileURL: primaryURL
            ).load()

            try expect(outcome == .migrated)
            try expect(migrated == dictionary)
            try expect(
                !FileManager.default.fileExists(atPath: legacyURL.path),
                "verified legacy dictionary was not removed"
            )
        }

        await runAsync("personal dictionary migration never overwrites an existing stable dictionary", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-existing-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let legacyURL = directory.appendingPathComponent("legacy.json")
            let primaryURL = directory.appendingPathComponent("primary.json")
            let legacyDictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "旧词条"),
            ])
            let primaryDictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "新词条"),
            ])
            try await VersionedJSONPersonalDictionaryStore(fileURL: legacyURL)
                .save(legacyDictionary)
            try await VersionedJSONPersonalDictionaryStore(fileURL: primaryURL)
                .save(primaryDictionary)

            let outcome = await VersionedJSONPersonalDictionaryStore
                .migrateLegacyFileIfNeeded(
                    from: legacyURL,
                    to: primaryURL
                )
            let retained = try await VersionedJSONPersonalDictionaryStore(
                fileURL: primaryURL
            ).load()

            try expect(outcome == .primaryAlreadyExists)
            try expect(retained == primaryDictionary)
            try expect(
                FileManager.default.fileExists(atPath: legacyURL.path),
                "legacy data was removed without being selected for migration"
            )
        }

        await runAsync("corrupted legacy dictionary is preserved when migration fails", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-corrupt-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let legacyURL = directory.appendingPathComponent("legacy.json")
            let primaryURL = directory.appendingPathComponent("primary.json")
            try Data("not-json".utf8).write(to: legacyURL)

            let outcome = await VersionedJSONPersonalDictionaryStore
                .migrateLegacyFileIfNeeded(
                    from: legacyURL,
                    to: primaryURL
                )

            try expect(outcome == .failed)
            try expect(
                FileManager.default.fileExists(atPath: legacyURL.path),
                "corrupted legacy dictionary was deleted"
            )
            try expect(
                !FileManager.default.fileExists(atPath: primaryURL.path),
                "failed migration left a primary dictionary"
            )
        }

        await runAsync("owner-only settings never follow a symbolic-link file", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-settings-symlink-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let targetURL = directory.appendingPathComponent("outside.json")
            let fileURL = directory.appendingPathComponent("settings.json")
            try await VersionedLocalAppSettingsStore(fileURL: targetURL).save(
                SpeakerAppSettings(launchAtLogin: true)
            )
            try FileManager.default.createSymbolicLink(
                at: fileURL,
                withDestinationURL: targetURL
            )

            let result = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()

            try expect(result.settings == .default)
            guard case .recoveryFailed = result else {
                throw SpecFailure(message: "symlinked settings were loaded or recovered")
            }
            let target = await VersionedLocalAppSettingsStore(fileURL: targetURL).load()
            try expect(target.settings.launchAtLogin)
            let destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: fileURL.path
            )
            try expect(destination == targetURL.path)
        }

        await runAsync("owner-only dictionary and credentials never follow symbolic-link files", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-sensitive-symlink-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let dictionaryTarget = directory.appendingPathComponent("dictionary-target.json")
            let dictionaryLink = directory.appendingPathComponent("dictionary.json")
            let expectedDictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "private-term"),
            ])
            try await VersionedJSONPersonalDictionaryStore(fileURL: dictionaryTarget)
                .save(expectedDictionary)
            try FileManager.default.createSymbolicLink(
                at: dictionaryLink,
                withDestinationURL: dictionaryTarget
            )
            do {
                _ = try await VersionedJSONPersonalDictionaryStore(fileURL: dictionaryLink)
                    .load()
                throw SpecFailure(message: "symlinked dictionary was loaded")
            } catch let error as PersonalDictionaryStoreError {
                try expect(error == .privacyProtectionFailed)
            }

            let credentialTarget = directory.appendingPathComponent("credential-target.json")
            let credentialLink = directory.appendingPathComponent("credentials.json")
            let targetStore = LocalFileProviderCredentialStore(fileURL: credentialTarget)
            try await targetStore.save(apiKey: "private-key", for: .doubao)
            try FileManager.default.createSymbolicLink(
                at: credentialLink,
                withDestinationURL: credentialTarget
            )
            do {
                _ = try await LocalFileProviderCredentialStore(fileURL: credentialLink)
                    .apiKey(for: .doubao)
                throw SpecFailure(message: "symlinked credentials were loaded")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .storageUnavailable)
            }
        }

        await runAsync("owner-only persistence never writes through a symbolic-link directory", failures: &failures) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-directory-symlink-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let outsideDirectory = root.appendingPathComponent(
                "outside",
                isDirectory: true
            )
            let linkedDirectory = root.appendingPathComponent(
                "Speaker",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outsideDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: linkedDirectory,
                withDestinationURL: outsideDirectory
            )
            let fileURL = linkedDirectory.appendingPathComponent("settings.json")

            do {
                try await VersionedLocalAppSettingsStore(fileURL: fileURL).save(
                    SpeakerAppSettings(launchAtLogin: true)
                )
                throw SpecFailure(message: "settings were written through a symlink directory")
            } catch is AppSettingsStoreError {
                // Expected: the public store maps the fail-closed path error.
            }
            try expect(
                !FileManager.default.fileExists(
                    atPath: outsideDirectory
                        .appendingPathComponent("settings.json")
                        .path
                )
            )

            let outsideCredential = outsideDirectory.appendingPathComponent(
                "credentials.json"
            )
            try Data("external-credential".utf8).write(to: outsideCredential)
            do {
                _ = try OwnerOnlyFilePersistence.removeRegularFile(
                    at: linkedDirectory.appendingPathComponent("credentials.json")
                )
                throw SpecFailure(message: "credential was removed through a symlink directory")
            } catch let failure as SpecFailure {
                throw failure
            } catch {
                // Expected: removal uses the same no-follow directory boundary.
            }
            let retainedCredential = try Data(contentsOf: outsideCredential)
            try expect(
                retainedCredential == Data("external-credential".utf8),
                "external credential was changed"
            )
        }

        await runAsync("settings reject non-regular and oversized files without moving evidence", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-settings-file-boundary-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let directoryURL = directory.appendingPathComponent(
                "settings-as-directory.json",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            let nonRegular = await VersionedLocalAppSettingsStore(
                fileURL: directoryURL
            ).load()
            guard case .recoveryFailed = nonRegular else {
                throw SpecFailure(message: "non-regular settings were treated as recoverable JSON")
            }
            var isDirectory: ObjCBool = false
            try expect(
                FileManager.default.fileExists(
                    atPath: directoryURL.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue,
                "non-regular settings evidence was moved"
            )

            let oversizedURL = directory.appendingPathComponent("oversized-settings.json")
            try Data(repeating: 0x41, count: 1_048_577).write(to: oversizedURL)
            let oversized = await VersionedLocalAppSettingsStore(
                fileURL: oversizedURL
            ).load()
            guard case .recoveryFailed = oversized else {
                throw SpecFailure(message: "oversized settings were treated as recoverable JSON")
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: oversizedURL.path
            )
            try expect(
                (attributes[.size] as? NSNumber)?.intValue == 1_048_577,
                "oversized settings evidence was moved or rewritten"
            )

            let store = VersionedLocalAppSettingsStore(fileURL: oversizedURL)
            do {
                _ = try await store.updateLaunchAtLogin(true)
                throw SpecFailure(message: "an update overwrote unreadable settings")
            } catch let error as AppSettingsStoreError {
                guard case .writeFailed = error else {
                    throw SpecFailure(message: "unexpected settings update error")
                }
            }
            let retainedAttributes = try FileManager.default.attributesOfItem(
                atPath: oversizedURL.path
            )
            try expect(
                (retainedAttributes[.size] as? NSNumber)?.intValue == 1_048_577,
                "failed settings update did not preserve oversized evidence"
            )
        }

        run("recovery archives retain only recent bounded no-follow evidence", failures: &failures) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-recovery-budget-spec-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let now = Date()
            for index in 0..<5 {
                let file = root.appendingPathComponent(
                    "settings.recovery-\(index).json"
                )
                try OwnerOnlyFilePersistence.write(Data([UInt8(index)]), to: file)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-Double(index * 60))],
                    ofItemAtPath: file.path
                )
            }
            let external = root.appendingPathComponent("external-sentinel")
            try Data("external".utf8).write(to: external)
            let linked = root.appendingPathComponent("settings.recovery-linked.json")
            try FileManager.default.createSymbolicLink(
                at: linked,
                withDestinationURL: external
            )

            RecoveryArchivePruner.pruneRegularFiles(
                in: root,
                prefix: "settings.recovery-",
                suffix: ".json",
                now: now
            )

            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            try expect(names.contains("settings.recovery-0.json"))
            try expect(names.contains("settings.recovery-1.json"))
            try expect(names.contains("settings.recovery-2.json"))
            try expect(!names.contains("settings.recovery-3.json"))
            try expect(!names.contains("settings.recovery-4.json"))
            try expect(names.contains("settings.recovery-linked.json"))
            let sentinel = try Data(contentsOf: external)
            try expect(sentinel == Data("external".utf8))

            let old = root.appendingPathComponent("history.corrupt-old.json")
            try OwnerOnlyFilePersistence.write(Data("old".utf8), to: old)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(
                    -RecoveryArchivePruner.maximumAge - 60
                )],
                ofItemAtPath: old.path
            )
            let current = root.appendingPathComponent("history.corrupt-current.json")
            try OwnerOnlyFilePersistence.write(Data("current".utf8), to: current)
            RecoveryArchivePruner.pruneRegularFiles(
                in: root,
                prefix: "history.corrupt-",
                suffix: ".json",
                now: now
            )
            try expect(!FileManager.default.fileExists(atPath: old.path))
            try expect(FileManager.default.fileExists(atPath: current.path))

            for index in 0..<5 {
                let archive = root.appendingPathComponent(
                    "history.corrupt-\(index)",
                    isDirectory: true
                )
                let database = archive.appendingPathComponent("history.sqlite3")
                try OwnerOnlyFilePersistence.write(Data([UInt8(index)]), to: database)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-Double(index * 60))],
                    ofItemAtPath: archive.path
                )
            }
            RecoveryArchivePruner.pruneFlatDirectories(
                in: root,
                prefix: "history.corrupt-",
                now: now
            )
            let directoryNames = try FileManager.default.contentsOfDirectory(
                atPath: root.path
            )
            try expect(directoryNames.contains("history.corrupt-0"))
            try expect(directoryNames.contains("history.corrupt-1"))
            try expect(directoryNames.contains("history.corrupt-2"))
            try expect(!directoryNames.contains("history.corrupt-3"))
            try expect(!directoryNames.contains("history.corrupt-4"))
        }

        await runAsync("versioned app settings round trip shortcut refinement and login launch", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let store = VersionedLocalAppSettingsStore(fileURL: fileURL)
            let settings = SpeakerAppSettings(
                shortcut: .custom(keyCode: 49, modifiers: 2_048, displayName: "⌥ Space"),
                refinement: .custom(name: "短句", prompt: "只清理重复"),
                launchAtLogin: true,
                doubaoResourceID: DoubaoStreamingResource.model1Concurrent.rawValue,
                historyRetention: .thirtyDays
            )

            try await store.save(settings)
            let loaded = await store.load()
            try expect(loaded.settings == settings)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "settings file is not owner-only"
            )

            async let shortcutUpdate = store.updateShortcut(.functionKey)
            async let refinementUpdate = store.updateRefinement(.fullRewrite)
            async let loginUpdate = store.updateLaunchAtLogin(false)
            async let resourceUpdate = store.updateDoubaoResource(.model2Duration)
            async let retentionUpdate = store.updateHistoryRetention(.oneYear)
            _ = try await (
                shortcutUpdate,
                refinementUpdate,
                loginUpdate,
                resourceUpdate,
                retentionUpdate
            )
            let atomicallyUpdated = await store.load().settings
            try expect(atomicallyUpdated.shortcut == .functionKey)
            try expect(atomicallyUpdated.refinement == .fullRewrite)
            try expect(atomicallyUpdated.launchAtLogin == false)
            try expect(
                atomicallyUpdated.doubaoResourceID
                    == DoubaoStreamingResource.model2Duration.rawValue
            )
            try expect(atomicallyUpdated.historyRetention == .oneYear)

            let savedCustom = RefinementPreference(
                mode: .custom(name: "邮件", prompt: "整理成简洁邮件")
            )
            try await store.updateSavedCustomRefinement(savedCustom)
            try await store.updateRefinement(.defaultSmooth)
            let afterBuiltInSwitch = await store.load().settings
            try expect(afterBuiltInSwitch.refinement == .defaultSmooth)
            try expect(afterBuiltInSwitch.savedCustomRefinement == savedCustom)
        }

        await runAsync("legacy settings without retention preserve existing history", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-legacy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            let legacy = Data(#"{"schemaVersion":1,"settings":{"shortcut":{"kind":"functionKey"},"refinement":{"kind":"defaultSmooth"},"launchAtLogin":false}}"#.utf8)
            try legacy.write(to: fileURL)

            let loaded = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()
            try expect(loaded.settings.historyRetention == .forever)
        }

        await runAsync("settings refuse to load when owner-only protection fails", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-settings-protection-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let writer = VersionedLocalAppSettingsStore(fileURL: fileURL)
            try await writer.save(
                SpeakerAppSettings(launchAtLogin: true)
            )
            let protected = VersionedLocalAppSettingsStore(
                fileURL: fileURL,
                fileProtection: LocalFileProtection { _ in
                    throw FileProtectionFailure()
                }
            )

            let result = await protected.load()

            try expect(result.settings == .default)
            guard case let .recoveryFailed(_, reason) = result else {
                throw SpecFailure(message: "settings protection failure was hidden")
            }
            try expect(reason.contains("文件权限"))
        }

        run("app settings persistence errors have a user-facing description", failures: &failures) {
            let error = AppSettingsStoreError.writeFailed(reason: "disk unavailable")
            try expect(error.localizedDescription == "无法保存 Speaker 设置：disk unavailable")
        }

        await runAsync("corrupt app settings recover to defaults without overwriting evidence", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-corrupt-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            try Data("broken".utf8).write(to: fileURL)

            let result = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()
            if case let .recovered(settings, recovery) = result {
                try expect(settings == .default)
                try expect(FileManager.default.fileExists(atPath: recovery.backupURL.path))
            } else {
                throw SpecFailure(message: "corrupt settings were not preserved and recovered")
            }
        }

        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            Darwin.exit(1)
        }

        print("PASS: \(SpecExecutionCounter.value) core specs")
    }
}

private let specAudio = CapturedAudio(
    data: Data([0x52, 0x49, 0x46, 0x46]),
    duration: .seconds(1),
    peakPower: -10
)

@MainActor
private final class AccessibilityStateFake {
    var granted: Bool

    init(granted: Bool) {
        self.granted = granted
    }
}

@MainActor
private final class FunctionKeyMonitorFake: FunctionKeyMonitoring {
    private let startResult: FunctionKeyMonitorStartResult
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(startResult: FunctionKeyMonitorStartResult = .active) {
        self.startResult = startResult
    }

    func start() -> FunctionKeyMonitorStartResult {
        startCount += 1
        isRunning = startResult == .active
        return startResult
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

@MainActor
private final class CustomShortcutMonitorFake: CustomShortcutMonitoring {
    private let registerResult: CustomShortcutRegistrationResult
    private(set) var isRegistered = false
    private(set) var registeredKeys: [CustomHotKey] = []
    private(set) var unregisterCount = 0

    init(registerResult: CustomShortcutRegistrationResult = .active) {
        self.registerResult = registerResult
    }

    func register(_ hotKey: CustomHotKey) -> CustomShortcutRegistrationResult {
        registeredKeys.append(hotKey)
        isRegistered = registerResult == .active
        return registerResult
    }

    func unregister() {
        unregisterCount += 1
        isRegistered = false
    }
}

private actor ShortcutPersistenceFake {
    private var storedValues: [VoiceShortcutPreference] = []

    var values: [VoiceShortcutPreference] { storedValues }

    func save(_ preference: VoiceShortcutPreference) {
        storedValues.append(preference)
    }
}

private actor FailOnceShortcutPersistenceFake {
    private var shouldFail = true
    private var storedValues: [VoiceShortcutPreference] = []

    var values: [VoiceShortcutPreference] { storedValues }

    func save(_ preference: VoiceShortcutPreference) throws {
        if shouldFail {
            shouldFail = false
            throw AppSettingsStoreError.writeFailed(reason: "temporary failure")
        }
        storedValues.append(preference)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class DeepSeekURLProtocolProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var stopped = false

    var didStart: Bool {
        lock.withLock { started }
    }

    var didStop: Bool {
        lock.withLock { stopped }
    }

    func markStarted() {
        lock.withLock { started = true }
    }

    func markStopped() {
        lock.withLock { stopped = true }
    }
}

private final class BlockingDeepSeekURLProtocol: URLProtocol,
    @unchecked Sendable {
    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var installedProbe:
        DeepSeekURLProtocolProbe?

    static func install(_ probe: DeepSeekURLProtocolProbe?) {
        probeLock.withLock {
            installedProbe = probe
        }
    }

    private static var probe: DeepSeekURLProtocolProbe? {
        probeLock.withLock { installedProbe }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.probe?.markStarted()
    }

    override func stopLoading() {
        Self.probe?.markStopped()
    }
}

private func makeDoubaoClient(
    responses: [Data] = [],
    receiveError: URLError? = nil,
    metadata: DoubaoWebSocketMetadata = .init()
) -> DoubaoStreamingASRClient {
    let connection = DoubaoWebSocketConnectionFake(
        responses: responses,
        receiveError: receiveError,
        metadata: metadata
    )
    return DoubaoStreamingASRClient(
        configuration: .init(
            apiKey: "test-api-key",
            requestUserID: "request-user"
        ),
        connector: DoubaoWebSocketConnectorFake(connection: connection)
    )
}

private actor DoubaoWebSocketConnectorFake: DoubaoWebSocketConnecting {
    let connection: DoubaoWebSocketConnectionFake
    private var requests: [URLRequest] = []

    init(connection: DoubaoWebSocketConnectionFake) {
        self.connection = connection
    }

    func connect(_ request: URLRequest) async throws -> any DoubaoWebSocketConnection {
        requests.append(request)
        return connection
    }

    func onlyRequest() throws -> URLRequest {
        guard requests.count == 1, let request = requests.first else {
            throw SpecFailure(message: "expected exactly one Doubao WebSocket request")
        }
        return request
    }

    var requestCount: Int { requests.count }
}

private struct HangingDoubaoWebSocketConnector: DoubaoWebSocketConnecting {
    func connect(_ request: URLRequest) async throws -> any DoubaoWebSocketConnection {
        try await Task.sleep(for: .seconds(10))
        return DoubaoWebSocketConnectionFake(responses: [])
    }
}

private actor AudioChunkConsumptionProbe {
    private var hasReturnedFirstChunk = false

    var firstChunkWasConsumed: Bool {
        hasReturnedFirstChunk
    }

    func takeFirstChunk() -> Bool {
        guard !hasReturnedFirstChunk else { return false }
        hasReturnedFirstChunk = true
        return true
    }
}

private struct DoubaoFailingWebSocketConnectorFake:
    DoubaoWebSocketConnecting {
    let error: URLError

    func connect(
        _ request: URLRequest
    ) async throws -> any DoubaoWebSocketConnection {
        _ = request
        throw error
    }
}

private actor DoubaoWebSocketConnectionFake: DoubaoWebSocketConnection {
    private let responses: [Data]
    private let receiveError: URLError?
    private let metadataValue: DoubaoWebSocketMetadata
    private let hangingSendIndex: Int?
    private let hangsOnReceive: Bool
    private let failingSendIndex: Int?
    private let blockingSendFailureIndex: Int?
    private let blocksReceiveUntilClose: Bool
    private var responseIndex = 0
    private var isClosed = false
    private var blockedReceive: CheckedContinuation<Data, Error>?
    private var blockedSend: CheckedContinuation<Void, Error>?
    private(set) var sentFrames: [Data] = []
    private(set) var sendAttemptCount = 0
    private(set) var closeCount = 0

    init(
        responses: [Data],
        receiveError: URLError? = nil,
        metadata: DoubaoWebSocketMetadata = .init(),
        hangingSendIndex: Int? = nil,
        hangsOnReceive: Bool = false,
        failingSendIndex: Int? = nil,
        blockingSendFailureIndex: Int? = nil,
        blocksReceiveUntilClose: Bool = false
    ) {
        self.responses = responses
        self.receiveError = receiveError
        metadataValue = metadata
        self.hangingSendIndex = hangingSendIndex
        self.hangsOnReceive = hangsOnReceive
        self.failingSendIndex = failingSendIndex
        self.blockingSendFailureIndex = blockingSendFailureIndex
        self.blocksReceiveUntilClose = blocksReceiveUntilClose
    }

    func send(_ data: Data) async throws {
        let sendIndex = sentFrames.count
        sendAttemptCount += 1
        if sendIndex == failingSendIndex {
            throw URLError(.networkConnectionLost)
        }
        if sendIndex == hangingSendIndex {
            try await Task.sleep(for: .seconds(10))
        }
        if sendIndex == blockingSendFailureIndex {
            try await withCheckedThrowingContinuation {
                blockedSend = $0
            }
        }
        sentFrames.append(data)
    }

    func receive() async throws -> Data {
        if blocksReceiveUntilClose {
            if isClosed { throw URLError(.cancelled) }
            return try await withCheckedThrowingContinuation { continuation in
                blockedReceive = continuation
            }
        }
        if hangsOnReceive {
            try await Task.sleep(for: .seconds(10))
        }
        if let receiveError { throw receiveError }
        guard responseIndex < responses.count else {
            throw URLError(.cannotParseResponse)
        }
        defer { responseIndex += 1 }
        return responses[responseIndex]
    }

    func metadata() -> DoubaoWebSocketMetadata { metadataValue }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        closeCount += 1
        blockedSend?.resume(
            throwing: URLError(.networkConnectionLost)
        )
        blockedSend = nil
        blockedReceive?.resume(throwing: URLError(.cancelled))
        blockedReceive = nil
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

private func makeAudioStream(_ chunks: [Data]) -> AsyncStream<Data> {
    AsyncStream { continuation in
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }
}

private func makeDoubaoServerResponse(text: String?, isFinal: Bool) -> Data {
    let body: Data
    if let text {
        body = Data(#"{"result":{"text":"\#(text)"}}"#.utf8)
    } else {
        body = Data(#"{"result":{"text":""}}"#.utf8)
    }
    return makeDoubaoServerFrame(
        messageType: 0x09,
        flags: isFinal ? 0x03 : 0x01,
        prefix: UInt32(bitPattern: isFinal ? -1 : 1),
        payload: body
    )
}

private func makeDoubaoServerError(code: UInt32, message: String) -> Data {
    makeDoubaoServerFrame(
        messageType: 0x0F,
        flags: 0,
        prefix: code,
        payload: Data(#"{"message":"\#(message)"}"#.utf8)
    )
}

private func makeDoubaoServerFrame(
    messageType: UInt8,
    flags: UInt8,
    prefix: UInt32,
    payload: Data
) -> Data {
    var data = Data([0x11, (messageType << 4) | flags, 0x10, 0x00])
    appendUInt32BE(prefix, to: &data)
    appendUInt32BE(UInt32(payload.count), to: &data)
    data.append(payload)
    return data
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private actor DeepSeekRefinerFake: DeepSeekTextRefining {
    let result: Result<DeepSeekRefinementResult, DeepSeekRefinementFailure>
    private(set) var callCount = 0
    private(set) var inputs: [String] = []
    private(set) var modes: [TextRefinementMode] = []

    init(result: Result<DeepSeekRefinementResult, DeepSeekRefinementFailure>) {
        self.result = result
    }

    func refine(
        _ text: String,
        using mode: TextRefinementMode
    ) async throws -> DeepSeekRefinementResult {
        callCount += 1
        inputs.append(text)
        modes.append(mode)
        return try result.get()
    }
}

private actor ContextualTranscriberFake: ContextualSpeechTranscribing {
    let text: String
    private(set) var hotwordCalls: [[String]] = []

    init(text: String) {
        self.text = text
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        try await transcribe(audio, hotwords: [], context: nil)
    }

    func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult {
        hotwordCalls.append(hotwords)
        return TranscriptionResult(text: text, providerRequestID: "doubao-context-spec")
    }
}

private actor DeepSeekTransportFake: DeepSeekTransport {
    let response: DeepSeekTransportResponse
    private var requests: [URLRequest] = []

    init(response: DeepSeekTransportResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> DeepSeekTransportResponse {
        requests.append(request)
        return response
    }

    func onlyRequest() throws -> URLRequest {
        guard requests.count == 1, let request = requests.first else {
            throw SpecFailure(message: "expected exactly one DeepSeek request")
        }
        return request
    }
}

private struct HangingDeepSeekTransport: DeepSeekTransport {
    func send(_ request: URLRequest) async throws -> DeepSeekTransportResponse {
        try await Task.sleep(for: .seconds(10))
        return DeepSeekTransportResponse(statusCode: 500, body: Data())
    }
}

private actor CancellableDeepSeekRefinerFake: DeepSeekTextRefining {
    private(set) var callCount = 0
    private(set) var cancellationCount = 0

    func refine(
        _ text: String,
        using mode: TextRefinementMode
    ) async throws -> DeepSeekRefinementResult {
        callCount += 1
        do {
            try await Task.sleep(for: .seconds(10))
            return DeepSeekRefinementResult(text: "迟到结果")
        } catch is CancellationError {
            cancellationCount += 1
            throw DeepSeekRefinementFailure(kind: .cancelled)
        }
    }
}

private func makeDeepSeekClient(content: String) -> DeepSeekRefinementClient {
    let encodedContent = try! JSONEncoder().encode(content)
    let body = Data(
        "{\"choices\":[{\"message\":{\"content\":\(String(decoding: encodedContent, as: UTF8.self))},\"finish_reason\":\"stop\"}]}".utf8
    )
    return DeepSeekRefinementClient(
        configuration: .init(apiKey: "deepseek-test-key"),
        transport: DeepSeekTransportFake(response: .init(statusCode: 200, body: body))
    )
}

private actor ProviderCredentialStoreFake: ProviderCredentialStoring {
    private var values: [ProviderID: String]
    private let corruptsSavedValues: Bool
    private let deleteFails: Bool
    private let readError: ProviderCredentialStoreError?

    init(
        values: [ProviderID: String] = [:],
        corruptsSavedValues: Bool = false,
        deleteFails: Bool = false,
        readError: ProviderCredentialStoreError? = nil
    ) {
        self.values = values
        self.corruptsSavedValues = corruptsSavedValues
        self.deleteFails = deleteFails
        self.readError = readError
    }

    func save(apiKey: String, for provider: ProviderID) async throws {
        values[provider] = corruptsSavedValues ? "mismatched-value" : apiKey
    }

    func apiKey(for provider: ProviderID) async throws -> String? {
        if let readError { throw readError }
        return values[provider]
    }

    func deleteAPIKey(for provider: ProviderID) async throws {
        if deleteFails { throw ProviderCredentialStoreError.storageUnavailable }
        values[provider] = nil
    }
}

private actor AudioCaptureFake: AudioCapturing {
    let delaysStart: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var isActive = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(delaysStart: Bool = false) {
        self.delaysStart = delaysStart
    }

    func start() async throws {
        startCount += 1
        if delaysStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        isActive = true
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        isActive = false
        return CapturedAudio(
            data: Data([0x52, 0x49, 0x46, 0x46]),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    func cancel() async {
        cancelCount += 1
        isActive = false
    }
}

private actor StreamingAudioCaptureFake: AudioCapturing, AudioChunkStreaming,
    AudioCaptureFailureProviding {
    private var continuation: AsyncStream<Data>.Continuation?
    private var failureContinuation: AsyncStream<AudioCaptureError>.Continuation?
    private var activeFailure: AudioCaptureError?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private let stoppedAudio: CapturedAudio

    init(
        stoppedAudio: CapturedAudio = CapturedAudio(
            data: Data(),
            duration: .seconds(1),
            peakPower: -12
        )
    ) {
        self.stoppedAudio = stoppedAudio
    }

    func audioChunks() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        return stream
    }

    func observeFailures() -> AsyncStream<AudioCaptureError> {
        let (stream, continuation) = AsyncStream<AudioCaptureError>.makeStream()
        failureContinuation = continuation
        if let activeFailure { continuation.yield(activeFailure) }
        return stream
    }

    func start() async throws { startCount += 1 }

    func emit(_ data: Data) {
        continuation?.yield(data)
    }

    func emitFailure(_ failure: AudioCaptureError) {
        activeFailure = failure
        failureContinuation?.yield(failure)
    }

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        continuation?.finish()
        continuation = nil
        failureContinuation?.finish()
        failureContinuation = nil
        activeFailure = nil
        try AudioCaptureQualityPolicy.validate(
            duration: stoppedAudio.duration,
            peakPower: stoppedAudio.peakPower
        )
        return stoppedAudio
    }

    func cancel() async {
        cancelCount += 1
        continuation?.finish()
        continuation = nil
        failureContinuation?.finish()
        failureContinuation = nil
        activeFailure = nil
    }
}

private actor EarlyFailingStreamingProcessor: VoiceTextProcessing, StreamingVoiceTextProcessing {
    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw VoiceTextProcessingFailure(
            userFailure: .providerAuthenticationFailed,
            providerDiagnostic: .init(
                provider: "doubao",
                requestID: "early-provider-failure",
                code: "invalidCredential"
            )
        )
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw VoiceTextProcessingFailure(
            userFailure: .providerAuthenticationFailed,
            providerDiagnostic: .init(
                provider: "doubao",
                requestID: "early-provider-failure",
                code: "invalidCredential"
            )
        )
    }
}

private actor StreamingVoiceTextProcessorFake: VoiceTextProcessing, StreamingVoiceTextProcessing {
    private(set) var receivedChunkCount = 0

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw SpecFailure(message: "streaming processor used buffered fallback")
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        for await chunk in audioChunks where !chunk.isEmpty {
            receivedChunkCount += 1
        }
        return VoiceTextProcessingResult(
            doubaoText: "流式结果",
            normalizedText: "流式结果",
            deepSeekText: nil,
            finalText: "流式结果",
            doubaoRequestID: "streaming-spec",
            deepSeekRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil,
            dictionaryReplacements: []
        )
    }
}

private actor DelayedFailingStopAudioCapture: AudioCapturing {
    private(set) var stopCount = 0
    private var stopContinuation: CheckedContinuation<CapturedAudio, Error>?

    func start() async throws {}

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func cancel() async {}

    func failStop() {
        stopContinuation?.resume(throwing: SpecFailure(message: "late recorder failure"))
        stopContinuation = nil
    }
}

private actor DelayedFailingStartAudioCapture: AudioCapturing {
    func start() async throws {
        try await Task.sleep(for: .milliseconds(20))
        throw SpecFailure(message: "recorder start failed")
    }

    func stop() async throws -> CapturedAudio { specAudio }

    func cancel() async {}
}

private actor TargetCaptureFake: InputTargetCapturing {
    let result: InputTargetCaptureResult

    init(result: InputTargetCaptureResult) {
        self.result = result
    }

    func capture() async -> InputTargetCaptureResult {
        result
    }
}

private actor AccessibilityTargetSystemFake: AccessibilityTargetSystem {
    private let evidence: AccessibilityTargetEvidence
    private var valueResponses: [AccessibilityOperationResult<String?>]
    private var selectionResponses:
        [AccessibilityOperationResult<NSRange?>]
    private var setSelectionResponses: [AccessibilityOperationResult<Void>]
    private var setSelectedTextResponses: [AccessibilityOperationResult<Void>]
    private var subroleResponses: [AccessibilityOperationResult<String?>]
    private var roleResponses: [AccessibilityOperationResult<String?>]
    private var focusResponses: [AccessibilityOperationResult<Bool>]
    private let frontmost: Bool
    private let postUnicodeSucceeds: Bool
    private(set) var setSelectionCallCount = 0
    private(set) var setSelectedTextCallCount = 0
    private(set) var postUnicodeCallCount = 0
    private(set) var captureFocusedCallCount = 0
    private(set) var captureTargetCallCount = 0

    init(
        originalValue: String = "Hello",
        selection: NSRange = NSRange(location: 5, length: 0),
        processID: pid_t = 42,
        supportsDirectInsertion: Bool = true,
        isFrontmost: Bool = true,
        valueResponses: [AccessibilityOperationResult<String?>],
        selectionResponses: [AccessibilityOperationResult<NSRange?>] = [],
        setSelectionResponses: [AccessibilityOperationResult<Void>] = [
            .success(()),
        ],
        setSelectedTextResponses: [AccessibilityOperationResult<Void>] = [
            .success(()),
        ],
        subroleResponses: [AccessibilityOperationResult<String?>] = [],
        roleResponses: [AccessibilityOperationResult<String?>] = [],
        focusResponses: [AccessibilityOperationResult<Bool>] = [],
        postUnicodeSucceeds: Bool = true
    ) {
        evidence = AccessibilityTargetEvidence(
            reference: AccessibilityTargetReference(),
            selection: selection,
            originalValue: originalValue,
            processID: processID,
            applicationBundleIdentifier: "com.example.Editor",
            applicationName: "Editor",
            supportsDirectInsertion: supportsDirectInsertion
        )
        frontmost = isFrontmost
        self.postUnicodeSucceeds = postUnicodeSucceeds
        self.valueResponses = valueResponses
        self.selectionResponses = selectionResponses
        self.setSelectionResponses = setSelectionResponses
        self.setSelectedTextResponses = setSelectedTextResponses
        self.subroleResponses = subroleResponses
        self.roleResponses = roleResponses
        self.focusResponses = focusResponses
    }

    func captureFocusedTarget() async -> AccessibilityTargetCapture {
        captureFocusedCallCount += 1
        return .writable(evidence)
    }

    func captureTarget(
        _ target: AccessibilityReleaseTarget
    ) async -> AccessibilityTargetCapture {
        captureTargetCallCount += 1
        guard target.processID == evidence.processID,
              target.reference == evidence.reference
        else {
            return .unavailable(.invalidatedTarget)
        }
        return .writable(evidence)
    }

    func secureInputEnabled() async -> Bool { false }

    func subrole(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard !subroleResponses.isEmpty else { return .success(nil) }
        return subroleResponses.removeFirst()
    }

    func role(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard !roleResponses.isEmpty else { return .success("AXTextArea") }
        return roleResponses.removeFirst()
    }

    func value(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard !valueResponses.isEmpty else {
            return .success(evidence.originalValue)
        }
        return valueResponses.removeFirst()
    }

    func setSelection(
        _ selection: NSRange,
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<Void> {
        setSelectionCallCount += 1
        guard !setSelectionResponses.isEmpty else { return .success(()) }
        return setSelectionResponses.removeFirst()
    }

    func setSelectedText(
        _ text: String,
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<Void> {
        setSelectedTextCallCount += 1
        guard !setSelectedTextResponses.isEmpty else { return .success(()) }
        return setSelectedTextResponses.removeFirst()
    }

    func focusedState(
        _ target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityOperationResult<Bool> {
        guard !focusResponses.isEmpty else { return .success(true) }
        return focusResponses.removeFirst()
    }

    func isFrontmost(processID: pid_t) async -> Bool {
        frontmost
    }

    func selection(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<NSRange?> {
        guard !selectionResponses.isEmpty else {
            return .success(evidence.selection)
        }
        return selectionResponses.removeFirst()
    }

    func postUnicode(_ text: String, to processID: pid_t) async -> Bool {
        postUnicodeCallCount += 1
        return postUnicodeSucceeds
    }
}

private actor ReleaseTimeTargetCaptureFake: InputTargetCapturing {
    private var applicationName: String
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var captureCallCount = 0

    init(applicationName: String) {
        self.applicationName = applicationName
    }

    func update(applicationName: String) {
        self.applicationName = applicationName
    }

    func capture() async -> InputTargetCaptureResult {
        captureCallCount += 1
        let capturedApplicationName = applicationName
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .writable(.init(
            id: UUID(),
            applicationName: capturedApplicationName
        ))
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedCaptureHintSource: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: Int32

    init(processID: Int32) {
        self.processID = processID
    }

    var hint: InputTargetCaptureHint {
        lock.withLock {
            InputTargetCaptureHint(processID: processID)
        }
    }

    func update(processID: Int32) {
        lock.withLock {
            self.processID = processID
        }
    }
}

private actor HintRecordingTargetCaptureFake: InputTargetCapturing {
    let result: InputTargetCaptureResult
    private(set) var capturedProcessIDs: [Int32] = []

    init(result: InputTargetCaptureResult) {
        self.result = result
    }

    func capture() async -> InputTargetCaptureResult {
        result
    }

    func capture(
        matching hint: InputTargetCaptureHint
    ) async -> InputTargetCaptureResult {
        capturedProcessIDs.append(hint.processID)
        return result
    }
}

private actor DiscardingTargetCaptureFake: InputTargetCapturing, InputTargetDiscarding {
    let snapshot: InputTargetSnapshot
    private(set) var discardedCount = 0

    init(snapshot: InputTargetSnapshot) {
        self.snapshot = snapshot
    }

    func capture() async -> InputTargetCaptureResult { .writable(snapshot) }

    func discard(_ target: InputTargetSnapshot) async {
        if target.id == snapshot.id { discardedCount += 1 }
    }
}

private struct DoubaoFailureTranscriber: ContextualSpeechTranscribing {
    let failure: DoubaoASRFailure

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        throw failure
    }

    func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult {
        throw failure
    }
}

private struct CredentialFailureTranscriber: ContextualSpeechTranscribing {
    let error: ProviderCredentialStoreError

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        throw error
    }

    func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult {
        throw error
    }
}

private struct NormalizedFailureProcessor: VoiceTextProcessing {
    let failure: VoiceTextProcessingFailure

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw failure
    }
}

private actor SpeechTranscriberFake: SpeechTranscribing {
    let text: String
    let delaysResponse: Bool
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(text: String, delaysResponse: Bool = false) {
        self.text = text
        self.delaysResponse = delaysResponse
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        callCount += 1
        if delaysResponse {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            } onCancel: {
                Task { await self.markCancelled() }
            }
        }
        try Task.checkCancellation()
        return TranscriptionResult(text: text, providerRequestID: "local-spec")
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func markCancelled() {
        cancellationCount += 1
    }
}

private actor TextDeliveryFake: TextDelivering {
    let result: DeliveryOutcome
    private(set) var deliveredTexts: [String] = []

    init(result: DeliveryOutcome) {
        self.result = result
    }

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        deliveredTexts.append(text)
        return result
    }
}

private actor TargetRecordingDeliveryFake: TextDelivering {
    private(set) var applicationNames: [String] = []

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        applicationNames.append(target.applicationName)
        return .delivered
    }
}

private actor DelayedCommitDeliveryFake: TextDelivering {
    private(set) var entered = false
    private(set) var deliveredTexts: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        deliveredTexts.append(text)
        return .delivered
    }

    func allowCommitAttempt() {
        continuation?.resume()
        continuation = nil
    }
}

private actor BlockingDeliveryFake: TextDelivering {
    let commitsBeforeBlocking: Bool
    private(set) var isBlocking = false
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<DeliveryOutcome, Never>?

    init(commitsBeforeBlocking: Bool) {
        self.commitsBeforeBlocking = commitsBeforeBlocking
    }

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        if commitsBeforeBlocking {
            guard await commitGate.commit() else {
                return .pendingCopy(.deliveryFailed)
            }
        }
        isBlocking = true
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.markCancelled() }
        }
        return Task.isCancelled ? .pendingCopy(.deliveryFailed) : outcome
    }

    func finish(with outcome: DeliveryOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func markCancelled() {
        cancellationCount += 1
    }
}

private actor ClipboardFake: ClipboardWriting {
    private(set) var copiedTexts: [String] = []
    private let succeeds: Bool

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func copy(_ text: String) async -> Bool {
        copiedTexts.append(text)
        return succeeds
    }
}

private actor SessionHistoryFake: SessionHistoryRecording {
    private(set) var records: [VoiceInputHistoryRecord] = []
    let failureNotice: String?

    init(failureNotice: String? = nil) {
        self.failureNotice = failureNotice
    }

    func save(_ record: VoiceInputHistoryRecord) async {
        if let index = records.firstIndex(where: { $0.sessionID == record.sessionID }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    func persistenceFailureNotice() async -> String? { failureNotice }
}

private actor BlockingSessionHistoryFake: SessionHistoryRecording {
    private(set) var saveCallCount = 0
    private var isBlocked = true
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func save(_ record: VoiceInputHistoryRecord) async {
        saveCallCount += 1
        guard isBlocked else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func unblock() {
        isBlocked = false
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor CompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

@MainActor
private final class PermissionAccessStub: PermissionAccess {
    var snapshot: PermissionSnapshot
    var requestResults: [PermissionKind: PermissionSnapshot] = [:]
    private(set) var requestedPermissions: [PermissionKind] = []

    init(snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> PermissionSnapshot {
        snapshot
    }

    func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        requestedPermissions.append(permission)
        let result = requestResults[permission] ?? snapshot
        snapshot = result
        return result
    }
}

private struct SpecFailure: Error {
    let message: String
}

private struct FileProtectionFailure: Error {}

@MainActor
private enum SpecExecutionCounter {
    static var value = 0
}

private extension VoiceInputActivity {
    var isCancelled: Bool {
        if case .cancelled = self { true } else { false }
    }

    var isRecordingFailed: Bool {
        if case .failed(_, .recordingFailed) = self { true } else { false }
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed"
) throws {
    guard condition() else {
        throw SpecFailure(message: message)
    }
}

private func injectLegacyProviderMessages(into fileURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        fileURL.path,
        &database,
        SQLITE_OPEN_READWRITE,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw SpecFailure(message: "could not open SQLite history for injection")
    }
    defer { sqlite3_close(database) }
    let sql = """
    UPDATE history_records
    SET payload = CAST(json_set(
        CAST(payload AS TEXT),
        '$.providerMessage',
        'future-api-key-secret',
        '$.refinementFailureMessage',
        'private-refinement-context'
    ) AS BLOB)
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw SpecFailure(message: "could not inject legacy provider messages")
    }
}

private func injectMalformedProviderMessageRow(
    into fileURL: URL,
    secret: String
) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        fileURL.path,
        &database,
        SQLITE_OPEN_READWRITE,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw SpecFailure(message: "could not open SQLite history for malformed injection")
    }
    defer { sqlite3_close(database) }
    let payload = try JSONSerialization.data(
        withJSONObject: ["providerMessage": secret],
        options: [.sortedKeys]
    )
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        INSERT INTO history_records(session_id, started_at, payload, payload_schema)
        VALUES('00000000-0000-0000-0000-000000000002', 1, ?, 1)
        """,
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw SpecFailure(message: "could not prepare malformed history injection")
    }
    defer { sqlite3_finalize(statement) }
    let bindStatus = payload.withUnsafeBytes { bytes in
        sqlite3_bind_blob(
            statement,
            1,
            bytes.baseAddress,
            Int32(bytes.count),
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }
    guard bindStatus == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
        throw SpecFailure(message: "could not inject malformed history row")
    }
}

private func injectProviderMessage(
    _ secret: String,
    into fileURL: URL
) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        fileURL.path,
        &database,
        SQLITE_OPEN_READWRITE,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw SpecFailure(message: "could not open SQLite history for provider injection")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        UPDATE history_records
        SET payload = CAST(json_set(
            CAST(payload AS TEXT),
            '$.providerMessage',
            ?
        ) AS BLOB)
        """,
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw SpecFailure(message: "could not prepare provider message injection")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_text(
        statement,
        1,
        secret,
        -1,
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    ) == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
        throw SpecFailure(message: "could not inject provider message")
    }
}

private func sqliteFilesContain(_ marker: Data, at fileURL: URL) -> Bool {
    for suffix in ["", "-wal", "-journal"] {
        let candidate = URL(fileURLWithPath: fileURL.path + suffix)
        guard let data = try? Data(contentsOf: candidate) else { continue }
        if data.range(of: marker) != nil {
            return true
        }
    }
    return false
}

private func readHistoryPayload(from fileURL: URL) throws -> String {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        fileURL.path,
        &database,
        SQLITE_OPEN_READONLY,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw SpecFailure(message: "could not open SQLite history payload")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT payload FROM history_records LIMIT 1",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw SpecFailure(message: "could not prepare history payload read")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let bytes = sqlite3_column_blob(statement, 0)
    else {
        throw SpecFailure(message: "history payload was missing")
    }
    let count = Int(sqlite3_column_bytes(statement, 0))
    return String(decoding: Data(bytes: bytes, count: count), as: UTF8.self)
}

@MainActor
private func run(
    _ name: String,
    failures: inout [String],
    body: () throws -> Void
) {
    SpecExecutionCounter.value += 1
    do {
        try body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

@MainActor
private func runAsync(
    _ name: String,
    failures: inout [String],
    body: () async throws -> Void
) async {
    SpecExecutionCounter.value += 1
    do {
        try await body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

private func terminalPresentation(
    from stream: AsyncStream<VoiceInputPresentation>
) -> Task<VoiceInputPresentation?, Never> {
    Task {
        for await presentation in stream {
            if presentation.activity.isTerminal {
                return presentation
            }
        }
        return nil
    }
}

private func firstTerminalPresentation(
    from stream: AsyncStream<VoiceInputPresentation>,
    before timeout: Duration
) async -> VoiceInputPresentation? {
    await withTaskGroup(of: VoiceInputPresentation?.self) { group in
        group.addTask {
            for await presentation in stream {
                if presentation.activity.isTerminal {
                    return presentation
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@MainActor
private func eventually(
    before timeout: Duration,
    pollEvery interval: Duration = .milliseconds(5),
    condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}
