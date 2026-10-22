import Foundation

public actor VoiceInputSessions {
    package static let standardMaximumRecordingDuration: Duration = .seconds(600)
    /// How far ahead of a provider's audio bound recording ends itself, so
    /// capture that is still draining when recording stops stays inside it.
    package static let providerBoundMargin: Duration = .seconds(2)

    /// The recording limit for one session: the standard limit, shortened
    /// to end just inside the selected provider's audio bound.
    package static func recordingLimit(
        for provider: SpeechRecognitionProviderID,
        standard: Duration = standardMaximumRecordingDuration
    ) -> Duration {
        guard let seconds = CredentialedSpeechTranscriber.maximumAudioSeconds(for: provider) else {
            return standard
        }
        return min(standard, .seconds(seconds) - providerBoundMargin)
    }

    private let audioCapture: any AudioCapturing
    private let targetCapture: any InputTargetCapturing
    private let textProcessor: any VoiceTextProcessing
    private let delivery: any TextDelivering
    private let clipboard: any ClipboardWriting
    private let history: any SessionHistoryRecording
    private let maximumRecordingDuration: Duration
    private let clock: any VoiceInputClock

    /// The session from its press until its cleanup ends. Every fact and task
    /// that belongs to one session lives here, so ending a session is
    /// `active = nil` and nothing of it reaches the next one.
    private var active: ActiveSession?
    private var activeRecordingSettlementTask: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    /// Callers waiting for the cancellation that holds `.finalizing` to finish
    /// its cleanup; `nil` while no cancellation cleanup is running.
    private var cancellationCleanupWaiters: [CheckedContinuation<Void, Never>]?
    private var historyWrites = SessionHistoryWriteQueue()
    private var isShutDown = false
    private var presentationTriggerSequence: UInt64?
    private var presenter = VoiceInputPresentationPublisher()
    private var triggerTerminations = TriggerTerminationPublisher()
    private var presentation: VoiceInputPresentation { presenter.current }

    package init(
        audioCapture: any AudioCapturing,
        targetCapture: any InputTargetCapturing,
        textProcessor: any VoiceTextProcessing,
        delivery: any TextDelivering,
        clipboard: any ClipboardWriting,
        history: any SessionHistoryRecording,
        maximumRecordingDuration: Duration = standardMaximumRecordingDuration,
        clock: any VoiceInputClock = ContinuousVoiceInputClock()
    ) {
        self.audioCapture = audioCapture
        self.targetCapture = targetCapture
        self.textProcessor = textProcessor
        self.delivery = delivery
        self.clipboard = clipboard
        self.history = history
        self.maximumRecordingDuration = maximumRecordingDuration
        self.clock = clock
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
        active?.triggerSequence == triggerSequence
    }

    package nonisolated func prepareAudioStart() -> AudioCaptureStart {
        audioCapture.prepareStart()
    }

    /// Starts a Voice Input Session for the dispatcher's press edge. The
    /// sequence fences a later Escape and is published again when the session
    /// terminates.
    package func press(
        triggerSequence: UInt64,
        audioStart: AudioCaptureStart? = nil
    ) async {
        await beginSession(
            triggerSequence: triggerSequence,
            audioStart: audioStart ?? prepareAudioStart()
        )
    }

    package func releaseFromDispatcher(
        captureHint: InputTargetCaptureHint?
    ) {
        if active?.stage == .preparing {
            active?.releasePending = true
            active?.pendingReleaseCaptureHint = captureHint
        } else {
            beginFinishingSession(captureHint: captureHint)
        }
    }

    package func finishRecording(
        expectedSessionID: VoiceInputSessionID,
        captureHint: InputTargetCaptureHint?
    ) {
        guard isCurrent(expectedSessionID, at: .recording) else { return }
        beginFinishingSession(captureHint: captureHint)
    }

    package func handleEscape(triggeredAtSequence sequence: UInt64) async {
        guard let presentationTriggerSequence,
            presentationTriggerSequence <= sequence
        else { return }
        switch presentation.activity {
        case .pendingCopy(let id, _, _), .failed(let id, _):
            dismissResult(expectedSessionID: id)
        default:
            await cancel(triggeredAtSequence: sequence)
            // Esc also runs on the dispatcher's preempting task, and a
            // session-scoped cancel action can run alongside it, so another
            // caller may own the cleanup. Return only after it ends, so the
            // dispatcher's next press finds the session idle instead of being
            // rejected mid-cleanup.
            await waitForCancellationCleanup()
        }
    }

    private func waitForCancellationCleanup() async {
        guard cancellationCleanupWaiters != nil else { return }
        await withCheckedContinuation { cancellationCleanupWaiters?.append($0) }
    }

    private func cancel(triggeredAtSequence sequence: UInt64) async {
        guard let activeTriggerSequence = active?.triggerSequence,
            activeTriggerSequence <= sequence
        else { return }
        await cancelSession()
    }

    package func cancel(expectedSessionID: VoiceInputSessionID) async {
        guard active?.id == expectedSessionID else { return }
        await cancelSession()
    }

    /// Settles processing with the confirmed recognition Stage Result instead
    /// of waiting for refinement, then delivers it through the normal path.
    /// Only a session whose refinement is still pending accepts it.
    package func useRecognitionResult(expectedSessionID: VoiceInputSessionID) async {
        guard let session = active,
            session.id == expectedSessionID,
            session.stage == .processing,
            case .processing(let presentedID, .refining) = presentation.activity,
            presentedID == session.id,
            let confirmed = session.confirmedRecognition,
            let processingResolution = session.processingResolution
        else { return }
        let refinement = session.transcriptionTask
        let settled = await processingResolution.resolve(
            .success(
                VoiceTextProcessingResult(
                    recognitionText: confirmed.text,
                    normalizedText: confirmed.text,
                    refinedText: nil,
                    finalText: confirmed.text,
                    recognitionRequestID: confirmed.providerRequestID,
                    refinementRequestID: nil,
                    refinementStatus: .skipped,
                    refinementFailure: nil
                )
            )
        )
        if settled { refinement?.cancel() }
    }

    /// A secure Input Target's result is copied as concealed clipboard
    /// content, and a failed copy keeps it classified as secure.
    package func copyPendingResult(expectedSessionID: VoiceInputSessionID) async {
        guard case .pendingCopy(let id, let text, let reason) = presentation.activity,
            id == expectedSessionID
        else { return }
        let copied = await clipboard.copy(
            text,
            privacy: reason.isSecureTarget ? .concealed : .ordinary
        )
        guard active == nil,
            case .pendingCopy(let currentID, _, _) = presentation.activity,
            currentID == id
        else { return }
        if copied {
            publish(.idle, notice: .copied)
        } else {
            publish(
                .pendingCopy(
                    id,
                    text: text,
                    reason: reason.isSecureTarget
                        ? .secureTargetClipboardFailed : .clipboardFailed
                )
            )
        }
    }

    package func dismissResult(expectedSessionID: VoiceInputSessionID) {
        guard presentation.activity.sessionID == expectedSessionID else { return }
        switch presentation.activity {
        case .pendingCopy where active == nil,
            .failed where active == nil || isCurrent(expectedSessionID, at: .finalizing):
            publish(.idle)
        default:
            return
        }
    }

    /// Stops active work and waits until every queued history mutation has
    /// reached durable storage. App termination must use this instead of only
    /// cancelling, otherwise the final cancellation record can be lost.
    public func shutdown() async {
        isShutDown = true
        let limitTask = active?.recordingLimitTask
        limitTask?.cancel()
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

    private func isCurrent(
        _ id: VoiceInputSessionID,
        at stage: ActiveSession.Stage
    ) -> Bool {
        active?.id == id && active?.stage == stage
    }

    private func beginSession(
        triggerSequence: UInt64,
        audioStart: AudioCaptureStart
    ) async {
        guard !isShutDown, active == nil else {
            finishRejectedTriggerSequence(triggerSequence)
            return
        }
        // A press while retained text is awaiting copy deliberately abandons
        // that text: the user chose to re-record, and the notice must never
        // block the next session. The retained body may exist nowhere else
        // (unclassified targets keep it out of history), so this is an
        // explicit, user-initiated discard.
        let id = VoiceInputSessionID()
        let startedAt = clock.date
        active = ActiveSession(
            id: id,
            startedAt: startedAt,
            triggerSequence: triggerSequence,
            audioStart: audioStart,
            audit: VoiceInputStageAudit(stage: "preparing", now: clock.monotonicNow)
        )
        presentationTriggerSequence = triggerSequence
        publish(.preparing(id))
        saveStage(.preparing(id), id: id, startedAt: startedAt, snapshot: nil)
        let snapshot = await textProcessor.captureSnapshot()
        guard isCurrent(id, at: .preparing) else { return }
        active?.snapshot = snapshot

        let streamingProcessor = textProcessor.streaming
        let liveStream: AsyncStream<Data>? =
            if streamingProcessor != nil {
                await audioCapture.audioChunks()
            } else {
                nil
            }
        guard isCurrent(id, at: .preparing) else {
            await audioStart.cancel()
            return
        }

        do {
            try await audioStart.start()
            guard isCurrent(id, at: .preparing) else {
                await audioStart.cancel()
                return
            }
            active?.audioStart = nil
            active?.stage = .recording
            active?.audit.advance(stage: "recording", now: clock.monotonicNow)
            publish(.recording(id))
            startRecordingLimit(for: id, snapshot: snapshot)
            if let liveStream, let streamingProcessor {
                let completion = AudioCaptureCompletionGate()
                active?.audioCaptureCompletion = completion
                let sessions = self
                let transcriptionTask = Task {
                    try await streamingProcessor.processStreaming(
                        liveStream,
                        snapshot: snapshot,
                        audioCaptureCompletion: completion
                    ) { progress in
                        await sessions.receivedProcessingProgress(progress, id: id)
                    }
                }
                active?.transcriptionTask = transcriptionTask
                observeStreamingCompletion(transcriptionTask, id: id)
            }
            observeRecordingTelemetry(for: id)
            observeCaptureFailures(for: id)
            saveStage(.recording(id), id: id, startedAt: startedAt, snapshot: snapshot)
            if active?.releasePending == true {
                let captureHint = active?.pendingReleaseCaptureHint
                active?.releasePending = false
                active?.pendingReleaseCaptureHint = nil
                beginFinishingSession(captureHint: captureHint)
                await finishingTask?.value
            }
        } catch {
            guard isCurrent(id, at: .preparing), let session = active else {
                await audioStart.cancel()
                return
            }
            let problem =
                (error as? AudioCaptureError)
                .map(VoiceInputProblem.init(audioCaptureError:))
                ?? VoiceInputProblem(failure: .recordingFailed)
            let activity = VoiceInputActivity.failed(id, problem.failure)
            let auditedStageDurations = active?.audit.finish(now: clock.monotonicNow) ?? [:]
            beginFinalizing()
            let record = VoiceInputSessionRecordBuilder.make(
                VoiceInputSessionEnding(
                    id: id,
                    startedAt: startedAt,
                    outcome: activity,
                    snapshot: snapshot,
                    problem: problem,
                    recordsRefinementProvider: false
                ),
                auditedStageDurations: auditedStageDurations,
                textPolicy: session.textPolicy,
                now: clock.date
            ).record
            active = nil
            publish(activity)
            _ = queueHistory(
                record,
                terminalPresentation: .init(activity: activity, notice: nil)
            )
        }
    }

    private func beginFinishingSession(
        captureHint: InputTargetCaptureHint?,
        endedAtRecordingLimit: Bool = false
    ) {
        guard let session = active, session.stage == .recording,
            let snapshot = session.snapshot
        else { return }
        let id = session.id
        active?.stopRecordingWork()
        active?.stage = .processing
        active?.audit.advance(stage: "targetCapture", now: clock.monotonicNow)
        publish(
            .processing(id, .capturingTarget),
            notice: endedAtRecordingLimit ? .recordingLimitReached : nil
        )
        saveStage(
            .processing(id, .capturingTarget),
            id: id,
            startedAt: session.startedAt,
            snapshot: snapshot
        )
        let targetCapture = targetCapture
        let audioCapture = audioCapture
        let targetTask = Task {
            await captureWithTiming(
                targetCapture,
                matching: captureHint
            )
        }
        let resolution = TextProcessingResolution()
        active?.processingResolution = resolution
        let completion = session.audioCaptureCompletion
        let audioTask = Task<CapturedAudio, Error> {
            do {
                let audio = try await audioCapture.stop()
                await completion?.accept()
                return audio
            } catch {
                await completion?.reject()
                throw error
            }
        }
        finishingTask = Task { [weak self] in
            await self?.finishSession(
                id: id,
                startedAt: session.startedAt,
                snapshot: snapshot,
                targetTask: targetTask,
                audioTask: audioTask,
                resolution: resolution
            )
        }
    }

    private func finishSession(
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot,
        targetTask: Task<(InputTargetCaptureResult, Int), Never>,
        audioTask: Task<CapturedAudio, Error>,
        resolution: TextProcessingResolution
    ) async {
        let (target, targetCaptureMilliseconds) = await targetTask.value
        guard isCurrent(id, at: .processing) else {
            await discard(target)
            return
        }
        active?.textPolicy =
            switch target {
            case .unavailable(.secureTarget): .redacted
            case .writable(let snapshot) where snapshot.isSecurityClassConfirmed: .allowed
            case .writable, .unavailable: .unclassified
            }
        var sessionStageDurations = ["targetCapture": targetCaptureMilliseconds]
        let audio: CapturedAudio
        do {
            audio = try await audioTask.value
        } catch {
            guard isCurrent(id, at: .processing) else {
                await discard(target)
                return
            }
            active?.cancelWork()
            await discard(target)
            guard isCurrent(id, at: .processing) else { return }
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: (error as? AudioCaptureError)
                    .map(VoiceInputProblem.init(audioCaptureError:))
                    ?? VoiceInputProblem(failure: .recordingFailed),
                snapshot: snapshot,
                measuredStageDurations: sessionStageDurations
            )
            return
        }
        sessionStageDurations["recording"] = Self.milliseconds(audio.duration)

        guard isCurrent(id, at: .processing) else {
            await discard(target)
            return
        }
        active?.audit.advance(
            stage: snapshot.recognitionProvider.provider.rawValue,
            now: clock.monotonicNow
        )
        publish(.processing(id, .transcribing))
        saveStage(
            .processing(id, .transcribing),
            id: id,
            startedAt: startedAt,
            snapshot: snapshot
        )

        let task: Task<VoiceTextProcessingResult, Error>
        if let liveTask = active?.transcriptionTask {
            task = liveTask
        } else {
            let activeProcessor = textProcessor
            // The task already holds the sessions strongly; saying so keeps the
            // progress callback's weak capture from reading as a mismatch.
            task = Task { [self] in
                try await activeProcessor.process(
                    audio,
                    snapshot: snapshot
                ) { [weak self] progress in
                    await self?.receivedProcessingProgress(progress, id: id)
                }
            }
            active?.transcriptionTask = task
        }
        let processedText: VoiceTextProcessingResult
        do {
            // Every provider's text crosses this one point before delivery,
            // presentation, and history.
            processedText = try await Self.settle(task, through: resolution)
                .removingControlCharacters()
        } catch {
            guard isCurrent(id, at: .processing) else {
                await discard(target)
                return
            }
            active?.transcriptionTask = nil
            await discard(target)
            guard isCurrent(id, at: .processing) else { return }
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: (error as? VoiceTextProcessingFailure)?.problem
                    ?? VoiceInputProblem(failure: .transcriptionFailed),
                snapshot: snapshot,
                measuredStageDurations: sessionStageDurations
            )
            return
        }
        guard isCurrent(id, at: .processing) else {
            await discard(target)
            return
        }
        active?.transcriptionTask = nil
        active?.processingResolution = nil
        // Text made only of control characters has nothing left to deliver.
        guard !processedText.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            await discard(target)
            guard isCurrent(id, at: .processing) else { return }
            await finishWithFailure(
                id: id,
                startedAt: startedAt,
                problem: VoiceInputProblem(failure: .providerReturnedNoText),
                snapshot: snapshot,
                measuredStageDurations: sessionStageDurations
            )
            return
        }

        let ending = { (outcome: VoiceInputActivity, deliveryDiagnosticCode: String?) in
            VoiceInputSessionEnding(
                id: id,
                startedAt: startedAt,
                outcome: outcome,
                snapshot: snapshot,
                processedText: processedText,
                deliveryDiagnosticCode: deliveryDiagnosticCode,
                measuredStageDurations: sessionStageDurations
            )
        }
        switch target {
        case .writable(let targetSnapshot):
            active?.audit.advance(stage: "delivery", now: clock.monotonicNow)
            publish(.processing(id, .delivering))
            saveStage(
                .processing(id, .delivering),
                id: id,
                startedAt: startedAt,
                snapshot: snapshot
            )
            let commitGate = DeliveryCommitGate()
            let deliveryStarted = clock.monotonicNow
            let resolution = DeliveryResolution()
            let delivery = delivery
            let finalText = processedText.finalText
            active?.deliveryCommitGate = commitGate
            active?.deliveryResolution = resolution
            active?.deliveryTask = Task {
                let outcome = await delivery.deliver(
                    finalText,
                    to: targetSnapshot,
                    commitGate: commitGate
                )
                await resolution.resolve(outcome)
                return outcome
            }
            let outcome = await resolution.wait()
            sessionStageDurations["delivery"] = Self.milliseconds(
                clock.monotonicNow - deliveryStarted
            )
            guard isCurrent(id, at: .processing) else { return }
            active?.deliveryTask = nil
            active?.deliveryResolution = nil
            active?.deliveryCommitGate = nil
            switch outcome {
            case .delivered, .pasteCommandPosted:
                await finishTerminal(
                    ending(
                        .delivered(id, text: processedText.finalText),
                        outcome.deliveryDiagnostic?.code
                    ))
            case .pendingCopy(let reason),
                .pendingCopyDiagnosed(let reason, _):
                if reason == .secureTarget {
                    active?.textPolicy = .redacted
                }
                await finishTerminal(
                    ending(
                        .pendingCopy(id, text: processedText.finalText, reason: reason),
                        outcome.deliveryDiagnostic?.code
                    ))
            }
        case .unavailable(let reason):
            await finishTerminal(
                ending(.pendingCopy(id, text: processedText.finalText, reason: reason), nil)
            )
        }
    }

    private func cancelSession() async {
        if let session = active, let deliveryCommitGate = session.deliveryCommitGate {
            // Once the delivery adapter has crossed its mutation boundary,
            // the target App may already contain the text. Hide the active UI
            // immediately, stop consuming Esc, and let the bounded receipt
            // task finish history in the background without resurfacing a
            // late result card or falsely rewriting the mutation as cancelled.
            guard await deliveryCommitGate.cancel() else {
                guard active?.id == session.id,
                    active?.suppressesTerminalPresentation == false
                else { return }
                active?.suppressesTerminalPresentation = true
                finishActiveTriggerSequence()
                publish(.cancelled(session.id))
                return
            }
        }
        guard let session = active, session.stage != .finalizing else { return }
        let id = session.id
        let activity = VoiceInputActivity.cancelled(id)
        let ending = VoiceInputSessionEnding(
            id: id,
            startedAt: session.startedAt,
            outcome: activity,
            snapshot: session.snapshot,
            confirmedRecognition: session.textPolicy == .allowed
                ? session.confirmedRecognition : nil,
            cancelledAtStage: session.audit.currentStage
        )
        let auditedStageDurations = active?.audit.finish(now: clock.monotonicNow) ?? [:]
        beginFinalizing()
        cancellationCleanupWaiters = []
        if let deliveryResolution = session.deliveryResolution {
            await deliveryResolution.resolve(.pendingCopy(.deliveryFailed))
        }
        // Cancellation is committed before cleanup or history I/O. The overlay
        // disappears immediately and late results are fenced by `.finalizing`.
        publish(activity)
        await session.audioCaptureCompletion?.reject()
        await session.audioStart?.cancel()
        await audioCapture.cancel()
        let now = clock.date
        let record = VoiceInputSessionRecordBuilder.make(
            ending,
            auditedStageDurations: auditedStageDurations.isEmpty
                ? [
                    "beforeCancellation": VoiceInputSessionRecordBuilder.elapsedMilliseconds(
                        since: session.startedAt,
                        now: now
                    )
                ]
                : auditedStageDurations,
            textPolicy: session.textPolicy,
            now: now
        ).record
        _ = queueHistory(record)
        active = nil
        let cleanupWaiters = cancellationCleanupWaiters ?? []
        cancellationCleanupWaiters = nil
        for waiter in cleanupWaiters { waiter.resume() }
    }

    /// Waits for whichever settles processing first: the processing task or
    /// a request to use the confirmed recognition Stage Result.
    private static func settle(
        _ task: Task<VoiceTextProcessingResult, Error>,
        through resolution: TextProcessingResolution
    ) async throws -> VoiceTextProcessingResult {
        Task {
            do {
                let result = try await task.value
                await resolution.resolve(.success(result))
            } catch {
                await resolution.resolve(.failure(error))
            }
        }
        return try await resolution.wait()
    }

    private func finishWithFailure(
        id: VoiceInputSessionID,
        startedAt: Date,
        problem: VoiceInputProblem,
        snapshot: VoiceTextProcessingSnapshot,
        measuredStageDurations: [String: Int]
    ) async {
        await finishTerminal(
            VoiceInputSessionEnding(
                id: id,
                startedAt: startedAt,
                outcome: .failed(id, problem.failure),
                snapshot: snapshot,
                problem: problem,
                measuredStageDurations: measuredStageDurations
            ))
    }

    private func finishTerminal(_ ending: VoiceInputSessionEnding) async {
        guard let session = active, session.id == ending.id else { return }
        let auditedStageDurations = active?.audit.finish(now: clock.monotonicNow) ?? [:]
        let terminal = VoiceInputSessionRecordBuilder.make(
            ending,
            auditedStageDurations: auditedStageDurations,
            textPolicy: session.textPolicy,
            now: clock.date
        )
        beginFinalizing()
        await session.audioCaptureCompletion?.reject()
        active = nil
        let presentsTerminal = !session.suppressesTerminalPresentation
        if presentsTerminal {
            publish(ending.outcome, notice: terminal.notice)
        }
        _ = queueHistory(
            terminal.record,
            terminalPresentation: presentsTerminal
                ? .init(activity: ending.outcome, notice: terminal.notice)
                : nil
        )
    }

    /// Moves the active session to `.finalizing`: its trigger sequence ends
    /// and every task it started is cancelled, so none of them can act on it
    /// or on a later session.
    private func beginFinalizing() {
        active?.stage = .finalizing
        active?.cancelWork()
        finishActiveTriggerSequence()
    }

    private func publish(
        _ activity: VoiceInputActivity,
        telemetry: RecordingTelemetry? = nil,
        notice: VoiceInputNotice? = nil
    ) {
        presenter.publish(activity, telemetry: telemetry, notice: notice)
    }

    private func observeRecordingTelemetry(for id: VoiceInputSessionID) {
        guard let source = audioCapture as? any AudioCaptureTelemetryProviding else { return }
        active?.telemetryTask = Task { [weak self] in
            let stream = await source.observeTelemetry()
            for await telemetry in stream {
                guard !Task.isCancelled else { return }
                await self?.receivedTelemetry(telemetry, for: id)
            }
        }
    }

    private func observeStreamingCompletion(
        _ task: Task<VoiceTextProcessingResult, Error>,
        id: VoiceInputSessionID
    ) {
        active?.streamingCompletionTask = Task { [weak self] in
            let result = await task.result
            guard case .failure(let error) = result else { return }
            await self?.failActiveRecording(
                id: id,
                problem: (error as? VoiceTextProcessingFailure)?.problem
                    ?? VoiceInputProblem(failure: .transcriptionFailed)
            )
        }
    }

    private func observeCaptureFailures(for id: VoiceInputSessionID) {
        guard let source = audioCapture as? any AudioCaptureFailureProviding else { return }
        active?.captureFailureTask = Task { [weak self] in
            let stream = await source.observeFailures()
            for await failure in stream {
                guard !Task.isCancelled else { return }
                await self?.failActiveRecording(
                    id: id,
                    problem: VoiceInputProblem(audioCaptureError: failure)
                )
                return
            }
        }
    }

    private func failActiveRecording(
        id: VoiceInputSessionID,
        problem: VoiceInputProblem
    ) {
        guard isCurrent(id, at: .recording), let session = active else { return }
        let activity = VoiceInputActivity.failed(id, problem.failure)
        let ending = VoiceInputSessionEnding(
            id: id,
            startedAt: session.startedAt,
            outcome: activity,
            snapshot: session.snapshot,
            problem: problem,
            recordsRefinementProvider: false
        )
        let auditedStageDurations = active?.audit.finish(now: clock.monotonicNow) ?? [:]
        beginFinalizing()
        // Surface the terminal problem before recorder cleanup or history I/O,
        // then fence late events while shutdown retains the settlement task.
        publish(activity)
        let audioCapture = audioCapture
        let completion = session.audioCaptureCompletion
        let textPolicy = session.textPolicy
        activeRecordingSettlementTask = Task { [weak self] in
            await completion?.reject()
            await audioCapture.cancel()
            await self?.completeActiveRecordingFailure(
                ending,
                auditedStageDurations: auditedStageDurations,
                textPolicy: textPolicy
            )
        }
    }

    private func completeActiveRecordingFailure(
        _ ending: VoiceInputSessionEnding,
        auditedStageDurations: [String: Int],
        textPolicy: HistoryTextPolicy
    ) {
        guard isCurrent(ending.id, at: .finalizing) else { return }
        _ = queueHistory(
            VoiceInputSessionRecordBuilder.make(
                ending,
                auditedStageDurations: auditedStageDurations,
                textPolicy: textPolicy,
                now: clock.date
            ).record
        )
        activeRecordingSettlementTask = nil
        active = nil
    }

    private func startRecordingLimit(
        for id: VoiceInputSessionID,
        snapshot: VoiceTextProcessingSnapshot
    ) {
        let duration = Self.recordingLimit(
            for: snapshot.recognitionProvider.provider,
            standard: maximumRecordingDuration
        )
        let clock = clock
        active?.recordingDeadline = clock.monotonicNow + duration
        active?.recordingLimitTask = Task { [weak self] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recordingLimitReached(id: id)
        }
    }

    private func recordingLimitReached(id: VoiceInputSessionID) async {
        guard isCurrent(id, at: .recording) else { return }
        // The limit ends recording the way a release does, at this moment:
        // the Input Target is captured now and the audio so far is kept.
        beginFinishingSession(captureHint: nil, endedAtRecordingLimit: true)
    }

    private func receivedTelemetry(
        _ telemetry: RecordingTelemetry,
        for id: VoiceInputSessionID
    ) {
        guard isCurrent(id, at: .recording) else { return }
        let remaining = active?.recordingDeadline.map { deadline in
            max(0, Self.milliseconds(deadline - clock.monotonicNow))
        }
        publish(
            .recording(id),
            telemetry: RecordingTelemetry(
                elapsedMilliseconds: telemetry.elapsedMilliseconds,
                peakPower: telemetry.peakPower,
                remainingMilliseconds: remaining
            )
        )
    }

    private func receivedProcessingProgress(
        _ progress: VoiceTextProcessingProgress,
        id: VoiceInputSessionID
    ) async {
        guard isCurrent(id, at: .processing), let session = active,
            let snapshot = session.snapshot
        else { return }
        let stage = progress.stage
        if let confirmed = progress.confirmedRecognitionResult {
            active?.confirmedRecognition = TranscriptionResult(
                text: ProviderTextSanitizer.removingControlCharacters(from: confirmed.text),
                providerRequestID: confirmed.providerRequestID
            )
        }
        let auditStage =
            switch stage {
            case .capturingTarget: "targetCapture"
            case .transcribing: snapshot.recognitionProvider.provider.rawValue
            case .refining: "deepseek"
            case .delivering: "delivery"
            }
        active?.audit.advance(stage: auditStage, now: clock.monotonicNow)
        let activity = VoiceInputActivity.processing(id, stage)
        publish(activity)
        saveStage(activity, id: id, startedAt: session.startedAt, snapshot: snapshot)
    }

    private func saveStage(
        _ activity: VoiceInputActivity,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot?
    ) {
        _ = queueHistory(
            VoiceInputSessionRecordBuilder.stage(
                activity,
                id: id,
                startedAt: startedAt,
                snapshot: snapshot
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
        persistenceNotice: LocalHistoryPersistenceNotice?
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
        guard case .writable(let target) = captureResult,
            let discarding = targetCapture as? any InputTargetDiscarding
        else { return }
        await discarding.discard(target)
    }

    private func captureWithTiming(
        _ capture: any InputTargetCapturing,
        matching hint: InputTargetCaptureHint?
    ) async -> (InputTargetCaptureResult, Int) {
        let started = clock.monotonicNow
        let result =
            if let hint {
                await capture.capture(matching: hint)
            } else {
                await capture.capture()
            }
        return (result, Self.milliseconds(clock.monotonicNow - started))
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
        guard let sequence = active?.triggerSequence else { return }
        active?.triggerSequence = nil
        triggerTerminations.yield(sequence)
    }

    private func finishRejectedTriggerSequence(_ sequence: UInt64) {
        triggerTerminations.yield(sequence)
    }

}

/// One Voice Input Session's state and the work it owns, from its press until
/// its cleanup ends.
private struct ActiveSession {
    enum Stage: Equatable {
        case preparing
        case recording
        case processing
        /// Ended; cleanup and the Session Record are still being written.
        case finalizing
    }

    let id: VoiceInputSessionID
    let startedAt: Date
    var stage = Stage.preparing
    /// The dispatcher sequence that started the session, until the session
    /// publishes that it ended.
    var triggerSequence: UInt64?
    var snapshot: VoiceTextProcessingSnapshot?
    /// The recorder start, until recording begins.
    var audioStart: AudioCaptureStart?
    var releasePending = false
    var pendingReleaseCaptureHint: InputTargetCaptureHint?
    var audit: VoiceInputStageAudit
    var textPolicy = HistoryTextPolicy.unclassified
    var confirmedRecognition: TranscriptionResult?
    /// Set when a cancel arrives after delivery committed: the session still
    /// records its truthful outcome but presents nothing more.
    var suppressesTerminalPresentation = false
    var recordingDeadline: Duration?

    var transcriptionTask: Task<VoiceTextProcessingResult, Error>?
    var processingResolution: TextProcessingResolution?
    var audioCaptureCompletion: AudioCaptureCompletionGate?
    var streamingCompletionTask: Task<Void, Never>?
    var telemetryTask: Task<Void, Never>?
    var captureFailureTask: Task<Void, Never>?
    var recordingLimitTask: Task<Void, Never>?
    var deliveryCommitGate: DeliveryCommitGate?
    var deliveryTask: Task<DeliveryOutcome, Never>?
    var deliveryResolution: DeliveryResolution?

    init(
        id: VoiceInputSessionID,
        startedAt: Date,
        triggerSequence: UInt64,
        audioStart: AudioCaptureStart,
        audit: VoiceInputStageAudit
    ) {
        self.id = id
        self.startedAt = startedAt
        self.triggerSequence = triggerSequence
        self.audioStart = audioStart
        self.audit = audit
    }

    /// Stops the work that only runs while recording: the recording limit,
    /// telemetry, and capture-failure observation.
    mutating func stopRecordingWork() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        recordingDeadline = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        captureFailureTask?.cancel()
        captureFailureTask = nil
    }

    /// Cancels every task the session started. This is the only place a
    /// session's tasks are cancelled.
    mutating func cancelWork() {
        stopRecordingWork()
        releasePending = false
        pendingReleaseCaptureHint = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        processingResolution = nil
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        deliveryResolution = nil
        deliveryCommitGate = nil
    }
}
