import Foundation

public protocol RealtimeSpeechConnection: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close() async
}

public protocol RealtimeSpeechConnecting: Sendable {
    func connect(_ request: URLRequest) async throws -> any RealtimeSpeechConnection
}

public struct URLSessionRealtimeSpeechConnector: RealtimeSpeechConnecting {
    public init() {}

    public func connect(_ request: URLRequest) async throws -> any RealtimeSpeechConnection {
        try Task.checkCancellation()
        let configuration = ProviderURLSessionFactory.ephemeralConfiguration()
        configuration.timeoutIntervalForRequest = .greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let session = URLSession(
            configuration: configuration, delegate: ChatCompletionRedirectPolicy(),
            delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = CredentialedSpeechTranscriber.maximumResponseByteCount
        task.resume()
        return URLSessionRealtimeSpeechConnection(session: session, task: task)
    }
}

private actor URLSessionRealtimeSpeechConnection: RealtimeSpeechConnection {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var closed = false

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    func send(_ text: String) async throws {
        try Task.checkCancellation()
        do { try await task.send(.string(text)) } catch { throw transportError(error) }
    }

    func receive() async throws -> String {
        try Task.checkCancellation()
        let message: URLSessionWebSocketTask.Message
        do { message = try await task.receive() } catch { throw transportError(error) }
        switch message {
        case .string(let text): return text
        case .data: throw RealtimeSpeechTransportError.invalidMessage
        @unknown default: throw RealtimeSpeechTransportError.invalidMessage
        }
    }

    private func transportError(_ error: any Error) -> any Error {
        if closed || Task.isCancelled { return CancellationError() }
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return RealtimeSpeechTransportError.httpStatus(response.statusCode)
        }
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain,
            failure.code == Int(POSIXErrorCode.EMSGSIZE.rawValue)
        {
            return RealtimeSpeechTransportError.responseTooLarge
        }
        return error
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

package enum RealtimeSpeechTransportError: Error {
    case invalidMessage
    case responseTooLarge
    case httpStatus(Int)
}
