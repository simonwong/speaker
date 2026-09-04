import Foundation

package struct DoubaoTranscriptionOptions: Equatable, Sendable {
    package var enablePunctuation: Bool
    package var enableITN: Bool
    package var enableSemanticSmoothing: Bool

    package init(
        enablePunctuation: Bool = true,
        enableITN: Bool = true,
        enableSemanticSmoothing: Bool = true
    ) {
        self.enablePunctuation = enablePunctuation
        self.enableITN = enableITN
        self.enableSemanticSmoothing = enableSemanticSmoothing
    }
}

public enum DoubaoStreamingResource: String, CaseIterable, Codable, Sendable {
    case model2Duration = "volc.seedasr.sauc.duration"
    case model2Concurrent = "volc.seedasr.sauc.concurrent"
    case model1Duration = "volc.bigasr.sauc.duration"
    case model1Concurrent = "volc.bigasr.sauc.concurrent"

    public static let `default` = DoubaoStreamingResource.model2Duration

    /// Doubao's own product name for the resource. It identifies the billing
    /// plan in diagnostics and settings and is not Speaker presentation copy.
    public var displayName: String {
        switch self {
        case .model2Duration: "流式模型 2.0 · 小时版"
        case .model2Concurrent: "流式模型 2.0 · 并发版"
        case .model1Duration: "流式模型 1.0 · 小时版"
        case .model1Concurrent: "流式模型 1.0 · 并发版"
        }
    }
}

package struct DoubaoStreamingASRConfiguration: Equatable, Sendable {
    package static let defaultEndpoint = URL(
        string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    )!

    package var apiKey: String
    package var resource: DoubaoStreamingResource
    package var requestUserID: String
    package var hotwords: [String]
    package var options: DoubaoTranscriptionOptions
    package var endpoint: URL

    package init(
        apiKey: String,
        resource: DoubaoStreamingResource = .default,
        requestUserID: String,
        hotwords: [String] = [],
        options: DoubaoTranscriptionOptions = .init(),
        endpoint: URL = Self.defaultEndpoint
    ) {
        self.apiKey = apiKey
        self.resource = resource
        self.requestUserID = requestUserID
        self.hotwords = hotwords
        self.options = options
        self.endpoint = endpoint
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

public struct DoubaoWebSocketMetadata: Equatable, Sendable {
    public let httpStatusCode: Int?
    public let providerRequestID: String?
    public let providerMessage: String?
    public let webSocketCloseCode: Int?
    /// Doubao's structured status code from the `X-Api-Status-Code` handshake
    /// header, when the handshake itself was rejected.
    public let providerStatusCode: String?

    public init(
        httpStatusCode: Int? = nil,
        providerRequestID: String? = nil,
        providerMessage: String? = nil,
        webSocketCloseCode: Int? = nil,
        providerStatusCode: String? = nil
    ) {
        self.httpStatusCode = httpStatusCode
        self.providerRequestID = providerRequestID
        self.providerMessage = providerMessage
        self.webSocketCloseCode = webSocketCloseCode
        self.providerStatusCode = providerStatusCode
    }
}

public protocol DoubaoWebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func metadata() async -> DoubaoWebSocketMetadata
    func close() async
}

public protocol DoubaoWebSocketConnecting: Sendable {
    func connect(_ request: URLRequest) async throws -> any DoubaoWebSocketConnection
}

public struct URLSessionDoubaoWebSocketConnector: DoubaoWebSocketConnecting {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public init() {
        session = ProviderURLSessionFactory.makeSession()
    }

    public func connect(_ request: URLRequest) async throws -> any DoubaoWebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 2 * 1_024 * 1_024
        task.resume()
        return URLSessionDoubaoWebSocketConnection(task: task)
    }
}

private actor URLSessionDoubaoWebSocketConnection: DoubaoWebSocketConnection {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case let .data(data):
            return data
        case let .string(text):
            return Data(text.utf8)
        @unknown default:
            throw DoubaoASRFailure(kind: .invalidResponse)
        }
    }

    func metadata() -> DoubaoWebSocketMetadata {
        let response = task.response as? HTTPURLResponse
        let closeCode = task.closeCode
        return DoubaoWebSocketMetadata(
            httpStatusCode: response?.statusCode,
            providerRequestID: response.flatMap {
                Self.header("X-Tt-Logid", in: $0)
            },
            providerMessage: response.flatMap {
                Self.header("X-Api-Message", in: $0)
            },
            webSocketCloseCode: closeCode == .invalid
                ? nil
                : closeCode.rawValue,
            providerStatusCode: response.flatMap {
                Self.header("X-Api-Status-Code", in: $0)
            }
        )
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first {
            String(describing: $0.key).caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value) }
    }
}

private struct DoubaoStreamingRequestBody: Encodable, Sendable {
    struct User: Encodable, Sendable { let uid: String }

