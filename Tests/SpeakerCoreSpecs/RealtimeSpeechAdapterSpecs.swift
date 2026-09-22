import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum RealtimeSpeechAdapterSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "realtime speech uploads before EOF and commits only after capture acceptance",
            failures: &failures
        ) {
            for provider in [SpeechRecognitionProviderID.openAI, .qwen] {
                let socket = RealtimeSpeechSocketFake(provider: provider)
                let connector = RealtimeSpeechConnectorFake(socket: socket)
                let client = makeClient(connector)
                let (stream, continuation) = AsyncStream<Data>.makeStream()
                let gate = AudioCaptureCompletionGate()
                let task = Task {
                    try await client.transcribe(stream, context: context(provider, gate: gate))
                }
                continuation.yield(Data(repeating: 1, count: 6_400))
                let sent = await eventually(before: .seconds(2)) {
                    await socket.count("input_audio_buffer.append") > 0
                }
                try expect(sent)
                continuation.finish()
                let premature = await eventually(before: .milliseconds(40)) {
                    await socket.count("input_audio_buffer.commit") > 0
                }
                try expect(!premature)
                await gate.accept()
                let result = try await task.value
                try expect(result.text == "confirmed result")
                let commitCount = await socket.count("input_audio_buffer.commit")
                let finishCount = await socket.count("session.finish")
                let bytes = await socket.audioBytes()
                try expect(commitCount == 1)
                try expect(finishCount == (provider == .qwen ? 1 : 0))
                try expect(bytes.count == (provider == .openAI ? 9_600 : 6_400))
                let requests = await connector.requests
                try expect(requests[0].url?.scheme == "wss")
                try expect(
                    requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-audio"
                )
                let updateText = await socket.firstMessage("session.update")
                let update =
                    try JSONSerialization.jsonObject(with: Data(updateText!.utf8)) as? [String: Any]
                let session = update?["session"] as? [String: Any]
                if provider == .openAI {
                    try expect(
                        requests[0].url?.absoluteString
                            == "wss://api.openai.com/v1/realtime?intent=transcription")
                    let input = (session?["audio"] as? [String: Any])?["input"] as? [String: Any]
                    let transcription = input?["transcription"] as? [String: Any]
                    try expect(transcription?["model"] as? String == "gpt-live-transcribe")
                    try expect(transcription?["delay"] as? String == "high")
                    try expect(transcription?["prompt"] as? String == "Speaker")
                    try expect(input?["turn_detection"] is NSNull)
                } else {
                    try expect(requests[0].url?.host == "dashscope.aliyuncs.com")
                    try expect(session?["sample_rate"] as? Int == 16_000)
                    try expect(session?["turn_detection"] is NSNull)
                    try expect(
                        (session?["input_audio_transcription"] as? [String: Any])?["language"]
                            == nil)
                }
            }
        }
        await runAsync(
            "realtime speech cancellation closes blocked creation ACK and receive without commit",
            failures: &failures
        ) {
            for stage in [0, 1, 2] {
                let socket = RealtimeSpeechSocketFake(
                    provider: .openAI, creation: stage != 0, updates: stage != 1, completes: false)
                let client = makeClient(RealtimeSpeechConnectorFake(socket: socket))
                let (stream, continuation) = AsyncStream<Data>.makeStream()
                let gate = AudioCaptureCompletionGate()
                let task = Task {
                    try await client.transcribe(stream, context: context(.openAI, gate: gate))
                }
                continuation.yield(Data(repeating: 1, count: 6_400))
                let receiving = await eventually(before: .seconds(2)) {
                    await socket.receiveCount > 0
                }
                try expect(receiving)
                if stage == 2 {
                    let sent = await eventually(before: .seconds(2)) {
                        await socket.count("input_audio_buffer.append") > 0
                    }
                    try expect(sent)
                }
                task.cancel()
                do {
                    _ = try await task.value
                    throw SpecFailure(message: "cancelled live request completed")
                } catch is CancellationError {}
                let closed = await socket.closed
                let commits = await socket.count("input_audio_buffer.commit")
                try expect(closed && commits == 0)
                continuation.finish()
            }
        }
        await runAsync(
            "realtime speech refuses rejected capture malformed results oversize and unsolicited finals",
            failures: &failures
        ) {
            for mode in [
                "rejectedCapture", "earlyFinal", "wrongItem", "malformed", "oversize",
                "remoteError",
            ] {
                let socket = RealtimeSpeechSocketFake(provider: .qwen, mode: mode)
                let client = makeClient(RealtimeSpeechConnectorFake(socket: socket))
                let gate = AudioCaptureCompletionGate()
                if mode == "rejectedCapture" { await gate.reject() } else { await gate.accept() }
                let stream = AsyncStream<Data> {
                    $0.yield(Data(repeating: 1, count: 6_400))
                    $0.finish()
                }
                do {
                    _ = try await client.transcribe(stream, context: context(.qwen, gate: gate))
                    throw SpecFailure(message: "invalid live response accepted: \(mode)")
                } catch is CancellationError {
                    try expect(mode == "rejectedCapture")
                } catch let failure as SpeechRecognitionFailure {
                    let expected: SpeechRecognitionFailureKind =
                        mode == "oversize"
                        ? .responseTooLarge
                        : mode == "remoteError" ? .authentication : .invalidResponse
                    try expect(failure.kind == expected, "\(mode): \(failure.kind)")
                    try expect(!String(describing: failure).contains("secret provider text"))
                }
                let closed = await socket.closed
                try expect(closed)
                if mode == "rejectedCapture" {
                    let commits = await socket.count("input_audio_buffer.commit")
                    try expect(commits == 0)
                }
            }
        }
        await runAsync(
            "realtime speech refuses invalid capture size and odd PCM without committing",
            failures: &failures
        ) {
            for bytes in [Data([1]), Data(repeating: 1, count: 180 * 32_000 + 2)] {
                let socket = RealtimeSpeechSocketFake(provider: .qwen)
                let client = makeClient(RealtimeSpeechConnectorFake(socket: socket))
                let stream = AsyncStream<Data> {
                    $0.yield(bytes)
                    $0.finish()
                }
                do {
                    _ = try await client.transcribe(stream, context: context(.qwen))
                    throw SpecFailure(message: "invalid PCM accepted")
                } catch let failure as SpeechRecognitionFailure {
                    try expect(failure.kind == (bytes.count == 1 ? .invalidAudio : .audioTooLarge))
                }
                let commits = await socket.count("input_audio_buffer.commit")
                try expect(commits == 0)
            }
        }
        await runAsync(
            "realtime speech preserves handshake status and remote failure while ACK sender waits",
            failures: &failures
        ) {
            for code in [401, 403, 429, 503] {
                let socket = RealtimeSpeechSocketFake(provider: .openAI, mode: "http-\(code)")
                let stream = AsyncStream<Data> {
                    $0.yield(Data(repeating: 1, count: 6_400))
                    $0.finish()
                }
                do {
                    _ = try await makeClient(RealtimeSpeechConnectorFake(socket: socket))
                        .transcribe(stream, context: context(.openAI))
                    throw SpecFailure(message: "handshake error accepted")
                } catch let failure as SpeechRecognitionFailure {
                    try expect(failure.httpStatusCode == code)
                    try expect(
                        failure.kind
                            == (code == 429
                                ? .rateLimited : code == 503 ? .rejected : .authentication))
                }
            }
            for _ in 0..<20 {
                let socket = RealtimeSpeechSocketFake(provider: .openAI, mode: "remoteError")
                let stream = AsyncStream<Data> {
                    $0.yield(Data(repeating: 1, count: 6_400))
                    $0.finish()
                }
                do {
                    _ = try await makeClient(RealtimeSpeechConnectorFake(socket: socket))
                        .transcribe(stream, context: context(.openAI))
                    throw SpecFailure(message: "provider authentication failure accepted")
                } catch let failure as SpeechRecognitionFailure {
                    try expect(failure.kind == .authentication)
                }
            }
        }
        await runAsync(
            "realtime speech cancels Waiting For Result without promoting partial text",
            failures: &failures
        ) {
            let socket = RealtimeSpeechSocketFake(provider: .openAI, completes: false)
            let stream = AsyncStream<Data> {
                $0.yield(Data(repeating: 1, count: 6_400))
                $0.finish()
            }
            let task = Task {
                try await makeClient(RealtimeSpeechConnectorFake(socket: socket)).transcribe(
                    stream, context: context(.openAI))
            }
            let committed = await eventually(before: .seconds(2)) {
                await socket.count("input_audio_buffer.commit") == 1
            }
            try expect(committed)
            task.cancel()
            do {
                _ = try await task.value
                throw SpecFailure(message: "cancelled pending final accepted")
            } catch is CancellationError {}
            let closed = await socket.closed
            try expect(closed)
        }
        run(
            "realtime PCM resampling preserves duration DC and chunk partition at byte boundaries",
            failures: &failures
        ) {
            for count in [1, 2, 3, 63, 64, 65, 1_601] {
                let data = pcm((0..<count).map { _ in Int16(4_000) })
                var complete = RealtimePCMResampler()
                let expected = try complete.append(data, final: true)
                var streamed = RealtimePCMResampler()
                var actual = Data()
                var offset = 0
                while offset < data.count {
                    let end = min(data.count, offset + 13)
                    actual.append(try streamed.append(Data(data[offset..<end])))
                    offset = end
                }
                actual.append(try streamed.append(Data(), final: true))
                try expect(actual == expected)
                try expect(actual.count == count * 3 / 2 * 2)
                try expect(samples(actual).allSatisfy { $0 == 4_000 })
            }
        }
        run(
            "realtime PCM resampling is invariant for nonconstant byte-partitioned audio",
            failures: &failures
        ) {
            let source = (0..<8_003).map { index in
                Int16(
                    (7_000 * sin(Double(index) * 0.071) + 9_000 * cos(Double(index) * 0.73))
                        .rounded())
            }
            let data = pcm(source)
            var whole = RealtimePCMResampler()
            let expected = try whole.append(data, final: true)
            for size in [1, 13, 1_023, 6_400] {
                var converter = RealtimePCMResampler()
                var result = Data()
                for offset in stride(from: 0, to: data.count, by: size) {
                    result.append(
                        try converter.append(Data(data[offset..<min(data.count, offset + size)])))
                }
                result.append(try converter.append(Data(), final: true))
                try expect(result == expected)
            }
        }
        run(
            "realtime PCM resampling preserves speech band and suppresses spectral images",
            failures: &failures
        ) {
            for frequency in [1_000.0, 6_000.0] {
                let source = (0..<16_000).map {
                    Int16((10_000 * sin(2 * .pi * frequency * Double($0) / 16_000)).rounded())
                }
                var converter = RealtimePCMResampler()
                let output = samples(try converter.append(pcm(source), final: true))
                let interior = Array(output[240..<23_760])
                func amplitude(_ hz: Double) -> Double {
                    var real = 0.0
                    var imaginary = 0.0
                    for (index, value) in interior.enumerated() {
                        let angle = 2 * Double.pi * hz * Double(index + 240) / 24_000
                        real += Double(value) * cos(angle)
                        imaginary += Double(value) * sin(angle)
                    }
                    return 2 * sqrt(real * real + imaginary * imaginary) / Double(interior.count)
                }
                try expect(abs(amplitude(frequency) / 10_000 - 1) < 0.01)
                try expect(amplitude(16_000 - frequency) < 10, "spectral image exceeds -60 dB")
            }
        }
        await realtimeSessionCases(failures: &failures)
    }

    static func makeClient(_ connector: any RealtimeSpeechConnecting)
        -> CredentialedSpeechTranscriber
    {
        CredentialedSpeechTranscriber(
            credentials: ProviderCredentialStoreFake(values: [
                .openAITranscription: "fixture-audio", .qwenASRBeijing: "fixture-audio",
                .qwenASRSingapore: "fixture-singapore",
            ]),
            doubao: StreamingContextualTranscriberFake(text: "unused"), realtimeConnector: connector
        )
    }
    static func context(
        _ provider: SpeechRecognitionProviderID, gate: AudioCaptureCompletionGate? = nil
    ) -> SpeechTranscriptionContext {
        .init(
            hotwords: ["Speaker"], purpose: .defaultSmoothing,
            recognitionProvider: .init(provider: provider, method: .streaming),
            audioCaptureCompletion: gate)
    }
    static func pcm(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }
    static func samples(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count, by: 2).map {
            Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
        }
    }
}

