import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum VoiceInputSessionSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("hold and release delivers deterministic transcript", failures: &failures) {
            let audio = AudioCaptureFake()
            let targets = TargetCaptureFake(
                result: .writable(
                    .init(
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
                textProcessor: BasicVoiceTextProcessor(transcriber: transcriber),
                delivery: delivery,
                clipboard: clipboard,
                history: history
            )
            let presentations = await sessions.observe()

            await sessions.dispatchPress()
            // A release returns only after its session has finished, delivery
            // included.
            await sessions.releaseAndAwaitTerminal()
            let deliveryCompleted = await delivery.deliveredTexts == ["你好，SwiftUI。"]

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

            let values = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            // The Session Record is written after the terminal presentation;
            // shutdown returns once every queued history write has finished.
            await sessions.shutdown()
            let records = await history.records
            let historyCommitted = records.count == 1

            try expect(
                deliveryCompleted,
                "Voice Input Session did not deliver the transcript"
            )
            try expect(
                values.last?.activity.isDelivered == true,
                "slow observer did not receive the current terminal presentation"
            )
            try expect(
                zip(values, values.dropFirst()).allSatisfy {
                    $0.revision < $1.revision
                },
                "presentation revisions were not strictly increasing"
            )
            try expect(
                deliveredTexts == ["你好，SwiftUI。"],
                "delivered transcript changed"
            )
            try expect(
                historyCommitted,
                "terminal delivery was not committed to history"
            )
            try expect(records.count == 1, "Session Record count changed")
            try expect(
                records.first?.finalText == "你好，SwiftUI。",
                "Session Record final text changed"
            )
            try expect(
                records.first?.providerRequestID == "local-spec",
                "Session Record provider request ID changed"
            )
        }

        await runAsync("release during recorder startup still completes once", failures: &failures)
        {
            let audio = AudioCaptureFake(delaysStart: true)
            let targets = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
            )
            let transcriber = SpeechTranscriberFake(text: "短按也不会丢。")
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                textProcessor: BasicVoiceTextProcessor(transcriber: transcriber),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let press = Task { await sessions.dispatchPress() }
            while await audio.startCount == 0 {
                await Task.yield()
            }
            await sessions.releaseAndAwaitTerminal()
            await audio.resumeStart()
            await press.value
            await Task.yield()

            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts

            try expect(stopCount == 1)
            try expect(deliveredTexts == ["短按也不会丢。"])
        }

        await runAsync("cancel during recorder startup cleans late recording", failures: &failures)
        {
            let audio = AudioCaptureFake(delaysStart: true)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "不应出现")),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            let press = Task { await sessions.dispatchPress() }
            while await audio.startCount == 0 {
                await Task.yield()
            }
            await sessions.dispatchEscape()
            await audio.resumeStart()
            await press.value

            let isActive = await audio.isActive
            try expect(!isActive)
        }

        await runAsync("recorder start failure preserves preparation timing", failures: &failures) {
            let clock = ManualVoiceInputClock()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: DelayedFailingStartAudioCapture(
                    clock: clock,
                    startDelay: .milliseconds(20)
                ),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "unused")),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )

            await sessions.dispatchPress()
            await sessions.shutdown()

            let record = await history.records.last
            try expect(record?.outcome.isRecordingFailed == true)
            try expect(record?.durationMilliseconds == 20)
            try expect(record?.stageDurationsMilliseconds["preparing"] == 20)
        }

        await runAsync("missing target waits for explicit copy", failures: &failures) {
            let clipboard = ClipboardFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "请手动复制。")),
                delivery: delivery,
                clipboard: clipboard,
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()

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

            let hiddenAfterCopy = Task {
                for await presentation in await sessions.observe() {
                    if presentation.activity == .idle { return true }
                }
                return false
            }
            guard let id = result?.activity.sessionID else {
                throw SpecFailure(message: "the pending copy result had no session")
            }
            await sessions.copyPendingResult(expectedSessionID: id)
            let copiedAfter = await clipboard.copiedTexts
            let didHideAfterCopy = await hiddenAfterCopy.value
            try expect(copiedAfter == ["请手动复制。"])
            let privacies = await clipboard.copiedPrivacies
            try expect(privacies == [.ordinary], "an ordinary result was copied concealed")
            try expect(didHideAfterCopy)
        }

        await runAsync("a new press replaces text awaiting explicit copy", failures: &failures) {
            let clipboard = ClipboardFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "旧的留存文字。")),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()
            let retained = await terminal.value
            try expect(retained?.activity.pendingCopyReason == .missingTarget)

            // 用户在留存提示挂着时再按快捷键 = 主动放弃旧文字重录,
            // 会话层必须开新会话而不是拒绝按键。
            let replaced = Task { () -> VoiceInputPresentation? in
                for await presentation in await sessions.observe() {
                    if presentation.activity.pendingCopyReason == nil,
                        presentation.activity != .idle
                    {
                        return presentation
                    }
                }
                return nil
            }
            await sessions.dispatchPress()
            let next = await replaced.value
            try expect(
                next?.activity.sessionID != nil,
                "a press during pending copy did not start a new session"
            )
            try expect(
                next?.activity.pendingCopyReason == nil,
                "the retained-text notice survived a new press"
            )
            let copied = await clipboard.copiedTexts
            try expect(copied.isEmpty, "replacing retained text touched the clipboard")
            await sessions.dispatchEscape()
        }

        await runAsync("dismiss pending copy hides without changing clipboard", failures: &failures)
        {
            let clipboard = ClipboardFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "不要复制。")),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()
            guard let id = await terminal.value?.activity.sessionID else {
                throw SpecFailure(message: "the pending copy result had no session")
            }

            let hiddenAfterDismiss = Task {
                for await presentation in await sessions.observe() {
                    if presentation.activity == .idle { return true }
                }
                return false
            }
            await sessions.dismissResult(expectedSessionID: id)
            let didHideAfterDismiss = await hiddenAfterDismiss.value
            let copiedTexts = await clipboard.copiedTexts
            try expect(didHideAfterDismiss)
            try expect(copiedTexts.isEmpty)
        }

        await runAsync(
            "failed clipboard write keeps the result visible for retry", failures: &failures
        ) {
            let clipboard = ClipboardFake(succeeds: false)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "必须保留。")),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake()
            )

            await sessions.dispatchPress()
            let retained = await sessions.releaseAndAwaitTerminal()
            guard let id = retained?.activity.sessionID else {
                throw SpecFailure(message: "the pending copy result had no session")
            }
            let clipboardFailure = Task<VoiceInputPresentation?, Never> {
                for await presentation in await sessions.observe() {
                    if presentation.activity.pendingCopyReason == .clipboardFailed {
                        return presentation
                    }
                }
                return nil
            }
            await sessions.copyPendingResult(expectedSessionID: id)
            let presentation = await clipboardFailure.value

            try expect(presentation?.activity.pendingCopyReason == .clipboardFailed)
            try expect(presentation?.activity.pendingText == "必须保留。")
        }

        await runAsync(
            "failed system copy restores every prior pasteboard representation", failures: &failures
        ) {
            let originalItems = [
                [
                    "public.utf8-plain-text": Data("original text".utf8),
                    "public.rtf": Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D]),
                ],
                ["public.png": Data([0x89, 0x50, 0x4E, 0x47])],
            ]
            let pasteboard = ClipboardPasteboardFake(
                items: originalItems,
                replacementWriteSucceeds: false
            )
            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)

            let copied = await writer.copy("replacement")

            try expect(!copied)
            try expect(pasteboard.items == originalItems)

            let emptyPasteboard = ClipboardPasteboardFake(
                items: [],
                replacementWriteSucceeds: false
            )
            let emptyWriter = SystemClipboardWriter(
                pasteboard: emptyPasteboard.access
            )
            let copiedOverEmpty = await emptyWriter.copy("replacement")
            try expect(!copiedOverEmpty)
            try expect(emptyPasteboard.items.isEmpty)
        }

        await runAsync(
            "failed owned system copy restores after a partial pasteboard mutation",
            failures: &failures
        ) {
            let originalItems = [
                [
                    "public.utf8-plain-text": Data("original text".utf8),
                    "public.rtf": Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D]),
                ],
                ["public.png": Data([0x89, 0x50, 0x4E, 0x47])],
            ]
            let pasteboard = ClipboardPasteboardFake(
                items: originalItems,
                replacementWriteSucceeds: false,
                failedReplacementItems: [
                    [
                        "public.utf8-plain-text": Data("partial replacement".utf8)
                    ]
                ]
            )
            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)

            let copied = await writer.copy("replacement")

            try expect(!copied)
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "system clipboard reports success only after exact readback", failures: &failures
        ) {
            let originalItems = [
                ["public.utf8-plain-text": Data("original".utf8)]
            ]
            let stalePasteboard = ClipboardPasteboardFake(
                items: originalItems,
                replacementReadback: "previous clipboard value"
            )
            let confirmedPasteboard = ClipboardPasteboardFake(items: [])
            let staleWriter = SystemClipboardWriter(
                pasteboard: stalePasteboard.access
            )
            let confirmedWriter = SystemClipboardWriter(
                pasteboard: confirmedPasteboard.access
            )

            let staleResult = await staleWriter.copy("expected value")
            let confirmedResult = await confirmedWriter.copy("expected value")
            try expect(!staleResult)
            try expect(stalePasteboard.items == originalItems)
            try expect(confirmedResult)
            try expect(
                confirmedPasteboard.items
                    == [["public.utf8-plain-text": Data("expected value".utf8)]]
            )
        }

        await runAsync(
            "system copy preserves a newer external clipboard owner", failures: &failures
        ) {
            let externalItems = [
                ["public.utf8-plain-text": Data("new external copy".utf8)]
            ]
            let pasteboard = ClipboardPasteboardFake(
                items: [["public.png": Data([0x89, 0x50])]],
                externalItemsAfterReplacement: externalItems
            )
            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)

            let copied = await writer.copy("Speaker text")

            try expect(!copied)
            try expect(pasteboard.items == externalItems)
        }

        await runAsync(
            "explicit copy replaces an over-budget clipboard and refuses an unreadable one",
            failures: &failures
        ) {
            let oneItem = [["type.a": Data([1, 2, 3, 4])]]
            let cases:
                [(
                    items: [[String: Data]],
                    unreadableTypes: Set<String>,
                    budget: PasteboardSnapshotBudget
                )] = [
                    (
                        oneItem,
                        [],
                        .init(
                            maximumItemCount: 0,
                            maximumRepresentationCount: 1,
                            maximumBytesPerRepresentation: 4,
                            maximumTotalBytes: 4
                        )
                    ),
                    (
                        oneItem,
                        [],
                        .init(
                            maximumItemCount: 1,
                            maximumRepresentationCount: 0,
                            maximumBytesPerRepresentation: 4,
                            maximumTotalBytes: 4
                        )
                    ),
                    (
                        oneItem,
                        [],
                        .init(
                            maximumItemCount: 1,
                            maximumRepresentationCount: 1,
                            maximumBytesPerRepresentation: 3,
                            maximumTotalBytes: 4
                        )
                    ),
                    (
                        oneItem,
                        [],
                        .init(
                            maximumItemCount: 1,
                            maximumRepresentationCount: 1,
                            maximumBytesPerRepresentation: 4,
                            maximumTotalBytes: 3
                        )
                    ),
                    (
                        oneItem,
                        ["type.a"],
                        .init(
                            maximumItemCount: 1,
                            maximumRepresentationCount: 1,
                            maximumBytesPerRepresentation: 4,
                            maximumTotalBytes: 4
                        )
                    ),
                ]

            for testCase in cases {
                let pasteboard = ClipboardPasteboardFake(
                    items: testCase.items,
                    unreadableTypes: testCase.unreadableTypes
                )
                let writer = SystemClipboardWriter(
                    pasteboard: pasteboard.access,
                    snapshotBudget: testCase.budget
                )

                let copied = await writer.copy("replacement")
                if testCase.unreadableTypes.isEmpty {
                    // The user asked to replace this clipboard; one too large
                    // to set aside is replaced without a rollback copy.
                    try expect(copied, "an explicit copy refused an over-budget clipboard")
                    try expect(
                        pasteboard.items
                            == [["public.utf8-plain-text": Data("replacement".utf8)]]
                    )
                } else {
                    try expect(!copied)
                    try expect(pasteboard.clearCount == 0)
                    try expect(pasteboard.items == testCase.items)
                }
            }
        }

        await runAsync(
            "clipboard metadata enumeration stops at the configured boundary",
            failures: &failures
        ) {
            let tooManyItems = ClipboardPasteboardFake(items: [
                ["type.a": Data([1])],
                ["type.b": Data([2])],
            ])
            let itemResult = PasteboardSnapshot.capture(
                from: tooManyItems.access,
                budget: .init(
                    maximumItemCount: 1,
                    maximumRepresentationCount: 2,
                    maximumBytesPerRepresentation: 1,
                    maximumTotalBytes: 2
                )
            )
            try expect(itemResult == .failure(.tooLarge))
            try expect(tooManyItems.itemTypesReadCount == 0)

            let tooManyRepresentations = ClipboardPasteboardFake(items: [
                [
                    "type.a": Data([1]),
                    "type.b": Data([2]),
                ]
            ])
            let representationResult = PasteboardSnapshot.capture(
                from: tooManyRepresentations.access,
                budget: .init(
                    maximumItemCount: 1,
                    maximumRepresentationCount: 1,
                    maximumBytesPerRepresentation: 1,
                    maximumTotalBytes: 1
                )
            )
            try expect(representationResult == .failure(.tooLarge))
            try expect(tooManyRepresentations.itemTypesReadCount == 1)
            try expect(tooManyRepresentations.clearCount == 0)
        }

        await runAsync(
            "system clipboard snapshot accepts exact resource limits", failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(
                items: [["type.a": Data([1, 2, 3, 4])]]
            )
            let writer = SystemClipboardWriter(
                pasteboard: pasteboard.access,
                snapshotBudget: .init(
                    maximumItemCount: 1,
                    maximumRepresentationCount: 1,
                    maximumBytesPerRepresentation: 4,
                    maximumTotalBytes: 4
                )
            )

            let copied = await writer.copy("replacement")
            try expect(copied)
        }

        await runAsync(
            "a window-scope target delivers but keeps its text out of history",
            failures: &failures
        ) {
            for isSecurityClassConfirmed in [false, true] {
                let history = SessionHistoryFake()
                let sessions = VoiceInputSessions(
                    audioCapture: AudioCaptureFake(),
                    targetCapture: TargetCaptureFake(
                        result: .writable(
                            InputTargetSnapshot(
                                id: UUID(),
                                applicationName: "Terminal",
                                isSecurityClassConfirmed: isSecurityClassConfirmed
                            ))
                    ),
                    textProcessor: BasicVoiceTextProcessor(
                        transcriber: SpeechTranscriberFake(text: "窗口里的文字")),
                    delivery: TextDeliveryFake(result: .delivered),
                    clipboard: ClipboardFake(),
                    history: history
                )
                let terminal = terminalPresentation(from: await sessions.observe())

                await sessions.dispatchPress()
                await sessions.releaseAndAwaitTerminal()

                let result = await terminal.value
                _ = await eventually(before: .seconds(2)) {
                    await history.records.first != nil
                }
                let record = await history.records.first
                try expect(
                    result?.activity.isDelivered == true,
                    "the target did not receive the text"
                )
                if isSecurityClassConfirmed {
                    try expect(
                        record?.finalText == "窗口里的文字",
                        "an element target lost its history text"
                    )
                } else {
                    try expect(
                        record?.transcription == nil && record?.finalText == nil,
                        "an unclassified target persisted transcript text"
                    )
                    guard case .delivered(_, let storedText)? = record?.outcome else {
                        throw SpecFailure(message: "the delivered outcome was not recorded")
                    }
                    try expect(
                        storedText.isEmpty,
                        "an unclassified target persisted text in its outcome"
                    )
                }
            }
        }

        await runAsync("secure target never receives automatic text", failures: &failures) {
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.secureTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "敏感文本")),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            _ = await eventually(before: .seconds(2)) {
                await history.records.first?.outcome.pendingCopyReason == .secureTarget
            }
            let record = await history.records.first
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
                record?.refinementRequestID == nil,
                "secure refinement request identity was persisted"
            )
            try expect(
                record?.outcome.pendingText == "",
                "secure text was persisted inside its outcome"
            )
            try expect(
                record?.refinedText == nil,
                "secure DeepSeek text was persisted"
            )
            try expect(
                record?.outcome.pendingText == "",
                "secure pending text was persisted"
            )
        }

        await runAsync(
            "a secure target's retained result is copied as concealed text, even after a failed copy",
            failures: &failures
        ) {
            let clipboard = ClipboardFake(succeeds: false)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.secureTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "密码框的文字")),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()
            guard let id = await terminal.value?.activity.sessionID else {
                throw SpecFailure(message: "the pending copy result had no session")
            }

            let failedCopy = Task<VoiceInputPresentation?, Never> {
                for await presentation in await sessions.observe() {
                    if presentation.activity.pendingCopyReason?.isClipboardFailure == true {
                        return presentation
                    }
                }
                return nil
            }
            await sessions.copyPendingResult(expectedSessionID: id)
            let failed = await failedCopy.value
            try expect(
                failed?.activity.pendingCopyReason == .secureTargetClipboardFailed,
                "a failed copy lost the secure classification"
            )

            await clipboard.setSucceeds(true)
            await sessions.copyPendingResult(expectedSessionID: id)
            let privacies = await clipboard.copiedPrivacies
            try expect(privacies == [.concealed, .concealed], "\(privacies)")
        }

        await runAsync(
            "provider and refinement text loses control characters before delivery and history",
            failures: &failures
        ) {
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let refined = "echo hi\u{1B}[201~\r\nrm -rf ~\u{07}\u{9B}\tend\rnext\u{7F}"
            let processor = DefaultVoiceTextProcessor(
                configuration: VoiceInputConfigurationController(
                    refinementMode: .conciseCleanup()
                ),
                transcriber: ContextualTranscriberFake(text: "识别\u{1B}结果\u{0}"),
                refinement: OptionalTextRefinementPipeline(
                    refiner: DeepSeekRefinerFake(result: .success(.init(text: refined)))
                )
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "Terminal"))
                ),
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()
            let result = await terminal.value

            let expected = "echo hi[201~\nrm -rf ~\tend\nnext"
            let delivered = await delivery.deliveredTexts
            try expect(result?.activity.isDelivered == true)
            try expect(delivered == [expected], "\(delivered)")
            _ = await eventually(before: .seconds(2)) {
                await history.records.first?.finalText == expected
            }
            let record = await history.records.first
            try expect(record?.finalText == expected, "\(String(describing: record?.finalText))")
            try expect(record?.transcription == "识别结果")
        }

        await runAsync(
            "text made only of control characters ends quietly without delivery",
            failures: &failures
        ) {
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "Terminal"))
                ),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "\u{1B}\u{07}\r\n")),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()
            let result = await terminal.value

            let delivered = await delivery.deliveredTexts
            try expect(delivered.isEmpty)
            guard case .failed(_, .providerReturnedNoText) = result?.activity else {
                throw SpecFailure(message: "unexpected outcome: \(String(describing: result))")
            }
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
                    refinementMode: .conciseCleanup()
                ),
                transcriber: ContextualTranscriberFake(text: secret),
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

            await sessions.dispatchPress()
            let release = Task { await sessions.releaseAndAwaitTerminal() }
            while await refiner.callCount == 0 { await Task.yield() }

            let inFlightRecords = await history.allRecords()
            try expect(
                inFlightRecords.isEmpty,
                "textless in-flight session reached history"
            )
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "confirmed secure transcript reached SQLite or WAL bytes"
            )

            await sessions.dispatchEscape()
            _ = await release.value
            await sessions.shutdown()
            let cancelledRecords = await history.allRecords()
            try expect(
                cancelledRecords.isEmpty,
                "textless cancelled session reached history"
            )
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "cancelling refinement left the secure transcript in SQLite storage"
            )
        }

        await runAsync(
            "posted paste finishes without exposing retryable manual copy", failures: &failures
        ) {
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "Editor"))
                ),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "只粘贴一次。")),
                delivery: TextDeliveryFake(
                    result: .pasteCommandPosted(
                        .init(
                            stage: .pasteReceipt,
                            cause: .unconfirmed
                        )
                    )
                ),
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()

            let result = await terminal.value
            let persisted = await eventually(before: .seconds(2)) {
                await history.records.first?.deliveryDiagnosticCode != nil
            }
            let record = await history.records.first
            try expect(result?.activity.isDelivered == true)
            try expect(result?.activity.pendingText == nil)
            try expect(persisted)
            try expect(
                record?.deliveryDiagnosticCode
                    == "pasteReceipt.unconfirmed"
            )
        }

        await runAsync("delivery failure keeps transcript pending copy", failures: &failures) {
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "结果不能丢。")),
                delivery: TextDeliveryFake(
                    result: .pendingCopyDiagnosed(
                        .deliveryUnconfirmed,
                        .init(
                            stage: .pasteReceipt,
                            cause: .unconfirmed
                        )
                    )
                ),
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()

            let result = await terminal.value
            let persisted = await eventually(
                before: .seconds(2)
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
                    == "pasteReceipt.unconfirmed"
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
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "只提交一次。")),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.dispatchPress()
            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()
            await sessions.releaseAndAwaitTerminal()

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
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "发往结束时的输入框")),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.dispatchPress()
            await target.update(applicationName: "Focused at release")
            let release = Task { await sessions.releaseAndAwaitTerminal() }
            while await target.captureCallCount == 0 { await Task.yield() }
            await target.update(applicationName: "Focused after release")
            await target.resume()
            _ = await release.value

            let deliveredApplicationNames = await delivery.applicationNames
            try expect(
                deliveredApplicationNames == ["Focused at release"],
                "focus changes after release replaced the captured delivery target"
            )
        }

        await runAsync(
            "global release callback never performs target AX work inline",
            failures: &failures
        ) {
            let audio = AudioCaptureFake()
            // The focused-input capture answers only after the case opens
            // this gate, so the release callback can return first only if it
            // leaves that capture to the session.
            let captureGate = OneShotGate()
            let targetSystem = AccessibilityTargetSystemFake(
                processID: 41,
                valueResponses: [],
                captureGate: captureGate
            )
            let targets = AccessibilityInputTargets(
                system: targetSystem,
                releaseCapture: { .process(processID: 41) }
            )
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "不会阻塞事件回调")),
                delivery: targets,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let dispatcher = VoiceInputTriggerDispatcher(
                sessions: sessions,
                releaseCaptureHint: { targets.releaseCaptureHint() }
            )

            dispatcher.send(.pressed, at: 0)
            while await audio.startCount == 0 { await Task.yield() }
            let release = Task.detached { () throws in
                dispatcher.send(
                    .released,
                    at: VoiceShortcutGestureStateMachine
                        .defaultLongPressNanoseconds
                )
            }
            let callbackReturned = await finishes(release, before: .seconds(2))
            let captureStarted = await eventually(before: .seconds(2)) {
                await targetSystem.captureFocusedCallCount == 1
            }
            await captureGate.open()
            await dispatcher.shutdown()

            try expect(
                callbackReturned,
                "release callback waited for the focused-input capture"
            )
            try expect(captureStarted, "the session never captured the focused input")
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
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "不会送到后来切换的应用")),
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

        await runAsync(
            "global trigger dispatcher supports tap-to-start and tap-to-stop", failures: &failures
        ) {
            let audio = AudioCaptureFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "顺序正确。")),
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

        await runAsync(
            "terminal result is published before blocked history persistence", failures: &failures
        ) {
            let history = BlockingSessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "先把结果交给用户")),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.dispatchPress()
            await sessions.releaseAndAwaitTerminal()
            let presentation = await terminal.value

            try expect(
                presentation?.activity.pendingText == "先把结果交给用户",
                "history I/O blocked the user-visible terminal result"
            )

            let shutdown = Task { await sessions.shutdown() }
            await history.unblock()
            await shutdown.value
        }

        await runAsync(
            "processing-time shortcut presses are rejected instead of delayed", failures: &failures
        ) {
            let audio = AudioCaptureFake()
            let transcriber = SpeechTranscriberFake(
                text: "处理完成",
                delaysResponse: true
            )
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(transcriber: transcriber),
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
            await settle()
            let startCountDuringProcessing = await audio.startCount
            try expect(startCountDuringProcessing == 1)

            await transcriber.resume()
            let retained = await terminal.value
            await settle()
            let startCountAfterProcessing = await audio.startCount
            try expect(
                startCountAfterProcessing == 1,
                "a press made during processing started a delayed recording"
            )

            if let id = retained?.activity.sessionID {
                await sessions.dismissResult(expectedSessionID: id)
            }
            dispatcher.send(.pressed, at: 4_000_000_000)
            let restarted = await eventually(before: .seconds(2)) {
                await audio.startCount == 2
            }
            try expect(
                restarted,
                "the gesture did not reset after rejecting a processing-time press"
            )
            await dispatcher.shutdown()
        }

        await runAsync(
            "provider processing has no business timeout and remains cancellable",
            failures: &failures
        ) {
            let transcriber = SpeechTranscriberFake(
                text: "late result",
                delaysResponse: true
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(transcriber: transcriber),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let releaseCompleted = CompletionFlag()

            await sessions.dispatchPress()
            let release = Task {
                await sessions.releaseAndAwaitTerminal()
                await releaseCompleted.markComplete()
            }
            while await transcriber.callCount == 0 { await Task.yield() }
            await settle()

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

            await sessions.dispatchEscape()
            await transcriber.resume()
            await release.value
            let cancellationCount = await transcriber.cancellationCount
            try expect(cancellationCount == 1)
        }

        await runAsync(
            "recording deadline starts only after audio capture succeeds",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let audio = AudioCaptureFake(delaysStart: true)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: BasicVoiceTextProcessor(
                    transcriber: SpeechTranscriberFake(text: "unused")),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )

            let press = Task { await sessions.dispatchPress() }
            while await audio.startCount == 0 { await Task.yield() }
            await settle()
            let preparingRequestCount = clock.sleepRequestCount
            try expect(preparingRequestCount == 0)

            await audio.resumeStart()
            await press.value
            try await clock.waitUntilSleepRequestCount(1)
            let recordingRequestCount = clock.sleepRequestCount
            try expect(recordingRequestCount == 1)
            await sessions.shutdown()
        }
    }
}
