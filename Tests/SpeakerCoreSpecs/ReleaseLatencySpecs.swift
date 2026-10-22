import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

/// The time from shortcut release to delivery: streaming recognition connects
/// while the microphone starts, the refinement connection opens before the
/// request, short finished transcripts skip Concise Cleanup, and refinement
/// confirmed during Input Target capture keeps its recognition-result shortcut.
enum ReleaseLatencySpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runStreamingConnectionSpecs(failures: &failures)
        await runDoubaoFinalFrameSpecs(failures: &failures)
        await runRefinementConnectionSpecs(failures: &failures)
        await runShortTranscriptSpecs(failures: &failures)
        await runConfirmedRefinementSpecs(failures: &failures)
    }

    // MARK: - Streaming connection beside microphone start

    @MainActor
    private static func runStreamingConnectionSpecs(failures: inout [String]) async {
        await runAsync(
            "streaming recognition connects while the microphone starts and sends early audio once in order",
            failures: &failures
        ) {
            let audio = AudioCaptureFake(delaysStart: true, streamsAudio: true)
            let processor = HandshakeStreamingProcessor()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = makeSessions(audio: audio, processor: processor, delivery: delivery)

            let press = Task { await sessions.dispatchPress() }
            let connectingDuringStart = await eventually(before: .seconds(2)) {
                await processor.isConnecting
            }
            let microphoneStillStarting = await audio.hasPendingStart
            try expect(connectingDuringStart, "the connection waited for the microphone")
            try expect(microphoneStillStarting, "the microphone finished starting first")

            await audio.resumeStart()
            await press.value
            await audio.emit(Data([1]))
            await audio.emit(Data([2]))
            let release = Task { await sessions.releaseAndAwaitTerminal() }
            let stopped = await eventually(before: .seconds(2)) { await audio.stopCount == 1 }
            let chunksBeforeConnecting = await processor.receivedChunks
            try expect(stopped)
            try expect(chunksBeforeConnecting.isEmpty, "audio was sent before connecting")

            await processor.completeHandshake()
            let terminal = await release.value
            let receivedChunks = await processor.receivedChunks
            let finalAudioAuthorized = await processor.finalAudioAuthorized
            let deliveredTexts = await delivery.deliveredTexts
            try expect(terminal?.activity.isDelivered == true)
            try expect(receivedChunks == [Data([1]), Data([2])])
            try expect(finalAudioAuthorized)
            try expect(deliveredTexts == ["连接与录音并行"])
        }

        await runAsync(
            "a connection that fails while the microphone starts ends the recording once it starts",
            failures: &failures
        ) {
            let audio = AudioCaptureFake(delaysStart: true, streamsAudio: true)
            let processor = HandshakeStreamingProcessor(
                handshakeFailure: VoiceTextProcessingFailure(
                    userFailure: .providerAuthenticationFailed))
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = makeSessions(audio: audio, processor: processor, delivery: delivery)
            let stream = await sessions.observe()

            let press = Task { await sessions.dispatchPress() }
            let connecting = await eventually(before: .seconds(2)) { await processor.isConnecting }
            try expect(connecting)
            await processor.completeHandshake()
            await audio.resumeStart()
            await press.value

            let terminal = await firstTerminalPresentation(from: stream, before: .seconds(2))
            try expect(terminal?.activity.failure == .providerAuthenticationFailed)
            let cancelled = await eventually(before: .seconds(2)) { await audio.cancelCount == 1 }
            let deliveredTexts = await delivery.deliveredTexts
            let finalAudioAuthorized = await processor.finalAudioAuthorized
            try expect(cancelled, "the failed connection left the microphone running")
            try expect(deliveredTexts.isEmpty)
            try expect(!finalAudioAuthorized)
        }

        await runAsync(
            "a microphone that fails to start authorizes no final audio on the open connection",
            failures: &failures
        ) {
            let audio = AudioCaptureFake(
                delaysStart: true,
                streamsAudio: true,
                prepareStart: {
                    AudioCaptureStart(
                        start: { throw SpecFailure(message: "microphone failed to start") },
                        cancel: {})
                }
            )
            let processor = HandshakeStreamingProcessor()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = makeSessions(audio: audio, processor: processor, delivery: delivery)
            let stream = await sessions.observe()

            let press = Task { await sessions.dispatchPress() }
            let connecting = await eventually(before: .seconds(2)) { await processor.isConnecting }
            try expect(connecting)
            await processor.completeHandshake()
            await audio.resumeStart()
            await press.value

            let terminal = await firstTerminalPresentation(from: stream, before: .seconds(2))
            try expect(terminal?.activity.isRecordingFailed == true)
            let ended = await eventually(before: .seconds(2)) {
                await processor.endedWithoutFinalAudio
            }
            let finalAudioAuthorized = await processor.finalAudioAuthorized
            let deliveredTexts = await delivery.deliveredTexts
            try expect(ended, "the connection outlived the failed start")
            try expect(!finalAudioAuthorized)
            try expect(deliveredTexts.isEmpty)
        }
    }

    // MARK: - Doubao final frame

    @MainActor
    private static func runDoubaoFinalFrameSpecs(failures: inout [String]) async {
        await runAsync(
            "Doubao sends audio captured during the handshake once and in order after it connects",
            failures: &failures
        ) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "握手后送达", isFinal: true)])
            let connector = HeldDoubaoWebSocketConnector(connection: connection)
            let client = DoubaoStreamingASRClient(
                configuration: .init(apiKey: "test-api-key", requestUserID: "request-user"),
                connector: connector
            )
            let (chunks, continuation) = AsyncStream<Data>.makeStream()
            let gate = AudioCaptureCompletionGate()
            let request = Task {
                try await client.transcribe(chunks, audioCaptureCompletion: gate)
            }
            let connecting = await eventually(before: .seconds(2)) {
                await connector.isConnecting
            }
            try expect(connecting)
            continuation.yield(Data([1]))
            continuation.yield(Data([2]))
            continuation.yield(Data([3]))
            continuation.finish()
            await gate.accept()
            await connector.completeHandshake()

            let result = try await request.value
            let frames = try await connection.sentFrames.dropFirst().map(
                DoubaoStreamingFrameCodec.decode)
            try expect(result.text == "握手后送达")
            try expect(frames.map(\.payload) == [Data([1]), Data([2]), Data([3])])
            try expect(frames.map(\.isFinal) == [false, false, true])
        }

        await runAsync(
            "Doubao holds the final audio frame until the session accepts the capture",
            failures: &failures
        ) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "录音已确认", isFinal: true)])
            let client = DoubaoStreamingASRClient(
                configuration: .init(apiKey: "test-api-key", requestUserID: "request-user"),
                connector: DoubaoWebSocketConnectorFake(connection: connection)
            )
            let gate = AudioCaptureCompletionGate()
            let request = Task {
                try await client.transcribe(
                    makeAudioStream([Data([1, 2]), Data([3, 4])]), audioCaptureCompletion: gate)
            }
            let streamed = await eventually(before: .seconds(2)) {
                await connection.sentFrames.count == 2
            }
            try expect(streamed)
            try await Task.sleep(for: .milliseconds(50))
            let framesBeforeAcceptance = await connection.sentFrames.count
            try expect(framesBeforeAcceptance == 2, "final audio preceded acceptance")

            await gate.accept()
            _ = try await request.value
            let frames = try await connection.sentFrames.dropFirst().map(
                DoubaoStreamingFrameCodec.decode)
            try expect(frames.map(\.isFinal) == [false, true])
            try expect(frames.last?.payload == Data([3, 4]))
        }

        await runAsync(
            "Doubao sends no final audio frame for a capture the session rejected",
            failures: &failures
        ) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "不该发送", isFinal: true)])
            let client = DoubaoStreamingASRClient(
                configuration: .init(apiKey: "test-api-key", requestUserID: "request-user"),
                connector: DoubaoWebSocketConnectorFake(connection: connection)
            )
            let gate = AudioCaptureCompletionGate()
            let request = Task {
                try await client.transcribe(
                    makeAudioStream([Data([1, 2]), Data([3, 4])]), audioCaptureCompletion: gate)
            }
            let streamed = await eventually(before: .seconds(2)) {
                await connection.sentFrames.count == 2
            }
            try expect(streamed)

            await gate.reject()
            do {
                _ = try await request.value
                throw SpecFailure(message: "a rejected capture produced a transcript")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .cancelled)
            }
            let frames = try await connection.sentFrames.dropFirst().map(
                DoubaoStreamingFrameCodec.decode)
            try expect(frames.allSatisfy { !$0.isFinal }, "a rejected capture sent final audio")
        }
    }

    // MARK: - Refinement connection preparation

    @MainActor
    private static func runRefinementConnectionSpecs(failures: inout [String]) async {
        let longTranscript = "这是一段需要精简清理的比较长的识别结果"

        await runAsync(
            "streaming refinement connects once the capture is accepted and before its request",
            failures: &failures
        ) {
            let refiner = TextRefinerFake(refinedText: "整理后的文字。")
            let transcriber = HeldStreamingTranscriber(text: longTranscript)
            let processor = DefaultVoiceTextProcessor(
                configuration: VoiceInputConfigurationController(
                    refinementMode: .conciseCleanup()),
                transcriber: transcriber,
                refinement: OptionalTextRefinementPipeline(refiner: refiner)
            )
            let snapshot = await processor.captureSnapshot()
            let gate = AudioCaptureCompletionGate()
            let processing = Task {
                try await processor.processStreaming(
                    makeAudioStream([Data([1])]), snapshot: snapshot,
                    audioCaptureCompletion: gate
                ) { _ in }
            }
            try await Task.sleep(for: .milliseconds(50))
            let eventsBeforeAcceptance = await refiner.events
            try expect(eventsBeforeAcceptance.isEmpty, "connected before recording ended")

            await gate.accept()
            let prepared = await eventually(before: .seconds(2)) {
                let providers = await refiner.preparedProviders
                let isHeld = await transcriber.isHeld
                return providers == [snapshot.refinementProvider] && isHeld
            }
            let refineCountWhileRecognizing = await refiner.refineCount
            try expect(prepared, "accepted capture did not prepare the connection")
            try expect(refineCountWhileRecognizing == 0)

            await transcriber.resume()
            let result = try await processing.value
            let events = await refiner.events
            try expect(result.finalText == "整理后的文字。")
            try expect(
                events == [
                    .preparedConnection(snapshot.refinementProvider), .refined(longTranscript),
                ])
        }

        await runAsync(
            "Default Smoothing and a rejected capture open no refinement connection",
            failures: &failures
        ) {
            for mode in [TextRefinementMode.defaultSmooth, .conciseCleanup()] {
                let refiner = TextRefinerFake(refinedText: "整理后的文字。")
                let transcriber = HeldStreamingTranscriber(text: longTranscript)
                let processor = DefaultVoiceTextProcessor(
                    configuration: VoiceInputConfigurationController(refinementMode: mode),
                    transcriber: transcriber,
                    refinement: OptionalTextRefinementPipeline(refiner: refiner)
                )
                let snapshot = await processor.captureSnapshot()
                let gate = AudioCaptureCompletionGate()
                let processing = Task {
                    try await processor.processStreaming(
                        makeAudioStream([Data([1])]), snapshot: snapshot,
                        audioCaptureCompletion: gate
                    ) { _ in }
                }
                if mode == .defaultSmooth {
                    await gate.accept()
                    let held = await eventually(before: .seconds(2)) { await transcriber.isHeld }
                    try expect(held)
                    await transcriber.resume()
                    _ = try await processing.value
                } else {
                    await gate.reject()
                    _ = try? await processing.value
                    try await Task.sleep(for: .milliseconds(50))
                }
                let preparedProviders = await refiner.preparedProviders
                try expect(preparedProviders.isEmpty, "\(mode) prepared a connection")
            }
        }

        await runAsync(
            "a complete recording opens the refinement connection while it is recognized",
            failures: &failures
        ) {
            let refiner = TextRefinerFake(refinedText: "整理后的文字。")
            let transcriber = SpeechTranscriberFake(text: longTranscript, delaysResponse: true)
            let processor = DefaultVoiceTextProcessor(
                configuration: VoiceInputConfigurationController(refinementMode: .fullRewrite()),
                transcriber: transcriber,
                refinement: OptionalTextRefinementPipeline(refiner: refiner)
            )
            let snapshot = await processor.captureSnapshot()
            let processing = Task {
                try await processor.process(specAudio, snapshot: snapshot) { _ in }
            }
            let prepared = await eventually(before: .seconds(2)) {
                let providers = await refiner.preparedProviders
                let calls = await transcriber.callCount
                return providers.count == 1 && calls == 1
            }
            let refineCountWhileRecognizing = await refiner.refineCount
            try expect(prepared)
            try expect(refineCountWhileRecognizing == 0)
            await transcriber.resume()
            _ = try await processing.value
            let events = await refiner.events
            try expect(
                events == [
                    .preparedConnection(snapshot.refinementProvider), .refined(longTranscript),
                ])
        }

        run(
            "the refinement connection preparation is a bodiless HEAD without credentials",
            failures: &failures
        ) {
            let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
            let request = URLSessionChatCompletionTransport.connectionPreparationRequest(
                for: endpoint)
            try expect(request.url == endpoint)
            try expect(request.httpMethod == "HEAD")
            try expect(request.httpBody == nil && request.httpBodyStream == nil)
            try expect(request.allHTTPHeaderFields?.isEmpty ?? true)
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }

        await runAsync(
            "the credentialed refiner prepares the provider's endpoint without reading its Key",
            failures: &failures
        ) {
            let credentials = ReadCountingCredentialStore()
            let transport = ConnectionPreparationTransportFake()
            let refiner = CredentialedTextRefiner(credentials: credentials, transport: transport)
            let deepSeek = RefinementProviderProfile.defaultProfile(for: .deepSeek)
            let custom = RefinementProviderProfile(
                provider: .custom, modelID: "local-model", baseURL: "https://llm.example.test/v1")
            let invalid = RefinementProviderProfile(
                provider: .custom, modelID: "local-model", baseURL: "not a url")

            await refiner.prepareConnection(to: deepSeek)
            await refiner.prepareConnection(to: custom)
            await refiner.prepareConnection(to: invalid)

            let preparedEndpoints = await transport.preparedEndpoints
            let sentRequestCount = await transport.sentRequestCount
            let readCount = await credentials.readCount
            let expectedEndpoints = [
                try deepSeek.completionEndpoint(), try custom.completionEndpoint(),
            ]
            try expect(preparedEndpoints == expectedEndpoints)
            try expect(sentRequestCount == 0)
            try expect(readCount == 0, "preparation read a Key")
        }
    }

    // MARK: - Short transcripts skip Concise Cleanup

    @MainActor
    private static func runShortTranscriptSpecs(failures: inout [String]) async {
        run(
            "only a short finished Concise Cleanup transcript without fillers skips refinement",
            failures: &failures
        ) {
            let concise = TextRefinementMode.conciseCleanup()
            for text in ["好的，收到。", "谢谢！", "OK.", "  明天见。  ", "十个字以内的一句话。"] {
                try expect(
                    ShortTranscriptRefinementPolicy.skipsRefinement(
                        of: text, mode: concise, dictionaryWords: []),
                    "\(text) was refined")
            }
            let refined: [(String, TextRefinementMode, [String])] = [
                ("好的，收到。", .fullRewrite(), []),
                ("好的，收到。", .custom(name: "邮件", prompt: "改写成邮件"), []),
                ("好的，收到。", .conciseCleanup(promptOverride: "保留口语"), []),
                ("好的，收到。", .defaultSmooth, []),
                ("好的，收到。", concise, ["Speaker"]),
                ("好的收到", concise, []),
                ("好的，\n收到。", concise, []),
                ("这一句话超过了十个字的长度。", concise, []),
                ("嗯，好的。", concise, []),
                ("那个明天见。", concise, []),
                ("不对，周三。", concise, []),
                ("Um, okay.", concise, []),
                ("好好好的。", concise, []),
                ("明天明天见。", concise, []),
                ("。", concise, []),
            ]
            for (text, mode, words) in refined {
                try expect(
                    !ShortTranscriptRefinementPolicy.skipsRefinement(
                        of: text, mode: mode, dictionaryWords: words),
                    "\(text) in \(mode) skipped refinement")
            }
        }

        await runAsync(
            "a short finished transcript never presents refinement or reaches the provider",
            failures: &failures
        ) {
            for (text, expectsRefinement) in [("好的，收到。", false), ("这是一段需要精简清理的比较长的识别结果", true)] {
                let refiner = TextRefinerFake(refinedText: "整理后的文字。")
                let processor = DefaultVoiceTextProcessor(
                    configuration: VoiceInputConfigurationController(
                        refinementMode: .conciseCleanup()),
                    transcriber: ContextualTranscriberFake(text: text),
                    refinement: OptionalTextRefinementPipeline(refiner: refiner)
                )
                let stages = StageRecorder()
                let result = try await processor.process(
                    specAudio, snapshot: await processor.captureSnapshot()
                ) { progress in
                    await stages.record(progress.stage)
                }
                let presentedRefinement = await stages.stages.contains(.refining)
                let refineCount = await refiner.refineCount
                try expect(presentedRefinement == expectsRefinement)
                try expect(refineCount == (expectsRefinement ? 1 : 0))
                try expect(
                    result.refinementStatus == (expectsRefinement ? .succeeded : .skipped))
                try expect(result.finalText == (expectsRefinement ? "整理后的文字。" : text))
                try expect(result.refinedText == (expectsRefinement ? "整理后的文字。" : nil))
                try expect(result.refinementFailure == nil)
            }
        }

        await runAsync(
            "a session delivers a short finished transcript and records refinement as skipped",
            failures: &failures
        ) {
            let refiner = TextRefinerFake(refinedText: "整理后的文字。")
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))),
                textProcessor: DefaultVoiceTextProcessor(
                    configuration: VoiceInputConfigurationController(
                        refinementMode: .conciseCleanup()),
                    transcriber: ContextualTranscriberFake(text: "好的，收到。"),
                    refinement: OptionalTextRefinementPipeline(refiner: refiner)
                ),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )

            await sessions.dispatchPress()
            let terminal = await sessions.releaseAndAwaitTerminal()
            try expect(terminal?.activity.isDelivered == true)
            let deliveredTexts = await delivery.deliveredTexts
            let refineCount = await refiner.refineCount
            try expect(terminal?.notice == nil)
            try expect(deliveredTexts == ["好的，收到。"])
            try expect(refineCount == 0)
            let recorded = await eventually(before: .seconds(1)) {
                await history.records.last?.outcome.isDelivered == true
            }
            try expect(recorded)
            let record = await history.records.last
            try expect(record?.refinementStatus == TextRefinementStatus.skipped.rawValue)
            try expect(record?.refinedText == nil)
            try expect(record?.finalText == "好的，收到。")
        }
    }

    // MARK: - Refinement confirmed during Input Target capture

    @MainActor
    private static func runConfirmedRefinementSpecs(failures: inout [String]) async {
        await runAsync(
            "refinement confirmed during Input Target capture keeps its recognition-result shortcut",
            failures: &failures
        ) {
            let target = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit")),
                delaysFirstCapture: true
            )
            let processor = ConfirmedStreamingVoiceTextProcessor(confirmedText: "已识别的文字")
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(streamsAudio: true),
                targetCapture: target,
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )

            await sessions.dispatchPress()
            await sessions.dispatchRelease()
            let confirmedDuringCapture = await eventually(before: .seconds(2)) {
                let refining = await processor.hasReportedRefining
                let capturing = await target.hasPendingCapture
                return refining && capturing
            }
            try expect(confirmedDuringCapture)
            guard case .processing(let id, .refining) = await currentActivity(of: sessions) else {
                throw SpecFailure(message: "confirmed recognition did not present refinement")
            }

            await target.resumeFirstCapture()
            let captured = await eventually(before: .seconds(2)) {
                let captures = await target.captureCount
                let capturing = await target.hasPendingCapture
                return captures == 1 && !capturing
            }
            try expect(captured)
            try await Task.sleep(for: .milliseconds(100))
            let afterCapture = await currentActivity(of: sessions)
            try expect(
                afterCapture == .processing(id, .refining),
                "Input Target capture stepped back to \(String(describing: afterCapture))")

            let stream = await sessions.observe()
            await sessions.useRecognitionResult(expectedSessionID: id)
            let terminal = await firstTerminalPresentation(from: stream, before: .seconds(2))
            let deliveredTexts = await delivery.deliveredTexts
            try expect(terminal?.activity.isDelivered == true)
            try expect(deliveredTexts == ["已识别的文字"])
            let cancelled = await eventually(before: .seconds(2)) {
                await processor.cancellationCount == 1
            }
            try expect(cancelled, "pending refinement kept running")
            let recorded = await eventually(before: .seconds(1)) {
                await history.records.last?.outcome.isDelivered == true
            }
            let refinementStatus = await history.records.last?.refinementStatus
            try expect(recorded)
            try expect(refinementStatus == TextRefinementStatus.skipped.rawValue)
        }
    }

    // MARK: - Fixtures

    private static func makeSessions(
        audio: AudioCaptureFake,
        processor: some VoiceTextProcessing,
        delivery: TextDeliveryFake
    ) -> VoiceInputSessions {
        VoiceInputSessions(
            audioCapture: audio,
            targetCapture: TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))),
            textProcessor: processor,
            delivery: delivery,
            clipboard: ClipboardFake(),
            history: SessionHistoryFake()
        )
    }

    private static func currentActivity(of sessions: VoiceInputSessions) async
        -> VoiceInputActivity?
    {
        var presentations = await sessions.observe().makeAsyncIterator()
        return await presentations.next()?.activity
    }
}

