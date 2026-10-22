import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

/// However a session ends, the next one starts from nothing it left behind:
/// no task, deadline, pending release, or confirmed recognition result of the
/// earlier session can act on the later one.
enum SessionResetSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "a session after a capture failure while recording runs without the failed session's work",
            failures: &failures
        ) {
            let clock = ManualVoiceInputClock()
            let audio = StreamingAudioCaptureFake()
            let history = SessionHistoryFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: history,
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )
            let failed = terminalPresentation(from: await sessions.observe())

            await sessions.dispatchPress()
            try await clock.waitUntilSleepRequestCount(1)
            await audio.emitFailure(.deviceConfigurationChanged)
            guard case .failed(let failedID, .audioDeviceChanged)? = await failed.value?.activity
            else {
                throw SpecFailure(message: "the capture failure did not end the first session")
            }
            try await settleFailedRecording(failedID, in: history, sessions: sessions)

            await sessions.dispatchPress()
            try await clock.waitUntilSleepRequestCount(2)
            await audio.emit(Data([1, 0]))
            let terminal = await sessions.releaseAndAwaitTerminal()
            guard case .delivered(let deliveredID, let text)? = terminal?.activity else {
                throw SpecFailure(message: "the session after the failure did not deliver")
            }
            await sessions.shutdown()

            let records = await history.records
            let failedRecord = records.first { $0.sessionID == failedID }
            let deliveredRecord = records.first { $0.sessionID == deliveredID }
            let deliveredTexts = await delivery.deliveredTexts
            let cancelCount = await audio.cancelCount
            try expect(deliveredID != failedID)
            try expect(text == "流式结果")
            try expect(deliveredTexts == ["流式结果"])
            try expect(cancelCount == 1, "the later session's capture was cancelled")
            try expect(records.count == 2)
            try expect(failedRecord?.outcome.failure == .audioDeviceChanged)
            try expect(deliveredRecord?.providerErrorCode == nil)
            try expect(deliveredRecord?.finalText == "流式结果")
            try expect(clock.cancelledSleepCount == 2)
        }

        await runAsync(
            "a session after a streaming failure while recording is not ended by the failed stream",
            failures: &failures
        ) {
            let audio = StreamingAudioCaptureFake()
            let processor = FirstStreamFailingProcessor()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))),
                textProcessor: processor,
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history
            )
            let failed = terminalPresentation(from: await sessions.observe())

            await sessions.dispatchPress()
            let waiting = await eventually(before: .seconds(2)) {
                await processor.isHoldingFirstStream
            }
            try expect(waiting, "the first stream never started")
            await processor.failFirstStream()
            guard
                case .failed(let failedID, .providerAuthenticationFailed)? = await failed.value?
                    .activity
            else {
                throw SpecFailure(message: "the streaming failure did not end the first session")
            }
            try await settleFailedRecording(failedID, in: history, sessions: sessions)

            await sessions.dispatchPress()
            await audio.emit(Data([1, 0]))
            let terminal = await sessions.releaseAndAwaitTerminal()
            guard case .delivered(let deliveredID, let text)? = terminal?.activity else {
                throw SpecFailure(
                    message: "the session after the streaming failure did not deliver")
            }
            await sessions.shutdown()

            let records = await history.records
            let failedRecord = records.first { $0.sessionID == failedID }
            let deliveredRecord = records.first { $0.sessionID == deliveredID }
            let streamCount = await processor.streamCount
            try expect(text == "第二次识别")
            try expect(streamCount == 2)
            try expect(failedRecord?.providerRequestID == "first-stream")
            try expect(deliveredRecord?.providerRequestID == "second-stream")
            try expect(deliveredRecord?.providerErrorCode == nil)
        }

        await runAsync(
            "a release held while preparing is not carried into the session after a cancel",
            failures: &failures
        ) {
            let audio = StreamingAudioCaptureFake(delaysFirstAudioChunks: true)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))),
                textProcessor: StreamingVoiceTextProcessorFake(),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let presentations = await sessions.observe()

            let firstPress = Task { await sessions.dispatchPress() }
            let preparing = await eventually(before: .seconds(2)) {
                await audio.audioChunksCount == 1
            }
            try expect(preparing, "the first press never reached audio setup")
            await sessions.dispatchRelease()
            await sessions.dispatchEscape()
            await audio.resumeFirstAudioChunks()
            await firstPress.value

            await sessions.dispatchPress()
            var recordingID: VoiceInputSessionID?
            for await presentation in presentations where presentation.activity.isRecording {
                recordingID = presentation.activity.sessionID
                break
            }
            await settle()
            let stillRecording = await sessions.isRecording(recordingID)
            let stopCount = await audio.stopCount
            try expect(recordingID != nil, "the press after the cancel did not record")
            try expect(stillRecording, "the earlier release ended the new recording")
            try expect(stopCount == 0)
            let terminal = await sessions.releaseAndAwaitTerminal()
            try expect(terminal?.activity.isDelivered == true)
            await sessions.shutdown()
        }

        await runAsync(
            "a cancelled session's confirmed recognition result is never used by the next session",
            failures: &failures
        ) {
            let processor = ConfirmingOnceProcessor()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))),
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let presentations = await sessions.observe()

            await sessions.dispatchPress()
            await sessions.dispatchRelease()
            let firstID = await refiningSession(after: nil, in: presentations)
            try expect(firstID != nil, "the first session never reached refinement")
            await sessions.dispatchEscape()

            await sessions.dispatchPress()
            await sessions.dispatchRelease()
            guard let secondID = await refiningSession(after: firstID, in: presentations) else {
                throw SpecFailure(message: "the second session never reached refinement")
            }
            await sessions.useRecognitionResult(expectedSessionID: secondID)
            await settle()
            let deliveredTexts = await delivery.deliveredTexts
            try expect(deliveredTexts.isEmpty, "the earlier confirmed result was delivered")
            await sessions.dispatchEscape()
            await sessions.shutdown()
        }
    }

    /// Waits for the failed session's record, then makes one more call into
    /// the session actor so the turn that returned it to idle has finished.
    private static func settleFailedRecording(
        _ id: VoiceInputSessionID,
        in history: SessionHistoryFake,
        sessions: VoiceInputSessions
    ) async throws {
        let settled = await eventually(before: .seconds(2)) {
            await history.records.first { $0.sessionID == id }?.outcome.failure != nil
        }
        try expect(settled, "the failed recording never settled")
        _ = await sessions.isActive(triggerSequence: 0)
    }

    private static func refiningSession(
        after previous: VoiceInputSessionID?,
        in presentations: AsyncStream<VoiceInputPresentation>
    ) async -> VoiceInputSessionID? {
        for await presentation in presentations {
            if case .processing(let id, .refining) = presentation.activity, id != previous {
                return id
            }
        }
        return nil
    }
}

