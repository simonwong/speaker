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
        case probeEnded
    }

    private let connection: any DoubaoWebSocketConnection
    private let requestID: String
    private let runtimeDiagnostics: VoiceProviderRuntimeDiagnostics?
    private let liveness: TransportLivenessProbe
    private let closeGate: DoubaoWebSocketCloseGate
    private let failurePriority = DoubaoExchangeFailurePriority()

    package init(
        connection: any DoubaoWebSocketConnection,
        requestID: String,
        runtimeDiagnostics: VoiceProviderRuntimeDiagnostics?,
        liveness: TransportLivenessProbe = .live
    ) {
        self.connection = connection
        self.requestID = requestID
        self.runtimeDiagnostics = runtimeDiagnostics
        self.liveness = liveness
        closeGate = DoubaoWebSocketCloseGate(connection: connection)
    }

    /// Sends `requestPayload` and the audio in `chunks`. When `audioCaptureCompletion`
    /// is given, the final audio frame waits for it: a rejected capture sends
    /// no final frame and ends the exchange as cancelled.
    package func run(
        requestPayload: Data,
        audio chunks: AsyncStream<Data>,
        audioCaptureCompletion: AudioCaptureCompletionGate? = nil
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
                let result = try await exchangeAudio(
                    chunks, audioCaptureCompletion: audioCaptureCompletion)
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
                    let failure = await failurePriority.preferredFailure()
                {
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
    /// finished: audio fully sent and a final result received. After the
    /// final audio frame, a liveness probe runs beside the receiver.
    private func exchangeAudio(
        _ chunks: AsyncStream<Data>,
        audioCaptureCompletion: AudioCaptureCompletionGate?
    ) async throws -> TranscriptionResult {
        try await withThrowingTaskGroup(
            of: Event.self,
            returning: TranscriptionResult.self
        ) { group in
            group.addTask {
                do {
                    try await sendAudio(chunks, audioCaptureCompletion: audioCaptureCompletion)
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
                    // When the liveness probe closed the socket, the receive
                    // ended without a final result because the connection
                    // was lost, not because of the close it inflicted.
                    let failure: DoubaoASRFailure
                    if let loss = await failurePriority.connectionLoss() {
                        failure = loss
                    } else {
                        failure = DoubaoFailureClassifier.transportFailure(
                            error,
                            metadata: await connection.metadata(),
                            fallbackRequestID: requestID
                        )
                    }
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
                    if finalResult == nil {
                        group.addTask { try await watchLiveness() }
                    }
                case .finalResult(let result):
                    finalResult = result
                case .probeEnded:
                    break
                }
                if didFinishSending, let finalResult {
                    // A normal return awaits remaining children without
                    // cancelling them; the liveness probe never ends alone.
                    group.cancelAll()
                    return finalResult
                }
            }
            throw DoubaoASRFailure(kind: .invalidResponse, providerRequestID: requestID)
        }
    }

    /// A failed ping closes the socket and leaves the verdict to the
    /// receiver: a final result or error frame already queued still wins, and
    /// only a receive that ends without one is connection loss. An unanswered
    /// ping keeps the session Waiting For Result.
    private func watchLiveness() async throws -> Event {
        do {
            try await liveness.watch { try await connection.ping() }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if !(error is CancellationError) {
                await failurePriority.recordConnectionLoss(
                    DoubaoFailureClassifier.transportFailure(
                        error,
                        metadata: await connection.metadata(),
                        fallbackRequestID: requestID
                    ))
                await closeGate.close()
            }
        }
        return .probeEnded
    }

    private func sendAudio(
        _ chunks: AsyncStream<Data>,
        audioCaptureCompletion: AudioCaptureCompletionGate?
    ) async throws {
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
        // The stream also ends when a capture fails or is cancelled. Only a
        // capture the session accepted may end with a final frame.
        try await audioCaptureCompletion?.wait()
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
                    !text.isEmpty
                {
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
    private var lostConnection: DoubaoASRFailure?

    /// A failed liveness ping. It names the failure only if the receiver then
    /// ends without a final result or an error frame.
    func recordConnectionLoss(_ failure: DoubaoASRFailure) {
        guard lostConnection == nil else { return }
        lostConnection = failure
    }

    func connectionLoss() -> DoubaoASRFailure? {
        lostConnection
    }

    func recordReceiverFailure(_ failure: DoubaoASRFailure) {
        guard receiverFailure == nil else { return }
        receiverFailure = failure
    }

    func preferredFailure() -> DoubaoASRFailure? {
        receiverFailure
    }
}
