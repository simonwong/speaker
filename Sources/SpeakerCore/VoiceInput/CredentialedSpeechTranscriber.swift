import Foundation

public enum SpeechRecognitionFailureKind: String, Sendable {
    case missingCredential, credentialUnavailable, invalidConfiguration, audioTooLarge, invalidAudio
    case responseTooLarge, invalidResponse, emptyResponse, authentication, rateLimited, rejected
    case transport
}

public struct SpeechRecognitionFailure: Error, Equatable, Sendable {
    public let provider: SpeechRecognitionProviderID
    public let kind: SpeechRecognitionFailureKind
    public let code: String?
    public let requestID: String?
    public let httpStatusCode: Int?

    public init(
        provider: SpeechRecognitionProviderID, kind: SpeechRecognitionFailureKind,
        code: String? = nil, requestID: String? = nil, httpStatusCode: Int? = nil
    ) {
        self.provider = provider
        self.kind = kind
        self.code = Self.safeIdentifier(code)
        self.requestID = Self.safeIdentifier(requestID)
        self.httpStatusCode = httpStatusCode
    }

    public var userFailure: VoiceInputFailure {
        switch kind {
        case .missingCredential: .providerNotConfigured
        case .credentialUnavailable: .providerCredentialUnavailable
        case .authentication: .providerAuthenticationFailed
        case .rateLimited: .providerRateLimited
        case .audioTooLarge: .recordingLimitReached
        case .invalidAudio: .audioProcessingFailed
        case .emptyResponse: .providerReturnedNoText
        case .transport: .networkUnavailable
        default: .transcriptionFailed
        }
    }

    public var providerDiagnostic: VoiceProviderDiagnostic {
        .init(
            provider: provider.rawValue,
            operation: kind == .missingCredential || kind == .credentialUnavailable
                ? .credentialAccess : .transcription,
            requestID: requestID, code: code ?? kind.rawValue,
            statusCode: httpStatusCode.map(String.init)
        )
    }

    package static func safeIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 200,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            })
        else { return nil }
        return value
    }
}

public protocol SpeechRecognitionTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ChatCompletionTransportResponse
}

public struct URLSessionSpeechRecognitionTransport: SpeechRecognitionTransport {
    private let session: URLSession

    public init(session: URLSession) { self.session = session }
    public init() { session = ProviderURLSessionFactory.makeSession() }

    public func send(_ request: URLRequest) async throws -> ChatCompletionTransportResponse {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(
            for: request, delegate: ChatCompletionRedirectPolicy())
        defer { bytes.task.cancel() }
        return try await withTaskCancellationHandler {
            guard
                response.expectedContentLength
                    <= CredentialedSpeechTranscriber.maximumResponseByteCount
            else { throw SpeechRecognitionTransportError.responseTooLarge }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < CredentialedSpeechTranscriber.maximumResponseByteCount else {
                    throw SpeechRecognitionTransportError.responseTooLarge
                }
                body.append(byte)
            }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw SpeechRecognitionTransportError.invalidResponse
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) {
                $0[String(describing: $1.key)] = String(describing: $1.value)
            }
            return .init(statusCode: response.statusCode, headers: headers, body: body)
        } onCancel: {
            bytes.task.cancel()
        }
    }
}

private enum SpeechRecognitionTransportError: Error {
    case responseTooLarge, invalidResponse
}