extension VoiceInputSessions {
    fileprivate func isRecording(_ id: VoiceInputSessionID?) async -> Bool {
        await observeCurrent().activity == .recording(id ?? VoiceInputSessionID())
    }

    fileprivate func observeCurrent() async -> VoiceInputPresentation {
        for await presentation in observe() { return presentation }
        return VoiceInputPresentation(revision: 0, activity: .idle)
    }
}

/// Holds its first stream open until told to fail it; every later stream
/// reads its audio and recognizes it.
private actor FirstStreamFailingProcessor: VoiceTextProcessing, StreamingVoiceTextProcessing {
    nonisolated var streaming: (any StreamingVoiceTextProcessing)? { self }

    private(set) var streamCount = 0
    private var firstStream: CheckedContinuation<Void, Never>?
    var isHoldingFirstStream: Bool { firstStream != nil }

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw SpecFailure(message: "the streaming fake was asked for buffered processing")
    }

    func processStreaming(
        _ audioChunks: AsyncStream<Data>,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        streamCount += 1
        if streamCount == 1 {
            await withCheckedContinuation { firstStream = $0 }
            throw VoiceTextProcessingFailure(
                userFailure: .providerAuthenticationFailed,
                providerDiagnostic: .init(
                    provider: "doubao",
                    requestID: "first-stream",
                    code: "invalidCredential"
                )
            )
        }
        for await _ in audioChunks {}
        return VoiceTextProcessingResult(
            recognitionText: "第二次识别",
            normalizedText: "第二次识别",
            refinedText: nil,
            finalText: "第二次识别",
            recognitionRequestID: "second-stream",
            refinementRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil
        )
    }

    func failFirstStream() {
        firstStream?.resume()
        firstStream = nil
    }
}

/// Reports refinement with a confirmed recognition result only on its first
/// call; every call then waits in refinement until it is cancelled.
private actor ConfirmingOnceProcessor: VoiceTextProcessing {
    nonisolated var streaming: (any StreamingVoiceTextProcessing)? { nil }

    private var callCount = 0

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        callCount += 1
        await progress(
            .init(
                stage: .refining,
                confirmedRecognitionResult: callCount == 1
                    ? TranscriptionResult(text: "上一次的识别", providerRequestID: nil)
                    : nil
            ))
        try await Task.sleep(for: .seconds(3_600))
        throw VoiceTextProcessingFailure(userFailure: .transcriptionFailed)
    }
}
