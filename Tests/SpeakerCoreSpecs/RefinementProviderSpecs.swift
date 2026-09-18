import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum RefinementProviderSpecs: CoreSpecDomain {
    private static let response = ChatCompletionTransportResponse(
        statusCode: 200,
        body: Data(
            #"{"choices":[{"message":{"content":"{\"text\":\"结果\"}"},"finish_reason":"stop"}]}"#
                .utf8)
    )

    @MainActor
    static func run(failures: inout [String]) async {
        run("refinement provider legacy settings preserve the DeepSeek model", failures: &failures)
        {
            try expect(RefinementProviderSettings().selectedProfile == .legacyDeepSeek)
            for provider in RefinementProviderID.allCases where provider != .custom {
                var profile = RefinementProviderProfile.defaultProfile(for: provider)
                profile.baseURL = "https://attacker.invalid/v1"
                let validated = try profile.validated()
                try expect(validated.baseURL == RefinementProviderCatalog.baseURL(for: provider))
            }
        }

        run(
            "refinement provider rejects unsafe custom addresses and preserves custom model IDs",
            failures: &failures
        ) {
            let invalid = [
                "http://example.com/v1", "/v1", "https://", "https://a:b@example.com/v1",
                "https://example.com/v1?api_key=secret", "https://example.com/v1#fragment",
                "https://example.com/\nheader", "https://example.com/with space",
                "https://example.com:99999/v1",
                "https://example.com/a/../v1", "https://example.com/v1%2fother",
                "https://example.com/v1%0aheader",
            ]
            for address in invalid {
                do {
                    _ = try RefinementProviderProfile(
                        provider: .custom, modelID: "test", baseURL: address
                    ).validated()
                    throw SpecFailure(message: "invalid custom address was accepted")
                } catch let failure as TextRefinementFailure {
                    try expect(failure.kind == .invalidRequest)
                }
            }
            var builtin = RefinementProviderProfile.defaultProfile(for: .openAI)
            builtin.modelID = "future-model"
            let future = try builtin.validated()
            try expect(future.modelID == "future-model")
            builtin.modelID = "model\nheader"
            do {
                _ = try builtin.validated()
                throw SpecFailure(message: "model control character was accepted")
            } catch let failure as TextRefinementFailure {
                try expect(failure.kind == .invalidRequest)
            }
            let normalized = try RefinementProviderProfile(
                provider: .custom, modelID: "custom/model", baseURL: "https://EXAMPLE.com:443/v1/"
            ).completionEndpoint()
            try expect(normalized.absoluteString == "https://example.com/v1/chat/completions")
        }

        await runAsync(
            "refinement provider never sends an already cancelled request", failures: &failures
        ) {
            let transport = ChatCompletionTransportFake(response: response)
            let client = ChatCompletionRefinementClient(
                configuration: .init(apiKey: "test"), transport: transport)
            let task = Task { try await client.refine("原文", using: .init(mode: .fullRewrite())) }
            task.cancel()
            do {
                _ = try await task.value
                throw SpecFailure(message: "cancelled refinement returned text")
            } catch let failure as TextRefinementFailure {
                try expect(failure.kind == .cancelled)
            }
            _ = try await client.refine("原文", using: .init(mode: .fullRewrite()))
            _ = try await transport.onlyRequest()
        }

        await runAsync(
            "refinement provider requests use only reviewed vendor parameters", failures: &failures
        ) {
            for provider in RefinementProviderID.allCases {
                let profile =
                    provider == .custom
                    ? RefinementProviderProfile(
                        provider: .custom, modelID: "custom-model",
                        baseURL: "https://example.com/v1")
                    : .defaultProfile(for: provider)
                let transport = ChatCompletionTransportFake(response: response)
                let client = ChatCompletionRefinementClient(
                    configuration: try .init(apiKey: "test-key", profile: profile),
                    transport: transport)
                _ = try await client.refine(
                    "原文", using: .init(mode: .conciseCleanup(), provider: profile))
                let request = try await transport.onlyRequest()
                let body =
                    try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let endpoint = try profile.completionEndpoint()
                try expect(request.url == endpoint)
                try expect(body["model"] as? String == profile.modelID)
                try expect(body["stream"] as? Bool == false)
                try expect((body["response_format"] as? [String: String])?["type"] == "json_object")
                try expect(
                    (body["thinking"] != nil) == [.deepSeek, .kimi, .glm].contains(provider))
                try expect((body["temperature"] != nil) == (provider == .deepSeek))
                try expect(
                    (body["max_completion_tokens"] as? Int) == (provider == .openAI ? 2_048 : nil))
                try expect((body["max_tokens"] as? Int) == (provider == .openAI ? nil : 2_048))
            }
        }

        await runAsync(
            "refinement provider credentials stay isolated and custom credentials bind to their address",
            failures: &failures
        ) {
            let store = ProviderCredentialStoreFake(values: [
                .doubao: "audio-key", .deepSeek: "existing-deepseek-key",
            ])
            let custom = RefinementProviderProfile(
                provider: .custom, modelID: "test-model", baseURL: "https://example.com/v1")
            let changed = RefinementProviderProfile(
                provider: .custom, modelID: "test-model", baseURL: "https://other.example.com/v1")
            let transport = ChatCompletionTransportFake(response: response)
            let refiner = CredentialedTextRefiner(credentials: store, transport: transport)
            for provider in [RefinementProviderID.openAI, .kimi, .glm] {
                let profile = RefinementProviderProfile.defaultProfile(for: provider)
                let keyAbsent = try await !refiner.hasAPIKey(for: profile)
                try expect(keyAbsent)
                try await refiner.saveAPIKey("key-\(provider.rawValue)", for: profile)
                let keySaved = try await refiner.hasAPIKey(for: profile)
                try expect(keySaved)
                let selectedTransport = ChatCompletionTransportFake(response: response)
                let selectedRefiner = CredentialedTextRefiner(
                    credentials: store, transport: selectedTransport)
                _ = try await selectedRefiner.refine(
                    "原文", using: .init(mode: .fullRewrite(), provider: profile))
                let selectedRequest = try await selectedTransport.onlyRequest()
                try expect(
                    selectedRequest.value(forHTTPHeaderField: "Authorization")
                        == "Bearer key-\(provider.rawValue)")
            }
            try await refiner.saveAPIKey("custom-key", for: custom)
            let customKeyAvailable = try await refiner.hasAPIKey(for: custom)
            try expect(customKeyAvailable)
            let changedEndpointHasNoKey = try await !refiner.hasAPIKey(for: changed)
            try expect(changedEndpointHasNoKey)
            do {
                _ = try await refiner.refine(
                    "不应发送", using: .init(mode: .fullRewrite(), provider: changed))
                throw SpecFailure(message: "custom key crossed its saved address")
            } catch let failure as TextRefinementFailure {
                try expect(failure.kind == .invalidCredential)
            }
            var otherModel = custom
            otherModel.modelID = "other-model"
            _ = try await refiner.refine(
                "原文", using: .init(mode: .fullRewrite(), provider: otherModel))
            let request = try await transport.onlyRequest()
            let endpoint = try custom.completionEndpoint()
            try expect(request.url == endpoint)
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer custom-key")
            try await refiner.deleteAPIKey(for: .custom)
            let customKeyDeleted = try await !refiner.hasAPIKey(for: custom)
            try expect(customKeyDeleted)
            let deepSeekKeyPreserved =
                try await store.apiKey(for: .deepSeek) == "existing-deepseek-key"
            try expect(deepSeekKeyPreserved)
            let doubaoKeyPreserved = try await store.apiKey(for: .doubao) == "audio-key"
            try expect(doubaoKeyPreserved)
            let openAIKeyPreserved = try await store.apiKey(for: .openAI) == "key-openai"
            try expect(openAIKeyPreserved)
        }

        await runAsync(
            "refinement provider rejects byte budgets before decode and never sends an oversized request",
            failures: &failures
        ) {
            let transport = ChatCompletionTransportFake(response: response)
            let client = ChatCompletionRefinementClient(
                configuration: .init(apiKey: "key"), transport: transport)
            for text in [
                String(repeating: "x", count: 262_145), String(repeating: "\"", count: 150_000),
            ] {
                do {
                    _ = try await client.refine(text, using: .init(mode: .fullRewrite()))
                    throw SpecFailure(message: "oversized request was accepted")
                } catch let failure as TextRefinementFailure {
                    try expect(failure.kind == .invalidRequest)
                }
            }
            _ = try await client.refine("原文", using: .init(mode: .fullRewrite()))
            _ = try await transport.onlyRequest()
            let oversized = ChatCompletionRefinementClient(
                configuration: .init(apiKey: "key"),
                transport: ChatCompletionTransportFake(
                    response: .init(statusCode: 200, body: Data(repeating: 32, count: 1_048_577)))
            )
            do {
                _ = try await oversized.refine("原文", using: .init(mode: .fullRewrite()))
                throw SpecFailure(message: "oversized response was decoded")
            } catch let failure as TextRefinementFailure {
                try expect(failure.kind == .outputTooLarge)
            }
        }

        await runAsync(
            "refinement provider refuses explicit refusal or tool output despite normal stop",
            failures: &failures
        ) {
            for field in ["\"refusal\":\"denied\"", "\"tool_calls\":[{}]", "\"function_call\":{}"] {
                let body = Data(
                    "{\"choices\":[{\"message\":{\"content\":\"{\\\"text\\\":\\\"unsafe\\\"}\",\(field)},\"finish_reason\":\"stop\"}]}"
                        .utf8)
                let client = ChatCompletionRefinementClient(
                    configuration: .init(apiKey: "key"),
                    transport: ChatCompletionTransportFake(
                        response: .init(statusCode: 200, body: body)))
                do {
                    _ = try await client.refine("原文", using: .init(mode: .fullRewrite()))
                    throw SpecFailure(message: "refusal or tool output was accepted")
                } catch let failure as TextRefinementFailure {
                    try expect([.contentFiltered, .toolCalls].contains(failure.kind))
                }
            }
        }

        await runAsync(
            "refinement provider live transport bounds chunked bytes and rejects redirects",
            failures: &failures
        ) {
            for scenario in ["oversized", "redirect"] {
                let configuration = ProviderURLSessionFactory.ephemeralConfiguration()
                configuration.protocolClasses = [RefinementBoundaryURLProtocol.self]
                configuration.timeoutIntervalForRequest = 2
                configuration.timeoutIntervalForResource = 2
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let transport = URLSessionChatCompletionTransport(session: session)
                var request = URLRequest(
                    url: URL(string: "https://refinement.invalid/\(scenario)")!)
                request.httpMethod = "POST"
                request.httpBody = Data("test-transcript".utf8)
                request.setValue("Bearer test-credential", forHTTPHeaderField: "Authorization")
                do {
                    let result = try await transport.send(request)
                    try expect(
                        scenario == "redirect" && result.statusCode == 307,
                        "redirect was followed or large body accepted")
                } catch let failure as TextRefinementFailure {
                    try expect(scenario == "oversized" && failure.kind == .outputTooLarge)
                }
            }
        }
    }
}

private final class RefinementBoundaryURLProtocol: URLProtocol, @unchecked Sendable {
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
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 1_048_577))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
