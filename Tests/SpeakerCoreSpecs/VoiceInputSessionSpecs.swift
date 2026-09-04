import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum VoiceInputSessionSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
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

            await sessions.send(.pressed)
            await sessions.send(.released)
            let deliveryCompleted = await eventually(before: .seconds(1)) {
                await delivery.deliveredTexts == ["你好，SwiftUI。"]
            }

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
            let historyCommitted = await eventually(before: .seconds(1)) {
                await history.records.count == 1
            }
            let records = await history.records

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

        await runAsync("a new press replaces text awaiting explicit copy", failures: &failures) {
            let clipboard = ClipboardFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "旧的留存文字。"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            await sessions.send(.pressed)
            await sessions.send(.released)
            let retained = await terminal.value
            try expect(retained?.activity.pendingCopyReason == .missingTarget)

            // 用户在留存提示挂着时再按快捷键 = 主动放弃旧文字重录,
            // 会话层必须开新会话而不是拒绝按键。
            let replaced = Task { () -> VoiceInputPresentation? in
                for await presentation in await sessions.observe() {
                    if presentation.activity.pendingCopyReason == nil,
                       presentation.activity != .idle {
                        return presentation
                    }
                }
                return nil
            }
            await sessions.send(.pressed)
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
            await sessions.send(.cancel)
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

        await runAsync("failed system copy restores every prior pasteboard representation", failures: &failures) {
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
                failedReplacementItems: [[
                    "public.utf8-plain-text": Data("partial replacement".utf8),
                ]]
            )
            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)

            let copied = await writer.copy("replacement")

            try expect(!copied)
            try expect(pasteboard.items == originalItems)
        }

        await runAsync("system clipboard reports success only after exact readback", failures: &failures) {
            let originalItems = [
                ["public.utf8-plain-text": Data("original".utf8)],
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

        await runAsync("system copy preserves a newer external clipboard owner", failures: &failures) {
            let externalItems = [
                ["public.utf8-plain-text": Data("new external copy".utf8)],
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

        await runAsync("unsafe system clipboard snapshots fail before mutation", failures: &failures) {
            let oneItem = [["type.a": Data([1, 2, 3, 4])]]
            let cases: [(
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
                try expect(!copied)
                try expect(pasteboard.clearCount == 0)
                try expect(pasteboard.items == testCase.items)
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
            let itemBoundedWriter = SystemClipboardWriter(
                pasteboard: tooManyItems.access,
                snapshotBudget: .init(
                    maximumItemCount: 1,
                    maximumRepresentationCount: 2,
                    maximumBytesPerRepresentation: 1,
                    maximumTotalBytes: 2
                )
            )

            let itemResult = await itemBoundedWriter.copy("replacement")
            try expect(!itemResult)
            try expect(tooManyItems.itemTypesReadCount == 0)

            let tooManyRepresentations = ClipboardPasteboardFake(items: [[
                "type.a": Data([1]),
                "type.b": Data([2]),
            ]])
            let representationBoundedWriter = SystemClipboardWriter(
                pasteboard: tooManyRepresentations.access,
                snapshotBudget: .init(
                    maximumItemCount: 1,
                    maximumRepresentationCount: 1,
                    maximumBytesPerRepresentation: 1,
                    maximumTotalBytes: 1
                )
            )

            let representationResult = await representationBoundedWriter.copy(
                "replacement"
            )
            try expect(!representationResult)
            try expect(tooManyRepresentations.itemTypesReadCount == 1)
            try expect(tooManyRepresentations.clearCount == 0)
        }

        await runAsync("system clipboard snapshot accepts exact resource limits", failures: &failures) {
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
                    refinementMode: .conciseCleanup()
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

            let inFlightRecords = await history.allRecords()
            try expect(
                inFlightRecords.isEmpty,
                "textless in-flight session reached history"
            )
            try expect(
                !sqliteFilesContain(Data(secret.utf8), at: fileURL),
                "confirmed secure transcript reached SQLite or WAL bytes"
            )

            await sessions.send(.cancel)
            await release.value
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

        await runAsync("posted paste finishes without exposing retryable manual copy", failures: &failures) {
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "Editor"))
                ),
                transcriber: SpeechTranscriberFake(text: "只粘贴一次。"),
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

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let persisted = await eventually(before: .milliseconds(300)) {
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
                transcriber: SpeechTranscriberFake(text: "结果不能丢。"),
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
            "global release callback never performs target AX work inline",
            failures: &failures
        ) {
            let audio = AudioCaptureFake()
            let targetSystem = AccessibilityTargetSystemFake(
                processID: 41,
                valueResponses: []
            )
            let targets = AccessibilityInputTargets(
                system: targetSystem,
                releaseCapture: { .process(processID: 41) }
            )
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                transcriber: SpeechTranscriberFake(text: "不会阻塞事件回调"),
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
            let clock = ContinuousClock()
            let started = clock.now
            dispatcher.send(
                .released,
                at: VoiceShortcutGestureStateMachine
                    .defaultLongPressNanoseconds
            )
            let callbackDuration = started.duration(to: clock.now)

            try expect(
                callbackDuration < .milliseconds(20),
                "release callback blocked on target capture for \(callbackDuration)"
            )
            while await targetSystem.captureFocusedCallCount == 0 {
                await Task.yield()
            }
            await dispatcher.shutdown()
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

        await runAsync(
            "recording deadline starts only after audio capture succeeds",
            failures: &failures
        ) {
            let deadline = ControlledRecordingDeadline()
            let audio = AudioCaptureFake(delaysStart: true)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )

            let press = Task { await sessions.send(.pressed) }
            while await audio.startCount == 0 { await Task.yield() }
            for _ in 0..<10 { await Task.yield() }
            let preparingRequestCount = await deadline.requestCount
            try expect(preparingRequestCount == 0)

            await audio.resumeStart()
            await press.value
            await deadline.waitUntilStarted()
            let recordingRequestCount = await deadline.requestCount
            try expect(recordingRequestCount == 1)
            await sessions.shutdown()
        }
    }
}