/// A streaming processor whose connection opens when the session begins and
/// completes only on `completeHandshake()`. It then reads the audio and sends
/// final audio only after the session accepts the capture.
private actor HandshakeStreamingProcessor: VoiceTextProcessing, StreamingVoiceTextProcessing {
    nonisolated var streaming: (any StreamingVoiceTextProcessing)? { self }

    private let handshakeFailure: VoiceTextProcessingFailure?
    private var handshakeContinuation: CheckedContinuation<Void, Never>?
    private var handshakeCompleted = false
    private(set) var isConnecting = false
    private(set) var receivedChunks: [Data] = []
    private(set) var finalAudioAuthorized = false
    private(set) var endedWithoutFinalAudio = false

    init(handshakeFailure: VoiceTextProcessingFailure? = nil) {
        self.handshakeFailure = handshakeFailure
    }

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw SpecFailure(message: "streaming processor used the complete recording")
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw SpecFailure(message: "streaming processor ran without a completion gate")
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        audioCaptureCompletion: AudioCaptureCompletionGate,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        isConnecting = true
        if !handshakeCompleted {
            await withCheckedContinuation { handshakeContinuation = $0 }
        }
        isConnecting = false
        if let handshakeFailure { throw handshakeFailure }
        for await chunk in audioChunks { receivedChunks.append(chunk) }
        do {
            try await audioCaptureCompletion.wait()
        } catch {
            endedWithoutFinalAudio = true
            throw error
        }
        finalAudioAuthorized = true
        return VoiceTextProcessingResult(
            recognitionText: "连接与录音并行",
            normalizedText: "连接与录音并行",
            refinedText: nil,
            finalText: "连接与录音并行",
            recognitionRequestID: "handshake-spec",
            refinementRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil
        )
    }

    func completeHandshake() {
        handshakeCompleted = true
        handshakeContinuation?.resume()
        handshakeContinuation = nil
    }
}

