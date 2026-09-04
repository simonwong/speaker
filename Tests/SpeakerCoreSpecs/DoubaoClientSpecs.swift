import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum DoubaoClientSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "Doubao WebSocket uses streaming headers and binary frames", failures: &failures
        ) {
            let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "  你好，世界。  ", isFinal: true)],
                metadata: .init(httpStatusCode: 101, providerRequestID: "log-12")
            )
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user",
                    hotwords: ["Speaker"]
                ),
                connector: connector,
                requestIDGenerator: { requestID }
            )

            let result = try await client.transcribe(
                makeAudioStream([Data([1, 2]), Data([3, 4])])
            )
            let request = try await connector.onlyRequest()
            let frames = await connection.sentFrames
            try expect(frames.count == 3)
            let fullRequest = try DoubaoStreamingFrameCodec.decode(frames[0])
            let firstAudio = try DoubaoStreamingFrameCodec.decode(frames[1])
            let finalAudio = try DoubaoStreamingFrameCodec.decode(frames[2])
            let body = try JSONSerialization.jsonObject(with: fullRequest.payload) as? [String: Any]
            let recognition = body?["request"] as? [String: Any]
            let audio = body?["audio"] as? [String: Any]
            let corpus = recognition?["corpus"] as? [String: Any]
            let context = corpus?["context"] as? String
            let contextData = context.map { Data($0.utf8) }
            let hotwordContext = try contextData.flatMap {
                try JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let hotwords = hotwordContext?["hotwords"] as? [[String: String]]

            try expect(request.url == DoubaoStreamingASRConfiguration.defaultEndpoint)
            try expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-api-key")
            try expect(
                request.value(forHTTPHeaderField: "X-Api-Resource-Id")
                    == "volc.seedasr.sauc.duration")
            try expect(
                request.value(forHTTPHeaderField: "X-Api-Request-Id") == requestID.uuidString)
            try expect(
                request.value(forHTTPHeaderField: "X-Api-Connect-Id") == requestID.uuidString)
            try expect(request.value(forHTTPHeaderField: "X-Api-Sequence") == "-1")
            try expect(recognition?["enable_itn"] as? Bool == true)
            try expect(recognition?["enable_punc"] as? Bool == true)
            try expect(recognition?["enable_ddc"] as? Bool == true)
            try expect(recognition?["context"] == nil)
            try expect(hotwords == [["word": "Speaker"]])
            try expect(audio?["format"] as? String == "pcm")
            try expect(audio?["rate"] as? Int == 16_000)
            try expect(audio?["language"] == nil)
            try expect(fullRequest.messageType == 0x01)
            try expect(firstAudio.payload == Data([1, 2]) && !firstAudio.isFinal)
            try expect(finalAudio.payload == Data([3, 4]) && finalAudio.isFinal)
            try expect(result == .init(text: "你好，世界。", providerRequestID: "log-12"))
        }

        await runAsync(
            "Doubao disables semantic smoothing while keeping written form and punctuation",
            failures: &failures
        ) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "你好，世界。", isFinal: true)],
                metadata: .init(httpStatusCode: 101, providerRequestID: "log-ddc-off")
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user",
                    options: .init(enableSemanticSmoothing: false)
                ),
                connector: DoubaoWebSocketConnectorFake(connection: connection)
            )

            _ = try await client.transcribe(makeAudioStream([Data([1, 2])]))
            let frames = await connection.sentFrames
            let fullRequest = try DoubaoStreamingFrameCodec.decode(frames[0])
            let body = try JSONSerialization.jsonObject(with: fullRequest.payload) as? [String: Any]
            let recognition = body?["request"] as? [String: Any]

            try expect(recognition?["enable_ddc"] as? Bool == false)
            try expect(recognition?["enable_itn"] as? Bool == true)
            try expect(recognition?["enable_punc"] as? Bool == true)
        }

        await runAsync(
            "Doubao provider errors interrupt audio that is still being recorded",
            failures: &failures
        ) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerError(code: 45_000_001, message: "invalid api key")],
                metadata: .init(httpStatusCode: 101, providerRequestID: "early-error-log")
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "bad-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(connection: connection)
            )
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            continuation.yield(Data([1, 2]))

            do {
                _ = try await client.transcribe(stream)
                throw SpecFailure(message: "provider error waited for the recording to finish")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .invalidCredential)
                try expect(failure.providerRequestID == "early-error-log")
            }
            continuation.finish()
            let closeCount = await connection.closeCount
            try expect(closeCount == 1)
        }

        await runAsync(
            "Doubao provider errors outrank send failures caused by closing the socket",
            failures: &failures
        ) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [
                    makeDoubaoServerError(
                        code: 45_000_001,
                        message: "resource not activated"
                    )
                ],
                metadata: .init(
                    httpStatusCode: 101,
                    providerRequestID: "provider-error-priority"
                ),
                blockingSendFailureIndex: 1
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                )
            )

            do {
                _ = try await client.transcribe(
                    makeAudioStream([Data([1]), Data([2])])
                )
                throw SpecFailure(message: "provider error was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .resourceNotActivated)
                try expect(
                    failure.providerRequestID
                        == "provider-error-priority"
                )
            }
        }

        await runAsync(
            "Doubao send failures close a receive that ignores task cancellation",
            failures: &failures
        ) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [],
                failingSendIndex: 1,
                blocksReceiveUntilClose: true
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(connection: connection)
            )
            let completion = CompletionFlag()
            let request = Task {
                let result: Result<TranscriptionResult, Error>
                do {
                    result = .success(
                        try await client.transcribe(
                            makeAudioStream([Data([1, 2])])
                        ))
                } catch {
                    result = .failure(error)
                }
                await completion.markComplete()
                return result
            }

            let completedWithoutExternalCancellation = await eventually(before: .seconds(2)) {
                await completion.isComplete
            }
            if !completedWithoutExternalCancellation {
                // Clean up the deliberately non-cooperative fake so a red test
                // reports normally instead of leaving the suite suspended.
                await connection.close()
            }
            let result = await request.value

            try expect(
                completedWithoutExternalCancellation,
                "send failure waited forever for a receive that ignores Task cancellation"
            )
            if case .failure(let failure as DoubaoASRFailure) = result {
                try expect(failure.kind == .network)
            } else {
                throw SpecFailure(message: "send failure did not become a Doubao network problem")
            }
            let closeCount = await connection.closeCount
            try expect(closeCount == 1)
        }

        await runAsync("Doubao cancellation never sends a final audio frame", failures: &failures) {
            let connection = DoubaoWebSocketConnectionFake(
                responses: [],
                blocksReceiveUntilClose: true
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                )
            )
            let probe = AudioChunkConsumptionProbe()
            let stream = AsyncStream<Data>(unfolding: {
                if await probe.takeFirstChunk() {
                    return Data([1, 2])
                }
                try? await suspendUntilCancelled()
                return nil
            })
            let request = Task {
                try await client.transcribe(stream)
            }
            while !(await probe.firstChunkWasConsumed) {
                await Task.yield()
            }

            request.cancel()
            let finished = await finishes(request, before: .seconds(2))
            try expect(finished, "cancellation did not end the Doubao request")
            do {
                _ = try await request.value
                throw SpecFailure(message: "cancelled Doubao request succeeded")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .cancelled)
            }

            let frames = await connection.sentFrames
            let audioFrames = try frames.dropFirst().map(
                DoubaoStreamingFrameCodec.decode
            )
            try expect(
                audioFrames.allSatisfy { !$0.isFinal },
                "cancelled request sent a final audio frame"
            )
        }

        await runAsync(
            "Doubao runtime diagnostics report the exact active transport phase",
            failures: &failures
        ) {
            let requestID = UUID(
                uuidString: "00000000-0000-0000-0000-000000000099"
            )!
            let diagnostics = VoiceProviderRuntimeDiagnostics()
            let connection = DoubaoWebSocketConnectionFake(
                responses: [],
                metadata: .init(
                    httpStatusCode: 101,
                    providerRequestID: "server-request-99"
                ),
                blocksReceiveUntilClose: true
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                ),
                requestIDGenerator: { requestID },
                runtimeDiagnostics: diagnostics
            )
            let request = Task {
                try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
            }
            let reachedAwaitingFinal = await eventually(
                before: .seconds(2)
            ) {
                await diagnostics.activeSnapshot()?.phase
                    == .awaitingFinal
            }
            let snapshot = await diagnostics.activeSnapshot()

            try expect(reachedAwaitingFinal)
            try expect(snapshot?.operation == .voiceInput)
            try expect(
                snapshot?.requestID == requestID.uuidString
            )
            try expect(
                snapshot?.providerRequestID == "server-request-99"
            )
            try expect(snapshot?.httpStatusCode == 101)

            request.cancel()
            let finished = await finishes(request, before: .seconds(2))
            try expect(finished, "cancellation did not end the Doubao request")
            let cleared = await eventually(
                before: .seconds(2)
            ) {
                await diagnostics.activeSnapshot() == nil
            }
            try expect(cleared)
        }

        await runAsync(
            "Doubao diagnostics stay connecting until the first WebSocket send succeeds",
            failures: &failures
        ) {
            let diagnostics = VoiceProviderRuntimeDiagnostics()
            let connection = DoubaoWebSocketConnectionFake(
                responses: [],
                hangingSendIndex: 0
            )
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                ),
                runtimeDiagnostics: diagnostics
            )
            let request = Task {
                try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
            }
            let sendStarted = await eventually(before: .seconds(2)) {
                await connection.sendAttemptCount == 1
            }
            let snapshot = await diagnostics.activeSnapshot()

            try expect(sendStarted)
            try expect(snapshot?.phase == .connecting)

            request.cancel()
            let finished = await finishes(request, before: .seconds(2))
            try expect(finished, "cancellation did not end the Doubao request")
        }

        await runAsync(
            "Doubao response metadata cannot advance the audio transport phase", failures: &failures
        ) {
            let diagnostics = VoiceProviderRuntimeDiagnostics()
            await diagnostics.beginDoubao(
                requestID: "request-early-response",
                operation: .voiceInput
            )
            await diagnostics.updateDoubao(
                requestID: "request-early-response",
                phase: .streamingAudio
            )
            await diagnostics.updateDoubaoMetadata(
                requestID: "request-early-response",
                metadata: .init(
                    httpStatusCode: 101,
                    providerRequestID: "server-early-response"
                )
            )
            let snapshot = await diagnostics.activeSnapshot()

            try expect(snapshot?.phase == .streamingAudio)
            try expect(
                snapshot?.providerRequestID == "server-early-response"
            )
            try expect(snapshot?.httpStatusCode == 101)
        }

        await runAsync("Doubao maps silence without exposing a transcript", failures: &failures) {
            let client = makeDoubaoClient(
                responses: [makeDoubaoServerResponse(text: nil, isFinal: true)],
                metadata: .init(httpStatusCode: 101, providerRequestID: "silent-log")
            )
            do {
                _ = try await client.transcribe(makeAudioStream([Data([0, 0])]))
                throw SpecFailure(message: "silence response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .emptyTranscript)
                try expect(failure.providerRequestID == "silent-log")
            }
        }

        await runAsync(
            "Doubao silent error frame validates a credential connection probe", failures: &failures
        ) {
            let credentials = ProviderCredentialStoreFake(
                values: [.doubao: "valid-key"]
            )
            let connection = DoubaoWebSocketConnectionFake(
                responses: [
                    makeDoubaoServerError(
                        code: 20_000_003,
                        message: "no speech detected"
                    )
                ],
                metadata: .init(
                    httpStatusCode: 101,
                    providerRequestID: "silent-probe-request"
                )
            )
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                connector: DoubaoWebSocketConnectorFake(
                    connection: connection
                )
            )

            let requestID = try await transcriber.checkConnection()
            try expect(requestID == "silent-probe-request")
        }

        await runAsync(
            "Doubao distinguishes inactive resource from bad credential", failures: &failures
        ) {
            let inactive = makeDoubaoClient(responses: [
                makeDoubaoServerError(code: 45_000_001, message: "resource not activated")
            ])
            do {
                _ = try await inactive.transcribe(makeAudioStream([Data([1, 2])]))
                throw SpecFailure(message: "inactive resource response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .resourceNotActivated)
            }

            let unauthorized = makeDoubaoClient(
                receiveError: URLError(.badServerResponse),
                metadata: .init(httpStatusCode: 401, providerMessage: "unauthorized api key")
            )
            do {
                _ = try await unauthorized.transcribe(makeAudioStream([Data([1, 2])]))
                throw SpecFailure(message: "invalid credential response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .invalidCredential)
            }
        }

        await runAsync(
            "Doubao preserves a remote WebSocket close code as structured diagnostics",
            failures: &failures
        ) {
            let client = makeDoubaoClient(
                receiveError: URLError(.networkConnectionLost),
                metadata: .init(
                    providerRequestID: "closed-request",
                    webSocketCloseCode: 1006
                )
            )

            do {
                _ = try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
                throw SpecFailure(message: "closed WebSocket succeeded")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .network)
                try expect(
                    failure.providerStatusCode
                        == "websocket.close.1006"
                )
                try expect(
                    failure.providerRequestID == "closed-request"
                )
            }
        }

        await runAsync(
            "Doubao classifies URL transport failures without raw error text", failures: &failures
        ) {
            let client = makeDoubaoClient(
                receiveError: URLError(.cannotFindHost)
            )

            do {
                _ = try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
                throw SpecFailure(message: "DNS failure succeeded")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .network)
                try expect(
                    failure.providerStatusCode == "url.cannotFindHost"
                )
            }
        }

        await runAsync(
            "Doubao classifies connection setup failures before a socket exists",
            failures: &failures
        ) {
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    requestUserID: "request-user"
                ),
                connector: DoubaoFailingWebSocketConnectorFake(
                    error: URLError(.secureConnectionFailed)
                )
            )

            do {
                _ = try await client.transcribe(
                    makeAudioStream([Data([1, 2])])
                )
                throw SpecFailure(message: "TLS setup failure succeeded")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .network)
                try expect(
                    failure.providerStatusCode
                        == "url.secureConnectionFailed"
                )
                try expect(failure.providerRequestID != nil)
            }
        }

        await runAsync(
            "credential-backed Doubao transcriber loads the current stored value",
            failures: &failures
        ) {
            let credentials = ProviderCredentialStoreFake(values: [.doubao: "first-key"])
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "第一条", isFinal: true)]
            )
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                connector: connector,
                requestUserID: { "request-user-1" }
            )

            _ = try await transcriber.transcribe(specAudio)
            let firstRequest = try await connector.onlyRequest()
            let sentFrames = await connection.sentFrames
            let fullRequest = try DoubaoStreamingFrameCodec.decode(
                sentFrames[0]
            )
            let body =
                try JSONSerialization.jsonObject(
                    with: fullRequest.payload
                ) as? [String: Any]
            let user = body?["user"] as? [String: Any]
            try expect(firstRequest.value(forHTTPHeaderField: "X-Api-Key") == "first-key")
            try expect(user?["uid"] as? String == "request-user-1")
        }

        await runAsync(
            "credential-backed Doubao transcriber maps transcription purpose to semantic smoothing",
            failures: &failures
        ) {
            func smoothingFlag(
                for purpose: SpeechTranscriptionPurpose
            ) async throws -> (ddc: Bool?, itn: Bool?, punctuation: Bool?) {
                let connection = DoubaoWebSocketConnectionFake(
                    responses: [makeDoubaoServerResponse(text: "豆包结果", isFinal: true)]
                )
                let transcriber = CredentialedDoubaoTranscriber(
                    credentials: ProviderCredentialStoreFake(values: [.doubao: "purpose-key"]),
                    connector: DoubaoWebSocketConnectorFake(connection: connection),
                    requestUserID: { "request-user-purpose" }
                )

                _ = try await transcriber.transcribe(
                    specAudio,
                    context: .init(hotwords: [], purpose: purpose)
                )
                let frames = await connection.sentFrames
                let fullRequest = try DoubaoStreamingFrameCodec.decode(frames[0])
                let body =
                    try JSONSerialization.jsonObject(
                        with: fullRequest.payload
                    ) as? [String: Any]
                let recognition = body?["request"] as? [String: Any]
                return (
                    recognition?["enable_ddc"] as? Bool,
                    recognition?["enable_itn"] as? Bool,
                    recognition?["enable_punc"] as? Bool
                )
            }

            let smoothing = try await smoothingFlag(for: .defaultSmoothing)
            let refinementSource = try await smoothingFlag(for: .refinementSource)

            try expect(smoothing.ddc == true)
            try expect(refinementSource.ddc == false)
            try expect(refinementSource.itn == true)
            try expect(refinementSource.punctuation == true)
        }

        await runAsync(
            "credential-backed Doubao transcriber fails before network when unconfigured",
            failures: &failures
        ) {
            let credentials = ProviderCredentialStoreFake()
            let connection = DoubaoWebSocketConnectionFake(responses: [])
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                connector: connector
            )

            do {
                _ = try await transcriber.transcribe(specAudio)
                throw SpecFailure(message: "unconfigured transcriber sent a request")
            } catch let failure as ProviderCredentialStoreError {
                try expect(failure == .emptyAPIKey)
                let requestCount = await connector.requestCount
                try expect(requestCount == 0)
            }
        }

        await runAsync(
            "Doubao failure becomes stable user state and diagnostic history", failures: &failures
        ) {
            let history = SessionHistoryFake()
            let target = DiscardingTargetCaptureFake(
                snapshot: .init(id: UUID(), applicationName: "TextEdit")
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: target,
                textProcessor: FailingVoiceTextProcessor(
                    failure: .init(
                        userFailure: .providerNotConfigured,
                        providerDiagnostic: .init(
                            provider: "doubao",
                            requestID: "provider-log-id",
                            code: "invalidCredential",
                            statusCode: "401",
                            message: "invalid api key"
                        )
                    )),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let presentation = await terminal.value
            await sessions.shutdown()
            let record = await history.records.first
            if case .failed(_, let failure) = presentation?.activity {
                try expect(failure == .providerNotConfigured)
            } else {
                throw SpecFailure(message: "provider failure did not reach terminal UI state")
            }
            try expect(record?.providerRequestID == "provider-log-id")
            try expect(record?.providerErrorCode == "invalidCredential")
            try expect(record?.providerOperation == "transcription")
            try expect(record?.providerStatusCode == "401")
            try expect(
                record?.providerMessage == nil,
                "untrusted provider response text entered session history"
            )
            try expect(record?.transcriptionProvider == "doubao")
            try expect(record?.applicationName == nil)
            let discardedCount = await target.discardedCount
            try expect(discardedCount == 1)
        }

        await runAsync(
            "history persistence failure is visible on the terminal session", failures: &failures
        ) {
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "仍可使用"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(failureNotice: .writeFailed(reason: "磁盘不可用"))
            )
            let noticePresentation = Task<VoiceInputPresentation?, Never> {
                for await presentation in await sessions.observe() {
                    if presentation.notice
                        == .persistenceFailure(.writeFailed(reason: "磁盘不可用"))
                    {
                        return presentation
                    }
                }
                return nil
            }
            await sessions.send(.pressed)
            await sessions.send(.released)
            let presentation = await noticePresentation.value
            try expect(
                presentation?.notice
                    == .persistenceFailure(.writeFailed(reason: "磁盘不可用"))
            )
            try expect(presentation?.activity.pendingText == "仍可使用")
        }

        await runAsync(
            "voice text processing owns Doubao failure normalization", failures: &failures
        ) {
            let cases: [(DoubaoASRFailureKind, VoiceInputFailure)] = [
                (.invalidCredential, .providerAuthenticationFailed),
                (.silence, .noSpeechDetected),
                (.emptyAudio, .providerReceivedNoAudio),
                (.emptyTranscript, .providerReturnedNoText),
                (.resourceNotActivated, .providerResourceUnavailable),
                (.rateLimited, .providerRateLimited),
                (.network, .networkUnavailable),
                (.serverBusy, .providerUnavailable),
                (.serviceUnavailable, .providerUnavailable),
                (.cancelled, .transcriptionFailed),
                (.invalidRequest, .transcriptionFailed),
                (.invalidAudioFormat, .transcriptionFailed),
                (.invalidResponse, .transcriptionFailed),
            ]

            for (kind, expectedFailure) in cases {
                let processor = DefaultVoiceTextProcessor(
                    configuration: VoiceInputConfigurationController(),
                    doubao: DoubaoFailureTranscriber(
                        failure: .init(
                            kind: kind,
                            providerRequestID: "doubao-mapping-log"
                        )),
                    refinement: OptionalTextRefinementPipeline(
                        refiner: DeepSeekRefinerFake(result: .success(.init(text: "unused")))
                    )
                )
                do {
                    _ = try await processor.process(specAudio, snapshot: .empty) { _ in }
                    throw SpecFailure(message: "\(kind.rawValue) escaped the processing seam")
                } catch let failure as VoiceTextProcessingFailure {
                    try expect(failure.userFailure == expectedFailure)
                    try expect(
                        failure.providerDiagnostic
                            == .init(
                                provider: "doubao",
                                operation: .transcription,
                                requestID: "doubao-mapping-log",
                                code: kind.rawValue
                            ))
                }
            }
        }

        await runAsync(
            "credential-store failures remain actionable provider diagnostics", failures: &failures
        ) {
            let processor = DefaultVoiceTextProcessor(
                configuration: VoiceInputConfigurationController(),
                doubao: CredentialFailureTranscriber(error: .interactionUnavailable),
                refinement: OptionalTextRefinementPipeline(
                    refiner: DeepSeekRefinerFake(result: .success(.init(text: "unused")))
                )
            )
            do {
                _ = try await processor.process(specAudio, snapshot: .empty) { _ in }
                throw SpecFailure(message: "credential-store failure escaped the processing seam")
            } catch let failure as VoiceTextProcessingFailure {
                try expect(failure.userFailure == .providerCredentialUnavailable)
                try expect(
                    failure.providerDiagnostic
                        == .init(
                            provider: "doubao",
                            operation: .credentialAccess,
                            requestID: nil,
                            code: "credential.interactionUnavailable"
                        ))
            }
        }
    }
}
