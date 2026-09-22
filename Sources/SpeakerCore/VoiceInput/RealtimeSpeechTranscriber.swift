import Foundation

package struct RealtimeSpeechTranscriber: Sendable {
    private let connector: any RealtimeSpeechConnecting

    package init(connector: any RealtimeSpeechConnecting) { self.connector = connector }

    package func transcribe(
        _ chunks: AsyncStream<Data>, profile: SpeechRecognitionProfile,
        apiKey: String, context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        guard context.hotwords.count <= 1_000,
            context.hotwords.reduce(0, { $0 + $1.utf8.count }) <= 16_384
        else {
            throw SpeechRecognitionFailure(provider: profile.provider, kind: .invalidConfiguration)
        }
        var request = URLRequest(url: Self.endpoint(profile))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let connection: any RealtimeSpeechConnection
        do { connection = try await connector.connect(request) } catch {
            try Task.checkCancellation()
            throw Self.classify(error, provider: profile.provider)
        }
        let state = RealtimeSpeechState(provider: profile.provider)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let result = try await exchange(
                    connection, state: state, chunks: chunks, profile: profile, context: context)
                await connection.close()
                try Task.checkCancellation()
                return result
            } catch {
                await state.cancel()
                await connection.close()
                try Task.checkCancellation()
                if let failure = await state.failure { throw failure }
                if await state.isCancelled { throw CancellationError() }
                if error is CancellationError { throw CancellationError() }
                if let failure = error as? SpeechRecognitionFailure { throw failure }
                throw Self.classify(error, provider: profile.provider)
            }
        } onCancel: {
            Task {
                await state.cancel()
                await connection.close()
            }
        }
    }

    private enum Event: Sendable {
        case sent
        case result(TranscriptionResult)
    }

    private func exchange(
        _ connection: any RealtimeSpeechConnection, state: RealtimeSpeechState,
        chunks: AsyncStream<Data>, profile: SpeechRecognitionProfile,
        context: SpeechTranscriptionContext
    ) async throws -> TranscriptionResult {
        try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask {
                do {
                    try await state.waitForCreation()
                    try await state.beginUpdate()
                    try await connection.send(
                        Self.sessionUpdate(profile, hotwords: context.hotwords))
                    try await state.waitForUpdate()
                    try await Self.sendAudio(
                        connection, state: state, chunks: chunks, profile: profile,
                        completion: context.audioCaptureCompletion)
                    return .sent
                } catch {
                    if error is CancellationError {
                        await state.cancel()
                    } else {
                        await state.record(Self.classify(error, provider: profile.provider))
                    }
                    await connection.close()
                    throw error
                }
            }
            group.addTask {
                do {
                    return .result(
                        try await Self.receive(connection, state: state, profile: profile))
                } catch {
                    if error is CancellationError {
                        await state.cancel()
                    } else {
                        await state.record(Self.classify(error, provider: profile.provider))
                    }
                    await connection.close()
                    throw error
                }
            }
            var result: TranscriptionResult?
            var sent = false
            while let event = try await group.next() {
                switch event {
                case .sent: sent = true
                case .result(let value): result = value
                }
                if sent, let result { return result }
            }
            throw SpeechRecognitionFailure(provider: profile.provider, kind: .invalidResponse)
        }
    }

    private static func sendAudio(
        _ connection: any RealtimeSpeechConnection, state: RealtimeSpeechState,
        chunks: AsyncStream<Data>, profile: SpeechRecognitionProfile,
        completion: AudioCaptureCompletionGate?
    ) async throws {
        let maximum =
            (CredentialedSpeechTranscriber.maximumAudioSeconds(for: profile.provider) ?? 300)
            * 32_000
        var total = 0
        var converter = RealtimePCMResampler()
        var pendingByte: UInt8?
        for await chunk in chunks {
            try Task.checkCancellation()
            guard chunk.count <= maximum - total else {
                throw SpeechRecognitionFailure(provider: profile.provider, kind: .audioTooLarge)
            }
            total += chunk.count
            var offset = chunk.startIndex
            while offset < chunk.endIndex {
                try Task.checkCancellation()
                let end = min(chunk.endIndex, offset + 6_400)
                var input = Data(chunk[offset..<end])
                let output: Data
                if profile.provider == .openAI {
                    output = try converter.append(input)
                } else {
                    if let pendingByte { input.insert(pendingByte, at: 0) }
                    pendingByte = input.count.isMultiple(of: 2) ? nil : input.removeLast()
                    output = input
                }
                if !output.isEmpty {
                    try await connection.send(
                        event(
                            "input_audio_buffer.append",
                            fields: ["audio": output.base64EncodedString()]))
                }
                offset = end
            }
        }
        try Task.checkCancellation()
        guard total > 0, total.isMultiple(of: 2) else {
            throw SpeechRecognitionFailure(provider: profile.provider, kind: .invalidAudio)
        }
        try await completion?.wait()
        try Task.checkCancellation()
        if profile.provider == .openAI {
            let tail = try converter.append(Data(), final: true)
            if !tail.isEmpty {
                try await connection.send(
                    event(
                        "input_audio_buffer.append", fields: ["audio": tail.base64EncodedString()]))
            }
        }
        try Task.checkCancellation()
        try await state.beginCommit()
        try Task.checkCancellation()
        try await connection.send(event("input_audio_buffer.commit"))
        if profile.provider == .qwen {
            try Task.checkCancellation()
            try await state.beginFinish()
            try await connection.send(event("session.finish"))
        }
    }

    private static func receive(
        _ connection: any RealtimeSpeechConnection, state: RealtimeSpeechState,
        profile: SpeechRecognitionProfile
    ) async throws -> TranscriptionResult {
        var cumulativeBytes = 0
        var final: TranscriptionResult?
        while true {
            try Task.checkCancellation()
            let text = try await connection.receive()
            try Task.checkCancellation()
            cumulativeBytes += text.utf8.count
            guard text.utf8.count <= CredentialedSpeechTranscriber.maximumResponseByteCount,
                cumulativeBytes <= 32 * 1_024 * 1_024
            else {
                throw SpeechRecognitionFailure(provider: profile.provider, kind: .responseTooLarge)
            }
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                let type = object["type"] as? String
            else {
                throw SpeechRecognitionFailure(provider: profile.provider, kind: .invalidResponse)
            }
            switch type {
            case "session.created", "transcription_session.created":
                try await state.created()
            case "session.updated", "transcription_session.updated":
                guard let session = object["session"] as? [String: Any],
                    validSession(session, profile: profile)
                else {
                    throw SpeechRecognitionFailure(
                        provider: profile.provider, kind: .invalidResponse)
                }
                try await state.updated()
            case "input_audio_buffer.committed":
                guard let item = object["item_id"] as? String, !item.isEmpty, item.utf8.count <= 200
                else {
                    throw SpeechRecognitionFailure(
                        provider: profile.provider, kind: .invalidResponse)
                }
                try await state.committed(item)
            case "conversation.item.input_audio_transcription.completed":
                guard let item = object["item_id"] as? String,
                    object["content_index"] as? Int == 0,
                    let transcript = object["transcript"] as? String
                else {
                    throw SpeechRecognitionFailure(
                        provider: profile.provider, kind: .invalidResponse)
                }
                try await state.validateResult(item)
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SpeechRecognitionFailure(provider: profile.provider, kind: .emptyResponse)
                }
                guard final == nil else {
                    throw SpeechRecognitionFailure(
                        provider: profile.provider, kind: .invalidResponse)
                }
                final = .init(
                    text: transcript,
                    providerRequestID: SpeechRecognitionFailure.safeIdentifier(item))
                if profile.provider == .openAI { return final! }
            case "session.finished":
                guard profile.provider == .qwen else {
                    throw SpeechRecognitionFailure(
                        provider: profile.provider, kind: .invalidResponse)
                }
                try await state.validateFinish()
                guard let final else {
                    throw SpeechRecognitionFailure(provider: profile.provider, kind: .emptyResponse)
                }
                return final
            case "error", "conversation.item.input_audio_transcription.failed":
                let error = object["error"] as? [String: Any]
                let code = error?["code"] as? String
                let kind: SpeechRecognitionFailureKind
                switch code?.lowercased() {
                case "invalid_api_key", "invalidapikey", "authentication_error", "unauthorized":
                    kind = .authentication
                case "rate_limit_exceeded", "rate_limit_error", "throttling",
                    "throttling.ratequota":
                    kind = .rateLimited
                default: kind = .rejected
                }
                throw SpeechRecognitionFailure(provider: profile.provider, kind: kind, code: code)
            default: break
            }
        }
    }

    private static func classify(_ error: any Error, provider: SpeechRecognitionProviderID)
        -> SpeechRecognitionFailure
    {
        if let failure = error as? SpeechRecognitionFailure { return failure }
        if case RealtimeSpeechTransportError.httpStatus(let status) = error {
            return .init(
                provider: provider,
                kind: status == 401 || status == 403
                    ? .authentication : status == 429 ? .rateLimited : .rejected,
                httpStatusCode: status)
        }
        return .init(
            provider: provider,
            kind: error is RealtimeSpeechTransportError ? .invalidResponse : .transport)
    }

    private static func endpoint(_ profile: SpeechRecognitionProfile) -> URL {
        if profile.provider == .openAI {
            return URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        }
        let host =
            profile.region == .beijing ? "dashscope.aliyuncs.com" : "dashscope-intl.aliyuncs.com"
        var components = URLComponents(string: "wss://\(host)/api-ws/v1/realtime")!
        components.queryItems = [.init(name: "model", value: profile.model)]
        return components.url!
    }

    private static func sessionUpdate(_ profile: SpeechRecognitionProfile, hotwords: [String])
        throws -> String
    {
        let session: [String: Any]
        if profile.provider == .openAI {
            var transcription: [String: Any] = ["model": profile.model, "delay": "high"]
            if !hotwords.isEmpty { transcription["prompt"] = hotwords.joined(separator: ", ") }
            session = [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription, "turn_detection": NSNull(),
                    ]
                ],
            ]
        } else {
            var transcription: [String: Any] = [:]
            if !hotwords.isEmpty {
                transcription["corpus"] = ["text": hotwords.joined(separator: ", ")]
            }
            session = [
                "input_audio_format": "pcm", "sample_rate": 16_000,
                "input_audio_transcription": transcription, "turn_detection": NSNull(),
            ]
        }
        return try event("session.update", fields: ["session": session])
    }

    private static func validSession(_ session: [String: Any], profile: SpeechRecognitionProfile)
        -> Bool
    {
        if profile.provider == .openAI {
            guard session["type"] as? String == "transcription",
                let audio = session["audio"] as? [String: Any],
                let input = audio["input"] as? [String: Any],
                let format = input["format"] as? [String: Any],
                format["type"] as? String == "audio/pcm",
                format["rate"] as? Int == 24_000,
                let transcription = input["transcription"] as? [String: Any],
                transcription["model"] as? String == profile.model
            else { return false }
            return input["turn_detection"] is NSNull
        }
        let format = session["input_audio_format"] as? String
        return session["turn_detection"] is NSNull && (format == "pcm" || format == "pcm16")
            && (session["sample_rate"] == nil || session["sample_rate"] as? Int == 16_000)
            && (session["model"] == nil || session["model"] as? String == profile.model)
    }

    private static func event(_ type: String, fields: [String: Any] = [:]) throws -> String {
        var object = fields
        object["type"] = type
        object["event_id"] = UUID().uuidString
        return String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self)
    }
}