/// Holds the WebSocket handshake open until `completeHandshake()`.
private actor HeldDoubaoWebSocketConnector: DoubaoWebSocketConnecting {
    let connection: DoubaoWebSocketConnectionFake
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isConnecting = false

    init(connection: DoubaoWebSocketConnectionFake) {
        self.connection = connection
    }

    func connect(_ request: URLRequest) async throws -> any DoubaoWebSocketConnection {
        isConnecting = true
        await withCheckedContinuation { continuation = $0 }
        isConnecting = false
        return connection
    }

    func completeHandshake() {
        continuation?.resume()
        continuation = nil
    }
}

/// A streaming transcriber that, after the capture is accepted, holds its
/// confirmed text until `resume()`.
private actor HeldStreamingTranscriber: ContextualSpeechTranscribing,
    StreamingContextualSpeechTranscribing
{
    let text: String
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isHeld = false

    init(text: String) {
        self.text = text
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        TranscriptionResult(text: text, providerRequestID: "held-streaming")
    }

    func transcribe(
        _ audio: CapturedAudio, context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: text, providerRequestID: "held-streaming")
    }

    func transcribe(
        _ audioChunks: AsyncStream<Data>, context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        for await _ in audioChunks {}
        try await context.audioCaptureCompletion?.wait()
        isHeld = true
        await withCheckedContinuation { continuation = $0 }
        return TranscriptionResult(text: text, providerRequestID: "held-streaming")
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// Records connection preparations and counts requests; it never answers one.
private actor ConnectionPreparationTransportFake: ChatCompletionTransport {
    private(set) var preparedEndpoints: [URL] = []
    private(set) var sentRequestCount = 0

    func send(_ request: URLRequest) async throws -> ChatCompletionTransportResponse {
        sentRequestCount += 1
        throw URLError(.notConnectedToInternet)
    }

    func prepareConnection(to endpoint: URL) async {
        preparedEndpoints.append(endpoint)
    }
}

private actor ReadCountingCredentialStore: ProviderCredentialStoring {
    private(set) var readCount = 0

    func save(apiKey: String, for provider: ProviderID) async throws {}

    func apiKey(for provider: ProviderID) async throws -> String? {
        readCount += 1
        return "refinement-test-key"
    }

    func deleteAPIKey(for provider: ProviderID) async throws {}
}

private actor StageRecorder {
    private(set) var stages: [VoiceInputProcessingStage] = []

    func record(_ stage: VoiceInputProcessingStage) {
        stages.append(stage)
    }
}
