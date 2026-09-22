import Foundation
import SpeakerCore

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
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private(set) var sent: [String] = []
    private(set) var closed = false
    private(set) var receiveCount = 0

    init(
        provider: SpeechRecognitionProviderID, creation: Bool = true, updates: Bool = true,
        completes: Bool = true, mode: String = "", receiveError: (any Error)? = nil
    ) {
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
        if type == "session.finish" { push(#"{"type":"session.finished"}"#) }
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
