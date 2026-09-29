import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum RecordingLimitSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "manual clock publishes sleep requests only when they can be resumed",
            failures: &failures
        ) {
            for iteration in 1...10_000 {
                let clock = ManualVoiceInputClock()
                let sleeper = Task.detached {
                    try await clock.sleep(for: .seconds(600))
                }
                defer { sleeper.cancel() }

                try await clock.waitUntilSleepRequestCount(1)
                try expect(
                    clock.resume(sleepRequest: 0),
                    "sleep request was visible before registration on iteration \(iteration)"
                )
                try await sleeper.value
            }
        }

        await runAsync(
            "manual clock reports missing sleep requests instead of waiting forever",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            do {
                try await clock.waitUntilSleepRequestCount(1, before: .milliseconds(10))
            } catch let failure as SpecFailure {
                try expect(failure.message == "expected 1 registered clock sleeps, observed 0")
                return
            }
            throw SpecFailure(message: "a missing sleep request was reported as ready")
        }

        await runAsync(
            "recording limit ends recording like a release and delivers the captured speech",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let audio = StreamingAudioCaptureFake()
            let processor = StreamingVoiceTextProcessorFake()
            let target = ReleaseTimeTargetCaptureFake(applicationName: "TextEdit")
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
                clock: clock
            )
            let triggerTerminations = await sessions.observeTriggerTerminations()
            let triggerTermination = Task {
                var iterator = triggerTerminations.makeAsyncIterator()
                return await iterator.next()
            }

            await sessions.send(.pressed, triggerSequence: 41)
            try await clock.waitUntilSleepRequestCount(1)
            let requestedDuration = clock.sleepRequests.last
            try expect(
                requestedDuration == .seconds(600),
                "armed a \(String(describing: requestedDuration)) deadline"
            )

            clock.advance(by: .seconds(600))
            let captureStarted = await eventually(before: .seconds(2)) {
                await target.captureCallCount == 1
            }
            try expect(captureStarted, "the limit did not capture the Input Target")
            // Target capture is held open, so the presentation published when
            // the limit ended recording is still the current one.
            var limitStream = await sessions.observe().makeAsyncIterator()
            let limitPresentation = await limitStream.next()
            guard case .processing(_, .capturingTarget, _) = limitPresentation?.activity else {
                throw SpecFailure(
                    message:
                        "the limit published \(String(describing: limitPresentation?.activity))"
                )
            }
            try expect(
                limitPresentation?.notice == .recordingLimitReached,
                "the limit notice was \(String(describing: limitPresentation?.notice))"
            )

            let terminal = terminalPresentation(from: await sessions.observe())
            await target.resume()
            let presentation = await terminal.value
            let terminatedSequence = await triggerTermination.value
            let finalRecordReady = await eventually(before: .seconds(2)) {
                await history.records.last?.outcome.isDelivered == true
            }
            let records = await history.records
            let audioStopCount = await audio.stopCount
            let audioCancelCount = await audio.cancelCount
            let providerCancelCount = await processor.cancellationCount
            let targetCaptureCount = await target.captureCallCount
            let deliveredTexts = await delivery.deliveredTexts

            try expect(
                presentation?.activity.isDelivered == true,
                "the limit ended in \(String(describing: presentation?.activity))"
            )
            try expect(presentation?.notice == nil, "the limit notice outlived processing")
            try expect(
                terminatedSequence == 41, "terminated \(String(describing: terminatedSequence))")
            try expect(audioStopCount == 1, "audio stopped \(audioStopCount) times")
            try expect(audioCancelCount == 0, "audio was cancelled \(audioCancelCount) times")
            try expect(providerCancelCount == 0, "the provider was cancelled")
            try expect(
                targetCaptureCount == 1, "the target was captured \(targetCaptureCount) times")
            try expect(deliveredTexts == ["流式结果"], "delivered \(deliveredTexts)")
            try expect(finalRecordReady, "no delivered record")
            try expect(records.count == 1, "\(records.count) records")
            try expect(
                records.last?.durationMilliseconds == 600_000,
                "record duration \(String(describing: records.last?.durationMilliseconds))"
            )
        }

        await runAsync(
            "release before the recording limit preserves one normal delivery",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: StreamingAudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(
                        .init(
                            id: UUID(),
                            applicationName: "TextEdit"
                        ))
                ),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )

            await sessions.send(.pressed)
            try await clock.waitUntilSleepRequestCount(1)
            await sessions.send(.released)
            try await clock.waitUntilCancelledSleepCount(1)

            let deliveredTexts = await delivery.deliveredTexts
            let finalRecordReady = await eventually(before: .seconds(2)) {
                await history.records.last?.outcome.isDelivered == true
            }
            let record = await history.records.last
            let deadlineCancellationCount = clock.cancelledSleepCount
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
            "a release after the limit cannot finish the session a second time",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let audio = StreamingAudioCaptureFake()
            let processor = LateCompletingStreamingProcessor()
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
                clock: clock
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await processor.waitUntilStarted()
            // Streaming can begin before the deadline is armed; firing an
            // unarmed deadline is a no-op and the case would wait forever.
            try await clock.waitUntilSleepRequestCount(1)
            clock.advance(by: .seconds(600))
            let captured = await eventually(before: .seconds(2)) {
                await target.captureCount == 1
            }

            // The shortcut is still held when the limit ends recording; its
            // later release belongs to a session that is no longer recording.
            // A release waits for the finishing session, so it runs alongside
            // the provider result that lets that session finish.
            let release = Task { await sessions.send(.released) }
            await processor.complete()
            let presentation = await terminal.value
            await release.value
            await sessions.shutdown()

            let records = await history.records
            let deliveredTexts = await delivery.deliveredTexts
            let captureCount = await target.captureCount
            let stopCount = await audio.stopCount
            let cancellationCount = await processor.cancellationCount
            try expect(captured, "the limit did not capture the Input Target")
            try expect(presentation?.activity.isDelivered == true)
            try expect(deliveredTexts == ["late provider text"], "delivered \(deliveredTexts)")
            try expect(captureCount == 1, "the target was captured \(captureCount) times")
            try expect(stopCount == 1, "audio stopped \(stopCount) times")
            try expect(cancellationCount == 0, "the provider was cancelled")
            try expect(records.count == 1)
            try expect(records.last?.outcome.isDelivered == true)
        }

        await runAsync(
            "user cancellation and provider failure invalidate recording deadlines",
            failures: &failures
        ) {
            let cancellationClock = ManualVoiceInputClock()
            let cancellationHistory = SessionHistoryFake()
            let cancellationSessions = VoiceInputSessions(
                audioCapture: StreamingAudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: cancellationHistory,
                maximumRecordingDuration: .seconds(600),
                clock: cancellationClock
            )
            let cancelledTerminal = terminalPresentation(
                from: await cancellationSessions.observe()
            )

            await cancellationSessions.send(.pressed)
            try await cancellationClock.waitUntilSleepRequestCount(1)
            await cancellationSessions.send(.cancel)
            let cancelledPresentation = await cancelledTerminal.value
            try await cancellationClock.waitUntilCancelledSleepCount(1)
            cancellationClock.advance(by: .seconds(600))
            let cancellationRecordReady = await eventually(
                before: .seconds(5)
            ) {
                await cancellationHistory.records.last?.outcome.isCancelled == true
            }
            let cancellationRecords = await cancellationHistory.records

            try expect(
                cancelledPresentation?.activity.isCancelled == true,
                "cancellation did not settle as cancelled: \(String(describing: cancelledPresentation?.activity))"
            )
            try expect(
                cancellationRecordReady,
                "the cancelled session never reached a cancelled history outcome"
            )
            try expect(
                cancellationRecords.count == 1,
                "\(cancellationRecords.count) cancelled-session records reached history"
            )
            try expect(
                cancellationRecords.first?.outcome.failure
                    != .recordingLimitReached,
                "a cancelled session was recorded as hitting the recording limit"
            )

            let providerClock = ManualVoiceInputClock()
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
                clock: providerClock
            )
            let providerTerminal = terminalPresentation(
                from: await providerSessions.observe()
            )

            await providerSessions.send(.pressed)
            try await providerClock.waitUntilSleepRequestCount(1)
            await provider.waitUntilStarted()
            await provider.fail()
            let providerPresentation = await providerTerminal.value
            try await providerClock.waitUntilCancelledSleepCount(1)
            providerClock.advance(by: .seconds(600))
            let providerRecordReady = await eventually(before: .seconds(5)) {
                await providerHistory.records.last?.outcome.failure == .providerAuthenticationFailed
            }
            let providerRecords = await providerHistory.records

            try expect(
                providerPresentation?.activity.failure
                    == .providerAuthenticationFailed,
                "provider failure did not settle as authentication failure: \(String(describing: providerPresentation?.activity))"
            )
            try expect(
                providerRecordReady,
                "the failed session never reached an authentication-failure history outcome"
            )
            try expect(
                providerRecords.count == 1,
                "\(providerRecords.count) failed-session records reached history"
            )
            try expect(
                providerRecords.first?.outcome.failure
                    == .providerAuthenticationFailed,
                "the failed session was recorded with the wrong outcome: \(String(describing: providerRecords.first?.outcome))"
            )
        }

        await runAsync(
            "a cancelled old deadline cannot affect a newer recording",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock(honoursCancellation: false)
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
                clock: clock
            )

            await sessions.send(.pressed)
            try await clock.waitUntilSleepRequestCount(1)
            await sessions.send(.released)
            let firstRecordReady = await eventually(before: .seconds(2)) {
                await history.records.count == 1
            }
            try expect(firstRecordReady, "first session did not finish normally")

            await sessions.send(.pressed)
            try await clock.waitUntilSleepRequestCount(2)
            let secondTerminal = terminalPresentation(from: await sessions.observe())

            // The first session's deadline was cancelled, but the stubborn
            // clock kept it suspended. Wake it ten seconds into the second
            // recording: a stale wake-up that wrongly ended that recording
            // would leave a ten-second record instead of the ten-minute one
            // the real deadline produces below.
            clock.advance(by: .seconds(10))
            let staleResumed = clock.resume(sleepRequest: 0)
            try expect(staleResumed, "the cancelled deadline was not left suspended")

            clock.advance(by: .seconds(590))
            let secondPresentation = await secondTerminal.value
            let secondRecordReady = await eventually(before: .seconds(2)) {
                let records = await history.records
                return records.count == 2 && records.last?.outcome.isDelivered == true
            }
            let finalRecords = await history.records
            let cancelCount = await audio.cancelCount
            let captureCount = await target.captureCount
            try expect(
                secondPresentation?.activity.isDelivered == true,
                "current deadline produced \(String(describing: secondPresentation?.activity))"
            )
            try expect(secondRecordReady, "current deadline did not queue history")
            try expect(
                finalRecords.count == 2,
                "current deadline produced \(finalRecords.count) total records"
            )
            try expect(
                finalRecords.last?.durationMilliseconds == 600_000,
                "stale deadline ended the recording after \(String(describing: finalRecords.last?.durationMilliseconds)) ms"
            )
            try expect(cancelCount == 0, "audio was cancelled \(cancelCount) times")
            try expect(captureCount == 2, "target captures changed to \(captureCount)")
        }

        await runAsync(
            "shutdown after the limit cancels recognition and discards its late result",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let audio = StreamingAudioCaptureFake()
            let processor = LateCompletingStreamingProcessor()
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
                clock: clock
            )

            await sessions.send(.pressed)
            await processor.waitUntilStarted()
            try await clock.waitUntilSleepRequestCount(1)
            clock.advance(by: .seconds(600))
            let captured = await eventually(before: .seconds(2)) {
                await target.captureCount == 1
            }

            let shutdown = Task { await sessions.shutdown() }
            let providerCancelled = await eventually(before: .seconds(2)) {
                await processor.cancellationCount == 1
            }
            await processor.complete()
            await shutdown.value

            let records = await history.records
            let deliveredTexts = await delivery.deliveredTexts
            try expect(captured, "the limit did not capture the Input Target")
            try expect(providerCancelled, "shutdown did not cancel recognition")
            try expect(records.count == 1, "\(records.count) records")
            try expect(
                records.first?.outcome.isCancelled == true,
                "shutdown after the limit recorded \(String(describing: records.first?.outcome))"
            )
            try expect(deliveredTexts.isEmpty, "delivered \(deliveredTexts)")
        }

        await runAsync(
            "deadline termination resets the global tap gesture for another session",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let audio = StreamingAudioCaptureFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            let terminal = terminalPresentation(from: await sessions.observe())

            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_050_000_000)
            try await clock.waitUntilSleepRequestCount(1)
            clock.advance(by: .seconds(600))
            _ = await terminal.value
            await Task.yield()

            dispatcher.send(.pressed, at: 2_000_000_000)
            dispatcher.send(.released, at: 2_050_000_000)
            let restarted = await eventually(before: .seconds(2)) {
                await audio.startCount == 2
            }

            try expect(restarted)
            await dispatcher.shutdown()
        }

        await runAsync(
            "shutdown and capture failure cancel the recording deadline",
            failures: &failures
        ) {
            let shutdownClock = ManualVoiceInputClock()
            let shutdownAudio = AudioCaptureFake()
            let shutdownSessions = VoiceInputSessions(
                audioCapture: shutdownAudio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                clock: shutdownClock
            )

            await shutdownSessions.send(.pressed)
            try await shutdownClock.waitUntilSleepRequestCount(1)
            await shutdownSessions.shutdown()
            try await shutdownClock.waitUntilCancelledSleepCount(1)
            let shutdownCancelCount = await shutdownAudio.cancelCount
            try expect(shutdownCancelCount == 1)

            let failureClock = ManualVoiceInputClock()
            let failureAudio = StreamingAudioCaptureFake()
            let failureSessions = VoiceInputSessions(
                audioCapture: failureAudio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                clock: failureClock
            )
            let failureTerminal = terminalPresentation(
                from: await failureSessions.observe()
            )

            await failureSessions.send(.pressed)
            try await failureClock.waitUntilSleepRequestCount(1)
            await failureAudio.emitFailure(.deviceConfigurationChanged)
            let failurePresentation = await failureTerminal.value
            try await failureClock.waitUntilCancelledSleepCount(1)
            let failureDeadlineCancellationCount =
                failureClock.cancelledSleepCount

            try expect(failurePresentation?.activity.failure == .audioDeviceChanged)
            try expect(failureDeadlineCancellationCount == 1)
        }

        await runAsync(
            "the recording limit finishes a complete-recording session with the captured audio",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let audio = AudioCaptureFake()
            let transcriber = SpeechTranscriberFake(text: "上限内的内容")
            let target = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
            )
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: target,
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            try await clock.waitUntilSleepRequestCount(1)
            clock.advance(by: .seconds(600))
            let presentation = await terminal.value
            await sessions.shutdown()

            let records = await history.records
            let deliveredTexts = await delivery.deliveredTexts
            let transcriberCalls = await transcriber.callCount
            let cancelCount = await audio.cancelCount
            try expect(presentation?.activity.isDelivered == true)
            try expect(deliveredTexts == ["上限内的内容"], "delivered \(deliveredTexts)")
            try expect(transcriberCalls == 1)
            try expect(cancelCount == 0, "audio was cancelled \(cancelCount) times")
            try expect(records.count == 1)
            try expect(records.first?.outcome.isDelivered == true)
        }

        await runAsync(
            "the recording limit ends just inside the selected provider's audio bound",
            failures: &failures
        ) {
            try expect(VoiceInputSessions.recordingLimit(for: .doubao) == .seconds(600))
            try expect(VoiceInputSessions.recordingLimit(for: .openAI) == .seconds(298))
            try expect(VoiceInputSessions.recordingLimit(for: .qwen) == .seconds(178))
            try expect(
                VoiceInputSessions.recordingLimit(for: .qwen, standard: .seconds(60))
                    == .seconds(60),
                "a shorter standard limit must still win"
            )

            let clock = ManualVoiceInputClock()
            let dictionary = PersonalDictionarySnapshot(entries: [])
            let processor = StreamingVoiceTextProcessorFake(
                snapshot: VoiceTextProcessingSnapshot(
                    dictionary: dictionary,
                    dictionaryContext: DictionaryRequestContextBuilder.makeContext(
                        from: dictionary
                    ),
                    refinementMode: .defaultSmooth,
                    recognitionProvider: SpeechRecognitionProfile(provider: .qwen)
                )
            )
            let sessions = VoiceInputSessions(
                audioCapture: StreamingAudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: processor,
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )

            await sessions.send(.pressed)
            try await clock.waitUntilSleepRequestCount(1)
            let requested = clock.sleepRequests.last
            await sessions.shutdown()
            try expect(
                requested == .seconds(178),
                "a Qwen session armed a \(String(describing: requested)) deadline"
            )
        }

        await runAsync(
            "recording telemetry reports the time left before the limit",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let audio = TelemetryAudioCaptureFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )
            let stream = await sessions.observe()
            let firstTelemetry = Task { () -> RecordingTelemetry? in
                for await presentation in stream {
                    if let telemetry = presentation.recordingTelemetry { return telemetry }
                }
                return nil
            }

            await sessions.send(.pressed)
            try await clock.waitUntilSleepRequestCount(1)
            clock.advance(by: .seconds(585))
            await audio.emit(RecordingTelemetry(elapsedMilliseconds: 585_000, peakPower: -20))
            let telemetry = await firstTelemetry.value
            await sessions.shutdown()

            try expect(telemetry?.elapsedMilliseconds == 585_000)
            try expect(telemetry?.peakPower == -20)
            try expect(
                telemetry?.remainingMilliseconds == 15_000,
                "telemetry reported \(String(describing: telemetry?.remainingMilliseconds)) ms left"
            )
        }

        await runAsync(
            "shutdown awaits provider-failure cleanup and durable history queueing",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
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
                clock: clock
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            let shutdownCompletion = CompletionFlag()

            await sessions.send(.pressed)
            try await clock.waitUntilSleepRequestCount(1)
            await provider.waitUntilStarted()
            await provider.fail()
            let providerFailure = await terminal.value
            await audio.waitUntilCancelStarted()
            let shutdown = Task {
                await sessions.shutdown()
                await shutdownCompletion.markComplete()
            }
            await settle()
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

            let completed = await eventually(before: .seconds(2)) {
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
            await settle()
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

        await runAsync(
            "pending-copy trigger rejection resets the next shortcut gesture", failures: &failures
        ) {
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
            await settle()
            await sessions.send(.dismissResult)

            dispatcher.send(.pressed, at: 4_000_000_000)
            let restarted = await eventually(before: .seconds(2)) {
                await audio.startCount == 2
            }
            try expect(
                restarted,
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

        await runAsync(
            "trigger dispatcher shutdown cancels in-flight processing before waiting",
            failures: &failures
        ) {
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

        await runAsync(
            "trigger dispatcher shutdown flushes queued history writes", failures: &failures
        ) {
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
            await settle()
            let completedPrematurely = await completion.isComplete
            try expect(completedPrematurely == false)

            await history.unblock()
            await shutdown.value
            let completedAfterFlush = await completion.isComplete
            let saveCallCount = await history.saveCallCount
            try expect(completedAfterFlush)
            try expect(saveCallCount >= 2)
        }

        await runAsync(
            "shutdown flushes a history write enqueued while an earlier one is still pending",
            failures: &failures
        ) {
            let history = BlockingSessionHistoryFake()
            let transcriber = SpeechTranscriberFake(
                text: "unused",
                delaysResponse: true
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: transcriber,
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )

            // Session one completes while every history write stays blocked.
            await sessions.send(.pressed)
            let firstRelease = Task { await sessions.send(.released) }
            while await transcriber.callCount == 0 { await Task.yield() }
            await transcriber.resume()
            await firstRelease.value
            await sessions.send(.dismissResult)

            // Session two is still with the provider when shutdown begins.
            await sessions.send(.pressed)
            let secondRelease = Task { await sessions.send(.released) }
            while await transcriber.callCount < 2 { await Task.yield() }

            let completion = CompletionFlag()
            let shutdown = Task {
                await sessions.shutdown()
                await completion.markComplete()
            }
            // Let shutdown cancel the provider request before releasing it, so
            // session two settles as cancelled rather than racing to deliver.
            let providerCancelled = await eventually(before: .seconds(2)) {
                await transcriber.cancellationCount == 1
            }
            try expect(providerCancelled, "shutdown did not cancel the in-flight provider request")
            await transcriber.resume()
            await secondRelease.value
            await settle()
            let completedBeforeFlush = await completion.isComplete

            // Shutdown's cancellation of session two queued one more write
            // behind the blocked ones; it must reach storage before shutdown
            // returns. Unblocking resumes the blocked writers in no particular
            // order, so the records are checked by content rather than position.
            await history.unblock()
            await shutdown.value
            let records = await history.records
            try expect(!completedBeforeFlush, "shutdown returned while history writes were pending")
            try expect(
                records.count == 2,
                "\(records.count) sessions reached history before shutdown returned"
            )
            let outcomes = records.map(\.outcome)
            try expect(
                outcomes.contains { $0.isCancelled },
                "the write queued during shutdown did not reach history: \(outcomes)"
            )
            try expect(
                outcomes.contains { !$0.isCancelled },
                "the delivered session lost its record: \(outcomes)"
            )
        }

        await runAsync(
            "queued trigger cancel preempts an in-flight provider request", failures: &failures
        ) {
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

        await runAsync(
            "trigger cancellation fence cannot cancel a later session", failures: &failures
        ) {
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

/// Audio capture that reports level telemetry on demand. Telemetry emitted
/// before the session subscribes is held until it does.
private actor TelemetryAudioCaptureFake: AudioCapturing, AudioCaptureTelemetryProviding {
    private var continuation: AsyncStream<RecordingTelemetry>.Continuation?
    private var pending: [RecordingTelemetry] = []

    nonisolated func prepareStart() -> AudioCaptureStart {
        AudioCaptureStart(start: {}, cancel: {})
    }

    func start() async throws {}

    func stop() async throws -> CapturedAudio { specAudio }

    func cancel() async {}

    func observeTelemetry() -> AsyncStream<RecordingTelemetry> {
        let (stream, continuation) = AsyncStream<RecordingTelemetry>.makeStream()
        self.continuation = continuation
        for telemetry in pending { continuation.yield(telemetry) }
        pending = []
        return stream
    }

    func emit(_ telemetry: RecordingTelemetry) {
        if let continuation {
            continuation.yield(telemetry)
        } else {
            pending.append(telemetry)
        }
    }
}