private actor RealtimeSpeechState {
    private let provider: SpeechRecognitionProviderID
    private var creation = false
    private var update = false
    private var updateStarted = false
    private var cancelled = false
    private var commitStarted = false
    private var finishStarted = false
    private var committedItem: String?
    private var creationWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var updateWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var failure: SpeechRecognitionFailure?
    var isCancelled: Bool { cancelled }

    init(provider: SpeechRecognitionProviderID) { self.provider = provider }

    func waitForCreation() async throws { try await wait(forUpdate: false) }
    func waitForUpdate() async throws { try await wait(forUpdate: true) }

    private func wait(forUpdate: Bool) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if forUpdate ? update : creation {
                    continuation.resume()
                } else if forUpdate {
                    updateWaiters[id] = continuation
                } else {
                    creationWaiters[id] = continuation
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func created() throws {
        guard !creation, !cancelled else { throw invalid() }
        creation = true
        let pending = creationWaiters.values
        creationWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func beginUpdate() throws {
        guard creation, !updateStarted, !cancelled else { throw invalid() }
        updateStarted = true
    }

    func updated() throws {
        guard creation, updateStarted, !update, !cancelled else { throw invalid() }
        update = true
        let pending = updateWaiters.values
        updateWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func beginCommit() throws {
        guard update, !cancelled, !commitStarted else { throw invalid() }
        commitStarted = true
    }

    func committed(_ item: String) throws {
        guard commitStarted, !cancelled, committedItem == nil else { throw invalid() }
        committedItem = item
    }

    func validateResult(_ item: String) throws {
        guard !cancelled, committedItem == item else { throw invalid() }
    }

    func beginFinish() throws {
        guard commitStarted, !cancelled else { throw invalid() }
        finishStarted = true
    }

    func validateFinish() throws {
        guard finishStarted, !cancelled else { throw invalid() }
    }

    func record(_ failure: SpeechRecognitionFailure) {
        guard !cancelled else { return }
        if self.failure == nil { self.failure = failure }
        cancel()
    }

    func cancel() {
        cancelled = true
        let pending = Array(creationWaiters.values) + Array(updateWaiters.values)
        creationWaiters.removeAll()
        updateWaiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    private func cancelWaiter(_ id: UUID) {
        creationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        updateWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func invalid() -> SpeechRecognitionFailure {
        .init(provider: provider, kind: .invalidResponse)
    }
}
