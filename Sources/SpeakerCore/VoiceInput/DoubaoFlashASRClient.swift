import Foundation

public struct DoubaoTranscriptionOptions: Equatable, Sendable {
    public var enablePunctuation: Bool
    public var enableITN: Bool
    public var enableSemanticSmoothing: Bool

    public init(
        enablePunctuation: Bool = true,
        enableITN: Bool = true,
        enableSemanticSmoothing: Bool = true
    ) {
        self.enablePunctuation = enablePunctuation
        self.enableITN = enableITN
        self.enableSemanticSmoothing = enableSemanticSmoothing
    }
}

public struct DoubaoFlashASRConfiguration: Equatable, Sendable {
    public static let defaultEndpoint = URL(
        string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
    )!
    public static let defaultResourceID = "volc.bigasr.auc_turbo"

    public var apiKey: String
    public var resourceID: String
    public var installationID: String
    public var hotwords: [String]
    public var context: String?
    public var options: DoubaoTranscriptionOptions
    public var endpoint: URL

    public init(
        apiKey: String,
        resourceID: String = Self.defaultResourceID,
        installationID: String,
        hotwords: [String] = [],
        context: String? = nil,
        options: DoubaoTranscriptionOptions = .init(),
        endpoint: URL = Self.defaultEndpoint
    ) {
        self.apiKey = apiKey
        self.resourceID = resourceID
        self.installationID = installationID
        self.hotwords = hotwords
        self.context = context
        self.options = options
        self.endpoint = endpoint
    }
}

public struct DoubaoASRTransportResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol DoubaoASRTransport: Sendable {
    func send(_ request: URLRequest) async throws -> DoubaoASRTransportResponse
}

public struct URLSessionDoubaoASRTransport: DoubaoASRTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> DoubaoASRTransportResponse {
        let (body, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }

        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        return DoubaoASRTransportResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }
}

public enum DoubaoASRFailureKind: String, Equatable, Sendable {
    case silence
    case invalidCredential
    case resourceNotActivated
    case rateLimited
    case invalidRequest
    case emptyAudio
    case invalidAudioFormat
    case serverBusy
    case serviceUnavailable
    case network
    case cancelled
    case invalidResponse
    case emptyTranscript
}

public struct DoubaoASRFailure: Error, Equatable, Sendable {
    public let kind: DoubaoASRFailureKind
    public let providerStatusCode: String?
    public let providerRequestID: String?
    public let message: String?

    public init(
        kind: DoubaoASRFailureKind,
        providerStatusCode: String? = nil,
        providerRequestID: String? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.providerStatusCode = providerStatusCode
        self.providerRequestID = providerRequestID
        self.message = message
    }
}

public struct DoubaoFlashASRRequestBody: Encodable, Equatable, Sendable {
    public struct User: Encodable, Equatable, Sendable {
        public let uid: String

        public init(uid: String) {
            self.uid = uid
        }
    }

    public struct Audio: Encodable, Equatable, Sendable {
        public let data: String

        public init(data: String) {
            self.data = data
        }
    }

    public struct RecognitionRequest: Encodable, Equatable, Sendable {
        public let modelName: String
        public let enableITN: Bool
        public let enablePunctuation: Bool
        public let enableSemanticSmoothing: Bool

        public init(
            modelName: String = "bigmodel",
            enableITN: Bool,
            enablePunctuation: Bool,
            enableSemanticSmoothing: Bool
        ) {
            self.modelName = modelName
            self.enableITN = enableITN
            self.enablePunctuation = enablePunctuation
            self.enableSemanticSmoothing = enableSemanticSmoothing
        }

        private enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case enableITN = "enable_itn"
            case enablePunctuation = "enable_punc"
            case enableSemanticSmoothing = "enable_ddc"
        }
    }

    public struct Corpus: Encodable, Equatable, Sendable {
        public let context: String

        public init(context: String) {
            self.context = context
        }
    }

    public let user: User
    public let audio: Audio
    public let request: RecognitionRequest
    public let corpus: Corpus?

    public init(
        user: User,
        audio: Audio,
        request: RecognitionRequest,
        corpus: Corpus? = nil
    ) {
        self.user = user
        self.audio = audio
        self.request = request
        self.corpus = corpus
    }
}

public struct DoubaoFlashASRResponseBody: Decodable, Equatable, Sendable {
    public struct Result: Decodable, Equatable, Sendable {
        public let text: String?

        public init(text: String?) {
            self.text = text
        }
    }

    public let result: Result?

    public init(result: Result?) {
        self.result = result
    }
}

