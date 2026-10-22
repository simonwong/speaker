import ApplicationServices
import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum InputTargetSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
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
                    message:
                        "missing Accessibility permission was misreported as a target capability"
                )
            }
        }

        await runAsync("AX capture accepts the exact expected process", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                processID: 42,
                valueResponses: []
            )
            let targets = AccessibilityInputTargets(system: system)

            guard
                case .writable = await targets.capture(
                    expectedProcessID: 42
                )
            else {
                throw SpecFailure(
                    message: "the exact expected process was rejected"
                )
            }
        }

        await runAsync(
            "AX capture rejects a focused target from another process", failures: &failures
        ) {
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

        run(
            "release callback freezes the frontmost process without AX target IPC",
            failures: &failures
        ) {
            let system = LiveAccessibilityTargetSystem(
                isProcessTrusted: { true },
                isSecureInputEnabled: { false },
                frontmostProcessIdentifier: { 42 }
            )

            let capture = system.captureReleaseProcess()

            guard case .process(let processID) = capture else {
                throw SpecFailure(
                    message: "release callback did not preserve the frontmost process"
                )
            }
            try expect(processID == 42)
        }

        run(
            "release target selection falls back to the focused window when the app exposes no focused element",
            failures: &failures
        ) {
            let focusedWindow = AccessibilityTargetReference(scope: .window)
            let selected = AccessibilityReleaseTargetSelection.select(
                focusedElement: nil,
                focusedWindow: focusedWindow,
                processID: 42
            )

            try expect(
                selected?.reference == focusedWindow,
                "a target with a stable focused window was discarded"
            )
        }

        run(
            "text-marker selection evidence is treated as a non-atomic capability",
            failures: &failures
        ) {
            let decoded = AccessibilityTextRangeDecoder.decode(
                "text-marker-range" as CFString
            )
            guard case .success(nil) = decoded else {
                throw SpecFailure(
                    message: "a non-CFRange selection rejected the whole target"
                )
            }
        }

        run(
            "AX no-value is optional attribute absence rather than target failure",
            failures: &failures
        ) {
            try expect(
                AccessibilityAttributeReadPolicy.isAbsent(.noValue),
                "kAXErrorNoValue was promoted to a delivery failure"
            )
        }

        await runAsync(
            "every editable target commits through transactional paste",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let pasteCount = await system.pasteCallCount

            try expect(outcome == .delivered)
            try expect(
                pasteCount == 1,
                "delivery did not commit through transactional paste"
            )
        }

        await runAsync(
            "stale release evidence cannot recover into another process",
            failures: &failures
        ) {
            let releasedField = AccessibilityTargetReference()
            let system = AccessibilityTargetSystemFake(
                processID: 84,
                valueResponses: []
            )
            let targets = AccessibilityInputTargets(
                system: system,
                releaseCapture: {
                    .target(
                        .init(
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
                focusedCaptureCount == 1,
                "capture did not enforce the release-time process fence"
            )
            try expect(exactCaptureCount == 1)
        }

        await runAsync(
            "release capture recovers from stale same-process focus evidence",
            failures: &failures
        ) {
            let staleField = AccessibilityTargetReference()
            let system = AccessibilityTargetSystemFake(
                processID: 42,
                valueResponses: []
            )
            let targets = AccessibilityInputTargets(
                system: system,
                releaseCapture: {
                    .target(
                        .init(
                            reference: staleField,
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

            guard case .writable = capture else {
                throw SpecFailure(
                    message: "stale observer evidence blocked the currently focused input"
                )
            }
            try expect(exactCaptureCount == 1)
            try expect(
                focusedCaptureCount == 1,
                "capture did not recover with a fresh same-process focus read"
            )
        }

        await runAsync(
            "AX accepted insertion is not downgraded by stale immediate readback",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
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

        await runAsync(
            "paste without a receipt is committed without inviting manual duplication",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )

            guard case .pasteCommandPosted(let diagnostic) = outcome else {
                throw SpecFailure(
                    message: "posted paste was exposed as retryable Pending Copy"
                )
            }
            try expect(diagnostic.code == "pasteReceipt.unconfirmed")
        }

        await runAsync(
            "a passing third value settles back into an unconfirmed paste",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world\n"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system, clock: clock)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let delivery = Task {
                await targets.deliver(" world", to: target, commitGate: DeliveryCommitGate())
            }
            try await driveReceiptPolls(clock)
            let outcome = await delivery.value

            guard case .pasteCommandPosted(let diagnostic) = outcome else {
                throw SpecFailure(
                    message: "a value the target passed through invited duplicate delivery"
                )
            }
            try expect(diagnostic.code == "pasteReceipt.unconfirmed")
        }

        await runAsync(
            "a third value after paste keeps the result for the user to check",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                ],
                valueAfterResponses: .success("Hello 上一次剪贴板")
            )
            let targets = AccessibilityInputTargets(system: system, clock: clock)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }
            let commitGate = DeliveryCommitGate()

            let delivery = Task {
                await targets.deliver(" world", to: target, commitGate: commitGate)
            }
            try await driveReceiptPolls(clock)
            let outcome = await delivery.value
            let pasteCount = await system.pasteCallCount
            let receipts = await system.pasteReceipts

            try expect(
                outcome
                    == .pendingCopyDiagnosed(
                        .deliveryUnconfirmed,
                        .init(stage: .pasteReceipt, cause: .changed)
                    ),
                "a target showing neither value was reported as \(outcome)"
            )
            try expect(pasteCount == 1, "a committed paste was posted again")
            try expect(
                receipts.map(\.currentConclusion) == [.unconfirmed],
                "the clipboard restore was not told the paste is unconfirmed"
            )
            let cancelledAfterCommit = await commitGate.cancel()
            try expect(
                !cancelledAfterCommit,
                "a committed paste could still be reported as cancelled"
            )
        }

        await runAsync(
            "a readable target's receipt releases the clipboard as soon as the result shows",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system, clock: clock)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let delivery = Task {
                await targets.deliver(" world", to: target, commitGate: DeliveryCommitGate())
            }
            try await clock.waitUntilSleepRequestCount(1)
            let receipts = await system.pasteReceipts
            try expect(
                receipts.map(\.currentConclusion) == [nil],
                "the receipt concluded before the target was read again"
            )
            clock.advance(by: .milliseconds(50))
            let outcome = await delivery.value

            try expect(outcome == .delivered)
            try expect(receipts.map(\.currentConclusion) == [.confirmed])
        }

        await runAsync(
            "a target without a readable value pastes with an already concluded receipt",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                originalValue: nil,
                selection: nil,
                valueResponses: [],
                roleResponses: [.success("AXGroup")]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            _ = await targets.deliver(" world", to: target, commitGate: DeliveryCommitGate())
            let receipts = await system.pasteReceipts

            try expect(
                receipts.map(\.currentConclusion) == [.unconfirmed],
                "a target with no receipt held the clipboard restore open"
            )
        }

        await runAsync(
            "an oversized clipboard keeps the result for manual paste",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [.success("Hello")],
                pasteResult: .clipboardTooLarge
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }
            let commitGate = DeliveryCommitGate()

            let outcome = await targets.deliver(" world", to: target, commitGate: commitGate)

            try expect(
                outcome
                    == .pendingCopyDiagnosed(
                        .clipboardTooLarge,
                        .init(stage: .clipboardSnapshot, cause: .tooLarge)
                    ),
                "an oversized clipboard was reported as \(outcome)"
            )
            try expect(outcome.deliveryDiagnostic?.code == "clipboardSnapshot.tooLarge")
        }

        await runAsync(
            "unchanged AX selection proceeds through transactional paste", failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let pastePosts = await system.pasteCallCount

            try expect(outcome == .delivered)
            try expect(
                pastePosts == 1,
                "unchanged selection did not reach transactional paste"
            )
        }

        await runAsync(
            "moved AX selection fails closed before transactional paste",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello")
                ],
                selectionResponses: [
                    .success(NSRange(location: 0, length: 0))
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let pastePosts = await system.pasteCallCount

            try expect(outcome.pendingCopyReason == .changedTarget)
            try expect(
                pastePosts == 0,
                "delivery pasted after the user moved the selection"
            )
        }

        await runAsync("changed AX target content is never overwritten", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [.success("User edited this")]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let pastePosts = await system.pasteCallCount

            try expect(outcome.pendingCopyReason == .changedTarget)
            try expect(
                outcome.deliveryDiagnostic?.code
                    == "valueRead.changed"
            )
            try expect(pastePosts == 0)
        }

        await runAsync(
            "AX value IPC failure is reported as an unresponsive target instead of a focus change",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [.failure(.cannotComplete)]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let pastePosts = await system.pasteCallCount

            try expect(
                outcome.pendingCopyReason == .targetApplicationUnresponsive
            )
            try expect(outcome.deliveryDiagnostic?.code == "valueRead.cannotComplete")
            try expect(pastePosts == 0)
        }

        await runAsync(
            "AX role and security IPC failures preserve their exact diagnostic stage",
            failures: &failures
        ) {
            let securitySystem = AccessibilityTargetSystemFake(
                valueResponses: [],
                subroleResponses: [.failure(.cannotComplete)]
            )
            let securityTargets = AccessibilityInputTargets(system: securitySystem)
            guard case .writable(let securityTarget) = await securityTargets.capture()
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
            guard case .writable(let roleTarget) = await roleTargets.capture()
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

        await runAsync(
            "AX selection and focus IPC failures are not called user edits", failures: &failures
        ) {
            let selectionSystem = AccessibilityTargetSystemFake(
                valueResponses: [.success("Hello")],
                selectionResponses: [.failure(.cannotComplete)]
            )
            let selectionTargets = AccessibilityInputTargets(system: selectionSystem)
            guard case .writable(let selectionTarget) = await selectionTargets.capture()
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
                    == "fallbackSelection.cannotComplete"
            )

            let focusSystem = AccessibilityTargetSystemFake(
                valueResponses: [.success("Hello")],
                focusResponses: [.failure(.cannotComplete)]
            )
            let focusTargets = AccessibilityInputTargets(system: focusSystem)
            guard case .writable(let focusTarget) = await focusTargets.capture()
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

        await runAsync(
            "frontmost exact AX target can use receipt-verified paste fallback", failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                    .success("Hello world"),
                ]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let pastePosts = await system.pasteCallCount

            try expect(outcome == .delivered)
            try expect(
                pastePosts == 1,
                "standard focused target never reached paste fallback"
            )
        }

        await runAsync(
            "contenteditable target without flat AX value uses paste fallback",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                originalValue: nil,
                selection: nil,
                valueResponses: [],
                roleResponses: [.success("AXGroup")]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(
                    message: "contenteditable-style target was rejected during capture"
                )
            }

            let outcome = await targets.deliver(
                "hello from Speaker",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let pastePosts = await system.pasteCallCount

            guard case .pasteCommandPosted(let diagnostic) = outcome else {
                throw SpecFailure(
                    message: "paste-only contenteditable claimed a target receipt"
                )
            }
            try expect(diagnostic.code == "pasteReceipt.unconfirmed")
            try expect(
                pastePosts == 1,
                "contenteditable-style target never reached paste fallback"
            )
        }

        await runAsync(
            "window-scoped target can use paste when no focused AX element exists",
            failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                originalValue: nil,
                selection: nil,
                referenceScope: .window,
                valueResponses: [],
                roleResponses: [.success("AXWindow")]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "window-scoped target was rejected")
            }

            let outcome = await targets.deliver(
                "hello from Speaker",
                to: target,
                commitGate: DeliveryCommitGate()
            )

            let pasteCallCount = await system.pasteCallCount
            guard case .pasteCommandPosted(let diagnostic) = outcome else {
                throw SpecFailure(
                    message: "window-scoped paste claimed a target receipt"
                )
            }
            try expect(diagnostic.code == "pasteReceipt.unconfirmed")
            try expect(pasteCallCount == 1)
        }

        run(
            "paste transaction restores only while its ownership evidence matches",
            failures: &failures
        ) {
            try expect(
                PasteboardDeliveryTransaction.ownsPasteboard(
                    currentChangeCount: 12,
                    currentMarker: "speaker-transaction",
                    ownedChangeCount: 12,
                    marker: "speaker-transaction"
                ))
            try expect(
                !PasteboardDeliveryTransaction.ownsPasteboard(
                    currentChangeCount: 13,
                    currentMarker: "speaker-transaction",
                    ownedChangeCount: 12,
                    marker: "speaker-transaction"
                ))
            try expect(
                !PasteboardDeliveryTransaction.ownsPasteboard(
                    currentChangeCount: 12,
                    currentMarker: "new-user-copy",
                    ownedChangeCount: 12,
                    marker: "speaker-transaction"
                ))
        }

        run(
            "paste command uses the login session and one complete physical sequence",
            failures: &failures
        ) {
            let plan = PasteCommandEventPlan.standard
            try expect(plan.sourceStateID == .combinedSessionState)
            try expect(
                plan.transitions == [
                    .commandDown,
                    .vDown,
                    .vUp,
                    .commandUp,
                ])
        }

        run(
            "paste command presses V wherever the keyboard layout puts it",
            failures: &failures
        ) {
            // 55 is Command; 47 is the ANSI Period key, which types "v" under Dvorak.
            let events = PasteCommandEventPlan.standard.keyEvents(vKeyCode: 47)
            try expect(events.map(\.keyCode) == [55, 47, 47, 55], "\(events)")
            try expect(events.map(\.keyDown) == [true, true, false, false])
            try expect(events.map(\.isCommandHeld) == [true, true, true, false])
        }

        run(
            "paste key lookup falls back to the ANSI V position",
            failures: &failures
        ) {
            try expect(PasteKeyCodeLookup { nil }.vKeyCode() == 9)
            try expect(PasteKeyCodeLookup { 47 }.vKeyCode() == 47)
        }

        run(
            "keyboard layout lookup finds V with Command held",
            failures: &failures
        ) {
            try expect(
                KeyboardLayoutKeyCodes.keyCode(
                    producing: "v",
                    inLayoutWithID: "com.apple.keylayout.US"
                ) == 9
            )
            try expect(
                KeyboardLayoutKeyCodes.keyCode(
                    producing: "v",
                    inLayoutWithID: "com.apple.keylayout.Dvorak"
                ) == 47,
                "Dvorak types v on the ANSI Period key"
            )
            try expect(
                KeyboardLayoutKeyCodes.keyCode(
                    producing: "v",
                    inLayoutWithID: "com.apple.keylayout.DVORAK-QWERTYCMD"
                ) == 9,
                "Dvorak - QWERTY ⌘ keeps Command shortcuts on QWERTY positions"
            )
        }

        await runAsync(
            "event-post denial is reported before the pasteboard transaction starts",
            failures: &failures
        ) {
            let preparationCalls = LockedCounter()
            let system = LiveAccessibilityTargetSystem(
                canPostEvents: { false },
                preparePasteboardTransaction: { _ in
                    preparationCalls.increment()
                    return .failure(.unavailable)
                }
            )

            let result = await system.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )

            try expect(result == .eventFailed)
            try expect(
                preparationCalls.value == 0,
                "pasteboard was mutated before event-post authorization"
            )
        }

        await runAsync(
            "automatic paste refuses an over-budget clipboard before mutation",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(
                items: [["public.png": Data([1, 2, 3, 4])]]
            )
            let system = LiveAccessibilityTargetSystem(
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access,
                        snapshotBudget: .init(
                            maximumItemCount: 1,
                            maximumRepresentationCount: 1,
                            maximumBytesPerRepresentation: 4,
                            maximumTotalBytes: 3
                        )
                    )
                }
            )

            let result = await system.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )

            try expect(result == .clipboardTooLarge)
            try expect(pasteboard.clearCount == 0)
        }

        await runAsync(
            "automatic paste restores a complete owned snapshot on pre-commit failure",
            failures: &failures
        ) {
            let originalItems = [
                [
                    "public.utf8-plain-text": Data("original".utf8),
                    "public.rtf": Data([1, 2, 3, 4]),
                ],
                ["public.png": Data([5, 6, 7, 8])],
            ]
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let system = LiveAccessibilityTargetSystem(
                isSecureInputEnabled: { true },
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access,
                        snapshotBudget: .init(
                            maximumItemCount: 2,
                            maximumRepresentationCount: 3,
                            maximumBytesPerRepresentation: 8,
                            maximumTotalBytes: 16
                        )
                    )
                }
            )

            let result = await system.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )

            try expect(result == .secureTarget)
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "automatic paste never restores over a newer external clipboard",
            failures: &failures
        ) {
            let externalItems = [
                ["public.utf8-plain-text": Data("external".utf8)]
            ]
            let pasteboard = ClipboardPasteboardFake(
                items: [["public.png": Data([1, 2, 3])]],
                externalItemsAfterReplacement: externalItems
            )
            let system = LiveAccessibilityTargetSystem(
                isSecureInputEnabled: { true },
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access
                    )
                }
            )

            let result = await system.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )

            try expect(result == .clipboardFailed)
            try expect(pasteboard.items == externalItems)
        }

        await runAsync(
            "automatic paste rolls back a failed clipboard write before Command-V",
            failures: &failures
        ) {
            let originalItems = [
                ["public.utf8-plain-text": Data("original".utf8)]
            ]
            let pasteboard = ClipboardPasteboardFake(
                items: originalItems,
                replacementWriteSucceeds: false,
                failedReplacementItems: [["public.utf8-plain-text": Data("partial".utf8)]]
            )
            let pastePosts = LockedCounter()
            let system = LiveAccessibilityTargetSystem(
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access
                    )
                },
                postPasteCommand: {
                    pastePosts.increment()
                    return true
                }
            )

            let result = await system.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )

            try expect(result == .clipboardFailed)
            try expect(pastePosts.value == 0)
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "successful automatic paste posts once then restores after the target reads",
            failures: &failures
        ) {
            let originalItems = [
                ["public.rtf": Data([1, 2, 3])],
                ["public.png": Data([4, 5, 6])],
            ]
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let restoreCompletion = PasteboardRestoreCompletion()
            let pastePosts = LockedCounter()
            let system = LiveAccessibilityTargetSystem(
                isSecureInputEnabled: { false },
                frontmostProcessIdentifier: { 42 },
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access,
                        clock: clock,
                        conditionalRestoreDidFinish: {
                            await restoreCompletion.markCompleted()
                        }
                    )
                },
                focusedTargetState: { _, _ in .success(true) },
                postPasteCommand: {
                    pastePosts.increment()
                    return true
                }
            )

            let result = await system.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )
            try await clock.waitUntilSleepRequestCount(1)

            try expect(result == .posted)
            try expect(pastePosts.value == 1)
            try expect(
                pasteboard.items
                    == [["public.utf8-plain-text": Data("hello".utf8)]]
            )
            try expect(pasteboard.readPromisedTextAsAnotherApplication() == "hello")
            try await clock.waitUntilSleepRequestCount(2)
            try expect(clock.sleepRequests == [.seconds(3), .milliseconds(500)])

            clock.advance(by: .milliseconds(500))
            try await restoreCompletion.waitUntilCompleted()
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "automatic conditional restore preserves a newer clipboard owner",
            failures: &failures
        ) {
            let externalItems = [
                ["public.utf8-plain-text": Data("external".utf8)]
            ]
            let pasteboard = ClipboardPasteboardFake(
                items: [["public.png": Data([1, 2, 3])]]
            )
            let clock = ManualVoiceInputClock()
            let restoreCompletion = PasteboardRestoreCompletion()
            let system = LiveAccessibilityTargetSystem(
                isSecureInputEnabled: { false },
                frontmostProcessIdentifier: { 42 },
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access,
                        clock: clock,
                        conditionalRestoreDidFinish: {
                            await restoreCompletion.markCompleted()
                        }
                    )
                },
                focusedTargetState: { _, _ in .success(true) },
                postPasteCommand: { true }
            )

            let result = await system.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )
            try await clock.waitUntilSleepRequestCount(1)
            pasteboard.replaceExternally(with: externalItems)
            clock.advance(by: .seconds(3))
            try await restoreCompletion.waitUntilCompleted()

            try expect(result == .posted)
            try expect(pasteboard.items == externalItems)
        }

        await runAsync(
            "clipboard restore shutdown converges and preserves external ownership",
            failures: &failures
        ) {
            let originalItems = [
                ["public.png": Data([1, 2, 3])]
            ]
            let externalItems = [
                ["public.utf8-plain-text": Data("external".utf8)]
            ]
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let restoreCompletion = PasteboardRestoreCompletion()
            let pastePosts = LockedCounter()
            let system = LiveAccessibilityTargetSystem(
                isSecureInputEnabled: { false },
                frontmostProcessIdentifier: { 42 },
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access,
                        clock: clock,
                        conditionalRestoreDidFinish: {
                            await restoreCompletion.markCompleted()
                        }
                    )
                },
                focusedTargetState: { _, _ in .success(true) },
                postPasteCommand: {
                    pastePosts.increment()
                    return true
                }
            )

            let result = await system.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )
            try await clock.waitUntilSleepRequestCount(1)
            pasteboard.replaceExternally(with: externalItems)

            let firstCompletion = CompletionFlag()
            let secondCompletion = CompletionFlag()
            let firstShutdown = Task {
                await system.shutdown()
                await firstCompletion.markComplete()
            }
            let secondShutdown = Task {
                await system.shutdown()
                await secondCompletion.markComplete()
            }
            await settle()
            let firstCompletedEarly = await firstCompletion.isComplete
            let secondCompletedEarly = await secondCompletion.isComplete

            try expect(result == .posted)
            try expect(!firstCompletedEarly && !secondCompletedEarly)
            try expect(pastePosts.value == 1)

            clock.advance(by: .seconds(3))
            await firstShutdown.value
            await secondShutdown.value
            try expect(pasteboard.items == externalItems)

            await system.shutdown()
            let lateResult = await system.paste(
                "late text",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )
            try expect(lateResult == .eventFailed)
            try expect(pastePosts.value == 1)
            try expect(pasteboard.items == externalItems)
        }

        await runAsync(
            "shutdown owns a restore reserved before pasteboard preparation",
            failures: &failures
        ) {
            let originalItems = [
                ["public.png": Data([1, 2, 3])]
            ]
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let preparation = ControlledPasteboardPreparation()
            let clock = ManualVoiceInputClock()
            let restoreCompletion = PasteboardRestoreCompletion()
            let pastePosts = LockedCounter()
            let system = LiveAccessibilityTargetSystem(
                isSecureInputEnabled: { false },
                frontmostProcessIdentifier: { 42 },
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await preparation.block()
                    return await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access,
                        clock: clock,
                        conditionalRestoreDidFinish: {
                            await restoreCompletion.markCompleted()
                        }
                    )
                },
                focusedTargetState: { _, _ in .success(true) },
                postPasteCommand: {
                    pastePosts.increment()
                    return true
                }
            )
            let paste = Task {
                await system.paste(
                    "hello",
                    to: AccessibilityTargetReference(),
                    in: 42,
                    receipt: .unconfirmed
                )
            }
            await preparation.waitUntilBlocked()

            let completion = CompletionFlag()
            let shutdown = Task {
                await system.shutdown()
                await completion.markComplete()
            }
            await settle()
            let completedDuringPreparation = await completion.isComplete
            try expect(!completedDuringPreparation)

            await preparation.resume()
            try await clock.waitUntilSleepRequestCount(1)
            let completedBeforeRestore = await completion.isComplete
            try expect(!completedBeforeRestore)

            clock.advance(by: .seconds(3))
            let result = await paste.value
            await shutdown.value
            try expect(result == .posted)
            try expect(pastePosts.value == 1)
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "voice shutdown is immediate after automatic restore completed",
            failures: &failures
        ) {
            let originalItems = [
                ["public.rtf": Data([1, 2, 3])]
            ]
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let restoreCompletion = PasteboardRestoreCompletion()
            let liveSystem = LiveAccessibilityTargetSystem(
                isSecureInputEnabled: { false },
                frontmostProcessIdentifier: { 42 },
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access,
                        clock: clock,
                        conditionalRestoreDidFinish: {
                            await restoreCompletion.markCompleted()
                        }
                    )
                },
                focusedTargetState: { _, _ in .success(true) },
                postPasteCommand: { true }
            )
            let result = await liveSystem.paste(
                "hello",
                to: AccessibilityTargetReference(),
                in: 42,
                receipt: .unconfirmed
            )
            try await clock.waitUntilSleepRequestCount(1)
            clock.advance(by: .seconds(3))
            try await restoreCompletion.waitUntilCompleted()

            let targets = AccessibilityInputTargets(
                system: LifecycleAccessibilityTargetSystem(live: liveSystem)
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: targets,
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: targets,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let completion = CompletionFlag()
            let shutdown = Task {
                await sessions.shutdown()
                await completion.markComplete()
            }
            let completed = await eventually(before: .seconds(2)) {
                await completion.isComplete
            }
            await shutdown.value

            try expect(result == .posted)
            try expect(pasteboard.items == originalItems)
            try expect(
                completed,
                "completed restore remained owned by delivery shutdown"
            )
        }

        await runAsync("background AX target never receives paste events", failures: &failures) {
            let system = AccessibilityTargetSystemFake(
                isFrontmost: false,
                valueResponses: [.success("Hello")]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let pastePosts = await system.pasteCallCount

            try expect(
                outcome.pendingCopyReason == .unsupportedTarget
            )
            try expect(
                outcome.deliveryDiagnostic?.code
                    == "fallbackEligibility.notFrontmost"
            )
            try expect(pastePosts == 0)
        }

        await runAsync(
            "rejected paste fallback retains its exact delivery boundary", failures: &failures
        ) {
            let system = AccessibilityTargetSystemFake(
                valueResponses: [
                    .success("Hello"),
                    .success("Hello"),
                ],
                pasteResult: .eventFailed
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
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
                    == "pastePost.rejected"
            )
        }

        await runBoundedEvidenceSpecs(failures: &failures)
        runEditableSignalSpecs(failures: &failures)
    }

    @MainActor
    private static func runBoundedEvidenceSpecs(failures: inout [String]) async {
        let limit = AccessibilityValueEvidenceLimits.maximumCharacterCount
        let context = AccessibilityValueEvidenceLimits.contextCharacterCount

        run("value evidence reads a bounded window around the selection", failures: &failures) {
            try expect(
                AccessibilityValueEvidence.sampleRange(
                    around: NSRange(location: 5_000, length: 10),
                    length: 10_000
                ) == NSRange(location: 5_000 - context, length: 10 + 2 * context)
            )
            try expect(
                AccessibilityValueEvidence.sampleRange(
                    around: NSRange(location: 3, length: 0),
                    length: 10
                ) == NSRange(location: 0, length: 10)
            )
            try expect(
                AccessibilityValueEvidence.sampleRange(around: nil, length: 10_000)
                    == NSRange(location: 0, length: 2 * context),
                "a target without a selection read more than the start of its value"
            )
            try expect(
                AccessibilityValueEvidence.sampleRange(
                    around: NSRange(location: 0, length: 0),
                    length: limit + 1
                ) == nil,
                "a value over the limit was used as evidence"
            )
            try expect(
                AccessibilityTextSample.evidence(
                    fromValue: String(repeating: "a", count: limit + 1),
                    selection: nil
                ) == nil
            )
            try expect(
                AccessibilityTextSample.evidence(
                    fromValue: String(repeating: "a", count: limit),
                    selection: nil
                ) != nil
            )
        }

        run("a paste expectation tells the result from the original", failures: &failures) {
            let original = AccessibilityTextSample(
                value: "Hello world",
                range: NSRange(location: 0, length: 11)
            )
            guard
                let expectation = AccessibilityPasteExpectation(
                    original: original,
                    selection: NSRange(location: 6, length: 5),
                    inserting: "w"
                )
            else {
                throw SpecFailure(message: "a selection inside the window had no expectation")
            }
            let range = expectation.receiptRange
            try expect(range == NSRange(location: 0, length: 11))
            try expect(
                expectation.classify(.init(value: "Hello w", range: range)) == .expected
            )
            try expect(
                expectation.classify(.init(value: "Hello world", range: range)) == .original,
                "the unchanged value was taken as the pasted result"
            )
            try expect(
                expectation.classify(.init(value: "Hello x", range: range)) == .other
            )
            try expect(
                AccessibilityPasteExpectation(
                    original: original,
                    selection: nil,
                    inserting: "w"
                ) == nil,
                "a target without a selection claimed a receipt"
            )
        }

        run("an edit outside the window that changes the length is seen", failures: &failures) {
            let value = String(repeating: "a", count: 2_000)
            let selection = NSRange(location: 1_000, length: 0)
            guard
                let evidence = AccessibilityTextSample.evidence(
                    fromValue: value,
                    selection: selection
                )
            else { throw SpecFailure(message: "evidence was not built") }
            let edited = value + "b"
            try expect(
                !AccessibilityTextSample(value: edited, range: evidence.range).shows(evidence)
            )
            try expect(
                AccessibilityTextSample(value: value, range: evidence.range).shows(evidence)
            )
        }

        await runAsync(
            "a long value is checked through bounded windows and still confirms",
            failures: &failures
        ) {
            let value = String(repeating: "a", count: 10_000)
            let selection = NSRange(location: 5_000, length: 0)
            let pasted = (value as NSString).replacingCharacters(in: selection, with: " world")
            let system = AccessibilityTargetSystemFake(
                originalValue: value,
                selection: selection,
                valueResponses: [.success(value), .success(value), .success(pasted)]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let ranges = await system.sampleRangesRead

            try expect(outcome == .delivered)
            try expect(ranges.count == 3)
            try expect(
                ranges.allSatisfy { $0.length <= 2 * context + " world".utf16.count },
                "delivery read more than a bounded window: \(ranges)"
            )
        }

        await runAsync(
            "a length change outside the window stops delivery before paste",
            failures: &failures
        ) {
            let value = String(repeating: "a", count: 2_000)
            let system = AccessibilityTargetSystemFake(
                originalValue: value,
                selection: NSRange(location: 1_000, length: 0),
                valueResponses: [.success(value + "b")]
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "fake AX target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )

            try expect(
                outcome
                    == .pendingCopyDiagnosed(
                        .changedTarget,
                        .init(stage: .valueRead, cause: .changed)
                    )
            )
            let pastePosts = await system.pasteCallCount
            try expect(pastePosts == 0)
        }

        await runAsync(
            "a value over the evidence limit is pasted without a receipt",
            failures: &failures
        ) {
            let value = String(repeating: "a", count: limit + 1)
            let system = AccessibilityTargetSystemFake(
                originalValue: value,
                selection: NSRange(location: 0, length: 0),
                valueResponses: []
            )
            let targets = AccessibilityInputTargets(system: system)
            guard case .writable(let target) = await targets.capture() else {
                throw SpecFailure(message: "an over-limit target was not captured")
            }

            let outcome = await targets.deliver(
                " world",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            let receipts = await system.pasteReceipts
            let ranges = await system.sampleRangesRead

            guard case .pasteCommandPosted(let diagnostic) = outcome else {
                throw SpecFailure(message: "an over-limit target did not reach paste")
            }
            try expect(diagnostic.code == "pasteReceipt.unconfirmed")
            try expect(receipts.map(\.currentConclusion) == [.unconfirmed])
            try expect(ranges.isEmpty, "an over-limit value was read during delivery")
        }
    }

    @MainActor
    private static func runEditableSignalSpecs(failures: inout [String]) {
        func isEditable(
            role: String?,
            subrole: String? = nil,
            selection: Bool = false,
            settable: Bool = false,
            ancestor: Bool = false
        ) -> Bool {
            AccessibilityEditableSignal.isEditable(
                role: role,
                subrole: subrole,
                hasSelectedTextRange: selection,
                isValueSettable: { settable },
                hasEditableAncestor: { ancestor }
            )
        }

        run("automatic paste needs a positive editable signal", failures: &failures) {
            for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
                try expect(isEditable(role: role), "\(role) was not editable")
            }
            try expect(isEditable(role: "AXGroup", subrole: "AXSearchField"))
            try expect(isEditable(role: "AXGroup", selection: true))
            try expect(isEditable(role: "AXGroup", settable: true))
            try expect(isEditable(role: "AXGroup", ancestor: true))
            try expect(isEditable(role: nil, ancestor: true))
            try expect(
                !isEditable(role: "AXButton"),
                "a control with no editable signal accepted a paste"
            )
            try expect(!isEditable(role: "AXGroup"))
            try expect(!isEditable(role: nil))
        }
    }

    /// Advances `clock` through every receipt poll until the receipt
    /// deadline passes.
    private static func driveReceiptPolls(_ clock: ManualVoiceInputClock) async throws {
        let interval = Duration.milliseconds(50)
        let polls = Int(AccessibilityInputTargets.receiptTimeout / interval)
        for poll in 1...polls {
            try await clock.waitUntilSleepRequestCount(poll)
            clock.advance(by: interval)
        }
    }
}