    struct Audio: Encodable, Sendable {
        let format = "pcm"
        let codec = "raw"
        let rate = 16_000
        let bits = 16
        let channel = 1
    }

    struct RecognitionRequest: Encodable, Sendable {
        struct Corpus: Encodable, Sendable {
            let context: String
        }

        let modelName = "bigmodel"
        let enableITN: Bool
        let enablePunctuation: Bool
        let enableSemanticSmoothing: Bool
        let corpus: Corpus?

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case enableITN = "enable_itn"
            case enablePunctuation = "enable_punc"
            case enableSemanticSmoothing = "enable_ddc"
            case corpus
        }
    }

    let user: User
    let audio: Audio
    let request: RecognitionRequest
}

/// Connects to Doubao and hands the socket to a `DoubaoStreamingExchange`.
///
/// The client owns configuration, request identity, and the handshake. Frame
/// bytes live in `DoubaoStreamingFrameCodec`, failure kinds come from
/// `DoubaoFailureClassifier`, and the concurrent send/receive protocol is the
/// exchange's job.
package actor DoubaoStreamingASRClient {
    private let configuration: DoubaoStreamingASRConfiguration
    private let connector: any DoubaoWebSocketConnecting
    private let requestIDGenerator: @Sendable () -> UUID
    private let runtimeDiagnostics: VoiceProviderRuntimeDiagnostics?
    private let runtimeOperation: VoiceProviderRuntimeOperation

    package init(
        configuration: DoubaoStreamingASRConfiguration,
        connector: any DoubaoWebSocketConnecting = URLSessionDoubaoWebSocketConnector(),
        requestIDGenerator: @escaping @Sendable () -> UUID = UUID.init,
        runtimeDiagnostics: VoiceProviderRuntimeDiagnostics? = nil,
        runtimeOperation: VoiceProviderRuntimeOperation = .voiceInput
    ) {
        self.configuration = configuration
        self.connector = connector
        self.requestIDGenerator = requestIDGenerator
        self.runtimeDiagnostics = runtimeDiagnostics
        self.runtimeOperation = runtimeOperation
    }

    package func transcribe(_ chunks: AsyncStream<Data>) async throws -> TranscriptionResult {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoubaoASRFailure(kind: .invalidCredential)
        }

        let requestID = requestIDGenerator().uuidString
        let requestPayload = try makeRequestPayload(requestID: requestID)
        await runtimeDiagnostics?.beginDoubao(
            requestID: requestID,
            operation: runtimeOperation
        )
        let connection = try await connect(requestID: requestID)
        let exchange = DoubaoStreamingExchange(
            connection: connection,
            requestID: requestID,
            runtimeDiagnostics: runtimeDiagnostics
        )
        return try await exchange.run(requestPayload: requestPayload, audio: chunks)
    }

    /// Opens the socket, finishing the diagnostics entry on any failure so a
    /// rejected handshake never leaves a request looking active.
    private func connect(requestID: String) async throws -> any DoubaoWebSocketConnection {
        do {
            let connector = connector
            let request = makeURLRequest(requestID: requestID)
            return try await connector.connect(request)
        } catch is CancellationError {
            await runtimeDiagnostics?.finishDoubao(requestID: requestID)
            throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
        } catch let failure as DoubaoASRFailure {
            await runtimeDiagnostics?.finishDoubao(requestID: requestID)
            throw failure
        } catch {
            await runtimeDiagnostics?.finishDoubao(requestID: requestID)
            throw DoubaoFailureClassifier.transportFailure(
                error,
                metadata: .init(),
                fallbackRequestID: requestID
            )
        }
    }

    private func makeURLRequest(requestID: String) -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(configuration.resource.rawValue, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        return request
    }

    private func makeRequestPayload(requestID: String) throws -> Data {
        do {
            return try JSONEncoder().encode(makeRequestBody())
        } catch let failure as DoubaoASRFailure {
            throw failure
        } catch {
            throw DoubaoASRFailure(kind: .invalidRequest, providerRequestID: requestID)
        }
    }

    private func makeRequestBody() throws -> DoubaoStreamingRequestBody {
        DoubaoStreamingRequestBody(
            user: .init(uid: configuration.requestUserID),
            audio: .init(),
            request: .init(
                enableITN: configuration.options.enableITN,
                enablePunctuation: configuration.options.enablePunctuation,
                enableSemanticSmoothing: configuration.options.enableSemanticSmoothing,
                corpus: try Self.makeHotwordContext(hotwords: configuration.hotwords).map {
                    .init(context: $0)
                }
            )
        )
    }

    private static func makeHotwordContext(hotwords: [String]) throws -> String? {
        let words = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        struct HotwordContext: Encodable {
            struct Hotword: Encodable { let word: String }
            let hotwords: [Hotword]
        }

        let data = try JSONEncoder().encode(
            HotwordContext(hotwords: words.map(HotwordContext.Hotword.init(word:)))
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw DoubaoASRFailure(kind: .invalidRequest)
        }
        return string
    }
}