public actor DoubaoFlashASRClient: SpeechTranscribing {
    private static let successStatus = "20000000"

    private let configuration: DoubaoFlashASRConfiguration
    private let transport: any DoubaoASRTransport
    private let requestIDGenerator: @Sendable () -> UUID

    public init(
        configuration: DoubaoFlashASRConfiguration,
        transport: any DoubaoASRTransport = URLSessionDoubaoASRTransport(),
        requestIDGenerator: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.requestIDGenerator = requestIDGenerator
    }

    public func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        guard !audio.data.isEmpty else {
            throw DoubaoASRFailure(kind: .emptyAudio)
        }
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoubaoASRFailure(kind: .invalidCredential)
        }

        let requestID = requestIDGenerator().uuidString
        let request = try makeURLRequest(audioData: audio.data, requestID: requestID)

        let response: DoubaoASRTransportResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
        } catch let failure as DoubaoASRFailure {
            throw failure
        } catch {
            throw DoubaoASRFailure(
                kind: .network,
                providerRequestID: requestID,
                message: Self.safeNetworkMessage(error)
            )
        }

        guard !Task.isCancelled else {
            throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
        }
        let providerStatus = response.header(named: "X-Api-Status-Code")
        let providerMessage = response.header(named: "X-Api-Message")
        let providerRequestID = response.header(named: "X-Tt-Logid") ?? requestID

        guard response.statusCode == 200, providerStatus == Self.successStatus else {
            throw Self.mapFailure(
                httpStatus: response.statusCode,
                providerStatus: providerStatus,
                providerRequestID: providerRequestID,
                providerMessage: providerMessage
            )
        }

        let decoded: DoubaoFlashASRResponseBody
        do {
            decoded = try JSONDecoder().decode(DoubaoFlashASRResponseBody.self, from: response.body)
        } catch {
            throw DoubaoASRFailure(
                kind: .invalidResponse,
                providerStatusCode: providerStatus,
                providerRequestID: providerRequestID
            )
        }

        guard let text = decoded.result?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw DoubaoASRFailure(
                kind: .emptyTranscript,
                providerStatusCode: providerStatus,
                providerRequestID: providerRequestID
            )
        }

        return TranscriptionResult(text: text, providerRequestID: providerRequestID)
    }

    private func makeURLRequest(audioData: Data, requestID: String) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(configuration.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.httpBody = try JSONEncoder().encode(makeRequestBody(audioData: audioData))
        return request
    }

    private func makeRequestBody(audioData: Data) throws -> DoubaoFlashASRRequestBody {
        let corpusContext = try Self.makeCorpusContext(
            hotwords: configuration.hotwords,
            context: configuration.context
        )
        return DoubaoFlashASRRequestBody(
            user: .init(uid: configuration.installationID),
            audio: .init(data: audioData.base64EncodedString()),
            request: .init(
                enableITN: configuration.options.enableITN,
                enablePunctuation: configuration.options.enablePunctuation,
                enableSemanticSmoothing: configuration.options.enableSemanticSmoothing
            ),
            corpus: corpusContext.map(DoubaoFlashASRRequestBody.Corpus.init(context:))
        )
    }

    private static func makeCorpusContext(hotwords: [String], context: String?) throws -> String? {
        let cleanHotwords = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanContext = context?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanHotwords.isEmpty || !(cleanContext?.isEmpty ?? true) else { return nil }

        struct ContextPayload: Encodable {
            struct Hotword: Encodable {
                let word: String
            }

            let hotwords: [Hotword]?
            let context: String?
        }

        let payload = ContextPayload(
            hotwords: cleanHotwords.isEmpty ? nil : cleanHotwords.map(ContextPayload.Hotword.init(word:)),
            context: cleanContext?.isEmpty == false ? cleanContext : nil
        )
        let data = try JSONEncoder().encode(payload)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DoubaoASRFailure(kind: .invalidRequest)
        }
        return encoded
    }

    private static func mapFailure(
        httpStatus: Int,
        providerStatus: String?,
        providerRequestID: String?,
        providerMessage: String?
    ) -> DoubaoASRFailure {
        let normalizedMessage = providerMessage?.lowercased() ?? ""
        let kind: DoubaoASRFailureKind

        switch providerStatus {
        case "20000003":
            kind = .silence
        case "45000001":
            if messageLooksLikeResourceFailure(normalizedMessage) {
                kind = .resourceNotActivated
            } else if messageLooksLikeCredentialFailure(normalizedMessage) {
                kind = .invalidCredential
            } else {
                kind = .invalidRequest
            }
        case "45000002":
            kind = .emptyAudio
        case "45000151":
            kind = .invalidAudioFormat
        case "55000031":
            kind = .serverBusy
        case let code? where code.hasPrefix("550"):
            kind = .serviceUnavailable
        default:
            if messageLooksLikeResourceFailure(normalizedMessage) {
                kind = .resourceNotActivated
            } else if httpStatus == 401 || httpStatus == 403 || messageLooksLikeCredentialFailure(normalizedMessage) {
                kind = .invalidCredential
            } else if httpStatus == 429 || messageLooksLikeRateLimit(normalizedMessage) {
                kind = .rateLimited
            } else if (500...599).contains(httpStatus) {
                kind = .serviceUnavailable
            } else if providerStatus == nil && (200...299).contains(httpStatus) {
                kind = .invalidResponse
            } else {
                kind = .invalidRequest
            }
        }

        return DoubaoASRFailure(
            kind: kind,
            providerStatusCode: providerStatus,
            providerRequestID: providerRequestID,
            message: providerMessage
        )
    }

    private static func messageLooksLikeCredentialFailure(_ message: String) -> Bool {
        message.contains("api key")
            || message.contains("apikey")
            || message.contains("access key")
            || message.contains("unauthorized")
            || message.contains("authentication")
            || message.contains("鉴权")
    }

    private static func messageLooksLikeResourceFailure(_ message: String) -> Bool {
        (message.contains("resource") && (message.contains("not") || message.contains("permission")))
            || message.contains("not activated")
            || message.contains("未开通")
            || message.contains("无权限")
    }

    private static func messageLooksLikeRateLimit(_ message: String) -> Bool {
        message.contains("rate limit")
            || message.contains("too many")
            || message.contains("qps")
            || message.contains("限流")
    }

    private static func safeNetworkMessage(_ error: Error) -> String? {
        guard let urlError = error as? URLError else { return nil }
        return String(describing: urlError.code)
    }
}
