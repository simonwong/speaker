import Foundation
import SpeakerCore
import SpeakerSpecSupport

actor RealtimeSpeechConnectorFake: RealtimeSpeechConnecting {
    let socket: RealtimeSpeechSocketFake
    private(set) var requests: [URLRequest] = []
    init(socket: RealtimeSpeechSocketFake) { self.socket = socket }
    func connect(_ request: URLRequest) async throws -> any RealtimeSpeechConnection {
        requests.append(request)
        return socket
    }
}

actor RealtimeSpeechSocketFake: RealtimeSpeechConnection {
    let provider: SpeechRecognitionProviderID
    let updates: Bool
    let completes: Bool
    let mode: String
    let receiveError: (any Error)?
    nonisolated let pings: PingScriptFake
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private(set) var sent: [String] = []
    private(set) var closed = false
    private(set) var receiveCount = 0

    init(
        provider: SpeechRecognitionProviderID, creation: Bool = true, updates: Bool = true,
        completes: Bool = true, mode: String = "", receiveError: (any Error)? = nil,
        pings: PingScriptFake = PingScriptFake()
    ) {
        self.pings = pings
        self.provider = provider
        self.updates = updates
        self.completes = completes
        self.mode = mode
        self.receiveError = receiveError
        if creation { queue = [#"{"type":"session.created"}"#] }
    }
    func send(_ text: String) async throws {
        if closed { throw CancellationError() }
        sent.append(text)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let type = object["type"] as! String
        if type == "session.update", updates {
            if mode == "malformed" {
                push("not json")
                return
            }
            if mode == "oversize" {
                push(String(repeating: "x", count: 1_024 * 1_024 + 1))
                return
            }
            if mode == "remoteError" {
                push(
                    #"{"type":"error","error":{"code":"invalid_api_key","message":"secret provider text"}}"#
                )
                return
            }
            var session = object["session"] as! [String: Any]
            if provider == .qwen {
                session["input_audio_format"] = "pcm16"
                session.removeValue(forKey: "sample_rate")
            }
            push(json(["type": "session.updated", "session": session]))
            if mode == "earlyFinal" { push(result(item: "unrequested")) }
        }
        if type == "input_audio_buffer.commit" {
            push(
                #"{"type":"input_audio_buffer.committed","item_id":"item-1","previous_item_id":null}"#
            )
            if completes {
                push(result(item: mode == "wrongItem" ? "other-item" : "item-1"))
            } else {
                push(
                    #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","content_index":0,"delta":"partial must not deliver"}"#
                )
            }
        }
        if type == "session.finish", completes { push(#"{"type":"session.finished"}"#) }
    }
    func receive() async throws -> String {
        receiveCount += 1
        if let receiveError { throw receiveError }
        if mode.hasPrefix("http-"), let status = Int(mode.dropFirst(5)) {
            throw RealtimeSpeechTransportError.httpStatus(status)
        }
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func ping() async throws {
        try await pings.ping()
    }
    func close() {
        closed = true
        waiter?.resume(throwing: URLError(.cancelled))
        waiter = nil
    }
    func count(_ type: String) -> Int {
        sent.filter { object($0)?["type"] as? String == type }.count
    }
    func firstMessage(_ type: String) -> String? {
        sent.first { object($0)?["type"] as? String == type }
    }
    func audioBytes() -> Data {
        sent.compactMap(object).reduce(into: Data()) { data, value in
            if let base64 = value["audio"] as? String, let bytes = Data(base64Encoded: base64) {
                data.append(bytes)
            }
        }
    }
    private func object(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
    private func result(item: String) -> String {
        json([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": item,
            "content_index": 0, "transcript": "confirmed result",
        ])
    }
    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    private func push(_ text: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: text)
        } else {
            queue.append(text)
        }
    }
}

/// The transport's answers to liveness pings, scripted by a specification.
///
/// A pong answers at once and a failure throws at once. A hung ping stays
/// unanswered until the script changes its answer or the pinging task is
/// cancelled, as an unanswered live ping does.
final class PingScriptFake: @unchecked Sendable {
    enum Answer: Sendable {
        case pong
        case hang
        case fail(any Error & Sendable)
    }

    private let lock = NSLock()
    private var answer: Answer = .pong
    private var hung: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []
    private var count = 0

    /// Pings sent so far, answered or not.
    var pingCount: Int { lock.withLock { count } }

    /// Pings currently unanswered.
    var hungCount: Int { lock.withLock { hung.count } }

    /// Sets the answer for later pings and gives a pong or failure to every
    /// hung ping.
    func answer(_ answer: Answer) {
        let waiting: [CheckedContinuation<Void, Error>] = lock.withLock {
            self.answer = answer
            if case .hang = answer { return [] }
            defer { hung.removeAll() }
            return Array(hung.values)
        }
        for continuation in waiting {
            if case .fail(let error) = answer {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    func ping() async throws {
        let id = UUID()
        let answer = lock.withLock {
            count += 1
            return self.answer
        }
        switch answer {
        case .pong: return
        case .fail(let error): throw error
        case .hang:
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let alreadyCancelled = lock.withLock {
                        if cancelled.contains(id) { return true }
                        hung[id] = continuation
                        return false
                    }
                    if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let continuation = lock.withLock {
                    cancelled.insert(id)
                    return hung.removeValue(forKey: id)
                }
                continuation?.resume(throwing: CancellationError())
            }
        }
    }

    func waitUntilPingCount(_ expected: Int, before timeout: Duration = .seconds(2)) async throws {
        let ready = await eventually(before: timeout) { self.pingCount >= expected }
        try expect(ready, "expected \(expected) liveness pings, observed \(pingCount)")
    }
}

/// Wake and network path events a specification emits by hand.
final class TransportLivenessSignalsFake: TransportLivenessSignals, @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Probes currently listening for events.
    var subscriberCount: Int { lock.withLock { subscribers.count } }

    func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = lock.withLock { subscribers.removeValue(forKey: id) }
            }
        }
    }

    /// The Mac woke, or the network path changed.
    func emit() {
        let current = lock.withLock { Array(subscribers.values) }
        for continuation in current { continuation.yield() }
    }

    func waitUntilSubscribed(before timeout: Duration = .seconds(2)) async throws {
        let ready = await eventually(before: timeout) { self.subscriberCount > 0 }
        try expect(ready, "the liveness probe never started listening")
    }
}

extension TransportLivenessProbe {
    /// A probe driven entirely by the specification's clock and signals.
    static func scripted(
        clock: ManualVoiceInputClock, signals: TransportLivenessSignalsFake
    ) -> TransportLivenessProbe {
        TransportLivenessProbe(interval: .seconds(15), clock: clock, signals: signals)
    }
}
