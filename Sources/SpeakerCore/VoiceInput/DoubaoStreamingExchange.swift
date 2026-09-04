import Foundation

/// One transcription exchange over an open Doubao socket.
///
/// The exchange sends the request and audio frames while a concurrent
/// receiver waits for the final result. It owns the close gate that releases
/// a receive ignoring cancellation, and the rule that an error frame already
/// observed from Doubao outranks the transport error that closing the socket
/// inflicts on the sender.
package struct DoubaoStreamingExchange: Sendable {
    private enum Event: Sendable {
        case audioSent
        case finalResult(TranscriptionResult)
    }

    private let connection: any DoubaoWebSocketConnection
    private let requestID: String
    private let runtimeDiagnostics: VoiceProviderRuntimeDiagnostics?
    private let closeGate: DoubaoWebSocketCloseGate
    private let failurePriority = DoubaoExchangeFailurePriority()

    package init(
        connection: any DoubaoWebSocketConnection,
        requestID: String,
        runtimeDiagnostics: VoiceProviderRuntimeDiagnostics?
    ) {
        self.connection = connection
        self.requestID = requestID
        self.runtimeDiagnostics = runtimeDiagnostics
        closeGate = DoubaoWebSocketCloseGate(connection: connection)
    }

    package func run(
        requestPayload: Data,
        audio chunks: AsyncStream<Data>
    ) async throws -> TranscriptionResult {
        try await withTaskCancellationHandler {
            do {
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
                let result = try await exchangeAudio(chunks)
                await closeGate.close()
                await runtimeDiagnostics?.finishDoubao(requestID: requestID)
                return result
            } catch let failure as DoubaoASRFailure {
                await closeGate.close()
                await runtimeDiagnostics?.finishDoubao(requestID: requestID)
                if Task.isCancelled {
                    throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
                }
                if let preferred = await failurePriority.preferredFailure() {
                    throw preferred
                }
                throw failure
            } catch is CancellationError {
                await closeGate.close()
                await runtimeDiagnostics?.finishDoubao(requestID: requestID)
                if !Task.isCancelled,
                   let failure = await failurePriority.preferredFailure() {
                    throw failure
                }
                throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
            } catch {
                let metadata = await connection.metadata()
                await closeGate.close()
                await runtimeDiagnostics?.finishDoubao(requestID: requestID)
                if Task.isCancelled {
                    throw DoubaoASRFailure(kind: .cancelled, providerRequestID: requestID)
                }
                if let failure = await failurePriority.preferredFailure() {
                    throw failure
                }
                throw DoubaoFailureClassifier.transportFailure(
                    error,
                    metadata: metadata,
                    fallbackRequestID: requestID
                )
            }
        } onCancel: {
            Task { await closeGate.close() }
        }
    }

    /// Runs the sender and receiver together and returns once both have
    /// finished: audio fully sent and a final result received.
    private func exchangeAudio(_ chunks: AsyncStream<Data>) async throws -> TranscriptionResult {
        try await withThrowingTaskGroup(
            of: Event.self,
            returning: TranscriptionResult.self
        ) { group in
            group.addTask {
                do {
                    try await sendAudio(chunks)
                    await runtimeDiagnostics?.updateDoubao(
                        requestID: requestID,
                        phase: .awaitingFinal
                    )
                    return .audioSent
                } catch {
                    // Task cancellation alone is not a transport contract.
                    // Close the socket so a concurrent receive that ignores
                    // cancellation is released.
                    await closeGate.close()
                    throw error
                }
            }
            group.addTask {
                do {
                    return .finalResult(try await receiveFinalResult())
                } catch let failure as DoubaoASRFailure {
                    // Record the receiver's structured provider result before
                    // closing the socket. The close can make the concurrent
                    // sender fail with a generic transport error, which must
                    // not hide an error frame already observed from Doubao.
                    await failurePriority.recordReceiverFailure(failure)
                    await closeGate.close()
                    throw failure
                } catch {
                    let metadata = await connection.metadata()
                    let failure = DoubaoFailureClassifier.transportFailure(
                        error,
                        metadata: metadata,
                        fallbackRequestID: requestID
                    )
                    await failurePriority.recordReceiverFailure(failure)
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
            throw DoubaoASRFailure(kind: .invalidResponse, providerRequestID: requestID)
        }
    }

    private func sendAudio(_ chunks: AsyncStream<Data>) async throws {
        var pending: Data?
        for await chunk in chunks {
            try Task.checkCancellation()
            guard !chunk.isEmpty else { continue }
            if let pending {
                try await sendAudioFrame(pending, isFinal: false)
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
        try await sendAudioFrame(pending, isFinal: true)
        await runtimeDiagnostics?.updateDoubao(
            requestID: requestID,
            phase: .audioFinalized
        )
    }

    private func sendAudioFrame(_ payload: Data, isFinal: Bool) async throws {
        let frame = DoubaoStreamingFrameCodec.audioRequest(payload: payload, isFinal: isFinal)
        try await connection.send(frame)
    }

    private func receiveFinalResult() async throws -> TranscriptionResult {
        var latestText: String?
        while true {
            try Task.checkCancellation()
            let rawFrame = try await connection.receive()
            let frame = try DoubaoStreamingFrameCodec.decode(rawFrame)
            let metadata = await connection.metadata()
            let providerRequestID = metadata.providerRequestID ?? requestID
            await runtimeDiagnostics?.updateDoubaoMetadata(
                requestID: requestID,
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
                throw DoubaoFailureClassifier.providerFailure(
                    code: frame.errorCode,
                    message: DoubaoFailureClassifier.errorMessage(from: frame.payload),
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
}

private struct DoubaoStreamingResponseBody: Decodable, Sendable {
    struct Result: Decodable, Sendable { let text: String? }
    let result: Result?
    let message: String?
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

/// Remembers the first structured failure the receiver saw so it can outrank
/// the transport error that closing the socket inflicts on the sender.
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
