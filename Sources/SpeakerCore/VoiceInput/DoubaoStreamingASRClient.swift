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

public enum DoubaoStreamingResource: String, CaseIterable, Codable, Sendable {
    case model2Duration = "volc.seedasr.sauc.duration"
    case model2Concurrent = "volc.seedasr.sauc.concurrent"
    case model1Duration = "volc.bigasr.sauc.duration"
    case model1Concurrent = "volc.bigasr.sauc.concurrent"

    public static let `default` = DoubaoStreamingResource.model2Duration

    public var displayName: String {
        switch self {
        case .model2Duration: "流式模型 2.0 · 小时版"
        case .model2Concurrent: "流式模型 2.0 · 并发版"
        case .model1Duration: "流式模型 1.0 · 小时版"
        case .model1Concurrent: "流式模型 1.0 · 并发版"
        }
    }
}

public struct DoubaoStreamingASRConfiguration: Equatable, Sendable {
    public static let defaultEndpoint = URL(
        string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    )!

    public var apiKey: String
    public var resource: DoubaoStreamingResource
    public var requestUserID: String
    public var hotwords: [String]
    public var options: DoubaoTranscriptionOptions
    public var endpoint: URL

    public init(
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

    public init(
        httpStatusCode: Int? = nil,
        providerRequestID: String? = nil,
        providerMessage: String? = nil,
        webSocketCloseCode: Int? = nil
    ) {
        self.httpStatusCode = httpStatusCode
        self.providerRequestID = providerRequestID
        self.providerMessage = providerMessage
        self.webSocketCloseCode = webSocketCloseCode
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
                : closeCode.rawValue
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

private actor DoubaoWebSocketCloseGate {
    private let connection: any DoubaoWebSocketConnection
    private var isClosed = false

    init(connection: any DoubaoWebSocketConnection) {
        self.connection = connection
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await connection.close()
    }
}

private actor DoubaoExchangeFailurePriority {
    private var receiverFailure: DoubaoASRFailure?

    func recordReceiverFailure(_ failure: DoubaoASRFailure) {
        guard receiverFailure == nil else { return }
        receiverFailure = failure
    }

    func preferredFailure() -> DoubaoASRFailure? {
        receiverFailure
    }
}

public struct DoubaoStreamingFrame: Equatable, Sendable {
    public let messageType: UInt8
    public let flags: UInt8
    public let serialization: UInt8
    public let compression: UInt8
    public let sequence: Int32?
    public let errorCode: UInt32?
    public let payload: Data

    public var isFinal: Bool { flags & 0x02 != 0 }
}

public enum DoubaoStreamingFrameCodec {
    private static let versionAndHeaderSize: UInt8 = 0x11

    public static func fullClientRequest(payload: Data) -> Data {
        encode(
            messageType: 0x01,
            flags: 0x00,
            serialization: 0x01,
            compression: 0x00,
            payload: payload
        )
    }

    public static func audioRequest(payload: Data, isFinal: Bool) -> Data {
        encode(
            messageType: 0x02,
            flags: isFinal ? 0x02 : 0x00,
            serialization: 0x00,
            compression: 0x00,
            payload: payload
        )
    }

    public static func decode(_ data: Data) throws -> DoubaoStreamingFrame {
        guard data.count >= 8 else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }
        let headerSize = Int(data[data.startIndex] & 0x0F) * 4
        guard headerSize >= 4, data.count >= headerSize + 4 else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }

        let typeAndFlags = data[data.startIndex + 1]
        let serializationAndCompression = data[data.startIndex + 2]
        let messageType = typeAndFlags >> 4
        let flags = typeAndFlags & 0x0F
        let serialization = serializationAndCompression >> 4
        let compression = serializationAndCompression & 0x0F
        var offset = headerSize
        var sequence: Int32?
        var errorCode: UInt32?

        if messageType == 0x09, flags & 0x01 != 0 {
            guard data.count >= offset + 4 else {
                throw DoubaoASRFailure(kind: .invalidResponse)
            }
            sequence = Int32(bitPattern: readUInt32(data, at: offset))
            offset += 4
        } else if messageType == 0x0F {
            guard data.count >= offset + 4 else {
                throw DoubaoASRFailure(kind: .invalidResponse)
            }
            errorCode = readUInt32(data, at: offset)
            offset += 4
        }

        guard data.count >= offset + 4 else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }
        let payloadSize = Int(readUInt32(data, at: offset))
        offset += 4
        guard payloadSize >= 0, data.count >= offset + payloadSize else {
            throw DoubaoASRFailure(kind: .invalidResponse)
        }
        guard compression == 0 else {
            throw DoubaoASRFailure(
                kind: .invalidResponse,
                message: "Unexpected compressed response"
            )
        }

        return DoubaoStreamingFrame(
            messageType: messageType,
            flags: flags,
            serialization: serialization,
            compression: compression,
            sequence: sequence,
            errorCode: errorCode,
            payload: data.subdata(in: offset..<(offset + payloadSize))
        )
    }

