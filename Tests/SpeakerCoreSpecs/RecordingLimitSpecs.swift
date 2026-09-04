import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum RecordingLimitSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "recording safety limit stops capture and provider without delivery",
            failures: &failures
        ) {
            let deadline = ControlledRecordingDeadline()
            let audio = StreamingAudioCaptureFake()
            let processor = StreamingVoiceTextProcessorFake()
            let target = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
            )
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: target,
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            let triggerTerminations = await sessions.observeTriggerTerminations()
            let triggerTermination = Task {
                var iterator = triggerTerminations.makeAsyncIterator()
                return await iterator.next()
            }

            await sessions.send(.pressed, triggerSequence: 41)
            await deadline.waitUntilStarted()
            let requestedDuration = await deadline.requestedDuration
            try expect(requestedDuration == .seconds(600))

            await deadline.fire()
            let presentation = await terminal.value
            let terminatedSequence = await triggerTermination.value
            let providerCancelled = await eventually(before: .milliseconds(300)) {
                await processor.cancellationCount == 1
            }
            let finalRecordReady = await eventually(before: .milliseconds(300)) {
                await history.records.last?.outcome.failure
                    == .recordingLimitReached
            }
            let finalRecord = await history.records.last
            let recordCount = await history.records.count
            let audioCancelCount = await audio.cancelCount
            let targetCaptureCount = await target.captureCount
            let deliveredTexts = await delivery.deliveredTexts

            try expect(
                presentation?.activity.failure == .recordingLimitReached
            )
            try expect(terminatedSequence == 41)
            try expect(audioCancelCount == 1)
            try expect(providerCancelled)
            try expect(targetCaptureCount == 0)
            try expect(deliveredTexts.isEmpty)
            try expect(finalRecordReady)
            try expect(recordCount == 1)
            try expect(finalRecord?.transcription == nil)
            try expect(finalRecord?.finalText == nil)
            try expect(finalRecord?.applicationName == nil)
            try expect(finalRecord?.providerMessage == nil)
            try expect(finalRecord?.transcriptionProvider == "local")
            try expect(finalRecord?.providerErrorCode == "recording.limit_reached")
            try expect((finalRecord?.durationMilliseconds ?? 0) >= 0)
            try expect(finalRecord?.stageDurationsMilliseconds["recording"] != nil)

            guard let finalRecord else {
                throw SpecFailure(message: "recording-limit record was not queued")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-recording-limit-history-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let durableHistory = SQLiteSessionHistory(
                fileURL: directory.appendingPathComponent("history.sqlite3")
            )
            await durableHistory.save(finalRecord)
            let persistedRecords = await durableHistory.allRecords()
            try expect(persistedRecords.map(\.sessionID) == [finalRecord.sessionID])
            try expect(persistedRecords.first?.transcription == nil)
            try expect(persistedRecords.first?.finalText == nil)
        }

        await runAsync(
            "release before the recording limit preserves one normal delivery",
            failures: &failures
        ) {
            let deadline = ControlledRecordingDeadline()
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: StreamingAudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(
                        id: UUID(),
                        applicationName: "TextEdit"
                    ))
                ),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )

            await sessions.send(.pressed)
            await deadline.waitUntilStarted()
            await sessions.send(.released)
            await deadline.waitUntilCancelled()

            let deliveredTexts = await delivery.deliveredTexts
            let finalRecordReady = await eventually(before: .milliseconds(300)) {
                await history.records.last?.outcome.isDelivered == true
            }
            let record = await history.records.last
            let deadlineCancellationCount = await deadline.cancellationCount
            try expect(
                deliveredTexts == ["流式结果"],
                "normal delivery texts were \(deliveredTexts)"
            )
            try expect(
                finalRecordReady && record?.outcome.isDelivered == true,
                "normal release outcome was \(String(describing: record?.outcome))"
            )
            try expect(
                deadlineCancellationCount == 1,
                "deadline cancelled \(deadlineCancellationCount) times"
            )
        }

        await runAsync(
            "late release and provider result cannot replace a limit failure",
            failures: &failures
        ) {
            let deadline = ControlledRecordingDeadline()
            let processor = LateCompletingStreamingProcessor()
            let target = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
            )
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: StreamingAudioCaptureFake(),
                targetCapture: target,
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await processor.waitUntilStarted()
            await deadline.fire()
            let limitPresentation = await terminal.value
            while await processor.cancellationCount == 0 { await Task.yield() }

            await sessions.send(.released)
            await processor.complete()
            try? await Task.sleep(for: .milliseconds(20))

            let record = await history.records.last
            let deliveredTexts = await delivery.deliveredTexts
            let captureCount = await target.captureCount
            try expect(
                limitPresentation?.activity.failure == .recordingLimitReached
            )
            try expect(record?.outcome.failure == .recordingLimitReached)
            try expect(deliveredTexts.isEmpty)
            try expect(captureCount == 0)
        }

        await runAsync(
            "user cancellation and provider failure invalidate recording deadlines",
            failures: &failures
        ) {
            let cancellationDeadline = ControlledRecordingDeadline()
            let cancellationHistory = SessionHistoryFake()
            let cancellationSessions = VoiceInputSessions(
                audioCapture: StreamingAudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: cancellationHistory,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await cancellationDeadline.sleep(for: duration)
                }
            )
            let cancelledTerminal = terminalPresentation(
                from: await cancellationSessions.observe()
            )

            await cancellationSessions.send(.pressed)
            await cancellationDeadline.waitUntilStarted()
            await cancellationSessions.send(.cancel)
            let cancelledPresentation = await cancelledTerminal.value
            await cancellationDeadline.waitUntilCancelled()
            await cancellationDeadline.fire()
            let cancellationRecordReady = await eventually(
                before: .milliseconds(300)
            ) {
                await cancellationHistory.records.count == 1
            }
            let cancellationRecords = await cancellationHistory.records

            try expect(cancelledPresentation?.activity.isCancelled == true)
            try expect(cancellationRecordReady)
            try expect(cancellationRecords.count == 1)
            try expect(
                cancellationRecords.first?.outcome.failure
                    != .recordingLimitReached
            )

            let providerDeadline = ControlledRecordingDeadline()
            let provider = ManuallyFailingStreamingProcessor()
            let providerHistory = SessionHistoryFake()
            let providerSessions = VoiceInputSessions(
                audioCapture: StreamingAudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: provider,
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: providerHistory,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await providerDeadline.sleep(for: duration)
                }
            )
            let providerTerminal = terminalPresentation(
                from: await providerSessions.observe()
            )

            await providerSessions.send(.pressed)
            await providerDeadline.waitUntilStarted()
            await provider.waitUntilStarted()
            await provider.fail()
            let providerPresentation = await providerTerminal.value
            await providerDeadline.waitUntilCancelled()
            await providerDeadline.fire()
            let providerRecordReady = await eventually(before: .milliseconds(300)) {
                await providerHistory.records.count == 1
            }
            let providerRecords = await providerHistory.records

            try expect(
                providerPresentation?.activity.failure
                    == .providerAuthenticationFailed
            )
            try expect(providerRecordReady)
            try expect(providerRecords.count == 1)
            try expect(
                providerRecords.first?.outcome.failure
                    == .providerAuthenticationFailed
            )
        }

        await runAsync(
            "a cancelled old deadline cannot affect a newer recording",
            failures: &failures
        ) {
            let deadline = StubbornRecordingDeadline()
            let audio = StreamingAudioCaptureFake()
            let target = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
            )
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: target,
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )

            await sessions.send(.pressed)
            await deadline.waitUntilRequestCount(1)
            await sessions.send(.released)
            let firstRecordReady = await eventually(before: .milliseconds(300)) {
                await history.records.count == 1
            }
            try expect(firstRecordReady, "first session did not finish normally")

            await sessions.send(.pressed)
            await deadline.waitUntilRequestCount(2)
            let secondTerminal = terminalPresentation(from: await sessions.observe())
            await deadline.fire(requestID: 0)
            for _ in 0..<20 { await Task.yield() }

            let cancelCountBeforeCurrentDeadline = await audio.cancelCount
            let captureCountBeforeCurrentDeadline = await target.captureCount
            let recordsBeforeCurrentDeadline = await history.records
            try expect(
                cancelCountBeforeCurrentDeadline == 0,
                "stale deadline cancelled audio \(cancelCountBeforeCurrentDeadline) times"
            )
            try expect(
                captureCountBeforeCurrentDeadline == 1,
                "stale deadline changed target captures to \(captureCountBeforeCurrentDeadline)"
            )
            try expect(
                recordsBeforeCurrentDeadline.count == 2,
                "stale deadline changed history count to \(recordsBeforeCurrentDeadline.count)"
            )
            try expect(
                recordsBeforeCurrentDeadline.last?.outcome.isRecording == true,
                "stale deadline replaced the newer Recording outcome"
            )

            await deadline.fire(requestID: 1)
            let secondPresentation = await secondTerminal.value
            let secondRecordReady = await eventually(before: .milliseconds(300)) {
                await history.records.count == 2
            }
            let finalRecords = await history.records
            try expect(
                secondPresentation?.activity.failure == .recordingLimitReached,
                "current deadline produced \(String(describing: secondPresentation?.activity))"
            )
            try expect(secondRecordReady, "current deadline did not queue history")
            try expect(
                finalRecords.count == 2,
                "current deadline produced \(finalRecords.count) total records"
            )
            try expect(
                finalRecords.last?.outcome.failure == .recordingLimitReached,
                "current deadline history was \(String(describing: finalRecords.last?.outcome))"
            )
        }

        await runAsync(
            "shutdown does not wait for a cancelled provider after the limit",
            failures: &failures
        ) {
            let deadline = ControlledRecordingDeadline()
            let provider = LateCompletingStreamingProcessor()
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: StreamingAudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: provider,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            let shutdownCompletion = CompletionFlag()

            await sessions.send(.pressed)
            await provider.waitUntilStarted()
            await deadline.waitUntilStarted()
            await deadline.fire()
            let limitPresentation = await terminal.value
            let recordReady = await eventually(before: .milliseconds(300)) {
                await history.records.last?.outcome.failure
                    == .recordingLimitReached
            }

            let shutdown = Task {
                await sessions.shutdown()
                await shutdownCompletion.markComplete()
            }
            let shutdownFinished = await eventually(before: .milliseconds(300)) {
                await shutdownCompletion.isComplete
            }
            if !shutdownFinished {
                await provider.complete()
            }
            await shutdown.value
            await provider.complete()
            for _ in 0..<20 { await Task.yield() }

            let records = await history.records
            let deliveredTexts = await delivery.deliveredTexts
            try expect(
                limitPresentation?.activity.failure == .recordingLimitReached
            )
            try expect(recordReady)
            try expect(
                shutdownFinished,
                "shutdown waited for a provider that ignored cancellation"
            )
            try expect(records.count == 1)
            try expect(records.first?.outcome.failure == .recordingLimitReached)
            try expect(deliveredTexts.isEmpty)
        }

        await runAsync(
            "deadline termination resets the global tap gesture for another session",
            failures: &failures
        ) {
            let deadline = ControlledRecordingDeadline()
            let audio = StreamingAudioCaptureFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            let terminal = terminalPresentation(from: await sessions.observe())

            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_050_000_000)
            await deadline.waitUntilRequestCount(1)
            await deadline.fire()
            _ = await terminal.value
            await Task.yield()

            dispatcher.send(.pressed, at: 2_000_000_000)
            dispatcher.send(.released, at: 2_050_000_000)
            let restarted = await eventually(before: .milliseconds(300)) {
                await audio.startCount == 2
            }

            try expect(restarted)
            await dispatcher.shutdown()
        }

        await runAsync(
            "shutdown and capture failure cancel the recording deadline",
            failures: &failures
        ) {
            let shutdownDeadline = ControlledRecordingDeadline()
            let shutdownAudio = AudioCaptureFake()
            let shutdownSessions = VoiceInputSessions(
                audioCapture: shutdownAudio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await shutdownDeadline.sleep(for: duration)
                }
            )

            await shutdownSessions.send(.pressed)
            await shutdownDeadline.waitUntilStarted()
            await shutdownSessions.shutdown()
            await shutdownDeadline.waitUntilCancelled()
            let shutdownCancelCount = await shutdownAudio.cancelCount
            try expect(shutdownCancelCount == 1)

            let failureDeadline = ControlledRecordingDeadline()
            let failureAudio = StreamingAudioCaptureFake()
            let failureSessions = VoiceInputSessions(
                audioCapture: failureAudio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await failureDeadline.sleep(for: duration)
                }
            )
            let failureTerminal = terminalPresentation(
                from: await failureSessions.observe()
            )

            await failureSessions.send(.pressed)
            await failureDeadline.waitUntilStarted()
            await failureAudio.emitFailure(.deviceConfigurationChanged)
            let failurePresentation = await failureTerminal.value
            await failureDeadline.waitUntilCancelled()
            let failureDeadlineCancellationCount =
                await failureDeadline.cancellationCount

            try expect(failurePresentation?.activity.failure == .audioDeviceChanged)
            try expect(failureDeadlineCancellationCount == 1)
        }

        await runAsync(
            "shutdown awaits recording-limit cleanup and durable history queueing",
            failures: &failures
        ) {
            let deadline = ControlledRecordingDeadline()
            let audio = BlockingCancelAudioCapture()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )
            let shutdownCompletion = CompletionFlag()

            await sessions.send(.pressed)
            await deadline.waitUntilStarted()
            await deadline.fire()
            await audio.waitUntilCancelStarted()
            let shutdown = Task {
                await sessions.shutdown()
                await shutdownCompletion.markComplete()
            }
            for _ in 0..<20 { await Task.yield() }
            let completedBeforeCancelFinished = await shutdownCompletion.isComplete
            try expect(!completedBeforeCancelFinished)

            await audio.finishCancel()
            await shutdown.value
            let records = await history.records
            let completedAfterCancelFinished = await shutdownCompletion.isComplete
            try expect(completedAfterCancelFinished)
            try expect(records.count == 1)
            try expect(records.first?.outcome.failure == .recordingLimitReached)
        }

        await runAsync(
            "shutdown awaits provider-failure cleanup and durable history queueing",
            failures: &failures
        ) {
            let deadline = ControlledRecordingDeadline()
            let audio = BlockingCancelAudioCapture()
            let provider = ManuallyFailingStreamingProcessor()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: provider,
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                sleepUntilRecordingLimit: { duration in
                    try await deadline.sleep(for: duration)
                }
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            let shutdownCompletion = CompletionFlag()

            await sessions.send(.pressed)
            await deadline.waitUntilStarted()
            await provider.waitUntilStarted()
            await provider.fail()
            let providerFailure = await terminal.value
            await audio.waitUntilCancelStarted()
            let shutdown = Task {
                await sessions.shutdown()
                await shutdownCompletion.markComplete()
            }
            for _ in 0..<20 { await Task.yield() }
            let completedBeforeCancelFinished = await shutdownCompletion.isComplete
            try expect(!completedBeforeCancelFinished)

            await audio.finishCancel()
            await shutdown.value
            let completedAfterCancelFinished = await shutdownCompletion.isComplete
            let records = await history.records
            try expect(completedAfterCancelFinished)
            try expect(
                providerFailure?.activity.failure
                    == .providerAuthenticationFailed
            )
            try expect(records.count == 1)
            try expect(
                records.first?.outcome.failure
                    == .providerAuthenticationFailed
            )
        }

        await runAsync(
            "voice shutdown completes through a live delivery with no restore work",
            failures: &failures
        ) {
            let targets = AccessibilityInputTargets(
                system: LifecycleAccessibilityTargetSystem(
                    live: LiveAccessibilityTargetSystem()
                )
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

            let completed = await eventually(before: .milliseconds(300)) {
                await completion.isComplete
            }
            await shutdown.value

            try expect(
                completed,
                "live delivery shutdown waited without restore work"
            )
        }

        await runAsync(
            "voice shutdown waits for the full automatic clipboard restore",
            failures: &failures
        ) {
            let originalItems = [
                [
                    "public.utf8-plain-text": Data("original".utf8),
                    "public.rtf": Data([1, 2, 3]),
                ],
                ["public.png": Data([4, 5, 6])],
            ]
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let sleeper = ControlledPasteboardRestoreSleep()
            let pastePosts = LockedCounter()
            let liveSystem = LiveAccessibilityTargetSystem(
                isSecureInputEnabled: { false },
                frontmostProcessIdentifier: { 42 },
                canPostEvents: { true },
                preparePasteboardTransaction: { text in
                    await PasteboardDeliveryTransaction.prepare(
                        text: text,
                        pasteboard: pasteboard.access,
                        sleepBeforeRestore: { duration in
                            try await sleeper.sleep(for: duration)
                        },
                        conditionalRestoreDidFinish: {
                            await sleeper.markRestoreCompleted()
                        }
                    )
                },
                focusedTargetState: { _, _ in .success(true) },
                postPasteCommand: {
                    pastePosts.increment()
                    return true
                }
            )
            let targets = AccessibilityInputTargets(
                system: LifecycleAccessibilityTargetSystem(live: liveSystem)
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: targets,
                transcriber: SpeechTranscriberFake(text: "hello"),
                delivery: targets,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            await sessions.send(.released)
            await sleeper.waitUntilStarted()
            let requestedDuration = await sleeper.requestedDuration
            let shutdownCompletion = CompletionFlag()
            let shutdown = Task {
                await sessions.shutdown()
                await shutdownCompletion.markComplete()
            }
            for _ in 0..<20 { await Task.yield() }
            let completedBeforeRestore = await shutdownCompletion.isComplete

            try expect(requestedDuration == .milliseconds(500))
            try expect(!completedBeforeRestore)
            try expect(pastePosts.value == 1)
            try expect(
                pasteboard.items
                    == [["public.utf8-plain-text": Data("hello".utf8)]]
            )

            await sleeper.resume()
            await shutdown.value
            let completedAfterRestore = await shutdownCompletion.isComplete
            try expect(completedAfterRestore)
            try expect(pasteboard.items == originalItems)
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
            try expect(record?.applicationName == nil)
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
    }
}
