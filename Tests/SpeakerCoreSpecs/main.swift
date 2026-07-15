import Foundation
import Darwin
import SpeakerCore

@main
struct SpeakerCoreSpecs {
    @MainActor
    static func main() async {
        var failures: [String] = []

        run("initial snapshot comes from permission access", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .notDetermined)
            )

            let model = PermissionModel(access: access)

            try expect(model.snapshot == .init(
                accessibility: .denied,
                microphone: .notDetermined
            ))
            try expect(!model.snapshot.allGranted)
        }

        run("refresh publishes current permission snapshot", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .denied)
            )
            let model = PermissionModel(access: access)
            access.snapshot = .init(accessibility: .granted, microphone: .granted)

            model.refresh()

            try expect(model.snapshot == .init(
                accessibility: .granted,
                microphone: .granted
            ))
            try expect(model.snapshot.allGranted)
        }

        await runAsync("request updates snapshot with provider result", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .granted)
            )
            access.requestResults[.accessibility] = .init(
                accessibility: .granted,
                microphone: .granted
            )
            let model = PermissionModel(access: access)

            await model.request(.accessibility)

            try expect(access.requestedPermissions == [.accessibility])
            try expect(model.snapshot == .init(
                accessibility: .granted,
                microphone: .granted
            ))
        }

        await runAsync("first launch requests an undetermined microphone once", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .notDetermined)
            )
            access.requestResults[.microphone] = .init(
                accessibility: .denied,
                microphone: .granted
            )
            let model = PermissionModel(access: access)

            await model.requestMicrophoneIfNeeded()
            await model.requestMicrophoneIfNeeded()

            try expect(access.requestedPermissions == [.microphone])
            try expect(model.snapshot.microphone == .granted)
        }

        await runAsync("first launch does not reprompt a denied microphone", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .denied)
            )
            let model = PermissionModel(access: access)

            await model.requestMicrophoneIfNeeded()

            try expect(access.requestedPermissions.isEmpty)
        }

        await runAsync("first launch requests missing accessibility for the active bundle", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .granted)
            )
            let model = PermissionModel(access: access)

            await model.requestAccessibilityIfNeeded()

            try expect(access.requestedPermissions == [.accessibility])
        }

        await runAsync("hold and release delivers deterministic transcript", failures: &failures) {
            let audio = AudioCaptureFake()
            let targets = TargetCaptureFake(
                result: .writable(.init(
                    id: UUID(),
                    applicationName: "TextEdit"
                ))
            )
            let transcriber = SpeechTranscriberFake(text: "你好，SwiftUI。")
            let delivery = TextDeliveryFake(result: .delivered)
            let clipboard = ClipboardFake()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                transcriber: transcriber,
                delivery: delivery,
                clipboard: clipboard,
                history: history
            )
            let presentations = await sessions.observe()
            let terminal = Task { () -> [VoiceInputPresentation] in
                var values: [VoiceInputPresentation] = []
                for await presentation in presentations {
                    values.append(presentation)
                    if presentation.activity.isTerminal {
                        break
                    }
                }
                return values
            }

            await sessions.send(.pressed)
            await sessions.send(.released)

            let values = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            let records = await history.records

            try expect(values.contains { $0.activity.isRecording })
            try expect(values.contains { $0.activity.stage == .transcribing })
            try expect(values.last?.activity.isDelivered == true)
            try expect(zip(values, values.dropFirst()).allSatisfy { $0.revision < $1.revision })
            try expect(deliveredTexts == ["你好，SwiftUI。"])
            try expect(records.count == 1)
            try expect(records.first?.finalText == "你好，SwiftUI。")
            try expect(records.first?.providerRequestID == "local-spec")
        }

        await runAsync("release during recorder startup still completes once", failures: &failures) {
            let audio = AudioCaptureFake(delaysStart: true)
            let targets = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
            )
            let transcriber = SpeechTranscriberFake(text: "短按也不会丢。")
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let press = Task { await sessions.send(.pressed) }
            while await audio.startCount == 0 {
                await Task.yield()
            }
            await sessions.send(.released)
            await audio.resumeStart()
            await press.value
            await Task.yield()

            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts

            try expect(stopCount == 1)
            try expect(deliveredTexts == ["短按也不会丢。"])
        }

        await runAsync("cancel during recorder startup cleans late recording", failures: &failures) {
            let audio = AudioCaptureFake(delaysStart: true)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "不应出现"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            let press = Task { await sessions.send(.pressed) }
            while await audio.startCount == 0 {
                await Task.yield()
            }
            await sessions.send(.cancel)
            await audio.resumeStart()
            await press.value

            let isActive = await audio.isActive
            try expect(!isActive)
        }

        await runAsync("recorder start failure preserves preparation timing", failures: &failures) {
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: DelayedFailingStartAudioCapture(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )

            await sessions.send(.pressed)

            let record = await history.records.last
            try expect(record?.outcome.isRecordingFailed == true)
            try expect((record?.durationMilliseconds ?? 0) > 0)
            try expect((record?.stageDurationsMilliseconds["preparing"] ?? 0) > 0)
        }

        await runAsync("recording watchdog finishes and submits session", failures: &failures) {
            let audio = AudioCaptureFake()
            let watchdog = RecordingWatchdogFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "已自动提交。"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                watchdog: watchdog
            )
            let presentations = await sessions.observe()
            let terminal = Task { () -> VoiceInputPresentation? in
                for await presentation in presentations {
                    if presentation.activity.isTerminal {
                        return presentation
                    }
                }
                return nil
            }

            await sessions.send(.pressed)
            while await watchdog.waitCount == 0 {
                await Task.yield()
            }
            await watchdog.fire()

            let result = await terminal.value
            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts
            try expect(result?.activity.isDelivered == true)
            try expect(stopCount == 1)
            try expect(deliveredTexts == ["已自动提交。"])
        }

        await runAsync("missing target waits for explicit copy", failures: &failures) {
            let clipboard = ClipboardFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "请手动复制。"),
                delivery: delivery,
                clipboard: clipboard,
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            let copiedBefore = await clipboard.copiedTexts
            try expect(result?.activity.pendingCopyReason == .missingTarget)
            try expect(deliveredTexts.isEmpty)
            try expect(copiedBefore.isEmpty)

            await sessions.send(.copyPendingResult)
            let copiedAfter = await clipboard.copiedTexts
            try expect(copiedAfter == ["请手动复制。"])
        }

        await runAsync("secure target never receives automatic text", failures: &failures) {
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.secureTarget)),
                transcriber: SpeechTranscriberFake(text: "敏感文本"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            let record = await history.records.first
            try expect(result?.activity.pendingCopyReason == .secureTarget)
            try expect(deliveredTexts.isEmpty)
            try expect(record?.transcription == nil)
            try expect(record?.finalText == nil)
            try expect(record?.deepSeekText == nil)
            try expect(record?.outcome.pendingText == "")
        }

        await runAsync("delivery failure keeps transcript pending copy", failures: &failures) {
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "结果不能丢。"),
                delivery: TextDeliveryFake(result: .pendingCopy(.invalidatedTarget)),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            try expect(result?.activity.pendingCopyReason == .invalidatedTarget)
            try expect(result?.activity.pendingText == "结果不能丢。")
        }

        await runAsync("duplicate trigger edges submit only once", failures: &failures) {
            let audio = AudioCaptureFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "只提交一次。"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            await sessions.send(.pressed)
            await sessions.send(.released)
            await sessions.send(.released)

            let startCount = await audio.startCount
            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts
            try expect(startCount == 1)
            try expect(stopCount == 1)
            try expect(deliveredTexts == ["只提交一次。"])
        }

        await runAsync("global trigger dispatcher preserves quick press-release order", failures: &failures) {
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "顺序正确。"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)

            dispatcher.send(.pressed)
            dispatcher.send(.released)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            dispatcher.finish()
            try expect(result?.activity.isDelivered == true)
            try expect(deliveredTexts == ["顺序正确。"])
        }

        await runAsync("trigger dispatcher shutdown cancels in-flight processing before waiting", failures: &failures) {
            let transcriber = SpeechTranscriberFake(text: "不得送达", delaysResponse: true)
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            dispatcher.send(.pressed)
            dispatcher.send(.released)
            while await transcriber.callCount == 0 { await Task.yield() }

            let shutdown = Task { await dispatcher.shutdown() }
            while await transcriber.cancellationCount == 0 { await Task.yield() }
            await transcriber.resume()
            await shutdown.value

            let deliveredTexts = await delivery.deliveredTexts
            let record = await history.records.last
            try expect(deliveredTexts.isEmpty)
            try expect(record?.outcome.isCancelled == true)
            try expect(record?.applicationName == "TextEdit")
            try expect(record?.stageDurationsMilliseconds["doubao"] != nil)
        }

        await runAsync("queued trigger cancel preempts an in-flight provider request", failures: &failures) {
            let transcriber = SpeechTranscriberFake(text: "不得送达", delaysResponse: true)
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            let dispatcher = VoiceInputTriggerDispatcher(sessions: sessions)
            dispatcher.send(.pressed)
            dispatcher.send(.released)
            while await transcriber.callCount == 0 { await Task.yield() }

            dispatcher.send(.cancel)
            while await transcriber.cancellationCount == 0 { await Task.yield() }
            while await history.records.last?.outcome.isCancelled != true { await Task.yield() }

            let deliveredTexts = await delivery.deliveredTexts
            try expect(deliveredTexts.isEmpty)
            await transcriber.resume()
            dispatcher.finish()
        }

        await runAsync("trigger cancellation fence cannot cancel a later session", failures: &failures) {
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "后续会话"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed, triggerSequence: 2)
            await sessions.cancel(triggeredAtSequence: 1)
            await sessions.send(.released)

            let deliveredTexts = await delivery.deliveredTexts
            try expect(deliveredTexts == ["后续会话"])
        }

        await runAsync("cancel wins over a late recorder stop failure and discards target", failures: &failures) {
            let audio = DelayedFailingStopAudioCapture()
            let target = DiscardingTargetCaptureFake(
                snapshot: .init(id: UUID(), applicationName: "TextEdit")
            )
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: target,
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await audio.stopCount == 0 { await Task.yield() }
            await sessions.send(.cancel)
            await audio.failStop()
            await release.value

            let outcome = await history.records.last?.outcome
            let discardedCount = await target.discardedCount
            try expect(outcome?.isCancelled == true)
            try expect(discardedCount == 1)
        }

        await runAsync("cancel wins delivery commit gate before any text mutation", failures: &failures) {
            let delivery = DelayedCommitDeliveryFake()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "不得提交"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )
            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await delivery.entered == false { await Task.yield() }
            await sessions.send(.cancel)
            await delivery.allowCommitAttempt()
            await release.value

            let deliveredTexts = await delivery.deliveredTexts
            let record = await history.records.last
            try expect(deliveredTexts.isEmpty)
            try expect(record?.outcome.isCancelled == true)
            try expect(record?.applicationName == "TextEdit")
            try expect(record?.stageDurationsMilliseconds["delivery"] != nil)
        }

        await runAsync("cancelled late transcription cannot deliver", failures: &failures) {
            let transcriber = SpeechTranscriberFake(text: "迟到结果", delaysResponse: true)
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await transcriber.callCount == 0 {
                await Task.yield()
            }
            await sessions.send(.cancel)
            await transcriber.resume()
            await release.value

            let deliveredTexts = await delivery.deliveredTexts
            let cancellationCount = await transcriber.cancellationCount
            try expect(deliveredTexts.isEmpty)
            try expect(cancellationCount == 1, "active provider request was not cancelled")
        }

        await runAsync("live PCM reaches streaming processor before shortcut release", failures: &failures) {
            let audio = StreamingAudioCaptureFake()
            let processor = StreamingVoiceTextProcessorFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            await audio.emit(Data([1, 2, 3, 4]))
            while await processor.receivedChunkCount == 0 {
                await Task.yield()
            }
            let stopCountDuringRecording = await audio.stopCount
            try expect(stopCountDuringRecording == 0, "audio was not streamed during recording")

            await sessions.send(.released)

            let receivedChunkCount = await processor.receivedChunkCount
            let deliveredTexts = await delivery.deliveredTexts
            try expect(receivedChunkCount == 1)
            try expect(deliveredTexts == ["流式结果"])
        }

        await runAsync("Doubao WebSocket uses streaming headers and binary frames", failures: &failures) {
            let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "  你好，世界。  ", isFinal: true)],
                metadata: .init(httpStatusCode: 101, providerRequestID: "log-12")
            )
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let client = DoubaoStreamingASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    installationID: "local-installation",
                    hotwords: ["Speaker"]
                ),
                connector: connector,
                requestIDGenerator: { requestID }
            )

            let result = try await client.transcribe(
                makeAudioStream([Data([1, 2]), Data([3, 4])])
            )
            let request = try await connector.onlyRequest()
            let frames = await connection.sentFrames
            try expect(frames.count == 3)
            let fullRequest = try DoubaoStreamingFrameCodec.decode(frames[0])
            let firstAudio = try DoubaoStreamingFrameCodec.decode(frames[1])
            let finalAudio = try DoubaoStreamingFrameCodec.decode(frames[2])
            let body = try JSONSerialization.jsonObject(with: fullRequest.payload) as? [String: Any]
            let recognition = body?["request"] as? [String: Any]
            let audio = body?["audio"] as? [String: Any]

            try expect(request.url == DoubaoStreamingASRConfiguration.defaultEndpoint)
            try expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-api-key")
            try expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration")
            try expect(request.value(forHTTPHeaderField: "X-Api-Request-Id") == requestID.uuidString)
            try expect(request.value(forHTTPHeaderField: "X-Api-Connect-Id") == requestID.uuidString)
            try expect(request.value(forHTTPHeaderField: "X-Api-Sequence") == "-1")
            try expect(recognition?["enable_itn"] as? Bool == true)
            try expect(recognition?["enable_punc"] as? Bool == true)
            try expect(recognition?["enable_ddc"] as? Bool == true)
            try expect(audio?["format"] as? String == "pcm")
            try expect(audio?["rate"] as? Int == 16_000)
            try expect(fullRequest.messageType == 0x01)
            try expect(firstAudio.payload == Data([1, 2]) && !firstAudio.isFinal)
            try expect(finalAudio.payload == Data([3, 4]) && finalAudio.isFinal)
            try expect(result == .init(text: "你好，世界。", providerRequestID: "log-12"))
        }

        await runAsync("Doubao maps silence without exposing a transcript", failures: &failures) {
            let client = makeDoubaoClient(
                responses: [makeDoubaoServerResponse(text: nil, isFinal: true)],
                metadata: .init(httpStatusCode: 101, providerRequestID: "silent-log")
            )
            do {
                _ = try await client.transcribe(makeAudioStream([Data([0, 0])]))
                throw SpecFailure(message: "silence response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .emptyTranscript)
                try expect(failure.providerRequestID == "silent-log")
            }
        }

        await runAsync("Doubao distinguishes inactive resource from bad credential", failures: &failures) {
            let inactive = makeDoubaoClient(responses: [
                makeDoubaoServerError(code: 45_000_001, message: "resource not activated")
            ])
            do {
                _ = try await inactive.transcribe(makeAudioStream([Data([1, 2])]))
                throw SpecFailure(message: "inactive resource response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .resourceNotActivated)
            }

            let unauthorized = makeDoubaoClient(
                receiveError: URLError(.badServerResponse),
                metadata: .init(httpStatusCode: 401, providerMessage: "unauthorized api key")
            )
            do {
                _ = try await unauthorized.transcribe(makeAudioStream([Data([1, 2])]))
                throw SpecFailure(message: "invalid credential response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .invalidCredential)
            }
        }

        await runAsync("credential-backed Doubao transcriber loads the current Keychain value", failures: &failures) {
            let credentials = ProviderCredentialStoreFake(values: [.doubao: "first-key"])
            let connection = DoubaoWebSocketConnectionFake(
                responses: [makeDoubaoServerResponse(text: "第一条", isFinal: true)]
            )
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                installationID: "installation-spec",
                connector: connector
            )

            _ = try await transcriber.transcribe(specAudio)
            let firstRequest = try await connector.onlyRequest()
            try expect(firstRequest.value(forHTTPHeaderField: "X-Api-Key") == "first-key")
        }

        await runAsync("credential-backed Doubao transcriber fails before network when unconfigured", failures: &failures) {
            let credentials = ProviderCredentialStoreFake()
            let connection = DoubaoWebSocketConnectionFake(responses: [])
            let connector = DoubaoWebSocketConnectorFake(connection: connection)
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                installationID: "installation-spec",
                connector: connector
            )

            do {
                _ = try await transcriber.transcribe(specAudio)
                throw SpecFailure(message: "unconfigured transcriber sent a request")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .invalidCredential)
                let requestCount = await connector.requestCount
                try expect(requestCount == 0)
            }
        }

        await runAsync("Doubao failure becomes stable user state and diagnostic history", failures: &failures) {
            let history = SessionHistoryFake()
            let target = DiscardingTargetCaptureFake(
                snapshot: .init(id: UUID(), applicationName: "TextEdit")
            )
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: target,
                textProcessor: NormalizedFailureProcessor(failure: .init(
                    userFailure: .providerNotConfigured,
                    providerDiagnostic: .init(
                        provider: "doubao",
                        requestID: "provider-log-id",
                        code: "invalidCredential"
                    )
                )),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let presentation = await terminal.value
            let record = await history.records.first
            if case let .failed(_, failure) = presentation?.activity {
                try expect(failure == .providerNotConfigured)
            } else {
                throw SpecFailure(message: "provider failure did not reach terminal UI state")
            }
            try expect(record?.providerRequestID == "provider-log-id")
            try expect(record?.providerErrorCode == "invalidCredential")
            try expect(record?.transcriptionProvider == "doubao")
            try expect(record?.applicationName == "TextEdit")
            let discardedCount = await target.discardedCount
            try expect(discardedCount == 1)
        }

        await runAsync("history persistence failure is visible on the terminal session", failures: &failures) {
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "仍可使用"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(failureNotice: "会话历史写入失败：磁盘不可用")
            )
            let terminal = terminalPresentation(from: await sessions.observe())
            await sessions.send(.pressed)
            await sessions.send(.released)
            let presentation = await terminal.value
            try expect(presentation?.notice?.contains("会话历史写入失败") == true)
            try expect(presentation?.activity.pendingText == "仍可使用")
        }

        await runAsync("voice text processing owns Doubao failure normalization", failures: &failures) {
            let cases: [(DoubaoASRFailureKind, VoiceInputFailure)] = [
                (.invalidCredential, .providerNotConfigured),
                (.silence, .noSpeechDetected),
                (.emptyAudio, .noSpeechDetected),
                (.emptyTranscript, .noSpeechDetected),
                (.resourceNotActivated, .providerResourceUnavailable),
                (.rateLimited, .providerRateLimited),
                (.network, .networkUnavailable),
                (.serverBusy, .providerUnavailable),
                (.serviceUnavailable, .providerUnavailable),
                (.cancelled, .transcriptionFailed),
                (.invalidRequest, .transcriptionFailed),
                (.invalidAudioFormat, .transcriptionFailed),
                (.invalidResponse, .transcriptionFailed),
            ]

            for (kind, expectedFailure) in cases {
                let processor = DefaultVoiceTextProcessor(
                    configuration: VoiceInputConfigurationController(),
                    doubao: DoubaoFailureTranscriber(failure: .init(
                        kind: kind,
                        providerRequestID: "doubao-mapping-log"
                    )),
                    refinement: OptionalTextRefinementPipeline(
                        refiner: DeepSeekRefinerFake(result: .success(.init(text: "unused")))
                    )
                )
                do {
                    _ = try await processor.process(specAudio, snapshot: .empty) { _ in }
                    throw SpecFailure(message: "\(kind.rawValue) escaped the processing seam")
                } catch let failure as VoiceTextProcessingFailure {
                    try expect(failure.userFailure == expectedFailure)
                    try expect(failure.providerDiagnostic == .init(
                        provider: "doubao",
                        requestID: "doubao-mapping-log",
                        code: kind.rawValue
                    ))
                }
            }
        }

        await runAsync("Keychain failures remain actionable provider diagnostics", failures: &failures) {
            let processor = DefaultVoiceTextProcessor(
                configuration: VoiceInputConfigurationController(),
                doubao: CredentialFailureTranscriber(error: .interactionUnavailable),
                refinement: OptionalTextRefinementPipeline(
                    refiner: DeepSeekRefinerFake(result: .success(.init(text: "unused")))
                )
            )
            do {
                _ = try await processor.process(specAudio, snapshot: .empty) { _ in }
                throw SpecFailure(message: "Keychain failure escaped the processing seam")
            } catch let failure as VoiceTextProcessingFailure {
                try expect(failure.userFailure == .providerCredentialUnavailable)
                try expect(failure.providerDiagnostic == .init(
                    provider: "doubao",
                    requestID: nil,
                    code: "credential.interactionUnavailable"
                ))
            }
        }

        await runAsync("default smooth refinement never calls DeepSeek", failures: &failures) {
            let refiner = DeepSeekRefinerFake(result: .success(.init(text: "不应采用")))
            let pipeline = OptionalTextRefinementPipeline(refiner: refiner)

            let outcome = await pipeline.refine(
                doubaoText: "豆包默认顺滑",
                mode: .defaultSmooth
            )

            try expect(outcome.status == .notRequested)
            try expect(outcome.finalText == "豆包默认顺滑")
            let callCount = await refiner.callCount
            try expect(callCount == 0)
        }

        await runAsync("optional refinement succeeds or losslessly falls back to Doubao", failures: &failures) {
            let successfulRefiner = DeepSeekRefinerFake(
                result: .success(.init(text: "整理后的文本", providerRequestID: "ds-1"))
            )
            let successfulPipeline = OptionalTextRefinementPipeline(refiner: successfulRefiner)
            let success = await successfulPipeline.refine(
                doubaoText: "嗯 原始文本",
                mode: .conciseCleanup
            )
            try expect(success.status == .succeeded)
            try expect(success.deepSeekText == "整理后的文本")
            try expect(success.finalText == "整理后的文本")

            let failingRefiner = DeepSeekRefinerFake(
                result: .failure(.init(kind: .rateLimited, httpStatusCode: 429))
            )
            let fallbackPipeline = OptionalTextRefinementPipeline(refiner: failingRefiner)
            let fallback = await fallbackPipeline.refine(
                doubaoText: "豆包结果仍保留",
                mode: .fullRewrite
            )
            try expect(fallback.status == .fellBack)
            try expect(fallback.deepSeekText == nil)
            try expect(fallback.finalText == "豆包结果仍保留")
            try expect(fallback.failure?.kind == .rateLimited)
        }

        run("custom refinement modes reject empty and oversized prompts", failures: &failures) {
            do {
                _ = try TextRefinementMode.custom(name: "我的模式", prompt: " ").validated()
                throw SpecFailure(message: "empty custom prompt was accepted")
            } catch let error as TextRefinementModeValidationError {
                try expect(error == .emptyCustomPrompt)
            }

            do {
                _ = try TextRefinementMode.custom(
                    name: "我的模式",
                    prompt: String(repeating: "x", count: 4_001)
                ).validated()
                throw SpecFailure(message: "oversized custom prompt was accepted")
            } catch let error as TextRefinementModeValidationError {
                try expect(error == .customPromptTooLong)
            }
        }

        await runAsync("DeepSeek request disables thinking and requires strict JSON output", failures: &failures) {
            let transport = DeepSeekTransportFake(response: .init(
                statusCode: 200,
                headers: ["x-request-id": "ds-request-1"],
                body: Data(#"{"choices":[{"message":{"content":"{\"text\":\"  整理后  \"}"},"finish_reason":"stop"}]}"#.utf8)
            ))
            let client = DeepSeekRefinementClient(
                configuration: .init(apiKey: "deepseek-test-key"),
                transport: transport
            )

            let result = try await client.refine("嗯，原始文本。", using: .conciseCleanup)
            let request = try await transport.onlyRequest()
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let thinking = body?["thinking"] as? [String: Any]
            let responseFormat = body?["response_format"] as? [String: Any]

            try expect(request.url == DeepSeekRefinementConfiguration.defaultEndpoint)
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer deepseek-test-key")
            try expect(request.timeoutInterval == 20)
            try expect(body?["model"] as? String == "deepseek-v4-flash")
            try expect(thinking?["type"] as? String == "disabled")
            try expect(responseFormat?["type"] as? String == "json_object")
            try expect(body?["stream"] as? Bool == false)
            try expect(result == .init(text: "整理后", providerRequestID: "ds-request-1"))
        }

        await runAsync("DeepSeek rejects extra JSON fields and abnormal expansion", failures: &failures) {
            let extraFieldClient = makeDeepSeekClient(content: #"{"text":"结果","extra":true}"#)
            do {
                _ = try await extraFieldClient.refine("原文", using: .fullRewrite)
                throw SpecFailure(message: "extra JSON field was accepted")
            } catch let failure as DeepSeekRefinementFailure {
                try expect(failure.kind == .unexpectedJSONShape)
            }

            let expanded = String(repeating: "扩", count: 4_097)
            let expandedJSONData = try JSONEncoder().encode(["text": expanded])
            let expandedJSON = String(decoding: expandedJSONData, as: UTF8.self)
            let expandedClient = makeDeepSeekClient(content: expandedJSON)
            do {
                _ = try await expandedClient.refine("短文本", using: .fullRewrite)
                throw SpecFailure(message: "abnormally expanded output was accepted")
            } catch let failure as DeepSeekRefinementFailure {
                try expect(failure.kind == .outputTooLarge)
            }
        }

        await runAsync("DeepSeek enforces a wall-clock total timeout", failures: &failures) {
            let client = DeepSeekRefinementClient(
                configuration: .init(apiKey: "test-key", timeout: 0.05),
                transport: HangingDeepSeekTransport()
            )
            let startedAt = ContinuousClock().now
            do {
                _ = try await client.refine("原文", using: .conciseCleanup)
                throw SpecFailure(message: "hanging request escaped total timeout")
            } catch let failure as DeepSeekRefinementFailure {
                try expect(failure.kind == .timeout)
                try expect(startedAt.duration(to: .now) < .seconds(1))
            }
        }

        await runAsync("voice session freezes dictionary and refinement mode at press", failures: &failures) {
            let initialDictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "Swift", aliases: ["swift-lang"]),
            ])
            let configuration = VoiceInputConfigurationController(
                dictionary: initialDictionary,
                refinementMode: .conciseCleanup
            )
            let doubao = ContextualTranscriberFake(text: "Use swift-lang")
            let refiner = DeepSeekRefinerFake(result: .success(.init(text: "Use Swift.")))
            let processor = DefaultVoiceTextProcessor(
                configuration: configuration,
                doubao: doubao,
                refinement: OptionalTextRefinementPipeline(refiner: refiner)
            )
            let delivery = TextDeliveryFake(result: .delivered)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history
            )

            await sessions.send(.pressed)
            await configuration.replaceDictionary(.empty)
            try await configuration.selectRefinementMode(.fullRewrite)
            await sessions.send(.released)

            let hotwordCalls = await doubao.hotwordCalls
            let refinementModes = await refiner.modes
            let refinementInputs = await refiner.inputs
            let deliveredTexts = await delivery.deliveredTexts
            let record = await history.records.first
            try expect(hotwordCalls == [["Swift"]])
            try expect(refinementModes == [.conciseCleanup])
            try expect(refinementInputs == ["Use Swift"])
            try expect(deliveredTexts == ["Use Swift."])
            try expect(record?.transcription == "Use swift-lang")
            try expect(record?.deepSeekText == "Use Swift.")
            try expect(record?.refinementModeName == "精简清理")
            try expect(record?.refinementPrompt?.isEmpty == false)
            try expect(record?.refinementStatus == "succeeded")
            try expect(record?.dictionarySnapshotEntries.map(\.canonicalTerm) == ["Swift"])
            try expect(record?.dictionaryRequestContext?.hotwords == ["Swift"])
            try expect(record?.dictionaryReplacements.count == 1)
            try expect(record?.stageDurationsMilliseconds["targetCapture"] != nil)
            try expect(record?.stageDurationsMilliseconds["delivery"] != nil)
        }

        await runAsync("credential store rejects blank API keys", failures: &failures) {
            let store = KeychainProviderCredentialStore(
                service: "com.local.speaker.spec.\(UUID().uuidString)"
            )
            do {
                try await store.save(apiKey: "  \n ", for: .doubao)
                throw SpecFailure(message: "blank API key was accepted")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .emptyAPIKey)
            }
        }

        await runAsync("credential store round trips and deletes isolated API key", failures: &failures) {
            let store = KeychainProviderCredentialStore(
                service: "com.local.speaker.spec.\(UUID().uuidString)"
            )
            do {
                try await store.save(apiKey: "  local-test-key  ", for: .doubao)
                let storedKey = try await store.apiKey(for: .doubao)
                try expect(storedKey == "local-test-key")

                try await store.deleteAPIKey(for: .doubao)
                try await store.deleteAPIKey(for: .doubao)
                let deletedKey = try await store.apiKey(for: .doubao)
                try expect(deletedKey == nil)
            } catch let error as ProviderCredentialStoreError
                where error == .storageUnavailable || error == .interactionUnavailable {
                print("SKIP: Keychain round trip unavailable in this command-line environment")
            }
        }

        await runAsync("versioned local history persists searches deletes and excludes sensitive fields", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("history.json")
            let firstID = VoiceInputSessionID()
            let secondID = VoiceInputSessionID()
            let snapshotID = UUID()
            let dictionaryEntry = DictionaryEntry(canonicalTerm: "豆包", aliases: ["豆宝"])
            let store = VersionedLocalSessionHistory(fileURL: fileURL)
            await store.save(.init(
                sessionID: firstID,
                startedAt: Date(timeIntervalSince1970: 100),
                applicationName: "TextEdit",
                transcription: "豆包原文 alpha",
                finalText: "最终文本",
                transcriptionProvider: "doubao",
                providerRequestID: "request-log-1",
                providerErrorCode: nil,
                deepSeekText: "DeepSeek 结果 beta",
                deepSeekRequestID: "deepseek-log-1",
                refinementModeName: "精简清理",
                refinementPrompt: "只清理口语杂质",
                refinementStatus: "succeeded",
                dictionarySnapshotID: snapshotID,
                dictionarySnapshotEntries: [dictionaryEntry],
                dictionaryRequestContext: .init(
                    snapshotID: snapshotID,
                    hotwords: ["豆包"],
                    includedEntryIDs: [dictionaryEntry.id],
                    omissions: []
                ),
                dictionaryReplacements: [
                    .init(
                        entryID: UUID(),
                        alias: "豆宝",
                        canonicalTerm: "豆包",
                        matchedText: "豆宝",
                        utf16Location: 0,
                        utf16Length: 2
                    ),
                ],
                durationMilliseconds: 1_234,
                stageDurationsMilliseconds: ["doubao": 500, "deepseek": 300],
                outcome: .delivered(firstID, applicationName: "TextEdit", text: "最终文本")
            ))
            await store.save(.init(
                sessionID: secondID,
                startedAt: Date(timeIntervalSince1970: 200),
                applicationName: "Notes",
                transcription: nil,
                finalText: nil,
                providerRequestID: "request-log-2",
                providerErrorCode: "invalidCredential",
                outcome: .failed(secondID, .providerNotConfigured)
            ))

            let reloaded = VersionedLocalSessionHistory(fileURL: fileURL)
            let allRecords = await reloaded.allRecords()
            let transcriptMatches = await reloaded.search("ALPHA")
            let errorMatches = await reloaded.search("invalidcredential")
            let encoded = try String(contentsOf: fileURL, encoding: .utf8)
            try expect(allRecords.map(\.sessionID) == [secondID, firstID])
            try expect(transcriptMatches.map(\.sessionID) == [firstID])
            try expect(errorMatches.map(\.sessionID) == [secondID])
            try expect(allRecords.last?.deepSeekText == "DeepSeek 结果 beta")
            try expect(allRecords.last?.transcriptionProvider == "doubao")
            try expect(allRecords.last?.refinementPrompt == "只清理口语杂质")
            try expect(allRecords.last?.dictionarySnapshotEntries == [dictionaryEntry])
            try expect(allRecords.last?.dictionaryRequestContext?.hotwords == ["豆包"])
            try expect(allRecords.last?.dictionaryReplacements.count == 1)
            try expect(allRecords.last?.stageDurationsMilliseconds["doubao"] == 500)
            try expect(!encoded.contains("apiKey"))
            try expect(!encoded.contains("audio"))
            try expect(!encoded.contains("clipboard"))

            let deleted = await reloaded.delete(sessionID: firstID)
            try expect(deleted)
            await reloaded.clear()
            let recordsAfterClear = await reloaded.allRecords()
            try expect(recordsAfterClear.isEmpty)
        }

        await runAsync("corrupt history is preserved with a recoverable notice", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-corrupt-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            try Data("not-json".utf8).write(to: fileURL)

            let store = VersionedLocalSessionHistory(fileURL: fileURL)
            let status = await store.persistenceStatus()
            if case let .corruptedDataPreserved(backupURL, _) = status.notice {
                try expect(FileManager.default.fileExists(atPath: backupURL.path))
            } else {
                throw SpecFailure(message: "corrupt history did not produce a preserved recovery notice")
            }
            let recoveredRecords = await store.allRecords()
            try expect(recoveredRecords.isEmpty)
        }

        await runAsync("history delete and clear roll back when disk write fails", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-history-write-failure-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("blocks-directory".utf8).write(to: directory)
            let store = VersionedLocalSessionHistory(
                fileURL: directory.appendingPathComponent("history.json")
            )
            let id = VoiceInputSessionID()
            await store.save(.init(
                sessionID: id,
                startedAt: Date(),
                applicationName: nil,
                transcription: "需要保留",
                finalText: "需要保留",
                outcome: .pendingCopy(id, text: "需要保留", reason: .missingTarget)
            ))

            let deleted = await store.delete(sessionID: id)
            let cleared = await store.clear()
            let records = await store.allRecords()
            try expect(!deleted)
            try expect(!cleared)
            try expect(records.map(\.sessionID) == [id])
        }

        run("personal dictionary reports empty duplicate and conflicting enabled aliases", failures: &failures) {
            let emptyID = UUID()
            let duplicateOne = UUID()
            let duplicateTwo = UUID()
            let aliasOne = UUID()
            let aliasTwo = UUID()
            let issues = PersonalDictionaryValidator.validate([
                .init(id: emptyID, canonicalTerm: " "),
                .init(id: duplicateOne, canonicalTerm: "Speaker"),
                .init(id: duplicateTwo, canonicalTerm: "speaker"),
                .init(id: aliasOne, canonicalTerm: "Swift", aliases: ["斯威夫特"]),
                .init(id: aliasTwo, canonicalTerm: "SwiftUI", aliases: ["斯威夫特"]),
            ])

            try expect(issues.contains(.emptyCanonicalTerm(entryID: emptyID)))
            try expect(issues.contains { issue in
                if case .duplicateCanonicalTerm = issue { true } else { false }
            })
            try expect(issues.contains { issue in
                if case .conflictingEnabledAlias = issue { true } else { false }
            })
        }

        run("dictionary snapshot and provider truncation are deterministic", failures: &failures) {
            let alpha = DictionaryEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                canonicalTerm: "Alpha",
                aliases: ["A"]
            )
            let beta = DictionaryEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                canonicalTerm: "Beta"
            )
            let disabled = DictionaryEntry(canonicalTerm: "Disabled", isEnabled: false)
            let long = DictionaryEntry(canonicalTerm: "VeryLongTerm")
            let dictionary = try PersonalDictionary(entries: [long, disabled, beta, alpha])
            let snapshot = dictionary.snapshotEnabled(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                createdAt: Date(timeIntervalSince1970: 10)
            )
            let context = DictionaryRequestContextBuilder.makeContext(
                from: snapshot,
                capacity: .init(maximumHotwordCount: 1, maximumCharactersPerHotword: 6)
            )

            try expect(snapshot.entries.map(\.canonicalTerm) == ["Alpha", "Beta", "VeryLongTerm"])
            try expect(context.hotwords == ["Alpha"])
            try expect(context.includedEntryIDs == [alpha.id])
            try expect(context.omissions.contains { $0.reason == .providerCountLimit })
            try expect(context.omissions.contains { $0.reason == .providerTermLengthLimit })
        }

        run("dictionary alias normalization replaces only complete unambiguous tokens", failures: &failures) {
            let dictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "Swift", aliases: ["swift-lang"]),
                .init(canonicalTerm: "SwiftUI", aliases: ["swift-ui"]),
                .init(canonicalTerm: "豆包", aliases: ["豆宝"]),
            ])
            let result = DictionaryAliasNormalizer.normalize(
                "我用豆宝写字。Use swift-lang, not swift-language; then swift-ui.",
                using: dictionary.snapshotEnabled()
            )

            try expect(result.normalizedText == "我用豆包写字。Use Swift, not swift-language; then SwiftUI.")
            try expect(result.replacements.map(\.matchedText) == ["豆宝", "swift-lang", "swift-ui"])
            let ordinarySubstring = DictionaryAliasNormalizer.normalize(
                "豆宝贝",
                using: dictionary.snapshotEnabled()
            )
            try expect(ordinarySubstring.normalizedText == "豆宝贝")
        }

        await runAsync("versioned personal dictionary store round trips locally", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-dictionary-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = VersionedJSONPersonalDictionaryStore(
                fileURL: directory.appendingPathComponent("dictionary.json")
            )
            let dictionary = try PersonalDictionary(entries: [
                .init(canonicalTerm: "豆包", aliases: ["豆宝"]),
                .init(canonicalTerm: "DeepSeek", aliases: ["deep seek"], isEnabled: false),
            ])

            try await store.save(dictionary)
            let loaded = try await store.load()
            try expect(loaded == dictionary)
        }

        await runAsync("versioned app settings round trip shortcut refinement and login launch", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = VersionedLocalAppSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json")
            )
            let settings = SpeakerAppSettings(
                shortcut: .custom(keyCode: 49, modifiers: 2_048, displayName: "⌥ Space"),
                refinement: .custom(name: "短句", prompt: "只清理重复"),
                launchAtLogin: true,
                doubaoResourceID: DoubaoStreamingResource.model1Concurrent.rawValue
            )

            try await store.save(settings)
            let loaded = await store.load()
            try expect(loaded.settings == settings)

            async let shortcutUpdate = store.updateShortcut(.functionKey)
            async let refinementUpdate = store.updateRefinement(.fullRewrite)
            async let loginUpdate = store.updateLaunchAtLogin(false)
            async let resourceUpdate = store.updateDoubaoResource(.model2Duration)
            _ = try await (shortcutUpdate, refinementUpdate, loginUpdate, resourceUpdate)
            let atomicallyUpdated = await store.load().settings
            try expect(atomicallyUpdated.shortcut == .functionKey)
            try expect(atomicallyUpdated.refinement == .fullRewrite)
            try expect(atomicallyUpdated.launchAtLogin == false)
            try expect(
                atomicallyUpdated.doubaoResourceID
                    == DoubaoStreamingResource.model2Duration.rawValue
            )

            let savedCustom = RefinementPreference(
                mode: .custom(name: "邮件", prompt: "整理成简洁邮件")
            )
            try await store.updateSavedCustomRefinement(savedCustom)
            try await store.updateRefinement(.defaultSmooth)
            let afterBuiltInSwitch = await store.load().settings
            try expect(afterBuiltInSwitch.refinement == .defaultSmooth)
            try expect(afterBuiltInSwitch.savedCustomRefinement == savedCustom)
        }

        await runAsync("corrupt app settings recover to defaults without overwriting evidence", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-corrupt-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            try Data("broken".utf8).write(to: fileURL)

            let result = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()
            if case let .recovered(settings, recovery) = result {
                try expect(settings == .default)
                try expect(FileManager.default.fileExists(atPath: recovery.backupURL.path))
            } else {
                throw SpecFailure(message: "corrupt settings were not preserved and recovered")
            }
        }

        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            Darwin.exit(1)
        }

        print("PASS: 50 core specs")
    }
}