    private static func encode(
        messageType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        payload: Data
    ) -> Data {
        var data = Data([
            versionAndHeaderSize,
            (messageType << 4) | flags,
            (serialization << 4) | compression,
            0x00,
        ])
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) << 24
            | UInt32(data[start + 1]) << 16
            | UInt32(data[start + 2]) << 8
            | UInt32(data[start + 3])
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
        let language = "zh-CN"
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

private struct DoubaoStreamingResponseBody: Decodable, Sendable {
    struct Result: Decodable, Sendable { let text: String? }
    let result: Result?
    let message: String?
}

public actor DoubaoStreamingASRClient {
    private enum ExchangeEvent: Sendable {
        case audioSent
        case finalResult(TranscriptionResult)
    }

    private let configuration: DoubaoStreamingASRConfiguration
    private let connector: any DoubaoWebSocketConnecting
    private let requestIDGenerator: @Sendable () -> UUID
    private let runtimeDiagnostics: VoiceProviderRuntimeDiagnostics?
    private let runtimeOperation: VoiceProviderRuntimeOperation

    public init(
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

    public func transcribe(_ chunks: AsyncStream<Data>) async throws -> TranscriptionResult {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoubaoASRFailure(kind: .invalidCredential)
        }

        let requestID = requestIDGenerator().uuidString
        await runtimeDiagnostics?.beginDoubao(
            requestID: requestID,
            operation: runtimeOperation
        )
        let connection: any DoubaoWebSocketConnection
        do {
            let connector = connector
            let request = makeURLRequest(requestID: requestID)
            connection = try await connector.connect(request)
        } catch is CancellationError {
            await runtimeDiagnostics?.finishDoubao(requestID: requestID)
            throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
        } catch let failure as DoubaoASRFailure {
            await runtimeDiagnostics?.finishDoubao(requestID: requestID)
            throw failure
        } catch {
            await runtimeDiagnostics?.finishDoubao(requestID: requestID)
            throw Self.mapTransportFailure(
                error,
                metadata: .init(),
                fallbackRequestID: requestID
            )
        }
        let closeGate = DoubaoWebSocketCloseGate(connection: connection)
        let failurePriority = DoubaoExchangeFailurePriority()
        let runtimeDiagnostics = runtimeDiagnostics

        return try await withTaskCancellationHandler {
            do {
                let requestPayload = try JSONEncoder().encode(makeRequestBody())
                try await connection.send(
                    DoubaoStreamingFrameCodec.fullClientRequest(payload: requestPayload)
                )
                await runtimeDiagnostics?.updateDoubao(
                    requestID: requestID,
                    phase: .connected,
                    metadata: await connection.metadata()
                )
                await runtimeDiagnostics?.updateDoubao(
                    requestID: requestID,
                    phase: .requestSent
                )
                let result = try await withThrowingTaskGroup(
                    of: ExchangeEvent.self,
                    returning: TranscriptionResult.self
                    ) { group in
                        group.addTask {
                            do {
                                try await Self.sendAudio(
                                    chunks,
                                    through: connection,
                                    requestID: requestID,
                                    runtimeDiagnostics: runtimeDiagnostics
                                )
                                await runtimeDiagnostics?.updateDoubao(
                                    requestID: requestID,
                                    phase: .awaitingFinal
                                )
                                return .audioSent
                            } catch {
                                // Task cancellation alone is not a transport
                                // contract. Close the socket so a concurrent
                                // receive that ignores cancellation is released.
                                await closeGate.close()
                                throw error
                            }
                        }
                        group.addTask {
                            do {
                                return .finalResult(try await Self.receiveFinalResult(
                                    from: connection,
                                    fallbackRequestID: requestID,
                                    runtimeDiagnostics: runtimeDiagnostics
                                ))
                            } catch let failure as DoubaoASRFailure {
                                // Record the receiver's structured provider
                                // result before closing the socket. The close
                                // can make the concurrent sender fail with a
                                // generic transport error, which must not hide
                                // an error frame already observed from Doubao.
                                await failurePriority.recordReceiverFailure(
                                    failure
                                )
                                await closeGate.close()
                                throw failure
                            } catch {
                                let metadata = await connection.metadata()
                                let failure = Self.mapTransportFailure(
                                    error,
                                    metadata: metadata,
                                    fallbackRequestID: requestID
                                )
                                await failurePriority.recordReceiverFailure(
                                    failure
                                )
                                await closeGate.close()
                                throw failure
                            }
                        }

                    var finalResult: TranscriptionResult?
                    var didFinishSending = false
                    while let event = try await group.next() {
                        switch event {
                        case .audioSent:
                            didFinishSending = true
                        case let .finalResult(result):
                            finalResult = result
                        }
                        if didFinishSending, let finalResult {
                            return finalResult
                        }
                    }
                    throw DoubaoASRFailure(
                        kind: .invalidResponse,
                        providerRequestID: requestID
                    )
                }
                await closeGate.close()
                await runtimeDiagnostics?.finishDoubao(
                    requestID: requestID
                )
                return result
            } catch let failure as DoubaoASRFailure {
                await closeGate.close()
                await runtimeDiagnostics?.finishDoubao(
                    requestID: requestID
                )
                if Task.isCancelled {
                    throw DoubaoASRFailure(
                        kind: .cancelled,
                        providerRequestID: requestID
                    )
                }
                if let preferred = await failurePriority.preferredFailure() {
                    throw preferred
                }
                throw failure
            } catch is CancellationError {
                await closeGate.close()
                await runtimeDiagnostics?.finishDoubao(
                    requestID: requestID
                )
                if !Task.isCancelled,
                   let failure = await failurePriority.preferredFailure() {
                    throw failure
                }
                throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
            } catch {
                let metadata = await connection.metadata()
                await closeGate.close()
                await runtimeDiagnostics?.finishDoubao(
                    requestID: requestID
                )
                if Task.isCancelled {
                    throw DoubaoASRFailure(
                        kind: .cancelled,
                        providerRequestID: requestID
                    )
                }
                if let failure = await failurePriority.preferredFailure() {
                    throw failure
                }
                throw Self.mapTransportFailure(
                    error,
                    metadata: metadata,
                    fallbackRequestID: requestID
                )
            }
        } onCancel: {
            Task { await closeGate.close() }
        }
    }

    private static func sendAudio(
        _ chunks: AsyncStream<Data>,
        through connection: any DoubaoWebSocketConnection,
        requestID: String,
        runtimeDiagnostics: VoiceProviderRuntimeDiagnostics?
    ) async throws {
        var pending: Data?
        for await chunk in chunks {
            try Task.checkCancellation()
            guard !chunk.isEmpty else { continue }
            if let pending {
                try await sendAudioFrame(
                    pending,
                    isFinal: false,
                    through: connection
                )
                await runtimeDiagnostics?.updateDoubao(
                    requestID: requestID,
                    phase: .streamingAudio
                )
            }
            pending = chunk
        }
        // AsyncStream ends its iteration when the consuming task is cancelled.
        // Re-check here before treating the buffered chunk as a legitimate
        // end-of-audio frame; otherwise Esc can still send `isFinal=true`.
        try Task.checkCancellation()
        guard let pending else {
            throw DoubaoASRFailure(kind: .emptyAudio, providerRequestID: requestID)
        }
        try await sendAudioFrame(
            pending,
            isFinal: true,
            through: connection
        )
        await runtimeDiagnostics?.updateDoubao(
            requestID: requestID,
            phase: .audioFinalized
        )
    }

    private static func sendAudioFrame(
        _ payload: Data,
        isFinal: Bool,
        through connection: any DoubaoWebSocketConnection
    ) async throws {
        let frame = DoubaoStreamingFrameCodec.audioRequest(payload: payload, isFinal: isFinal)
        try await connection.send(frame)
    }

    private static func receiveFinalResult(
        from connection: any DoubaoWebSocketConnection,
        fallbackRequestID: String,
        runtimeDiagnostics: VoiceProviderRuntimeDiagnostics?
    ) async throws -> TranscriptionResult {
        var latestText: String?
        while true {
            try Task.checkCancellation()
            let rawFrame = try await connection.receive()
            let frame = try DoubaoStreamingFrameCodec.decode(rawFrame)
            let metadata = await connection.metadata()
            let providerRequestID = metadata.providerRequestID ?? fallbackRequestID
            await runtimeDiagnostics?.updateDoubaoMetadata(
                requestID: fallbackRequestID,
                metadata: metadata
            )

            switch frame.messageType {
            case 0x09:
                guard frame.serialization == 0x01 else {
                    throw DoubaoASRFailure(
                        kind: .invalidResponse,
                        providerRequestID: providerRequestID
                    )
                }
                let body: DoubaoStreamingResponseBody
                do {
                    body = try JSONDecoder().decode(
                        DoubaoStreamingResponseBody.self,
                        from: frame.payload
                    )
                } catch {
                    throw DoubaoASRFailure(
                        kind: .invalidResponse,
                        providerRequestID: providerRequestID
                    )
                }
                if let text = body.result?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    latestText = text
                }
                if frame.isFinal {
                    guard let latestText else {
                        throw DoubaoASRFailure(
                            kind: .emptyTranscript,
                            providerRequestID: providerRequestID,
                            message: body.message
                        )
                    }
                    return TranscriptionResult(
                        text: latestText,
                        providerRequestID: providerRequestID
                    )
                }
            case 0x0F:
                let message = Self.errorMessage(from: frame.payload)
                throw Self.mapProviderFailure(
                    code: frame.errorCode,
                    message: message,
                    providerRequestID: providerRequestID
                )
            default:
                throw DoubaoASRFailure(
                    kind: .invalidResponse,
                    providerRequestID: providerRequestID
                )
            }
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

    private static func errorMessage(from payload: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            return (object["message"] ?? object["error"] ?? object["msg"]).map {
                String(describing: $0)
            }
        }
        return String(data: payload, encoding: .utf8)
    }

    private static func mapProviderFailure(
        code: UInt32?,
        message: String?,
        providerRequestID: String?
    ) -> DoubaoASRFailure {
        let codeString = code.map(String.init)
        let normalizedMessage = message?.lowercased() ?? ""
        let kind: DoubaoASRFailureKind

        switch codeString {
        case "20000003": kind = .silence
        case "45000001":
            if messageLooksLikeResourceFailure(normalizedMessage) {
                kind = .resourceNotActivated
            } else if messageLooksLikeCredentialFailure(normalizedMessage) {
                kind = .invalidCredential
            } else {
                kind = .invalidRequest
            }
        case "45000002": kind = .emptyAudio
        case "45000081": kind = .serviceUnavailable
        case "45000151": kind = .invalidAudioFormat
        case "55000031": kind = .serverBusy
        case let code? where code.hasPrefix("550"): kind = .serviceUnavailable
        default:
            if messageLooksLikeResourceFailure(normalizedMessage) {
                kind = .resourceNotActivated
            } else if messageLooksLikeCredentialFailure(normalizedMessage) {
                kind = .invalidCredential
            } else if messageLooksLikeRateLimit(normalizedMessage) {
                kind = .rateLimited
            } else {
                kind = .invalidResponse
            }
        }

        return DoubaoASRFailure(
            kind: kind,
            providerStatusCode: codeString,
            providerRequestID: providerRequestID,
            message: message
        )
    }

    private static func mapTransportFailure(
        _ error: Error,
        metadata: DoubaoWebSocketMetadata,
        fallbackRequestID: String
    ) -> DoubaoASRFailure {
        let normalizedMessage = metadata.providerMessage?.lowercased() ?? ""
        let kind: DoubaoASRFailureKind
        if messageLooksLikeResourceFailure(normalizedMessage) {
            kind = .resourceNotActivated
        } else if metadata.httpStatusCode == 401
            || metadata.httpStatusCode == 403
            || messageLooksLikeCredentialFailure(normalizedMessage) {
            kind = .invalidCredential
        } else if metadata.httpStatusCode == 429 || messageLooksLikeRateLimit(normalizedMessage) {
            kind = .rateLimited
        } else if let status = metadata.httpStatusCode, (500...599).contains(status) {
            kind = .serviceUnavailable
        } else {
            kind = .network
        }
        return DoubaoASRFailure(
            kind: kind,
            providerStatusCode: transportStatusCode(
                error,
                metadata: metadata
            ),
            providerRequestID: metadata.providerRequestID ?? fallbackRequestID,
            message: metadata.providerMessage ?? safeNetworkMessage(error)
        )
    }

    private static func transportStatusCode(
        _ error: Error,
        metadata: DoubaoWebSocketMetadata
    ) -> String? {
        if let status = metadata.httpStatusCode {
            return String(status)
        }
        if let closeCode = metadata.webSocketCloseCode {
            return "websocket.close.\(closeCode)"
        }
        guard let urlError = error as? URLError else { return nil }
        return switch urlError.code {
        case .cancelled: "url.cancelled"
        case .timedOut: "url.timedOut"
        case .cannotFindHost: "url.cannotFindHost"
        case .cannotConnectToHost: "url.cannotConnectToHost"
        case .dnsLookupFailed: "url.dnsLookupFailed"
        case .networkConnectionLost: "url.networkConnectionLost"
        case .notConnectedToInternet: "url.notConnectedToInternet"
        case .secureConnectionFailed: "url.secureConnectionFailed"
        case .serverCertificateHasBadDate:
            "url.serverCertificateHasBadDate"
        case .serverCertificateUntrusted:
            "url.serverCertificateUntrusted"
        case .serverCertificateHasUnknownRoot:
            "url.serverCertificateHasUnknownRoot"
        case .serverCertificateNotYetValid:
            "url.serverCertificateNotYetValid"
        case .clientCertificateRejected:
            "url.clientCertificateRejected"
        case .clientCertificateRequired:
            "url.clientCertificateRequired"
        default: "url.\(urlError.code.rawValue)"
        }
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
