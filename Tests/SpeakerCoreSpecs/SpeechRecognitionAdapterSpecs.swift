import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum SpeechRecognitionAdapterSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        run(
            "speech recognition adapter retains profiles and rejects incompatible models",
            failures: &failures
        ) {
            var settings = SpeechRecognitionProviderSettings()
            try expect(settings.selectedProfile == .doubao)
            try settings.select(.init(provider: .qwen, region: .singapore))
            try settings.select(.init(provider: .openAI, model: "gpt-4o-mini-transcribe"))
            let restored = try JSONDecoder().decode(
                SpeechRecognitionProviderSettings.self, from: JSONEncoder().encode(settings))
            try expect(restored.profile(for: .qwen).region == .singapore)
            try expect(restored.selectedProfile.credentialProviderID == .openAITranscription)
            do {
                _ = try SpeechRecognitionProfile(provider: .openAI, model: "gpt-5.6").validated()
                throw SpecFailure(message: "chat model accepted for speech")
            } catch let failure as SpeechRecognitionFailure {
                try expect(failure.kind == .invalidConfiguration)
            }
        }

        run(
            "speech recognition adapter preserves inactive retired models without blocking valid selection",
            failures: &failures
        ) {
            let retired = SpeechRecognitionProfile(
                provider: .qwen, model: "retired-model", region: .singapore)
            var settings = SpeechRecognitionProviderSettings(
                selectedProvider: .openAI, profiles: ["qwen": retired])
            let validated = try settings.validated()
            try expect(validated.profile(for: .qwen) == retired)
            try settings.select(.doubao)
            let switched = try settings.validated()
            try expect(switched.selectedProfile == .doubao)
            try expect(switched.profile(for: .qwen) == retired)
            settings.selectedProvider = .qwen
            do {
                _ = try settings.validated()
                throw SpecFailure(message: "active retired model was accepted")
            } catch let failure as SpeechRecognitionFailure {
                try expect(failure.kind == .invalidConfiguration)
            }
            let mismatched = SpeechRecognitionProviderSettings(profiles: ["openai": retired])
            do {
                _ = try mismatched.validated()
                throw SpecFailure(message: "mismatched provider profile was accepted")
            } catch let failure as SpeechRecognitionFailure {
                try expect(failure.kind == .invalidConfiguration)
            }
        }

        await runAsync(
            "speech recognition adapter uploads valid complete WAV to OpenAI with separate credential",
            failures: &failures
        ) {
            let transport = SpeechRecognitionTransportFake()
            let client = makeClient(transport)
            let pcm = Data([1, 0, 255, 127])
            let result = try await client.transcribe(
                stream(pcm), context: context(.openAI, hotwords: ["Speaker", "千问"]))
            try expect(result.text == "完整文本")
            let requests = await transport.requests
            try expect(requests.count == 1)
            let request = requests[0]
            try expect(
                request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer audio-key")
            let body = try require(request.httpBody, "multipart body missing")
            let text = String(decoding: body, as: UTF8.self)
            try expect(text.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
            try expect(text.contains("Speaker, 千问"))
            let wav = SpeechRecognitionWAV.encode(pcm)
            try expect(body.range(of: wav) != nil)
            let decodedPCM = try SpeechRecognitionWAV.pcm(from: wav)
            try expect(decodedPCM == pcm)
        }

        await runAsync(
            "speech recognition adapter binds Qwen region credential and Base64 audio",
            failures: &failures
        ) {
            for region in QwenASRRegion.allCases {
                let transport = SpeechRecognitionTransportFake(response: qwenResponse())
                let client = makeClient(transport)
                let pcm = Data([1, 0, 2, 0])
                _ = try await client.transcribe(
                    stream(pcm), context: context(.qwen, region: region, hotwords: ["Speaker"]))
                let requests = await transport.requests
                try expect(requests.count == 1)
                let request = requests[0]
                try expect(
                    request.url?.host
                        == (region == .beijing
                            ? "dashscope.aliyuncs.com" : "dashscope-intl.aliyuncs.com"))
                try expect(
                    request.value(forHTTPHeaderField: "Authorization")
                        == "Bearer \(region.rawValue)-key")
                let object =
                    try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                try expect(object["model"] as? String == "qwen3-asr-flash")
                try expect(object["stream"] as? Bool == false)
                let options = object["asr_options"] as! [String: Any]
                try expect(options["language"] == nil)
                try expect(options["enable_itn"] as? Bool == true)
                let messages = object["messages"] as! [[String: Any]]
                try expect(messages[0]["role"] as? String == "system")
                let content = messages[1]["content"] as! [[String: Any]]
                let audio = content[0]["input_audio"] as! [String: Any]
                let url = audio["data"] as! String
                let wav = Data(
                    base64Encoded: String(url.dropFirst("data:audio/wav;base64,".count)))!
                let decodedPCM = try SpeechRecognitionWAV.pcm(from: wav)
                try expect(decodedPCM == pcm)
            }
        }

        await runAsync(
            "speech recognition adapter leaves existing Doubao stream intact", failures: &failures
        ) {
            let transport = SpeechRecognitionTransportFake()
            let doubao = StreamingContextualTranscriberFake(text: "豆包结果")
            let client = CredentialedSpeechTranscriber(
                credentials: ProviderCredentialStoreFake(), doubao: doubao, transport: transport)
            let result = try await client.transcribe(
                stream(Data([1, 0])), context: context(.doubao))
            try expect(result.text == "豆包结果")
            let requests = await transport.requests
            try expect(requests.isEmpty)
            let calls = await doubao.contextCalls
            try expect(calls.count == 1)
        }

        await runAsync(
            "speech recognition adapter refuses absent audio keys without fallback",
            failures: &failures
        ) {
            let transport = SpeechRecognitionTransportFake()
            let client = CredentialedSpeechTranscriber(
                credentials: ProviderCredentialStoreFake(values: [
                    .openAI: "text-only-key", .doubao: "doubao-key",
                ]),
                doubao: StreamingContextualTranscriberFake(text: "fallback"), transport: transport)
            do {
                _ = try await client.transcribe(stream(Data([1, 0])), context: context(.openAI))
                throw SpecFailure(message: "text credential was reused for audio")
            } catch let failure as SpeechRecognitionFailure {
                try expect(failure.kind == .missingCredential)
                try expect(failure.providerDiagnostic.provider == "openai")
            }
            let requests = await transport.requests
            try expect(requests.isEmpty)
        }

        await runAsync(
            "speech recognition adapter rejects overlength odd and malformed audio before upload",
            failures: &failures
        ) {
            for (provider, bytes, expected) in [
                (
                    SpeechRecognitionProviderID.qwen, Data(repeating: 0, count: 180 * 32_000 + 2),
                    SpeechRecognitionFailureKind.audioTooLarge
                ),
                (.openAI, Data(repeating: 0, count: 300 * 32_000 + 2), .audioTooLarge),
                (.openAI, Data([1]), .invalidAudio),
                (.qwen, Data(), .invalidAudio),
            ] {
                let transport = SpeechRecognitionTransportFake()
                do {
                    _ = try await makeClient(transport).transcribe(
                        stream(bytes), context: context(provider))
                    throw SpecFailure(message: "invalid audio was sent")
                } catch let failure as SpeechRecognitionFailure {
                    try expect(failure.kind == expected)
                }
                let requests = await transport.requests
                try expect(requests.isEmpty)
            }
            var wav = SpeechRecognitionWAV.encode(Data([1, 0]))
            wav[24] = 0
            do {
                _ = try await makeClient(SpeechRecognitionTransportFake()).transcribe(
                    .init(data: wav, duration: .seconds(1), peakPower: -10),
                    context: context(.openAI))
                throw SpecFailure(message: "mislabeled WAV accepted")
            } catch let failure as SpeechRecognitionFailure {
                try expect(failure.kind == .invalidAudio)
            }
        }

        await runAsync(
            "speech recognition adapter rejects partial empty malformed and oversized responses",
            failures: &failures
        ) {
            let cases:
                [(
                    SpeechRecognitionProviderID, ChatCompletionTransportResponse,
                    SpeechRecognitionFailureKind
                )] = [
                    (.qwen, qwenResponse(finish: "length"), .invalidResponse),
                    (
                        .openAI, .init(statusCode: 200, body: Data(#"{"text":" "}"#.utf8)),
                        .emptyResponse
                    ),
                    (
                        .openAI,
                        .init(
                            statusCode: 200,
                            body: Data(#"{"error":{"message":"private"},"text":"unsafe"}"#.utf8)),
                        .invalidResponse
                    ),
                    (
                        .openAI, .init(statusCode: 200, body: Data("not JSON".utf8)),
                        .invalidResponse
                    ),
                    (
                        .openAI,
                        .init(
                            statusCode: 200,
                            body: Data(
                                repeating: 0,
                                count: CredentialedSpeechTranscriber.maximumResponseByteCount + 1)),
                        .responseTooLarge
                    ),
                    (
                        .qwen,
                        .init(
                            statusCode: 401,
                            body: Data(#"{"message":"private transcript secret-key"}"#.utf8)),
                        .authentication
                    ),
                    (.openAI, .init(statusCode: 429, body: Data()), .rateLimited),
                    (
                        .openAI,
                        .init(
                            statusCode: 307, headers: ["Location": "https://other.invalid"],
                            body: Data()), .rejected
                    ),
                ]
            for (provider, response, expected) in cases {
                let transport = SpeechRecognitionTransportFake(response: response)
                do {
                    _ = try await makeClient(transport).transcribe(
                        stream(Data([1, 0])), context: context(provider))
                    throw SpecFailure(message: "unsafe response accepted")
                } catch let failure as SpeechRecognitionFailure {
                    try expect(failure.kind == expected)
                    try expect(!String(describing: failure).contains("private"))
                }
                let requests = await transport.requests
                try expect(requests.count == 1)
            }
        }

        await runAsync(
            "speech recognition adapter cancellation while collecting sends no request",
            failures: &failures
        ) {
            let transport = SpeechRecognitionTransportFake()
            let pair = AsyncStream<Data>.makeStream()
            let client = makeClient(transport)
            let task = Task { try await client.transcribe(pair.stream, context: context(.openAI)) }
            pair.continuation.yield(Data([1, 0]))
            task.cancel()
            pair.continuation.finish()
            do {
                _ = try await task.value
                throw SpecFailure(message: "cancelled collection returned")
            } catch is CancellationError {}
            let requests = await transport.requests
            try expect(requests.isEmpty)
        }

        await runAsync(
            "speech recognition adapter cancellation discards late complete response",
            failures: &failures
        ) {
            let transport = SpeechRecognitionTransportFake(holdsResponse: true)
            let client = makeClient(transport)
            let task = Task {
                try await client.transcribe(stream(Data([1, 0])), context: context(.openAI))
            }
            let didStart = await eventually(before: .seconds(2)) {
                await transport.requests.count == 1
            }
            try expect(didStart)
            task.cancel()
            await transport.finish()
            do {
                _ = try await task.value
                throw SpecFailure(message: "late cancelled response returned")
            } catch is CancellationError {}
        }

        await runAsync(
            "speech recognition adapter live transport refuses redirects and bounds received bytes",
            failures: &failures
        ) {
            for scenario in ["redirect", "chunked", "declared"] {
                let configuration = ProviderURLSessionFactory.ephemeralConfiguration()
                configuration.protocolClasses = [SpeechRecognitionBoundaryURLProtocol.self]
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let transport = URLSessionSpeechRecognitionTransport(session: session)
                var request = URLRequest(url: URL(string: "https://asr.invalid/\(scenario)")!)
                request.httpMethod = "POST"
                request.setValue("Bearer fixture-key", forHTTPHeaderField: "Authorization")
                request.httpBody = Data([1, 0])
                do {
                    let response = try await transport.send(request)
                    try expect(scenario == "redirect" && response.statusCode == 307)
                } catch let failure as SpecFailure {
                    throw failure
                } catch {
                    try expect(scenario != "redirect")
                }
            }
        }

        await runAsync(
            "speech recognition adapter rejects completed audio when capture validation fails",
            failures: &failures
        ) {
            for provider in [SpeechRecognitionProviderID.openAI, .qwen] {
                let completion = AudioCaptureCompletionGate()
                await completion.reject()
                let transport = SpeechRecognitionTransportFake()
                do {
                    _ = try await makeClient(transport).transcribe(
                        stream(Data([1, 0])),
                        context: context(provider, completion: completion))
                    throw SpecFailure(message: "rejected capture was uploaded")
                } catch is CancellationError {}
                let requests = await transport.requests
                try expect(requests.isEmpty)
            }
        }

        await runAsync(
            "speech recognition adapter accepts validated capture and preserves limits before approval",
            failures: &failures
        ) {
            let completion = AudioCaptureCompletionGate()
            let transport = SpeechRecognitionTransportFake()
            let client = makeClient(transport)
            await completion.accept()
            let result = try await client.transcribe(
                stream(Data([1, 0])), context: context(.openAI, completion: completion))
            try expect(result.text == "完整文本")
            let requests = await transport.requests
            try expect(requests.count == 1)

            let unapproved = AudioCaptureCompletionGate()
            let oversized = Data(repeating: 0, count: 180 * 32_000 + 2)
            do {
                _ = try await client.transcribe(
                    stream(oversized), context: context(.qwen, completion: unapproved))
                throw SpecFailure(message: "oversized recording waited for capture approval")
            } catch let failure as SpeechRecognitionFailure {
                try expect(failure.kind == .audioTooLarge)
            }
        }

        await runAsync(
            "speech recognition adapter cancellation with unapproved capture never uploads",
            failures: &failures
        ) {
            let completion = AudioCaptureCompletionGate()
            let transport = SpeechRecognitionTransportFake()
            let client = makeClient(transport)
            let task = Task {
                try await client.transcribe(
                    stream(Data([1, 0])), context: context(.openAI, completion: completion))
            }
            task.cancel()
            do {
                _ = try await task.value
                throw SpecFailure(message: "cancelled capture approval returned")
            } catch is CancellationError {}
            await completion.accept()
            let requests = await transport.requests
            try expect(requests.isEmpty)
        }
    }

    private static func makeClient(_ transport: any SpeechRecognitionTransport)
        -> CredentialedSpeechTranscriber
    {
        .init(
            credentials: ProviderCredentialStoreFake(values: [
                .openAI: "text-key", .openAITranscription: "audio-key",
                .qwenASRBeijing: "beijing-key", .qwenASRSingapore: "singapore-key",
            ]), doubao: StreamingContextualTranscriberFake(text: "doubao"), transport: transport)
    }

    private static func context(
        _ provider: SpeechRecognitionProviderID, region: QwenASRRegion = .beijing,
        hotwords: [String] = [], completion: AudioCaptureCompletionGate? = nil
    ) -> SpeechTranscriptionContext {
        .init(
            hotwords: hotwords, purpose: .defaultSmoothing,
            recognitionProvider: .init(provider: provider, region: region),
            audioCaptureCompletion: completion)
    }

    private static func stream(_ pcm: Data) -> AsyncStream<Data> {
        AsyncStream {
            $0.yield(pcm)
            $0.finish()
        }
    }

    private static func qwenResponse(finish: String = "stop") -> ChatCompletionTransportResponse {
        .init(
            statusCode: 200,
            body: Data(
                "{\"id\":\"qwen-request\",\"choices\":[{\"finish_reason\":\"\(finish)\",\"message\":{\"role\":\"assistant\",\"content\":\"完整文本\"}}]}"
                    .utf8))
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SpecFailure(message: message) }
        return value
    }
}

private final class SpeechRecognitionBoundaryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/redirect" {
            let destination = URL(string: "https://credential-leak.invalid/target")!
            let response = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        } else {
            let headers = url.path == "/declared" ? ["Content-Length": "1048577"] : [:]
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 1_048_577))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor SpeechRecognitionTransportFake: SpeechRecognitionTransport {
    let response: ChatCompletionTransportResponse
    let holdsResponse: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []

    init(
        response: ChatCompletionTransportResponse = .init(
            statusCode: 200, headers: ["x-request-id": "openai-request"],
            body: Data(#"{"text":"完整文本"}"#.utf8)), holdsResponse: Bool = false
    ) {
        self.response = response
        self.holdsResponse = holdsResponse
    }

    func send(_ request: URLRequest) async throws -> ChatCompletionTransportResponse {
        requests.append(request)
        if holdsResponse { await withCheckedContinuation { continuation = $0 } }
        return response
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
