import Foundation
import SpeakerCore
import SpeakerSpecSupport

final class DeepSeekURLProtocolProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var stopped = false

    var didStart: Bool {
        lock.withLock { started }
    }

    var didStop: Bool {
        lock.withLock { stopped }
    }

    func markStarted() {
        lock.withLock { started = true }
    }

    func markStopped() {
        lock.withLock { stopped = true }
    }
}

final class BlockingDeepSeekURLProtocol: URLProtocol,
    @unchecked Sendable {
    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var installedProbe:
        DeepSeekURLProtocolProbe?

    static func install(_ probe: DeepSeekURLProtocolProbe?) {
        probeLock.withLock {
            installedProbe = probe
        }
    }

    private static var probe: DeepSeekURLProtocolProbe? {
        probeLock.withLock { installedProbe }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.probe?.markStarted()
    }

    override func stopLoading() {
        Self.probe?.markStopped()
    }
}

func makeDoubaoClient(
    responses: [Data] = [],
    receiveError: URLError? = nil,
    metadata: DoubaoWebSocketMetadata = .init()
) -> DoubaoStreamingASRClient {
    let connection = DoubaoWebSocketConnectionFake(
        responses: responses,
        receiveError: receiveError,
        metadata: metadata
    )
    return DoubaoStreamingASRClient(
        configuration: .init(
            apiKey: "test-api-key",
            requestUserID: "request-user"
        ),
        connector: DoubaoWebSocketConnectorFake(connection: connection)
    )
}

actor DoubaoWebSocketConnectorFake: DoubaoWebSocketConnecting {
    let connection: DoubaoWebSocketConnectionFake
    private var requests: [URLRequest] = []

    init(connection: DoubaoWebSocketConnectionFake) {
        self.connection = connection
    }

    func connect(_ request: URLRequest) async throws -> any DoubaoWebSocketConnection {
        requests.append(request)
        return connection
    }

    func onlyRequest() throws -> URLRequest {
        guard requests.count == 1, let request = requests.first else {
            throw SpecFailure(message: "expected exactly one Doubao WebSocket request")
        }
        return request
    }

    var requestCount: Int { requests.count }
}

struct HangingDoubaoWebSocketConnector: DoubaoWebSocketConnecting {
    func connect(_ request: URLRequest) async throws -> any DoubaoWebSocketConnection {
        try await Task.sleep(for: .seconds(10))
        return DoubaoWebSocketConnectionFake(responses: [])
    }
}

actor AudioChunkConsumptionProbe {
    private var hasReturnedFirstChunk = false

    var firstChunkWasConsumed: Bool {
        hasReturnedFirstChunk
    }

    func takeFirstChunk() -> Bool {
        guard !hasReturnedFirstChunk else { return false }
        hasReturnedFirstChunk = true
        return true
    }
}

struct DoubaoFailingWebSocketConnectorFake:
    DoubaoWebSocketConnecting {
    let error: URLError

    func connect(
        _ request: URLRequest
    ) async throws -> any DoubaoWebSocketConnection {
        _ = request
        throw error
    }
}

