import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum MicrophoneSessionSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "microphone choice is frozen by the physical press before dispatch and changes apply next time",
            failures: &failures
        ) {
            let probe = MicrophoneCapturePlanProbe()
            let audio = AudioCaptureFake(prepareStart: { probe.prepareStart() })
            let sessions = makeSessions(audio: audio)
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            dispatcher.send(.pressed, at: 1_000_000_000)
            let preparedInline = probe.preparedCount
            probe.select("second-input")
            let started = await eventually(before: .seconds(2)) {
                probe.startedChoices == ["system-input"]
            }
            await sessions.send(.cancel)
            dispatcher.send(.cancel, at: 1_500_000_000)
            dispatcher.send(.pressed, at: 2_000_000_000)
            let restarted = await eventually(before: .seconds(2)) {
                probe.startedChoices == ["system-input", "second-input"]
            }
            await dispatcher.shutdown()
            try expect(
                preparedInline == 1, "the microphone was not snapshotted in the physical callback")
            try expect(started, "an async dispatch used the later microphone choice")
            try expect(restarted, "the following press did not use the new microphone choice")
        }

        await runAsync(
            "microphone choice is frozen before a semantic press awaits its text configuration",
            failures: &failures
        ) {
            let probe = MicrophoneCapturePlanProbe()
            let gate = MicrophoneSpecGate()
            let audio = AudioCaptureFake(prepareStart: { probe.prepareStart() })
            let processor = VoiceTextProcessorFake(result: unusedResult) {
                await gate.wait()
                return .empty
            }
            let sessions = makeSessions(audio: audio, processor: processor)
            let press = Task { await sessions.send(.pressed) }
            let waiting = await eventually(before: .seconds(2)) { await gate.entered }
            let preparedBeforeConfiguration = probe.preparedCount
            probe.select("later-input")
            await gate.resume()
            await press.value
            let choices = probe.startedChoices
            await sessions.shutdown()
            try expect(waiting)
            try expect(preparedBeforeConfiguration == 1)
            try expect(
                choices == ["system-input"], "configuration suspension changed the microphone")
        }

        await runAsync(
            "microphone choice remains press-scoped after an asynchronous failure clears a tap gesture",
            failures: &failures
        ) {
            let probe = MicrophoneCapturePlanProbe(firstStartError: .microphoneUnavailable)
            let audio = AudioCaptureFake(prepareStart: { probe.prepareStart() })
            let sessions = makeSessions(audio: audio)
            let presentations = await sessions.observe()
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            dispatcher.send(.pressed, at: 1_000_000_000)
            dispatcher.send(.released, at: 1_050_000_000)
            let terminal = await firstTerminalPresentation(from: presentations, before: .seconds(2))
            probe.select("reconnected-input")
            dispatcher.send(.pressed, at: 2_000_000_000)
            probe.select("later-input")
            let restarted = await eventually(before: .seconds(2)) {
                probe.startedChoices == ["system-input", "reconnected-input"]
            }
            await dispatcher.shutdown()
            try expect(terminal?.activity.failure == .microphoneUnavailable)
            try expect(restarted, "the recovered tap lost its original microphone snapshot")
        }

        await runAsync(
            "microphone startup cancellation discards its late result without processing or delivery",
            failures: &failures
        ) {
            let audio = AudioCaptureFake(delaysStart: true)
            let transcriber = SpeechTranscriberFake(text: "unused")
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let presentations = await sessions.observe()
            let press = Task { await sessions.send(.pressed) }
            let started = await eventually(before: .seconds(2)) { await audio.startCount == 1 }
            await sessions.send(.cancel)
            await audio.resumeStart()
            await press.value
            let terminal = await firstTerminalPresentation(from: presentations, before: .seconds(2))
            let active = await audio.isActive
            let processingCount = await transcriber.callCount
            let texts = await delivery.deliveredTexts
            await sessions.shutdown()
            try expect(started)
            try expect(terminal?.activity.isCancelled == true)
            try expect(!active, "a cancelled recorder became active when startup finished")
            try expect(processingCount == 0 && texts.isEmpty)
        }

        await runAsync(
            "microphone cancellation while awaiting audio chunks cannot start an old capture over a new session",
            failures: &failures
        ) {
            let audio = StreamingAudioCaptureFake(delaysFirstAudioChunks: true)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let oldPress = Task { await sessions.send(.pressed) }
            let waiting = await eventually(before: .seconds(2)) {
                await audio.audioChunksCount == 1
            }
            await sessions.send(.cancel)
            await sessions.send(.pressed)
            let startedBeforeOldResult = await audio.startCount
            await audio.resumeFirstAudioChunks()
            await oldPress.value
            let startedAfterOldResult = await audio.startCount
            let active = await audio.isActive
            await sessions.shutdown()
            try expect(waiting && startedBeforeOldResult == 1)
            try expect(
                startedAfterOldResult == 1,
                "a cancelled session started its recorder after audioChunks returned")
            try expect(active, "the late audio stream preparation displaced the new recorder")
        }

        await runAsync(
            "microphone startup cancellation cannot cancel a newer capture when an old start returns late",
            failures: &failures
        ) {
            let gate = MicrophoneSpecGate()
            let prepared = LockedCounter()
            let audio = AudioCaptureFake(prepareStart: {
                prepared.increment()
                let isFirst = prepared.value == 1
                return AudioCaptureStart(
                    start: {
                        if isFirst {
                            await gate.wait()
                            throw CancellationError()
                        }
                    },
                    cancel: {}
                )
            })
            let sessions = makeSessions(audio: audio)
            let oldPress = Task { await sessions.send(.pressed) }
            let waiting = await eventually(before: .seconds(2)) { await gate.entered }
            await sessions.send(.cancel)
            await sessions.send(.pressed)
            let activeBeforeOldResult = await audio.isActive
            await gate.resume()
            await oldPress.value
            let activeAfterOldResult = await audio.isActive
            await sessions.shutdown()
            try expect(waiting && activeBeforeOldResult)
            try expect(activeAfterOldResult, "the old startup cleanup cancelled the newer capture")
        }

        await runAsync(
            "microphone startup problems retain stable local codes without hardware identity",
            failures: &failures
        ) {
            let errors: [(AudioCaptureError, String)] = [
                (.microphoneUnavailable, "audio.microphone_unavailable"),
                (.microphoneSelectionFailed, "audio.microphone_selection_failed"),
            ]
            for (error, code) in errors {
                let history = SessionHistoryFake()
                let transcriber = SpeechTranscriberFake(text: "unused")
                let sessions = VoiceInputSessions(
                    audioCapture: AudioCaptureFake(prepareStart: {
                        AudioCaptureStart(start: { throw error }, cancel: {})
                    }),
                    targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                    transcriber: transcriber,
                    delivery: TextDeliveryFake(result: .delivered),
                    clipboard: ClipboardFake(),
                    history: history
                )
                let presentations = await sessions.observe()
                await sessions.send(.pressed)
                let terminal = await firstTerminalPresentation(
                    from: presentations, before: .seconds(2))
                await sessions.shutdown()
                let record = await history.records.last
                let processingCount = await transcriber.callCount
                try expect(terminal?.activity.failure == .microphoneUnavailable)
                try expect(record?.providerErrorCode == code)
                try expect(record?.transcriptionProvider == "local")
                try expect(record?.providerMessage == nil && record?.applicationName == nil)
                try expect(record?.transcription == nil && record?.finalText == nil)
                try expect(processingCount == 0)
            }
        }
    }

    private static func makeSessions(
        audio: AudioCaptureFake,
        processor: (any VoiceTextProcessing)? = nil
    ) -> VoiceInputSessions {
        VoiceInputSessions(
            audioCapture: audio,
            targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
            textProcessor: processor ?? VoiceTextProcessorFake(result: unusedResult),
            delivery: TextDeliveryFake(result: .delivered),
            clipboard: ClipboardFake(),
            history: SessionHistoryFake()
        )
    }

    private static var unusedResult: VoiceTextProcessingResult {
        VoiceTextProcessingResult(
            doubaoText: "unused", normalizedText: "unused", deepSeekText: nil,
            finalText: "unused", doubaoRequestID: nil, deepSeekRequestID: nil,
            refinementStatus: .notRequested, refinementFailure: nil
        )
    }
}

private final class MicrophoneCapturePlanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var selectedChoice = "system-input"
    private var prepared = 0
    private var started: [String] = []
    private let firstStartError: AudioCaptureError?

    init(firstStartError: AudioCaptureError? = nil) {
        self.firstStartError = firstStartError
    }

    var preparedCount: Int { lock.withLock { prepared } }
    var startedChoices: [String] { lock.withLock { started } }

    func select(_ choice: String) {
        lock.withLock { selectedChoice = choice }
    }

    func prepareStart() -> AudioCaptureStart {
        let (choice, error) = lock.withLock {
            prepared += 1
            return (selectedChoice, prepared == 1 ? firstStartError : nil)
        }
        return AudioCaptureStart(
            start: { [self] in
                lock.withLock { started.append(choice) }
                if let error { throw error }
            },
            cancel: {}
        )
    }
}

private actor MicrophoneSpecGate {
    private(set) var entered = false
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !resumed else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
