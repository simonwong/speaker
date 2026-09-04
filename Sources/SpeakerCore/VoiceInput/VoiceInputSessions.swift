import Foundation

public actor VoiceInputSessions {
    package static let standardMaximumRecordingDuration: Duration = .seconds(600)

    private enum Phase: Equatable {
        case idle
        case preparing(VoiceInputSessionID)
        case recording(
            VoiceInputSessionID,
            startedAt: Date,
            snapshot: VoiceTextProcessingSnapshot
        )
        case processing(
            VoiceInputSessionID,
            startedAt: Date,
            snapshot: VoiceTextProcessingSnapshot
        )
        case finalizing(VoiceInputSessionID)
    }

    private let audioCapture: any AudioCapturing
    private let targetCapture: any InputTargetCapturing
    private let textProcessor: any VoiceTextProcessing
    private let delivery: any TextDelivering
    private let clipboard: any ClipboardWriting
    private let history: any SessionHistoryRecording
    private let maximumRecordingDuration: Duration
    private let sleepUntilRecordingLimit:
        @Sendable (Duration) async throws -> Void

    private var phase: Phase = .idle
    private var releasePending = false
    private var pendingReleaseCaptureHint: InputTargetCaptureHint?
    private var transcriptionTask: Task<VoiceTextProcessingResult, Error>?
    private var streamingCompletionTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var captureFailureTask: Task<Void, Never>?
    private var recordingLimitTask: Task<Void, Never>?
    private var activeRecordingSettlementTask: Task<Void, Never>?
    private var deliveryCommitGate: DeliveryCommitGate?
    private var deliveryTask: Task<DeliveryOutcome, Never>?
    private var deliveryResolution: DeliveryResolution?
    private var suppressedTerminalPresentationSessionID: VoiceInputSessionID?
    private var finishingTask: Task<Void, Never>?
    private var historyWrites = SessionHistoryWriteQueue()
    private var isShutDown = false
    private var preparingStartedAt: Date?
    private var activeSnapshot: VoiceTextProcessingSnapshot?
    private var confirmedDoubaoResult: TranscriptionResult?
    private var historyTextPolicy = HistoryTextPolicy.unclassified
    private var activeTriggerSequence: UInt64?
    private var stageAudit = VoiceInputStageAudit()
    private var presenter = VoiceInputPresentationPublisher()
    private var triggerTerminations = TriggerTerminationPublisher()
    private var presentation: VoiceInputPresentation { presenter.current }

    public init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        transcriber: any SpeechTranscribing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        textProcessor = BasicVoiceTextProcessor(transcriber: transcriber)
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
        maximumRecordingDuration = Self.standardMaximumRecordingDuration
        sleepUntilRecordingLimit = { duration in
            try await Task.sleep(for: duration)
        }
    }

    public init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        textProcessor: any VoiceTextProcessing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        self.textProcessor = textProcessor
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
        maximumRecordingDuration = Self.standardMaximumRecordingDuration
        sleepUntilRecordingLimit = { duration in
            try await Task.sleep(for: duration)
        }
    }

    package init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        transcriber: any SpeechTranscribing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording,
        maximumRecordingDuration: Duration,
        sleepUntilRecordingLimit:
            @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        textProcessor = BasicVoiceTextProcessor(transcriber: transcriber)
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
        self.maximumRecordingDuration = maximumRecordingDuration
        self.sleepUntilRecordingLimit = sleepUntilRecordingLimit
    }

    package init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        textProcessor: any VoiceTextProcessing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording,
        maximumRecordingDuration: Duration,
        sleepUntilRecordingLimit:
            @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        self.textProcessor = textProcessor
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
        self.maximumRecordingDuration = maximumRecordingDuration
        self.sleepUntilRecordingLimit = sleepUntilRecordingLimit
    }

    public func observe() -> AsyncStream<VoiceInputPresentation> {
        presenter.subscribe { [weak self] id in
            Task { await self?.removeObserver(id) }
        }
    }

    /// Emits the dispatcher sequence owned by a session when that session
    /// reaches a terminal state without requiring another physical key edge.
    /// Consumers must compare the sequence before resetting gesture state so a
    /// delayed terminal event cannot affect a newer session.
    package func observeTriggerTerminations() -> AsyncStream<UInt64> {
        triggerTerminations.subscribe { [weak self] id in
            Task { await self?.removeTriggerTerminationObserver(id) }
        }
    }

    package func isActive(triggerSequence: UInt64) -> Bool {
        activeTriggerSequence == triggerSequence
    }

    package func send(_ command: VoiceInputCommand) async {
        await send(command, triggerSequence: nil)
    }

    package func send(
        _ command: VoiceInputCommand,
        triggerSequence: UInt64
    ) async {
        await send(command, triggerSequence: Optional(triggerSequence))
    }

    package func releaseFromDispatcher(
        captureHint: InputTargetCaptureHint?
    ) {
        if case .preparing = phase {
            releasePending = true
            pendingReleaseCaptureHint = captureHint
        } else {
            beginFinishingSession(captureHint: captureHint)
        }
    }

    public func cancel(triggeredAtSequence sequence: UInt64) async {
        guard let activeTriggerSequence,
              activeTriggerSequence <= sequence
        else { return }
        await cancelSession()
    }

    package func cancel(expectedSessionID: VoiceInputSessionID) async {
        guard currentActiveSessionID == expectedSessionID else { return }
        await cancelSession()
    }

    package func copyPendingResult(expectedSessionID: VoiceInputSessionID) async {
        guard case let .pendingCopy(id, text, _) = presentation.activity,
              id == expectedSessionID
        else { return }
        let copied = await clipboard.copy(text)
        guard phase == .idle,
              case let .pendingCopy(currentID, _, _) = presentation.activity,
              currentID == expectedSessionID
        else { return }
        if copied {
            publish(.idle, notice: .copied)
        } else {
            publish(
                .pendingCopy(
                    expectedSessionID,
                    text: text,
                    reason: .clipboardFailed
                )
            )
        }
    }

    package func dismissResult(expectedSessionID: VoiceInputSessionID) {
        guard phase == .idle,
              presentation.activity.sessionID == expectedSessionID
        else { return }
        publish(.idle)
    }

    /// Stops active work and waits until every queued history mutation has
    /// reached durable storage. App termination must use this instead of only
    /// sending `.cancel`, otherwise the final cancellation record can be lost.
    public func shutdown() async {
        isShutDown = true
        let limitTask = cancelRecordingLimit()
        let settlementTask = activeRecordingSettlementTask
        await cancelSession()
        await limitTask?.value
        await settlementTask?.value
        await finishingTask?.value
        await delivery.shutdown()
        // Converge instead of snapshotting: a write enqueued while an earlier
        // one was still being awaited must also reach durable storage before
        // shutdown returns. No new session can begin once `isShutDown` is set.
        while let (sessionID, task) = historyWrites.firstPending {
            await task.value
            historyWrites.discard(task, for: sessionID)
        }
    }

    private func send(
        _ command: VoiceInputCommand,
        triggerSequence: UInt64?
    ) async {
        switch command {
        case .pressed:
            await beginSession(triggerSequence: triggerSequence)
        case .released:
            if case .preparing = phase {
                releasePending = true
                pendingReleaseCaptureHint = nil
            } else {
                beginFinishingSession(captureHint: nil)
                await finishingTask?.value
            }
        case .cancel:
            await cancelSession()
        case .copyPendingResult:
            guard case let .pendingCopy(id, text, _) = presentation.activity else { return }
            let copied = await clipboard.copy(text)
            guard phase == .idle,
                  case let .pendingCopy(currentID, _, _) = presentation.activity,
                  currentID == id
            else { return }
            if copied {
                publish(.idle, notice: .copied)
            } else {
                publish(
                    .pendingCopy(
                        id,
                        text: text,
                        reason: .clipboardFailed
                    )
                )
            }
        case .dismissResult:
            guard phase == .idle else { return }
            publish(.idle)
        }
    }

    private var currentActiveSessionID: VoiceInputSessionID? {
        switch phase {
        case .idle:
            nil
        case let .preparing(id),
             let .recording(id, _, _),
             let .processing(id, _, _),
             let .finalizing(id):
            id
        }
    }

    private func beginSession(triggerSequence: UInt64?) async {
        guard !isShutDown, phase == .idle else {
            if let triggerSequence {
                finishRejectedTriggerSequence(triggerSequence)
            }
            return
        }
        // A press while retained text is awaiting copy deliberately abandons
        // that text: the user chose to re-record, and the notice must never
        // block the next session. The retained body may exist nowhere else
        // (unclassified targets keep it out of history), so this is an
        // explicit, user-initiated discard.
        let id = VoiceInputSessionID()
        let requestedAt = Date()
        releasePending = false
        pendingReleaseCaptureHint = nil
        phase = .preparing(id)
        activeTriggerSequence = triggerSequence
        preparingStartedAt = requestedAt
        confirmedDoubaoResult = nil
        historyTextPolicy = .unclassified
        suppressedTerminalPresentationSessionID = nil
        stageAudit.begin(id: id, stage: "preparing")
        publish(.preparing(id))
        saveStage(.preparing(id), id: id, startedAt: requestedAt)
        let snapshot = await textProcessor.captureSnapshot()
        guard phase == .preparing(id) else { return }
        activeSnapshot = snapshot

        let liveStream: AsyncStream<Data>?
        let streamingProcessor: (any StreamingVoiceTextProcessing)?
        if let chunkSource = audioCapture as? any AudioChunkStreaming,
           let processor = textProcessor as? any StreamingVoiceTextProcessing {
            liveStream = await chunkSource.audioChunks()
            streamingProcessor = processor
        } else {
            liveStream = nil
            streamingProcessor = nil
        }

        do {
            try await audioCapture.start()
            guard phase == .preparing(id) else {
                await audioCapture.cancel()
                return
            }
            let startedAt = requestedAt
            phase = .recording(id, startedAt: startedAt, snapshot: snapshot)
            stageAudit.advance(id: id, stage: "recording")
            publish(.recording(id))
            startRecordingLimit(
                for: id,
                startedAt: startedAt,
                snapshot: snapshot
            )
            if let liveStream, let streamingProcessor {
                let sessions = self
                transcriptionTask = Task {
                    try await streamingProcessor.processStreaming(
                        liveStream,
                        snapshot: snapshot
                    ) { progress in
                        await sessions.receivedProcessingProgress(
                            progress,
                            id: id,
                            startedAt: startedAt,
                            snapshot: snapshot,
                            applicationName: nil
                        )
                    }
                }
                if let transcriptionTask {
                    observeStreamingCompletion(
                        transcriptionTask,
                        id: id,
                        startedAt: startedAt,
                        snapshot: snapshot
                    )
                }
            }
            observeRecordingTelemetry(for: id)
            observeCaptureFailures(
                for: id,
                startedAt: startedAt,
                snapshot: snapshot
            )
            saveStage(.recording(id), id: id, startedAt: startedAt, snapshot: snapshot)
            if releasePending {
                releasePending = false
                let captureHint = pendingReleaseCaptureHint
                pendingReleaseCaptureHint = nil
                beginFinishingSession(captureHint: captureHint)
                await finishingTask?.value
            }
        } catch {
            guard phase == .preparing(id) else {
                await audioCapture.cancel()
                return
            }
            phase = .finalizing(id)
            finishActiveTriggerSequence()
            preparingStartedAt = nil
            activeSnapshot = nil
            confirmedDoubaoResult = nil
            historyTextPolicy = .unclassified
            let problem = (error as? AudioCaptureError)
                .map(VoiceInputProblem.init(audioCaptureError:))
                ?? VoiceInputProblem(failure: .recordingFailed)
            let activity = VoiceInputActivity.failed(id, problem.failure)
            let audit = stageAudit.finish(id: id)
            let elapsed = max(0, Int(Date().timeIntervalSince(requestedAt) * 1_000))
            let record = VoiceInputHistoryRecord(
                sessionID: id,
                startedAt: requestedAt,
                applicationName: nil,
                transcription: nil,
                finalText: nil,
                refinementModeName: snapshot.refinementMode.displayName,
                refinementPrompt: snapshot.refinementMode.deepSeekInstruction,
                dictionarySnapshotID: snapshot.dictionary.id,
                dictionarySnapshotEntries: snapshot.dictionary.entries.map(
                    RecordedDictionaryEntry.init
                ),
                dictionaryRequestContext: snapshot.dictionaryContext,
                durationMilliseconds: elapsed,
                stageDurationsMilliseconds: audit.stageDurations,
                outcome: activity
            )
            phase = .idle
            publish(activity)
            _ = queueHistory(
                record,
                terminalPresentation: .init(activity: activity, notice: nil)
            )
        }
    }

    private func beginFinishingSession(
        captureHint: InputTargetCaptureHint?
    ) {
        guard case let .recording(id, startedAt, snapshot) = phase else { return }
        _ = cancelRecordingLimit()
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()
        captureFailureTask = nil
        phase = .processing(id, startedAt: startedAt, snapshot: snapshot)
        stageAudit.advance(id: id, stage: "targetCapture")
        publish(.processing(id, .capturingTarget, applicationName: nil))
        saveStage(
            .processing(id, .capturingTarget, applicationName: nil),
            id: id,
            startedAt: startedAt,
            snapshot: snapshot
        )
        let targetCapture = targetCapture
        let audioCapture = audioCapture
        let targetTask = Task {
            await Self.captureWithTiming(
                targetCapture,
                matching: captureHint
            )
        }
        let audioTask = Task<CapturedAudio, Error> {
            try await audioCapture.stop()
        }
        finishingTask = Task { [weak self] in
            await self?.finishSession(
                id: id,
                startedAt: startedAt,
                snapshot: snapshot,
                targetTask: targetTask,
                audioTask: audioTask
            )
        }
    }

    private func finishSession(
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        targetTask: Task<(InputTargetCaptureResult, Int), Never>,
        audioTask: Task<CapturedAudio, Error>
    ) async {
        let (target, targetCaptureMilliseconds) = await targetTask.value
        historyTextPolicy = switch target {
        case .unavailable(.secureTarget): .redacted
        case .writable: .allowed
        case .unavailable: .unclassified
        }
        var sessionStageDurations = ["targetCapture": targetCaptureMilliseconds]
        let audio: CapturedAudio
        do {
            audio = try await audioTask.value
        } catch {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            streamingCompletionTask?.cancel()
            streamingCompletionTask = nil
            await discard(target)
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
                return
            }
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: (error as? AudioCaptureError)
                    .map(VoiceInputProblem.init(audioCaptureError:))
                    ?? VoiceInputProblem(failure: .recordingFailed),
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
            return
        }
        sessionStageDurations["recording"] = Self.milliseconds(audio.duration)

        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
            await discard(target)
            return
        }
        let applicationName = target.applicationName
        stageAudit.advance(id: id, stage: "doubao", applicationName: applicationName)
        publish(.processing(id, .transcribing, applicationName: applicationName))
        saveStage(
            .processing(id, .transcribing, applicationName: applicationName),
            id: id,
            startedAt: startedAt,
            applicationName: applicationName,
            snapshot: snapshot
        )

        let task: Task<VoiceTextProcessingResult, Error>
        if let liveTask = transcriptionTask {
            task = liveTask
        } else {
            let activeProcessor = textProcessor
            task = Task {
                try await activeProcessor.process(
                    audio,
                    snapshot: snapshot
                ) { [weak self] progress in
                    await self?.receivedProcessingProgress(
                        progress,
                        id: id,
                        startedAt: startedAt,
                        snapshot: snapshot,
                        applicationName: applicationName
                    )
                }
            }
            transcriptionTask = task
        }
        let processedText: VoiceTextProcessingResult
        do {
            processedText = try await task.value
        } catch let failure as VoiceTextProcessingFailure {
            transcriptionTask = nil
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
                await discard(target)
                return
            }
            await discard(target)
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: failure.problem,
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
            return
        } catch {
            transcriptionTask = nil
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
                await discard(target)
                return
            }
            await discard(target)
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: VoiceInputProblem(failure: .transcriptionFailed),
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            )
            return
        }
        transcriptionTask = nil
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil

        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else {
            await discard(target)
            return
        }

        switch target {
        case let .writable(targetSnapshot):
            stageAudit.advance(
                id: id,
                stage: "delivery",
                applicationName: targetSnapshot.applicationName
            )
            publish(.processing(id, .delivering, applicationName: targetSnapshot.applicationName))
            saveStage(
                .processing(id, .delivering, applicationName: targetSnapshot.applicationName),
                id: id,
                startedAt: startedAt,
                applicationName: targetSnapshot.applicationName,
                snapshot: snapshot
            )
            let commitGate = DeliveryCommitGate()
            deliveryCommitGate = commitGate
            let deliveryStarted = ContinuousClock.now
            let resolution = DeliveryResolution()
            deliveryResolution = resolution
            let delivery = delivery
            let finalText = processedText.finalText
            let deliveryTask = Task {
                let outcome = await delivery.deliver(
                    finalText,
                    to: targetSnapshot,
                    commitGate: commitGate
                )
                await resolution.resolve(outcome)
                return outcome
            }
            self.deliveryTask = deliveryTask
            let outcome = await resolution.wait()
            self.deliveryTask = nil
            deliveryResolution = nil
            deliveryCommitGate = nil
            sessionStageDurations["delivery"] = Self.milliseconds(
                deliveryStarted.duration(to: .now)
            )
            guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }
            switch outcome {
            case .delivered, .pasteCommandPosted:
                let activity = VoiceInputActivity.delivered(
                    id,
                    applicationName: targetSnapshot.applicationName,
                    text: processedText.finalText
                )
                await finishTerminal(.init(
                    activity: activity,
                    id: id,
                    startedAt: startedAt,
                    applicationName: targetSnapshot.applicationName,
                    transcription: processedText.doubaoText,
                    finalText: processedText.finalText,
                    providerRequestID: processedText.doubaoRequestID,
                    deliveryDiagnosticCode: outcome.deliveryDiagnostic?.code,
                    processedText: processedText,
                    processingSnapshot: snapshot,
                    additionalStageDurations: sessionStageDurations
                ))
            case let .pendingCopy(reason),
                 let .pendingCopyDiagnosed(reason, _):
                let activity = VoiceInputActivity.pendingCopy(
                    id,
                    text: processedText.finalText,
                    reason: reason
                )
                if reason == .secureTarget {
                    historyTextPolicy = .redacted
                    await finishTerminal(.init(
                        activity: activity,
                        id: id,
                        startedAt: startedAt,
                        applicationName: targetSnapshot.applicationName,
                        transcription: nil,
                        finalText: nil,
                        transcriptionProvider: "doubao",
                        providerRequestID: processedText.doubaoRequestID,
                        deliveryDiagnosticCode: outcome
                            .deliveryDiagnostic?.code,
                        processingSnapshot: snapshot,
                        additionalStageDurations: sessionStageDurations,
                        historyOutcome: .pendingCopy(
                            id,
                            text: "",
                            reason: .secureTarget
                        )
                    ))
                    return
                }
                await finishTerminal(.init(
                    activity: activity,
                    id: id,
                    startedAt: startedAt,
                    applicationName: targetSnapshot.applicationName,
                    transcription: processedText.doubaoText,
                    finalText: processedText.finalText,
                    providerRequestID: processedText.doubaoRequestID,
                    deliveryDiagnosticCode: outcome
                        .deliveryDiagnostic?.code,
                    processedText: processedText,
                    processingSnapshot: snapshot,
                    additionalStageDurations: sessionStageDurations
                ))
            }
        case let .unavailable(reason):
            let activity = VoiceInputActivity.pendingCopy(
                id,
                text: processedText.finalText,
                reason: reason
            )
            if reason == .secureTarget {
                historyTextPolicy = .redacted
                await finishTerminal(.init(
                    activity: activity,
                    id: id,
                    startedAt: startedAt,
                    applicationName: nil,
                    transcription: nil,
                    finalText: nil,
                    transcriptionProvider: "doubao",
                    providerRequestID: processedText.doubaoRequestID,
                    processingSnapshot: snapshot,
                    additionalStageDurations: sessionStageDurations,
                    historyOutcome: .pendingCopy(id, text: "", reason: .secureTarget)
                ))
                return
            }
            await finishTerminal(.init(
                activity: activity,
                id: id,
                startedAt: startedAt,
                applicationName: nil,
                transcription: processedText.doubaoText,
                finalText: processedText.finalText,
                providerRequestID: processedText.doubaoRequestID,
                processedText: processedText,
                processingSnapshot: snapshot,
                additionalStageDurations: sessionStageDurations
            ))
        }
    }

    private func cancelSession() async {
        if let deliveryCommitGate {
            // Once the delivery adapter has crossed its mutation boundary,
            // the target App may already contain the text. Hide the active UI
            // immediately, stop consuming Esc, and let the bounded receipt
            // task finish history in the background without resurfacing a
            // late result card or falsely rewriting the mutation as cancelled.
            guard await deliveryCommitGate.cancel() else {
                guard let id = currentActiveSessionID,
                      suppressedTerminalPresentationSessionID != id
                else { return }
                suppressedTerminalPresentationSessionID = id
                finishActiveTriggerSequence()
                publish(.cancelled(id))
                return
            }
        }
        let id: VoiceInputSessionID
        let startedAt: Date
        let processingSnapshot: VoiceTextProcessingSnapshot?
        let confirmedDoubaoResult = historyTextPolicy == .allowed
            ? confirmedDoubaoResult
            : nil
        switch phase {
        case let .preparing(sessionID):
            id = sessionID
            startedAt = preparingStartedAt ?? Date()
            processingSnapshot = activeSnapshot
        case let .recording(sessionID, sessionStartedAt, snapshot),
             let .processing(sessionID, sessionStartedAt, snapshot):
            id = sessionID
            startedAt = sessionStartedAt
            processingSnapshot = snapshot
        case .idle, .finalizing:
            return
        }

        let cancelledAtStage = stageAudit.currentStage
        let audit = stageAudit.finish(id: id)
        phase = .finalizing(id)
        finishActiveTriggerSequence()
        preparingStartedAt = nil
        activeSnapshot = nil
        self.confirmedDoubaoResult = nil
        historyTextPolicy = .unclassified
        releasePending = false
        pendingReleaseCaptureHint = nil
        _ = cancelRecordingLimit()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        if let deliveryResolution {
            await deliveryResolution.resolve(.pendingCopy(.deliveryFailed))
        }
        deliveryResolution = nil
        deliveryCommitGate = nil
        suppressedTerminalPresentationSessionID = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()
        captureFailureTask = nil
        let activity = VoiceInputActivity.cancelled(id)
        // Cancellation is committed before cleanup or history I/O. The overlay
        // disappears immediately and late results are fenced by `.finalizing`.
        publish(activity)
        await audioCapture.cancel()
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        _ = queueHistory(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: confirmedDoubaoResult?.text,
            finalText: nil,
            transcriptionProvider: confirmedDoubaoResult == nil ? nil : "doubao",
            providerRequestID: confirmedDoubaoResult?.providerRequestID,
            refinementModeName: processingSnapshot?.refinementMode.displayName,
            refinementPrompt: processingSnapshot?.refinementMode.deepSeekInstruction,
            cancelledAtStage: cancelledAtStage,
            dictionarySnapshotID: processingSnapshot?.dictionary.id,
            dictionarySnapshotEntries: processingSnapshot?.dictionary.entries
                .map(RecordedDictionaryEntry.init) ?? [],
            dictionaryRequestContext: processingSnapshot?.dictionaryContext,
            durationMilliseconds: elapsed,
            stageDurationsMilliseconds: audit.stageDurations.isEmpty
                ? ["beforeCancellation": elapsed]
                : audit.stageDurations,
            outcome: activity
        ))
        phase = .idle
    }

    private func finishWithFailure(
        id: VoiceInputSessionID,
        startedAt: Date,
        problem: VoiceInputProblem,
        processingSnapshot: VoiceTextProcessingSnapshot? = nil,
        additionalStageDurations: [String: Int] = [:]
    ) async {
        let activity = VoiceInputActivity.failed(id, problem.failure)
        await finishTerminal(.init(
            activity: activity,
            id: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: nil,
            finalText: nil,
            problem: problem,
            processingSnapshot: processingSnapshot,
            additionalStageDurations: additionalStageDurations
        ))
    }

    private func finishTerminal(_ termination: VoiceInputSessionTermination) async {
        let id = termination.id
        let audit = stageAudit.finish(id: id)
        let terminalHistoryTextPolicy = historyTextPolicy
        let suppressTerminalPresentation =
            suppressedTerminalPresentationSessionID == id
        phase = .finalizing(id)
        finishActiveTriggerSequence()
        preparingStartedAt = nil
        activeSnapshot = nil
        confirmedDoubaoResult = nil
        historyTextPolicy = .unclassified
        releasePending = false
        pendingReleaseCaptureHint = nil
        _ = cancelRecordingLimit()
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()
        captureFailureTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        deliveryResolution = nil
        deliveryCommitGate = nil
        suppressedTerminalPresentationSessionID = nil
        let terminal = VoiceInputTerminalRecordBuilder.make(
            termination,
            auditedStageDurations: audit.stageDurations,
            textPolicy: terminalHistoryTextPolicy
        )
        phase = .idle
        if !suppressTerminalPresentation {
            publish(termination.activity, notice: terminal.notice)
        }
        _ = queueHistory(
            terminal.record,
            terminalPresentation: suppressTerminalPresentation
                ? nil
                : .init(
                    activity: termination.activity,
                    notice: terminal.notice
                )
        )
    }

    private func publish(
        _ activity: VoiceInputActivity,
        telemetry: RecordingTelemetry? = nil,
        notice: VoiceInputNotice? = nil
    ) {
        presenter.publish(activity, telemetry: telemetry, notice: notice)
    }

    private func observeRecordingTelemetry(for id: VoiceInputSessionID) {
        telemetryTask?.cancel()
        guard let source = audioCapture as? any AudioCaptureTelemetryProviding else { return }
        telemetryTask = Task { [weak self] in
            let stream = await source.observeTelemetry()
            for await telemetry in stream {
                guard !Task.isCancelled else { return }
                await self?.receivedTelemetry(telemetry, for: id)
            }
        }
    }

    private func observeStreamingCompletion(
        _ task: Task<VoiceTextProcessingResult, Error>,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) {
        streamingCompletionTask?.cancel()
        streamingCompletionTask = Task { [weak self] in
            let result = await task.result
            guard case let .failure(error) = result else { return }
            await self?.receivedStreamingFailureWhileRecording(
                error,
                id: id,
                startedAt: startedAt,
                snapshot: snapshot
            )
        }
    }

    private func observeCaptureFailures(
        for id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) {
        captureFailureTask?.cancel()
        guard let source = audioCapture as? any AudioCaptureFailureProviding else { return }
        captureFailureTask = Task { [weak self] in
            let stream = await source.observeFailures()
            for await failure in stream {
                guard !Task.isCancelled else { return }
                await self?.receivedCaptureFailureWhileRecording(
                    failure,
                    id: id,
                    startedAt: startedAt,
                    snapshot: snapshot
                )
                return
            }
        }
    }

    private func receivedCaptureFailureWhileRecording(
        _ failure: AudioCaptureError,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) async {
        failActiveRecording(
            id: id,
            startedAt: startedAt,
            snapshot: snapshot,
            problem: VoiceInputProblem(audioCaptureError: failure)
        )
    }

    private func receivedStreamingFailureWhileRecording(
        _ error: Error,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) async {
        let problem = (error as? VoiceTextProcessingFailure)?.problem
            ?? VoiceInputProblem(failure: .transcriptionFailed)
        failActiveRecording(
            id: id,
            startedAt: startedAt,
            snapshot: snapshot,
            problem: problem
        )
    }

    private func failActiveRecording(
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        problem: VoiceInputProblem,
        cancelsRecordingLimit: Bool = true
    ) {
        guard case .recording(id, startedAt: startedAt, snapshot: snapshot) = phase else {
            return
        }
        let audit = stageAudit.finish(id: id)
        phase = .finalizing(id)
        finishActiveTriggerSequence()
        preparingStartedAt = nil
        activeSnapshot = nil
        confirmedDoubaoResult = nil
        historyTextPolicy = .unclassified
        releasePending = false
        pendingReleaseCaptureHint = nil
        if cancelsRecordingLimit {
            _ = cancelRecordingLimit()
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        streamingCompletionTask?.cancel()
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()

        let activity = VoiceInputActivity.failed(id, problem.failure)
        // Surface the terminal problem before recorder cleanup or history I/O,
        // then fence late events while shutdown retains the settlement task.
        publish(activity)
        let audioCapture = audioCapture
        activeRecordingSettlementTask = Task { [weak self] in
            await audioCapture.cancel()
            await self?.completeActiveRecordingFailure(
                id: id,
                startedAt: startedAt,
                snapshot: snapshot,
                problem: problem,
                activity: activity,
                stageDurations: audit.stageDurations
            )
        }
    }

    private func completeActiveRecordingFailure(
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        problem: VoiceInputProblem,
        activity: VoiceInputActivity,
        stageDurations: [String: Int]
    ) {
        guard phase == .finalizing(id) else { return }
        let diagnostic = problem.diagnostic
        _ = queueHistory(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: nil,
            transcription: nil,
            finalText: nil,
            transcriptionProvider: diagnostic?.provider ?? "doubao",
            providerRequestID: diagnostic?.requestID,
            providerErrorCode: diagnostic?.code,
            providerOperation: diagnostic?.operation.rawValue,
            providerStatusCode: diagnostic?.statusCode,
            providerMessage: nil,
            refinementModeName: snapshot.refinementMode.displayName,
            refinementPrompt: snapshot.refinementMode.deepSeekInstruction,
            dictionarySnapshotID: snapshot.dictionary.id,
            dictionarySnapshotEntries: snapshot.dictionary.entries.map(
                RecordedDictionaryEntry.init
            ),
            dictionaryRequestContext: snapshot.dictionaryContext,
            durationMilliseconds: max(
                0,
                Int(Date().timeIntervalSince(startedAt) * 1_000)
            ),
            stageDurationsMilliseconds: stageDurations,
            outcome: activity
        ))
        streamingCompletionTask = nil
        captureFailureTask = nil
        activeRecordingSettlementTask = nil
        phase = .idle
    }

    private func startRecordingLimit(
        for id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) {
        _ = cancelRecordingLimit()
        let duration = maximumRecordingDuration
        let sleep = sleepUntilRecordingLimit
        recordingLimitTask = Task { [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recordingLimitReached(
                id: id,
                startedAt: startedAt,
                snapshot: snapshot
            )
        }
    }

    private func recordingLimitReached(
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot
    ) async {
        guard case .recording(id, startedAt: startedAt, snapshot: snapshot) = phase else {
            return
        }
        failActiveRecording(
            id: id,
            startedAt: startedAt,
            snapshot: snapshot,
            problem: VoiceInputProblem(
                failure: .recordingLimitReached,
                diagnostic: VoiceProviderDiagnostic(
                    provider: "local",
                    operation: .transcription,
                    code: "recording.limit_reached"
                )
            ),
            cancelsRecordingLimit: false
        )
        recordingLimitTask = nil
    }

    @discardableResult
    private func cancelRecordingLimit() -> Task<Void, Never>? {
        let task = recordingLimitTask
        recordingLimitTask = nil
        task?.cancel()
        return task
    }

    private func receivedTelemetry(
        _ telemetry: RecordingTelemetry,
        for id: VoiceInputSessionID
    ) {
        guard case let .recording(activeID, _, _) = phase, activeID == id else { return }
        publish(.recording(id), telemetry: telemetry)
    }

    private func receivedProcessingProgress(
        _ progress: VoiceTextProcessingProgress,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        applicationName: String?
    ) async {
        guard phase == .processing(id, startedAt: startedAt, snapshot: snapshot) else { return }
        let stage = progress.stage
        if let confirmed = progress.confirmedDoubaoResult {
            confirmedDoubaoResult = confirmed
        }
        let auditStage = switch stage {
        case .capturingTarget: "targetCapture"
        case .transcribing: "doubao"
        case .refining: "deepseek"
        case .delivering: "delivery"
        }
        stageAudit.advance(
            id: id,
            stage: auditStage,
            applicationName: applicationName
        )
        let activity = VoiceInputActivity.processing(
            id,
            stage,
            applicationName: applicationName
        )
        publish(activity)
        saveStage(
            activity,
            id: id,
            startedAt: startedAt,
            applicationName: nil,
            snapshot: snapshot
        )
    }

    private func saveStage(
        _ activity: VoiceInputActivity,
        id: VoiceInputSessionID,
        startedAt: Date,
        applicationName: String? = nil,
        snapshot: VoiceTextProcessingSnapshot? = nil
    ) {
        _ = queueHistory(.init(
            sessionID: id,
            startedAt: startedAt,
            applicationName: applicationName,
            // Provider text is terminal data. Persisting it during processing
            // creates a crash window where a secure target can leave sensitive
            // text in SQLite/WAL before the target classification is applied.
            transcription: nil,
            finalText: nil,
            transcriptionProvider: nil,
            providerRequestID: nil,
            refinementModeName: snapshot?.refinementMode.displayName,
            refinementPrompt: snapshot?.refinementMode.deepSeekInstruction,
            dictionarySnapshotID: snapshot?.dictionary.id,
            dictionarySnapshotEntries: snapshot?.dictionary.entries
                .map(RecordedDictionaryEntry.init) ?? [],
            dictionaryRequestContext: snapshot?.dictionaryContext,
            outcome: activity
        ))
    }

    @discardableResult
    private func queueHistory(
        _ record: VoiceInputHistoryRecord,
        terminalPresentation: TerminalHistoryPresentation? = nil
    ) -> Task<Void, Never> {
        historyWrites.enqueue(
            record,
            into: history,
            reportsPersistenceFailure: terminalPresentation != nil
        ) { [weak self] token, persistenceNotice in
            await self?.historyWriteDidComplete(
                sessionID: record.sessionID,
                token: token,
                terminalPresentation: terminalPresentation,
                persistenceNotice: persistenceNotice
            )
        }
    }

    private func historyWriteDidComplete(
        sessionID: VoiceInputSessionID,
        token: UUID,
        terminalPresentation: TerminalHistoryPresentation?,
        persistenceNotice: String?
    ) {
        guard historyWrites.complete(sessionID: sessionID, token: token) else { return }
        guard let terminalPresentation,
              let persistenceNotice,
              presentation.activity == terminalPresentation.activity
        else { return }
        publish(
            terminalPresentation.activity,
            notice: .persistenceFailure(persistenceNotice)
        )
    }

    private func discard(_ captureResult: InputTargetCaptureResult) async {
        guard case let .writable(target) = captureResult,
              let discarding = targetCapture as? any InputTargetDiscarding
        else { return }
        await discarding.discard(target)
    }

    private static func captureWithTiming(
        _ capture: any InputTargetCapturing,
        matching hint: InputTargetCaptureHint?
    ) async -> (InputTargetCaptureResult, Int) {
        let started = ContinuousClock.now
        let result = if let hint {
            await capture.capture(matching: hint)
        } else {
            await capture.capture()
        }
        return (result, milliseconds(started.duration(to: .now)))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        duration.wholeMillisecondsClamped
    }

    private func removeObserver(_ id: UUID) {
        presenter.remove(id)
    }

    private func removeTriggerTerminationObserver(_ id: UUID) {
        triggerTerminations.remove(id)
    }

    private func finishActiveTriggerSequence() {
        guard let sequence = activeTriggerSequence else { return }
        activeTriggerSequence = nil
        triggerTerminations.yield(sequence)
    }

    private func finishRejectedTriggerSequence(_ sequence: UInt64) {
        triggerTerminations.yield(sequence)
    }

}