private let specAudio = CapturedAudio(
    data: Data([0x52, 0x49, 0x46, 0x46]),
    duration: .seconds(1),
    peakPower: -10
)

private func makeDoubaoClient(
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
            installationID: "local-spec-installation"
        ),
        connector: DoubaoWebSocketConnectorFake(connection: connection)
    )
}

private actor DoubaoWebSocketConnectorFake: DoubaoWebSocketConnecting {
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

private actor DoubaoWebSocketConnectionFake: DoubaoWebSocketConnection {
    private let responses: [Data]
    private let receiveError: URLError?
    private let metadataValue: DoubaoWebSocketMetadata
    private var responseIndex = 0
    private(set) var sentFrames: [Data] = []
    private(set) var closeCount = 0

    init(
        responses: [Data],
        receiveError: URLError? = nil,
        metadata: DoubaoWebSocketMetadata = .init()
    ) {
        self.responses = responses
        self.receiveError = receiveError
        metadataValue = metadata
    }

    func send(_ data: Data) async throws {
        sentFrames.append(data)
    }

    func receive() async throws -> Data {
        if let receiveError { throw receiveError }
        guard responseIndex < responses.count else {
            throw URLError(.cannotParseResponse)
        }
        defer { responseIndex += 1 }
        return responses[responseIndex]
    }

    func metadata() -> DoubaoWebSocketMetadata { metadataValue }

    func close() {
        closeCount += 1
    }
}

private func makeAudioStream(_ chunks: [Data]) -> AsyncStream<Data> {
    AsyncStream { continuation in
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }
}

private func makeDoubaoServerResponse(text: String?, isFinal: Bool) -> Data {
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

private func makeDoubaoServerError(code: UInt32, message: String) -> Data {
    makeDoubaoServerFrame(
        messageType: 0x0F,
        flags: 0,
        prefix: code,
        payload: Data(#"{"message":"\#(message)"}"#.utf8)
    )
}

private func makeDoubaoServerFrame(
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

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private actor DeepSeekRefinerFake: DeepSeekTextRefining {
    let result: Result<DeepSeekRefinementResult, DeepSeekRefinementFailure>
    private(set) var callCount = 0
    private(set) var inputs: [String] = []
    private(set) var modes: [TextRefinementMode] = []

    init(result: Result<DeepSeekRefinementResult, DeepSeekRefinementFailure>) {
        self.result = result
    }

    func refine(
        _ text: String,
        using mode: TextRefinementMode
    ) async throws -> DeepSeekRefinementResult {
        callCount += 1
        inputs.append(text)
        modes.append(mode)
        return try result.get()
    }
}

private actor ContextualTranscriberFake: ContextualSpeechTranscribing {
    let text: String
    private(set) var hotwordCalls: [[String]] = []

    init(text: String) {
        self.text = text
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        try await transcribe(audio, hotwords: [], context: nil)
    }

    func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult {
        hotwordCalls.append(hotwords)
        return TranscriptionResult(text: text, providerRequestID: "doubao-context-spec")
    }
}

private actor DeepSeekTransportFake: DeepSeekTransport {
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

private struct HangingDeepSeekTransport: DeepSeekTransport {
    func send(_ request: URLRequest) async throws -> DeepSeekTransportResponse {
        try await Task.sleep(for: .seconds(10))
        return DeepSeekTransportResponse(statusCode: 500, body: Data())
    }
}

private func makeDeepSeekClient(content: String) -> DeepSeekRefinementClient {
    let encodedContent = try! JSONEncoder().encode(content)
    let body = Data(
        "{\"choices\":[{\"message\":{\"content\":\(String(decoding: encodedContent, as: UTF8.self))},\"finish_reason\":\"stop\"}]}".utf8
    )
    return DeepSeekRefinementClient(
        configuration: .init(apiKey: "deepseek-test-key"),
        transport: DeepSeekTransportFake(response: .init(statusCode: 200, body: body))
    )
}

private actor ProviderCredentialStoreFake: ProviderCredentialStoring {
    private var values: [ProviderID: String]

    init(values: [ProviderID: String] = [:]) {
        self.values = values
    }

    func save(apiKey: String, for provider: ProviderID) async throws {
        values[provider] = apiKey
    }

    func apiKey(for provider: ProviderID) async throws -> String? {
        values[provider]
    }

    func deleteAPIKey(for provider: ProviderID) async throws {
        values[provider] = nil
    }
}

private actor AudioCaptureFake: AudioCapturing {
    let delaysStart: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var isActive = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(delaysStart: Bool = false) {
        self.delaysStart = delaysStart
    }

    func start() async throws {
        startCount += 1
        if delaysStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        isActive = true
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        isActive = false
        return CapturedAudio(
            data: Data([0x52, 0x49, 0x46, 0x46]),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    func cancel() async {
        cancelCount += 1
        isActive = false
    }
}

private actor StreamingAudioCaptureFake: AudioCapturing, AudioChunkStreaming {
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var stopCount = 0

    func audioChunks() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        return stream
    }

    func start() async throws {}

    func emit(_ data: Data) {
        continuation?.yield(data)
    }

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        continuation?.finish()
        continuation = nil
        return CapturedAudio(data: Data(), duration: .seconds(1), peakPower: -12)
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
    }
}

private actor StreamingVoiceTextProcessorFake: VoiceTextProcessing, StreamingVoiceTextProcessing {
    private(set) var receivedChunkCount = 0

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceInputProcessingStage) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw SpecFailure(message: "streaming processor used buffered fallback")
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceInputProcessingStage) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        for await chunk in audioChunks where !chunk.isEmpty {
            receivedChunkCount += 1
        }
        return VoiceTextProcessingResult(
            doubaoText: "流式结果",
            normalizedText: "流式结果",
            deepSeekText: nil,
            finalText: "流式结果",
            doubaoRequestID: "streaming-spec",
            deepSeekRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil,
            dictionaryReplacements: []
        )
    }
}

private actor DelayedFailingStopAudioCapture: AudioCapturing {
    private(set) var stopCount = 0
    private var stopContinuation: CheckedContinuation<CapturedAudio, Error>?

    func start() async throws {}

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func cancel() async {}

    func failStop() {
        stopContinuation?.resume(throwing: SpecFailure(message: "late recorder failure"))
        stopContinuation = nil
    }
}

private actor DelayedFailingStartAudioCapture: AudioCapturing {
    func start() async throws {
        try await Task.sleep(for: .milliseconds(20))
        throw SpecFailure(message: "recorder start failed")
    }

    func stop() async throws -> CapturedAudio { specAudio }

    func cancel() async {}
}

private actor TargetCaptureFake: InputTargetCapturing {
    let result: InputTargetCaptureResult

    init(result: InputTargetCaptureResult) {
        self.result = result
    }

    func capture() async -> InputTargetCaptureResult {
        result
    }
}

private actor DiscardingTargetCaptureFake: InputTargetCapturing, InputTargetDiscarding {
    let snapshot: InputTargetSnapshot
    private(set) var discardedCount = 0

    init(snapshot: InputTargetSnapshot) {
        self.snapshot = snapshot
    }

    func capture() async -> InputTargetCaptureResult { .writable(snapshot) }

    func discard(_ target: InputTargetSnapshot) async {
        if target.id == snapshot.id { discardedCount += 1 }
    }
}

private struct DoubaoFailureTranscriber: ContextualSpeechTranscribing {
    let failure: DoubaoASRFailure

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        throw failure
    }

    func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult {
        throw failure
    }
}

private struct CredentialFailureTranscriber: ContextualSpeechTranscribing {
    let error: ProviderCredentialStoreError

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        throw error
    }

    func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult {
        throw error
    }
}