actor DoubaoWebSocketConnectionFake: DoubaoWebSocketConnection {
    private let responses: [Data]
    private let receiveError: URLError?
    private let metadataValue: DoubaoWebSocketMetadata
    private let hangingSendIndex: Int?
    private let hangsOnReceive: Bool
    private let failingSendIndex: Int?
    private let blockingSendFailureIndex: Int?
    private let blocksReceiveUntilClose: Bool
    private var responseIndex = 0
    private var isClosed = false
    private var blockedReceive: CheckedContinuation<Data, Error>?
    private var blockedSend: CheckedContinuation<Void, Error>?
    private(set) var sentFrames: [Data] = []
    private(set) var sendAttemptCount = 0
    private(set) var closeCount = 0

    init(
        responses: [Data],
        receiveError: URLError? = nil,
        metadata: DoubaoWebSocketMetadata = .init(),
        hangingSendIndex: Int? = nil,
        hangsOnReceive: Bool = false,
        failingSendIndex: Int? = nil,
        blockingSendFailureIndex: Int? = nil,
        blocksReceiveUntilClose: Bool = false
    ) {
        self.responses = responses
        self.receiveError = receiveError
        metadataValue = metadata
        self.hangingSendIndex = hangingSendIndex
        self.hangsOnReceive = hangsOnReceive
        self.failingSendIndex = failingSendIndex
        self.blockingSendFailureIndex = blockingSendFailureIndex
        self.blocksReceiveUntilClose = blocksReceiveUntilClose
    }

    func send(_ data: Data) async throws {
        let sendIndex = sentFrames.count
        sendAttemptCount += 1
        if sendIndex == failingSendIndex {
            throw URLError(.networkConnectionLost)
        }
        if sendIndex == hangingSendIndex {
            try await Task.sleep(for: .seconds(10))
        }
        if sendIndex == blockingSendFailureIndex {
            try await withCheckedThrowingContinuation {
                blockedSend = $0
            }
        }
        sentFrames.append(data)
    }

    func receive() async throws -> Data {
        if blocksReceiveUntilClose {
            if isClosed { throw URLError(.cancelled) }
            return try await withCheckedThrowingContinuation { continuation in
                blockedReceive = continuation
            }
        }
        if hangsOnReceive {
            try await Task.sleep(for: .seconds(10))
        }
        if let receiveError { throw receiveError }
        guard responseIndex < responses.count else {
            throw URLError(.cannotParseResponse)
        }
        defer { responseIndex += 1 }
        return responses[responseIndex]
    }

    func metadata() -> DoubaoWebSocketMetadata { metadataValue }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        closeCount += 1
        blockedSend?.resume(
            throwing: URLError(.networkConnectionLost)
        )
        blockedSend = nil
        blockedReceive?.resume(throwing: URLError(.cancelled))
        blockedReceive = nil
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

func makeDoubaoServerResponse(text: String?, isFinal: Bool) -> Data {
    let body: Data
    if let text {
        body = Data(#"{"result":{"text":"\#(text)"}}"#.utf8)
    } else {
        body = Data(#"{"result":{"text":""}}"#.utf8)
    }
    return makeDoubaoServerFrame(
        messageType: 0x09,
        flags: isFinal ? 0x03 : 0x01,
        prefix: UInt32(bitPattern: isFinal ? -1 : 1),
        payload: body
    )
}

func makeDoubaoServerError(code: UInt32, message: String) -> Data {
    makeDoubaoServerFrame(
        messageType: 0x0F,
        flags: 0,
        prefix: code,
        payload: Data(#"{"message":"\#(message)"}"#.utf8)
    )
}

func makeDoubaoServerFrame(
    messageType: UInt8,
    flags: UInt8,
    prefix: UInt32,
    payload: Data
) -> Data {
    var data = Data([0x11, (messageType << 4) | flags, 0x10, 0x00])
    appendUInt32BE(prefix, to: &data)
    appendUInt32BE(UInt32(payload.count), to: &data)
    data.append(payload)
    return data
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

actor DeepSeekRefinerFake: DeepSeekTextRefining {
    let result: Result<DeepSeekRefinementResult, DeepSeekRefinementFailure>
    private(set) var callCount = 0
    private(set) var inputs: [String] = []
    private(set) var contexts: [TextRefinementContext] = []

    var modes: [TextRefinementMode] { contexts.map(\.mode) }

    init(result: Result<DeepSeekRefinementResult, DeepSeekRefinementFailure>) {
        self.result = result
    }

    func refine(
        _ text: String,
        using context: TextRefinementContext
    ) async throws -> DeepSeekRefinementResult {
        callCount += 1
        inputs.append(text)
        contexts.append(context)
        return try result.get()
    }
}

actor ContextualTranscriberFake: ContextualSpeechTranscribing {
    let text: String
    private(set) var contextCalls: [SpeechTranscriptionContext] = []

    var hotwordCalls: [[String]] { contextCalls.map(\.hotwords) }

    init(text: String) {
        self.text = text
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        try await transcribe(
            audio,
            context: .init(hotwords: [], purpose: .defaultSmoothing)
        )
    }

    func transcribe(
        _ audio: CapturedAudio,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        contextCalls.append(context)
        return TranscriptionResult(text: text, providerRequestID: "doubao-context-spec")
    }
}

actor StreamingContextualTranscriberFake: ContextualSpeechTranscribing,
    StreamingContextualSpeechTranscribing {
    let text: String
    private(set) var contextCalls: [SpeechTranscriptionContext] = []

    init(text: String) {
        self.text = text
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        try await transcribe(
            audio,
            context: .init(hotwords: [], purpose: .defaultSmoothing)
        )
    }

    func transcribe(
        _ audio: CapturedAudio,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        contextCalls.append(context)
        return TranscriptionResult(
            text: text,
            providerRequestID: "doubao-streaming-context-spec"
        )
    }

    func transcribe(
        _ audioChunks: AsyncStream<Data>,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        for await _ in audioChunks {}
        contextCalls.append(context)
        return TranscriptionResult(
            text: text,
            providerRequestID: "doubao-streaming-context-spec"
        )
    }
}

actor DeepSeekTransportFake: DeepSeekTransport {
    let response: DeepSeekTransportResponse
    private var requests: [URLRequest] = []

    init(response: DeepSeekTransportResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> DeepSeekTransportResponse {
        requests.append(request)
        return response
    }

    func onlyRequest() throws -> URLRequest {
        guard requests.count == 1, let request = requests.first else {
            throw SpecFailure(message: "expected exactly one DeepSeek request")
        }
        return request
    }
}

struct HangingDeepSeekTransport: DeepSeekTransport {
    func send(_ request: URLRequest) async throws -> DeepSeekTransportResponse {
        try await Task.sleep(for: .seconds(10))
        return DeepSeekTransportResponse(statusCode: 500, body: Data())
    }
}

actor CancellableDeepSeekRefinerFake: DeepSeekTextRefining {
    private(set) var callCount = 0
    private(set) var cancellationCount = 0

    func refine(
        _ text: String,
        using context: TextRefinementContext
    ) async throws -> DeepSeekRefinementResult {
        callCount += 1
        do {
            try await Task.sleep(for: .seconds(10))
            return DeepSeekRefinementResult(text: "迟到结果")
        } catch is CancellationError {
            cancellationCount += 1
            throw DeepSeekRefinementFailure(kind: .cancelled)
        }
    }
}

func makeDeepSeekClient(content: String) -> DeepSeekRefinementClient {
    let encodedContent = try! JSONEncoder().encode(content)
    let body = Data(
        "{\"choices\":[{\"message\":{\"content\":\(String(decoding: encodedContent, as: UTF8.self))},\"finish_reason\":\"stop\"}]}".utf8
    )
    return DeepSeekRefinementClient(
        configuration: .init(apiKey: "deepseek-test-key"),
        transport: DeepSeekTransportFake(response: .init(statusCode: 200, body: body))
    )
}

actor ProviderCredentialStoreFake: ProviderCredentialStoring {
    private var values: [ProviderID: String]
    private let corruptsSavedValues: Bool
    private let deleteFails: Bool
    private let readError: ProviderCredentialStoreError?

    init(
        values: [ProviderID: String] = [:],
        corruptsSavedValues: Bool = false,
        deleteFails: Bool = false,
        readError: ProviderCredentialStoreError? = nil
    ) {
        self.values = values
        self.corruptsSavedValues = corruptsSavedValues
        self.deleteFails = deleteFails
        self.readError = readError
    }

    func save(apiKey: String, for provider: ProviderID) async throws {
        values[provider] = corruptsSavedValues ? "mismatched-value" : apiKey
    }

    func apiKey(for provider: ProviderID) async throws -> String? {
        if let readError { throw readError }
        return values[provider]
    }

    func deleteAPIKey(for provider: ProviderID) async throws {
        if deleteFails { throw ProviderCredentialStoreError.storageUnavailable }
        values[provider] = nil
    }
}

actor EarlyFailingStreamingProcessor: VoiceTextProcessing, StreamingVoiceTextProcessing {
    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw VoiceTextProcessingFailure(
            userFailure: .providerAuthenticationFailed,
            providerDiagnostic: .init(
                provider: "doubao",
                requestID: "early-provider-failure",
                code: "invalidCredential"
            )
        )
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw VoiceTextProcessingFailure(
            userFailure: .providerAuthenticationFailed,
            providerDiagnostic: .init(
                provider: "doubao",
                requestID: "early-provider-failure",
                code: "invalidCredential"
            )
        )
    }
}

actor StreamingVoiceTextProcessorFake: VoiceTextProcessing, StreamingVoiceTextProcessing {
    private(set) var receivedChunkCount = 0
    private(set) var cancellationCount = 0

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw SpecFailure(message: "streaming processor used buffered fallback")
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        for await chunk in audioChunks where !chunk.isEmpty {
            receivedChunkCount += 1
        }
        if Task.isCancelled {
            cancellationCount += 1
            throw CancellationError()
        }
        return VoiceTextProcessingResult(
            doubaoText: "流式结果",
            normalizedText: "流式结果",
            deepSeekText: nil,
            finalText: "流式结果",
            doubaoRequestID: "streaming-spec",
            deepSeekRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil
        )
    }
}

actor LateCompletingStreamingProcessor: VoiceTextProcessing,
    StreamingVoiceTextProcessing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private(set) var cancellationCount = 0

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw SpecFailure(message: "late streaming fake used buffered processing")
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        started = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.markCancelled() }
        }
        return VoiceTextProcessingResult(
            doubaoText: "late provider text",
            normalizedText: "late provider text",
            deepSeekText: nil,
            finalText: "late provider text",
            doubaoRequestID: "late-provider",
            deepSeekRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }

    private func markCancelled() {
        cancellationCount += 1
    }
}

actor ManuallyFailingStreamingProcessor: VoiceTextProcessing,
    StreamingVoiceTextProcessing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw SpecFailure(message: "manual streaming fake used buffered processing")
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        throw VoiceTextProcessingFailure(
            userFailure: .providerAuthenticationFailed,
            providerDiagnostic: .init(
                provider: "doubao",
                requestID: "manual-provider-failure",
                code: "invalidCredential"
            )
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func fail() {
        continuation?.resume()
        continuation = nil
    }
}

struct DoubaoFailureTranscriber: ContextualSpeechTranscribing {
    let failure: DoubaoASRFailure

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        throw failure
    }

    func transcribe(
        _ audio: CapturedAudio,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        throw failure
    }
}

struct CredentialFailureTranscriber: ContextualSpeechTranscribing {
    let error: ProviderCredentialStoreError

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        throw error
    }

    func transcribe(
        _ audio: CapturedAudio,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        throw error
    }
}

struct NormalizedFailureProcessor: VoiceTextProcessing {
    let failure: VoiceTextProcessingFailure

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw failure
    }
}

actor SpeechTranscriberFake: SpeechTranscribing {
    let text: String
    let delaysResponse: Bool
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(text: String, delaysResponse: Bool = false) {
        self.text = text
        self.delaysResponse = delaysResponse
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        callCount += 1
        if delaysResponse {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            } onCancel: {
                Task { await self.markCancelled() }
            }
        }
        try Task.checkCancellation()
        return TranscriptionResult(text: text, providerRequestID: "local-spec")
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func markCancelled() {
        cancellationCount += 1
    }
}