extension RealtimeSpeechAdapterSpecs {
    @MainActor
    static func realtimeSessionCases(failures: inout [String]) async {
        await runAsync(
            "realtime speech session streams during capture and freezes method until next press",
            failures: &failures
        ) {
            let audio = StreamingAudioCaptureFake()
            let socket = RealtimeSpeechSocketFake(provider: .openAI)
            let connector = RealtimeSpeechConnectorFake(socket: socket)
            let transport = ChatCompletionTransportFake(
                response: .init(statusCode: 200, body: Data(#"{"text":"complete result"}"#.utf8)))
            let configuration = VoiceInputConfigurationController(
                recognitionProvider: .init(provider: .openAI, method: .streaming))
            let transcriber = CredentialedSpeechTranscriber(
                credentials: ProviderCredentialStoreFake(values: [.openAITranscription: "fixture"]),
                doubao: StreamingContextualTranscriberFake(text: "unused"), transport: transport,
                realtimeConnector: connector)
            let processor = DefaultVoiceTextProcessor(
                configuration: configuration, transcriber: transcriber,
                refinement: OptionalTextRefinementPipeline(
                    refiner: DeepSeekRefinerFake(result: .success(.init(text: "unused")))))
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))),
                textProcessor: processor, delivery: delivery, clipboard: ClipboardFake(),
                history: history)
            await sessions.send(.pressed)
            await audio.emit(Data(repeating: 1, count: 6_400))
            let streaming = await eventually(before: .seconds(2)) {
                await socket.count("input_audio_buffer.append") > 0
            }
            try expect(streaming)
            let beforeRelease = await delivery.deliveredTexts
            try expect(beforeRelease.isEmpty)
            try await configuration.selectRecognitionProvider(
                .init(provider: .openAI, method: .completeRecording))
            await sessions.send(.released)
            let firstDone = await eventually(before: .seconds(2)) {
                await delivery.deliveredTexts.count == 1
            }
            try expect(firstDone)
            let firstText = await delivery.deliveredTexts
            try expect(firstText == ["confirmed result"])
            let initialHTTP = await transport.requests
            try expect(initialHTTP.isEmpty)
            await sessions.send(.pressed)
            await audio.emit(Data(repeating: 1, count: 6_400))
            let prematureHTTP = await transport.requests
            try expect(prematureHTTP.isEmpty)
            await sessions.send(.released)
            let secondDone = await eventually(before: .seconds(2)) {
                await delivery.deliveredTexts.count == 2
            }
            try expect(secondDone)
            await sessions.shutdown()
            let texts = await delivery.deliveredTexts
            let sockets = await connector.requests
            let records = await history.records
            try expect(texts == ["confirmed result", "complete result"])
            try expect(sockets.count == 1)
            try expect(records.first?.transcriptionModelID == "gpt-live-transcribe")
            try expect(records.last?.transcriptionModelID == "gpt-transcribe")
        }
        await runAsync(
            "realtime speech session cancellation and capture rejection never commit or refine",
            failures: &failures
        ) {
            for cancel in [false, true] {
                let audio = StreamingAudioCaptureFake(
                    firstStopError: cancel ? nil : .conversionFailed)
                let socket = RealtimeSpeechSocketFake(provider: .qwen)
                let refiner = DeepSeekRefinerFake(result: .success(.init(text: "must not refine")))
                let processor = DefaultVoiceTextProcessor(
                    configuration: VoiceInputConfigurationController(
                        refinementMode: .conciseCleanup(),
                        recognitionProvider: .init(provider: .qwen, method: .streaming)),
                    transcriber: makeClient(RealtimeSpeechConnectorFake(socket: socket)),
                    refinement: OptionalTextRefinementPipeline(refiner: refiner))
                let delivery = TextDeliveryFake(result: .delivered)
                let history = SessionHistoryFake()
                let sessions = VoiceInputSessions(
                    audioCapture: audio,
                    targetCapture: TargetCaptureFake(
                        result: .writable(.init(id: UUID(), applicationName: "TextEdit"))),
                    textProcessor: processor, delivery: delivery, clipboard: ClipboardFake(),
                    history: history)
                await sessions.send(.pressed)
                await audio.emit(Data(repeating: 1, count: 6_400))
                let sent = await eventually(before: .seconds(2)) {
                    await socket.count("input_audio_buffer.append") > 0
                }
                try expect(sent)
                await sessions.send(cancel ? .cancel : .released)
                await sessions.shutdown()
                let commits = await socket.count("input_audio_buffer.commit")
                let texts = await delivery.deliveredTexts
                let calls = await refiner.callCount
                try expect(commits == 0 && texts.isEmpty && calls == 0)
            }
        }
        await runAsync(
            "realtime speech validates known complete audio before opening socket",
            failures: &failures
        ) {
            for bytes in [Data(), Data([1]), Data(repeating: 1, count: 180 * 32_000 + 2)] {
                let connector = RealtimeSpeechConnectorFake(
                    socket: RealtimeSpeechSocketFake(provider: .qwen))
                do {
                    _ = try await makeClient(connector).transcribe(
                        .init(data: bytes, duration: .seconds(1), peakPower: -12),
                        context: context(.qwen))
                    throw SpecFailure(message: "invalid complete audio connected")
                } catch is SpeechRecognitionFailure {}
                let requests = await connector.requests
                try expect(requests.isEmpty)
            }
        }
    }
}