public struct CredentialedSpeechTranscriber: ContextualSpeechTranscribing,
    StreamingContextualSpeechTranscribing
{
    public static let maximumResponseByteCount = 1_024 * 1_024
    private static let maximumRequestByteCount = 10_000_000
    private let credentials: any ProviderCredentialStoring
    private let doubao: any ContextualSpeechTranscribing & StreamingContextualSpeechTranscribing
    private let transport: any SpeechRecognitionTransport
    private let realtimeConnector: any RealtimeSpeechConnecting

    public init(
        credentials: any ProviderCredentialStoring,
        doubao: any ContextualSpeechTranscribing & StreamingContextualSpeechTranscribing,
        transport: any SpeechRecognitionTransport = URLSessionSpeechRecognitionTransport(),
        realtimeConnector: any RealtimeSpeechConnecting = URLSessionRealtimeSpeechConnector()
    ) {
        self.credentials = credentials
        self.doubao = doubao
        self.transport = transport
        self.realtimeConnector = realtimeConnector
    }

    public static func maximumAudioSeconds(for provider: SpeechRecognitionProviderID) -> Int? {
        switch provider {
        case .doubao: nil
        case .openAI: 300
        case .qwen: 180
        }
    }

    public func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        try await transcribe(audio, context: .init(hotwords: [], purpose: .defaultSmoothing))
    }

    public func transcribe(
        _ audio: CapturedAudio, context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let profile = try context.recognitionProvider.validated()
        if profile.provider == .doubao {
            return try await doubao.transcribe(audio, context: context)
        }
        guard audio.data.count <= Self.maximumPCMBytes(for: profile.provider) + 65_536 else {
            throw SpeechRecognitionFailure(provider: profile.provider, kind: .audioTooLarge)
        }
        let pcm: Data
        do { pcm = try SpeechRecognitionWAV.pcm(from: audio.data) } catch {
            throw SpeechRecognitionFailure(provider: profile.provider, kind: .invalidAudio)
        }
        if profile.method == .streaming {
            guard pcm.count <= Self.maximumPCMBytes(for: profile.provider) else {
                throw SpeechRecognitionFailure(provider: profile.provider, kind: .audioTooLarge)
            }
            guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
                throw SpeechRecognitionFailure(provider: profile.provider, kind: .invalidAudio)
            }
            let stream = AsyncStream<Data> { continuation in
                continuation.yield(pcm)
                continuation.finish()
            }
            return try await recognizeLive(stream, profile: profile, context: context)
        }
        return try await recognize(pcm, profile: profile, hotwords: context.hotwords)
    }

    public func transcribe(
        _ audioChunks: AsyncStream<Data>, context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let profile = try context.recognitionProvider.validated()
        if profile.provider == .doubao {
            return try await doubao.transcribe(audioChunks, context: context)
        }
        if profile.method == .streaming {
            return try await recognizeLive(audioChunks, profile: profile, context: context)
        }
        var pcm = Data()
        let maximum = Self.maximumPCMBytes(for: profile.provider)
        for await chunk in audioChunks {
            try Task.checkCancellation()
            guard chunk.count <= maximum - pcm.count else {
                throw SpeechRecognitionFailure(provider: profile.provider, kind: .audioTooLarge)
            }
            pcm.append(chunk)
        }
        try Task.checkCancellation()
        try await context.audioCaptureCompletion?.wait()
        try Task.checkCancellation()
        return try await recognize(pcm, profile: profile, hotwords: context.hotwords)
    }

    private static func maximumPCMBytes(for provider: SpeechRecognitionProviderID) -> Int {
        (maximumAudioSeconds(for: provider) ?? 300) * 32_000
    }

    private func recognize(
        _ pcm: Data, profile: SpeechRecognitionProfile, hotwords: [String]
    ) async throws -> TranscriptionResult {
        let provider = profile.provider
        try Task.checkCancellation()
        guard pcm.count <= Self.maximumPCMBytes(for: provider) else {
            throw SpeechRecognitionFailure(provider: provider, kind: .audioTooLarge)
        }
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
            throw SpeechRecognitionFailure(provider: provider, kind: .invalidAudio)
        }
        let apiKey = try await apiKey(for: profile)
        try Task.checkCancellation()
        let request = try Self.request(pcm, profile: profile, apiKey: apiKey, hotwords: hotwords)
        let response: ChatCompletionTransportResponse
        do { response = try await transport.send(request) } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            let kind: SpeechRecognitionFailureKind
            switch error {
            case SpeechRecognitionTransportError.responseTooLarge: kind = .responseTooLarge
            case SpeechRecognitionTransportError.invalidResponse: kind = .invalidResponse
            default: kind = .transport
            }
            throw SpeechRecognitionFailure(provider: provider, kind: kind)
        }
        try Task.checkCancellation()
        return try Self.result(response, provider: provider)
    }

    private func recognizeLive(
        _ chunks: AsyncStream<Data>, profile: SpeechRecognitionProfile,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        let apiKey = try await apiKey(for: profile)
        try Task.checkCancellation()
        return try await RealtimeSpeechTranscriber(connector: realtimeConnector).transcribe(
            chunks, profile: profile, apiKey: apiKey, context: context)
    }

    private func apiKey(for profile: SpeechRecognitionProfile) async throws -> String {
        let provider = profile.provider
        let apiKey: String
        do {
            guard let stored = try await credentials.apiKey(for: profile.credentialProviderID),
                !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw SpeechRecognitionFailure(provider: provider, kind: .missingCredential) }
            guard stored.utf8.count <= 64 * 1_024,
                !stored.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
            else {
                throw SpeechRecognitionFailure(provider: provider, kind: .credentialUnavailable)
            }
            apiKey = stored
        } catch let failure as SpeechRecognitionFailure { throw failure } catch {
            try Task.checkCancellation()
            throw SpeechRecognitionFailure(provider: provider, kind: .credentialUnavailable)
        }
        return apiKey
    }

    private static func request(
        _ pcm: Data, profile: SpeechRecognitionProfile, apiKey: String, hotwords: [String]
    ) throws -> URLRequest {
        guard hotwords.count <= 1_000,
            hotwords.reduce(0, { $0 + $1.utf8.count }) <= 16_384
        else {
            throw SpeechRecognitionFailure(provider: profile.provider, kind: .invalidConfiguration)
        }
        let wav = SpeechRecognitionWAV.encode(pcm)
        var request = URLRequest(url: profile.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if profile.provider == .openAI {
            let boundary = "Speaker-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(
                    Data(
                        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
                            .utf8))
            }
            field("model", profile.model)
            if !hotwords.isEmpty {
                field("prompt", hotwords.joined(separator: ", "))
            }
            body.append(
                Data(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
                        .utf8))
            body.append(wav)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.setValue(
                "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else {
            var messages: [[String: Any]] = []
            if !hotwords.isEmpty {
                messages.append(["role": "system", "content": hotwords.joined(separator: ", ")])
            }
            messages.append([
                "role": "user",
                "content": [
                    [
                        "type": "input_audio",
                        "input_audio": [
                            "data": "data:audio/wav;base64,\(wav.base64EncodedString())"
                        ],
                    ]
                ],
            ])
            request.httpBody = try JSONSerialization.data(
                withJSONObject: [
                    "model": profile.model, "messages": messages, "stream": false,
                    "asr_options": ["enable_itn": true],
                ], options: [.sortedKeys, .withoutEscapingSlashes])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard (request.httpBody?.count ?? 0) <= maximumRequestByteCount else {
            throw SpeechRecognitionFailure(provider: profile.provider, kind: .audioTooLarge)
        }
        return request
    }

    private static func result(
        _ response: ChatCompletionTransportResponse, provider: SpeechRecognitionProviderID
    ) throws -> TranscriptionResult {
        guard response.body.count <= maximumResponseByteCount else {
            throw SpeechRecognitionFailure(provider: provider, kind: .responseTooLarge)
        }
        let requestID = SpeechRecognitionFailure.safeIdentifier(
            response.header(named: "x-request-id")
                ?? response.header(named: "x-dashscope-request-id"))
        guard (200..<300).contains(response.statusCode) else {
            let kind: SpeechRecognitionFailureKind =
                response.statusCode == 401 || response.statusCode == 403
                ? .authentication
                : response.statusCode == 429 ? .rateLimited : .rejected
            throw SpeechRecognitionFailure(
                provider: provider, kind: kind, requestID: requestID,
                httpStatusCode: response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            object["error"] == nil
        else {
            throw SpeechRecognitionFailure(
                provider: provider, kind: .invalidResponse, requestID: requestID)
        }
        let text: String?
        if provider == .openAI {
            text = object["text"] as? String
        } else {
            guard let choices = object["choices"] as? [[String: Any]], choices.count == 1,
                choices[0]["finish_reason"] as? String == "stop",
                let message = choices[0]["message"] as? [String: Any],
                message["role"] as? String == "assistant",
                message["tool_calls"] == nil,
                message["refusal"] == nil || message["refusal"] is NSNull
            else {
                throw SpeechRecognitionFailure(
                    provider: provider, kind: .invalidResponse, requestID: requestID)
            }
            text = message["content"] as? String
        }
        guard let text else {
            throw SpeechRecognitionFailure(
                provider: provider, kind: .invalidResponse, requestID: requestID)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechRecognitionFailure(
                provider: provider, kind: .emptyResponse, requestID: requestID)
        }
        return .init(
            text: text,
            providerRequestID: requestID
                ?? SpeechRecognitionFailure.safeIdentifier(object["id"] as? String))
    }
}

package enum SpeechRecognitionWAV {
    package static func encode(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32, bytes: Int = 4) {
            for offset in 0..<bytes {
                data.append(UInt8(truncatingIfNeeded: value >> (offset * 8)))
            }
        }
        append(UInt32(pcm.count + 36))
        data.append(Data("WAVEfmt ".utf8))
        append(16)
        append(1, bytes: 2)
        append(1, bytes: 2)
        append(16_000)
        append(32_000)
        append(2, bytes: 2)
        append(16, bytes: 2)
        data.append(Data("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    package static func pcm(from input: Data) throws -> Data {
        let data = Data(input)
        guard data.starts(with: Data("RIFF".utf8)) else { return data }
        func integer(_ start: Int, _ bytes: Int = 4) -> Int {
            (0..<bytes).reduce(0) { $0 | Int(data[start + $1]) << ($1 * 8) }
        }
        guard data.count >= 12, data.subdata(in: 8..<12) == Data("WAVE".utf8),
            integer(4) + 8 == data.count
        else { throw SpeechRecognitionTransportError.invalidResponse }
        var offset = 12
        var formatSeen = false
        var pcm: Data?
        while offset < data.count {
            guard offset + 8 <= data.count else {
                throw SpeechRecognitionTransportError.invalidResponse
            }
            let size = integer(offset + 4)
            let start = offset + 8
            let end = start + size
            guard end + size % 2 <= data.count else {
                throw SpeechRecognitionTransportError.invalidResponse
            }
            let name = data.subdata(in: offset..<(offset + 4))
            if name == Data("fmt ".utf8) {
                guard !formatSeen, size >= 16, integer(start, 2) == 1,
                    integer(start + 2, 2) == 1, integer(start + 4) == 16_000,
                    integer(start + 8) == 32_000, integer(start + 12, 2) == 2,
                    integer(start + 14, 2) == 16
                else { throw SpeechRecognitionTransportError.invalidResponse }
                formatSeen = true
            } else if name == Data("data".utf8) {
                guard formatSeen, pcm == nil else {
                    throw SpeechRecognitionTransportError.invalidResponse
                }
                pcm = data.subdata(in: start..<end)
            }
            offset = end + size % 2
        }
        guard let pcm, formatSeen else { throw SpeechRecognitionTransportError.invalidResponse }
        return pcm
    }
}
