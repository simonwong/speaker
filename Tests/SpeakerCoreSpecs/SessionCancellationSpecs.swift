import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum SessionCancellationSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("cancel wins over a late recorder stop failure and discards target", failures: &failures) {
            let audio = DelayedFailingStopAudioCapture()
            let target = DiscardingTargetCaptureFake(
                snapshot: .init(id: UUID(), applicationName: "TextEdit")
            )
            let history = BlockingSessionHistoryFake()
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
            await history.unblock()

            let cancellationPersisted = await eventually(before: .seconds(1)) {
                await history.records.last?.outcome.isCancelled == true
            }

            let discardedCount = await target.discardedCount
            try expect(
                cancellationPersisted,
                "expected User Cancellation to reach history after persistence resumed"
            )
            try expect(
                discardedCount == 1,
                "expected one discarded target, got \(discardedCount)"
            )
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
            try expect(record?.applicationName == nil)
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
                    refinementMode: .conciseCleanup()
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
    }
}
