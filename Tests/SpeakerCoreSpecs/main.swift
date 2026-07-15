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
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.secureTarget)),
                transcriber: SpeechTranscriberFake(text: "敏感文本"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            try expect(result?.activity.pendingCopyReason == .secureTarget)
            try expect(deliveredTexts.isEmpty)
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

        await runAsync("Doubao request uses flash headers and semantic smoothing body", failures: &failures) {
            let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
            let transport = DoubaoTransportFake(response: .init(
                statusCode: 200,
                headers: ["X-Api-Status-Code": "20000000", "X-Tt-Logid": "log-12"],
                body: Data(#"{"result":{"text":"  你好，世界。  "}}"#.utf8)
            ))
            let client = DoubaoFlashASRClient(
                configuration: .init(
                    apiKey: "test-api-key",
                    installationID: "local-installation",
                    hotwords: ["Speaker"]
                ),
                transport: transport,
                requestIDGenerator: { requestID }
            )

            let result = try await client.transcribe(.init(
                data: Data([0x52, 0x49, 0x46, 0x46]),
                duration: .seconds(1),
                peakPower: -10
            ))
            let request = try await transport.onlyRequest()
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let recognition = body?["request"] as? [String: Any]
            let audio = body?["audio"] as? [String: Any]

            try expect(request.url == DoubaoFlashASRConfiguration.defaultEndpoint)
            try expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-api-key")
            try expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.bigasr.auc_turbo")
            try expect(request.value(forHTTPHeaderField: "X-Api-Request-Id") == requestID.uuidString)
            try expect(request.value(forHTTPHeaderField: "X-Api-Sequence") == "-1")
            try expect(recognition?["enable_itn"] as? Bool == true)
            try expect(recognition?["enable_punc"] as? Bool == true)
            try expect(recognition?["enable_ddc"] as? Bool == true)
            try expect(audio?["data"] as? String == Data([0x52, 0x49, 0x46, 0x46]).base64EncodedString())
            try expect(result == .init(text: "你好，世界。", providerRequestID: "log-12"))
        }

        await runAsync("Doubao maps silence without exposing a transcript", failures: &failures) {
            let client = makeDoubaoClient(response: .init(
                statusCode: 200,
                headers: ["X-Api-Status-Code": "20000003", "X-Tt-Logid": "silent-log"],
                body: Data()
            ))
            do {
                _ = try await client.transcribe(specAudio)
                throw SpecFailure(message: "silence response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .silence)
                try expect(failure.providerRequestID == "silent-log")
            }
        }

        await runAsync("Doubao distinguishes inactive resource from bad credential", failures: &failures) {
            let inactive = makeDoubaoClient(response: .init(
                statusCode: 403,
                headers: [
                    "X-Api-Status-Code": "45000001",
                    "X-Api-Message": "resource not activated",
                ],
                body: Data()
            ))
            do {
                _ = try await inactive.transcribe(specAudio)
                throw SpecFailure(message: "inactive resource response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .resourceNotActivated)
            }

            let unauthorized = makeDoubaoClient(response: .init(
                statusCode: 401,
                headers: ["X-Api-Message": "unauthorized api key"],
                body: Data()
            ))
            do {
                _ = try await unauthorized.transcribe(specAudio)
                throw SpecFailure(message: "invalid credential response was accepted")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .invalidCredential)
            }
        }

        await runAsync("credential-backed Doubao transcriber loads the current Keychain value", failures: &failures) {
            let credentials = ProviderCredentialStoreFake(values: [.doubao: "first-key"])
            let transport = DoubaoTransportFake(response: .init(
                statusCode: 200,
                headers: ["X-Api-Status-Code": "20000000"],
                body: Data(#"{"result":{"text":"第一条"}}"#.utf8)
            ))
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                installationID: "installation-spec",
                transport: transport
            )

            _ = try await transcriber.transcribe(specAudio)
            let firstRequest = try await transport.onlyRequest()
            try expect(firstRequest.value(forHTTPHeaderField: "X-Api-Key") == "first-key")
        }

        await runAsync("credential-backed Doubao transcriber fails before network when unconfigured", failures: &failures) {
            let credentials = ProviderCredentialStoreFake()
            let transport = DoubaoTransportFake(response: .init(
                statusCode: 500,
                headers: [:],
                body: Data()
            ))
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                installationID: "installation-spec",
                transport: transport
            )

            do {
                _ = try await transcriber.transcribe(specAudio)
                throw SpecFailure(message: "unconfigured transcriber sent a request")
            } catch let failure as DoubaoASRFailure {
                try expect(failure.kind == .invalidCredential)
                let requestCount = await transport.requestCount
                try expect(requestCount == 0)
            }
        }

        await runAsync("Doubao failure becomes stable user state and diagnostic history", failures: &failures) {
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: DoubaoFailureTranscriber(failure: .init(
                    kind: .invalidCredential,
                    providerRequestID: "provider-log-id"
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
            try expect(record?.refinementStatus == "succeeded")
            try expect(record?.dictionaryReplacements.count == 1)
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
            let store = VersionedLocalSessionHistory(fileURL: fileURL)
            await store.save(.init(
                sessionID: firstID,
                startedAt: Date(timeIntervalSince1970: 100),
                applicationName: "TextEdit",
                transcription: "豆包原文 alpha",
                finalText: "最终文本",
                providerRequestID: "request-log-1",
                providerErrorCode: nil,
                deepSeekText: "DeepSeek 结果 beta",
                deepSeekRequestID: "deepseek-log-1",
                refinementModeName: "精简清理",
                refinementStatus: "succeeded",
                dictionarySnapshotID: UUID(),
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
            ])
            let result = DictionaryAliasNormalizer.normalize(
                "Use swift-lang, not swift-language; then swift-ui.",
                using: dictionary.snapshotEnabled()
            )

            try expect(result.normalizedText == "Use Swift, not swift-language; then SwiftUI.")
            try expect(result.replacements.map(\.matchedText) == ["swift-lang", "swift-ui"])
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
                launchAtLogin: true
            )

            try await store.save(settings)
            let loaded = await store.load()
            try expect(loaded.settings == settings)
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

        print("PASS: 34 core specs")
    }
}

private let specAudio = CapturedAudio(
    data: Data([0x52, 0x49, 0x46, 0x46]),
    duration: .seconds(1),
    peakPower: -10
)

private func makeDoubaoClient(response: DoubaoASRTransportResponse) -> DoubaoFlashASRClient {
    DoubaoFlashASRClient(
        configuration: .init(
            apiKey: "test-api-key",
            installationID: "local-spec-installation"
        ),
        transport: DoubaoTransportFake(response: response)
    )
}

private actor DoubaoTransportFake: DoubaoASRTransport {
    let response: DoubaoASRTransportResponse
    private var requests: [URLRequest] = []

    init(response: DoubaoASRTransportResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> DoubaoASRTransportResponse {
        requests.append(request)
        return response
    }

    func onlyRequest() throws -> URLRequest {
        guard requests.count == 1, let request = requests.first else {
            throw SpecFailure(message: "expected exactly one Doubao request")
        }
        return request
    }

    var requestCount: Int { requests.count }
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

private actor TargetCaptureFake: InputTargetCapturing {
    let result: InputTargetCaptureResult

    init(result: InputTargetCaptureResult) {
        self.result = result
    }

    func capture() async -> InputTargetCaptureResult {
        result
    }
}

private struct DoubaoFailureTranscriber: SpeechTranscribing {
    let failure: DoubaoASRFailure

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
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

    func deliver(_ text: String, to target: InputTargetSnapshot) async -> DeliveryOutcome {
        deliveredTexts.append(text)
        return result
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

    func save(_ record: VoiceInputHistoryRecord) async {
        records.append(record)
    }
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