private struct NormalizedFailureProcessor: VoiceTextProcessing {
    let failure: VoiceTextProcessingFailure

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceInputProcessingStage) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw failure
    }
}

private actor SpeechTranscriberFake: SpeechTranscribing {
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

private actor TextDeliveryFake: TextDelivering {
    let result: DeliveryOutcome
    private(set) var deliveredTexts: [String] = []

    init(result: DeliveryOutcome) {
        self.result = result
    }

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        deliveredTexts.append(text)
        return result
    }
}

private actor DelayedCommitDeliveryFake: TextDelivering {
    private(set) var entered = false
    private(set) var deliveredTexts: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        deliveredTexts.append(text)
        return .delivered
    }

    func allowCommitAttempt() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ClipboardFake: ClipboardWriting {
    private(set) var copiedTexts: [String] = []

    func copy(_ text: String) async {
        copiedTexts.append(text)
    }
}

private actor SessionHistoryFake: SessionHistoryRecording {
    private(set) var records: [VoiceInputHistoryRecord] = []
    let failureNotice: String?

    init(failureNotice: String? = nil) {
        self.failureNotice = failureNotice
    }

    func save(_ record: VoiceInputHistoryRecord) async {
        if let index = records.firstIndex(where: { $0.sessionID == record.sessionID }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    func persistenceFailureNotice() async -> String? { failureNotice }
}

private actor RecordingWatchdogFake: RecordingWatchdog {
    private(set) var waitCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        waitCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PermissionAccessStub: PermissionAccess {
    var snapshot: PermissionSnapshot
    var requestResults: [PermissionKind: PermissionSnapshot] = [:]
    private(set) var requestedPermissions: [PermissionKind] = []

    init(snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> PermissionSnapshot {
        snapshot
    }

    func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        requestedPermissions.append(permission)
        let result = requestResults[permission] ?? snapshot
        snapshot = result
        return result
    }
}

private struct SpecFailure: Error {
    let message: String
}

private extension VoiceInputActivity {
    var isCancelled: Bool {
        if case .cancelled = self { true } else { false }
    }

    var isRecordingFailed: Bool {
        if case .failed(_, .recordingFailed) = self { true } else { false }
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed"
) throws {
    guard condition() else {
        throw SpecFailure(message: message)
    }
}

@MainActor
private func run(
    _ name: String,
    failures: inout [String],
    body: () throws -> Void
) {
    do {
        try body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

@MainActor
private func runAsync(
    _ name: String,
    failures: inout [String],
    body: () async throws -> Void
) async {
    do {
        try await body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

private func terminalPresentation(
    from stream: AsyncStream<VoiceInputPresentation>
) -> Task<VoiceInputPresentation?, Never> {
    Task {
        for await presentation in stream {
            if presentation.activity.isTerminal {
                return presentation
            }
        }
        return nil
    }
}
