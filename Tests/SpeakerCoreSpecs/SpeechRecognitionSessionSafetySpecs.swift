import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum SpeechRecognitionSessionSafetySpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "speech recognition safety refuses audio rejected after stream EOF", failures: &failures
        ) {
            for provider in [SpeechRecognitionProviderID.openAI, .qwen] {
                for failure in [AudioCaptureError.tooShort, .silent, .conversionFailed] {
                    let audio = StreamingAudioCaptureFake(firstStopError: failure)
                    let target = TargetCaptureFake(
                        result: .writable(.init(id: UUID(), applicationName: "TextEdit")),
                        delaysFirstCapture: true)
                    let transport = makeTransport(provider)
                    let history = SessionHistoryFake()
                    let sessions = makeSessions(
                        audio: audio, target: target, provider: provider, transport: transport,
                        history: history)
                    await sessions.send(.pressed)
                    await audio.emit(Data([1, 0]))
                    let release = Task { await sessions.send(.released) }
                    let captured = await eventually(before: .seconds(2)) {
                        await target.hasPendingCapture
                    }
                    try expect(captured)
                    let prematurelyUploaded = await eventually(before: .milliseconds(40)) {
                        await !transport.requests.isEmpty
                    }
                    await target.resumeFirstCapture()
                    await release.value
                    await sessions.shutdown()
                    try expect(!prematurelyUploaded)
                    let requests = await transport.requests
                    try expect(requests.isEmpty)
                    let record = await history.records.last
                    try expect(record?.transcription == nil && record?.finalText == nil)
                }
            }
        }

        await runAsync(
            "speech recognition safety waits for capture acceptance but not target completion",
            failures: &failures
        ) {
            for provider in [SpeechRecognitionProviderID.openAI, .qwen] {
                let audio = StreamingAudioCaptureFake(delaysFirstStop: true)
                let target = TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit")),
                    delaysFirstCapture: true)
                let transport = makeTransport(provider)
                let history = SessionHistoryFake()
                let sessions = makeSessions(
                    audio: audio, target: target, provider: provider, transport: transport,
                    history: history)
                await sessions.send(.pressed)
                await audio.emit(Data([1, 0]))
                let release = Task { await sessions.send(.released) }
                let stopped = await eventually(before: .seconds(2)) { await audio.hasPendingStop }
                try expect(stopped)
                let premature = await eventually(before: .milliseconds(40)) {
                    await !transport.requests.isEmpty
                }
                try expect(!premature)
                await audio.resumeFirstStop()
                let uploaded = await eventually(before: .seconds(2)) {
                    await transport.requests.count == 1
                }
                try expect(uploaded)
                let targetStillPending = await target.hasPendingCapture
                try expect(targetStillPending)
                await target.resumeFirstCapture()
                await release.value
                await sessions.shutdown()
                let record = await history.records.last
                try expect(record?.finalText == "private result")
            }
        }

        await runAsync(
            "speech recognition safety fences old target and stop failures from a newer secure session",
            failures: &failures
        ) {
            for delaysTarget in [false, true] {
                let audio = StreamingAudioCaptureFake(
                    delaysFirstStop: true, firstStopError: .conversionFailed)
                let target = TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "Old")),
                    delaysFirstCapture: delaysTarget, subsequentResult: .unavailable(.secureTarget))
                let refiner = CancellableDeepSeekRefinerFake()
                let transport = makeTransport(.openAI)
                let history = SessionHistoryFake()
                let configuration = VoiceInputConfigurationController(
                    refinementMode: .conciseCleanup(), recognitionProvider: .init(provider: .openAI)
                )
                let processor = makeProcessor(configuration, transport: transport, refiner: refiner)
                let sessions = VoiceInputSessions(
                    audioCapture: audio, targetCapture: target, textProcessor: processor,
                    delivery: TextDeliveryFake(result: .delivered), clipboard: ClipboardFake(),
                    history: history)
                await sessions.send(.pressed)
                await audio.emit(Data([1, 0]))
                let firstRelease = Task { await sessions.send(.released) }
                let stopped = await eventually(before: .seconds(2)) { await audio.hasPendingStop }
                try expect(stopped)
                await sessions.send(.cancel)
                await sessions.send(.pressed)
                await audio.emit(Data([1, 0]))
                let secondRelease = Task { await sessions.send(.released) }
                let refining = await eventually(before: .seconds(2)) {
                    await refiner.callCount == 1
                }
                try expect(refining)
                await audio.resumeFirstStop()
                await target.resumeFirstCapture()
                await firstRelease.value
                let unexpectedCancellation = await refiner.cancellationCount
                try expect(unexpectedCancellation == 0)
                await sessions.send(.cancel)
                await secondRelease.value
                await sessions.shutdown()
                let records = await history.records
                try expect(records.count == 2)
                let current = records.last
                try expect(current?.outcome.isCancelled == true)
                try expect(current?.transcription == nil && current?.finalText == nil)
                try expect(current?.providerRequestID == nil)
                let discarded = await target.discardedCount
                try expect(discarded == 1)
            }
        }
    }

    private static func makeTransport(_ provider: SpeechRecognitionProviderID)
        -> ChatCompletionTransportFake
    {
        let body =
            provider == .openAI
            ? #"{"text":"private result"}"#
            : #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"private result"}}]}"#
        return ChatCompletionTransportFake(response: .init(statusCode: 200, body: Data(body.utf8)))
    }

    private static func makeProcessor(
        _ configuration: VoiceInputConfigurationController, transport: ChatCompletionTransportFake,
        refiner: any TextRefining
    ) -> DefaultVoiceTextProcessor {
        let transcriber = CredentialedSpeechTranscriber(
            credentials: ProviderCredentialStoreFake(values: [
                .openAITranscription: "fixture", .qwenASRBeijing: "fixture",
            ]),
            doubao: StreamingContextualTranscriberFake(text: "unused"), transport: transport)
        return DefaultVoiceTextProcessor(
            configuration: configuration, transcriber: transcriber,
            refinement: OptionalTextRefinementPipeline(refiner: refiner))
    }

    private static func makeSessions(
        audio: StreamingAudioCaptureFake, target: TargetCaptureFake,
        provider: SpeechRecognitionProviderID, transport: ChatCompletionTransportFake,
        history: SessionHistoryFake
    ) -> VoiceInputSessions {
        let processor = makeProcessor(
            VoiceInputConfigurationController(recognitionProvider: .init(provider: provider)),
            transport: transport,
            refiner: DeepSeekRefinerFake(result: .success(.init(text: "unused"))))
        return VoiceInputSessions(
            audioCapture: audio, targetCapture: target, textProcessor: processor,
            delivery: TextDeliveryFake(result: .delivered), clipboard: ClipboardFake(),
            history: history)
    }
}
