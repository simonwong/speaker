import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum SkipRefinementSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "using the recognition result skips pending refinement and delivers it",
            failures: &failures
        ) {
            let fixture = makeFixture()
            let stream = await fixture.sessions.observe()

            await fixture.sessions.send(.pressed)
            let release = Task { await fixture.sessions.send(.released) }
            guard let id = await refiningSessionID(from: stream) else {
                throw SpecFailure(message: "refinement never became pending")
            }
            while await fixture.refiner.callCount == 0 { await Task.yield() }

            await fixture.sessions.useRecognitionResult(expectedSessionID: VoiceInputSessionID())
            let cancellationsAfterStaleAction = await fixture.refiner.cancellationCount
            try expect(
                cancellationsAfterStaleAction == 0,
                "another session's action must not skip this refinement"
            )

            await fixture.sessions.useRecognitionResult(expectedSessionID: id)
            let terminal = await firstTerminalPresentation(from: stream, before: .seconds(2))
            await release.value

            let deliveredTexts = await fixture.delivery.deliveredTexts
            let cancellationCount = await fixture.refiner.cancellationCount
            try expect(terminal?.activity.isDelivered == true)
            try expect(deliveredTexts == ["豆包已确认结果"])
            try expect(cancellationCount == 1)
            let recorded = await eventually(before: .seconds(1)) {
                await fixture.history.records.last?.outcome.isDelivered == true
            }
            try expect(recorded)
            let record = await fixture.history.records.last
            try expect(record?.refinementStatus == TextRefinementStatus.skipped.rawValue)
            try expect(record?.transcription == "豆包已确认结果")
            try expect(record?.finalText == "豆包已确认结果")
            try expect(record?.deepSeekText == nil)
        }

        await runAsync(
            "using the recognition result after cancellation delivers nothing",
            failures: &failures
        ) {
            let fixture = makeFixture()
            let stream = await fixture.sessions.observe()

            await fixture.sessions.send(.pressed)
            let release = Task { await fixture.sessions.send(.released) }
            guard let id = await refiningSessionID(from: stream) else {
                throw SpecFailure(message: "refinement never became pending")
            }
            await fixture.sessions.cancel(expectedSessionID: id)
            await fixture.sessions.useRecognitionResult(expectedSessionID: id)
            await release.value

            let deliveredTexts = await fixture.delivery.deliveredTexts
            try expect(deliveredTexts.isEmpty)
            let recorded = await eventually(before: .seconds(1)) {
                await fixture.history.records.last?.outcome.isCancelled == true
            }
            try expect(recorded)
            let transcription = await fixture.history.records.last?.transcription
            try expect(transcription == "豆包已确认结果")
        }
    }

    private struct Fixture {
        let sessions: VoiceInputSessions
        let refiner: CancellableDeepSeekRefinerFake
        let delivery: TextDeliveryFake
        let history: SessionHistoryFake
    }

    private static func makeFixture() -> Fixture {
        let refiner = CancellableDeepSeekRefinerFake()
        let delivery = TextDeliveryFake(result: .delivered)
        let history = SessionHistoryFake()
        let processor = DefaultVoiceTextProcessor(
            configuration: VoiceInputConfigurationController(
                refinementMode: .conciseCleanup()
            ),
            transcriber: ContextualTranscriberFake(text: "豆包已确认结果"),
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
        return Fixture(sessions: sessions, refiner: refiner, delivery: delivery, history: history)
    }

    private static func refiningSessionID(
        from stream: AsyncStream<VoiceInputPresentation>
    ) async -> VoiceInputSessionID? {
        for await presentation in stream {
            if case .processing(let id, .refining, _) = presentation.activity {
                return id
            }
            if presentation.activity.isTerminal { return nil }
        }
        return nil
    }
}
