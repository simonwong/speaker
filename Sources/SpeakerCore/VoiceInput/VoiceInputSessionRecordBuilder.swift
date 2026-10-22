import Foundation

/// History text is fail-closed until the release-time Accessibility target
/// has been classified. A secure target must never let provider text enter
/// an in-flight, cancelled, failed, or terminal history record.
enum HistoryTextPolicy {
    case unclassified
    case allowed
    case redacted
}

/// Everything the state machine knows when a session ends. The Session Record
/// is derived from this value, not assembled in the actor, so the persistence
/// rules stay in one place.
struct VoiceInputSessionEnding: Sendable {
    let id: VoiceInputSessionID
    let startedAt: Date
    /// The activity presented when the session ended.
    let outcome: VoiceInputActivity
    var snapshot: VoiceTextProcessingSnapshot? = nil
    var processedText: VoiceTextProcessingResult? = nil
    /// The recognition Stage Result confirmed before a session without a
    /// processed result ended.
    var confirmedRecognition: TranscriptionResult? = nil
    var problem: VoiceInputProblem? = nil
    var deliveryDiagnosticCode: String? = nil
    var cancelledAtStage: String? = nil
    var measuredStageDurations: [String: Int] = [:]
    /// Whether the session reached the point where its Refinement Provider
    /// applies. A session that fails while preparing or recording records none.
    var recordsRefinementProvider = true
}

/// Builds every Session Record a session writes: the text-free records of its
/// stages, and the record of how it ended with the notice shown with it.
enum VoiceInputSessionRecordBuilder {
    struct Output {
        let record: VoiceInputHistoryRecord
        let notice: VoiceInputNotice?
    }

    /// The record of a session still in progress. Provider text is terminal
    /// data: persisting it during processing would open a crash window where a
    /// secure target leaves text in SQLite before it is classified.
    static func stage(
        _ activity: VoiceInputActivity,
        id: VoiceInputSessionID,
        startedAt: Date,
        snapshot: VoiceTextProcessingSnapshot?
    ) -> VoiceInputHistoryRecord {
        VoiceInputHistoryRecord(
            sessionID: id,
            startedAt: startedAt,
            transcription: nil,
            finalText: nil,
            transcriptionProvider: snapshot?.recognitionProvider.provider.rawValue,
            transcriptionModelID: snapshot?.recognitionProvider.model,
            providerRequestID: nil,
            refinementModeName: snapshot?.refinementMode.displayName,
            refinementPrompt: snapshot?.refinementMode.refinementInstruction,
            dictionarySnapshotID: snapshot?.dictionary.id,
            dictionarySnapshotEntries: snapshot?.dictionary.entries
                .map(RecordedDictionaryEntry.init) ?? [],
            dictionaryRequestContext: snapshot?.dictionaryContext,
            outcome: activity
        )
    }

    static func make(
        _ ending: VoiceInputSessionEnding,
        auditedStageDurations: [String: Int],
        textPolicy: HistoryTextPolicy,
        now: Date = Date()
    ) -> Output {
        // A secure target keeps nothing the provider produced, so its record
        // carries no refinement facts either.
        let processedText = textPolicy == .redacted ? nil : ending.processedText
        let notice: VoiceInputNotice? =
            if processedText?.refinementStatus == .fellBack {
                .refinementFellBack(processedText?.refinementFailure?.kind)
            } else {
                nil
            }
        let measuredStageDurations = (processedText?.stageDurationsMilliseconds ?? [:])
            .merging(ending.measuredStageDurations) { _, latest in latest }
        let stageDurations =
            auditedStageDurations
            .merging(measuredStageDurations) { _, measured in measured }
        let providerDiagnostic = ending.problem?.diagnostic
        let refinementDiagnostic = processedText?.refinementFailure?.providerDiagnostic
        let mayPersistBody = textPolicy == .allowed
        let mayPersistProviderRequestID = textPolicy != .redacted
        let snapshot = ending.snapshot
        let recordsRefinementProvider =
            ending.recordsRefinementProvider
            && snapshot?.refinementMode.requiresRefinement == true
        let record = VoiceInputHistoryRecord(
            sessionID: ending.id,
            startedAt: ending.startedAt,
            transcription: mayPersistBody
                ? (processedText?.recognitionText ?? ending.confirmedRecognition?.text)
                : nil,
            finalText: mayPersistBody ? processedText?.finalText : nil,
            transcriptionProvider: providerDiagnostic?.provider
                ?? snapshot?.recognitionProvider.provider.rawValue,
            transcriptionModelID: snapshot?.recognitionProvider.model,
            providerRequestID: mayPersistProviderRequestID
                ? (providerDiagnostic?.requestID
                    ?? processedText?.recognitionRequestID
                    ?? ending.confirmedRecognition?.providerRequestID)
                : nil,
            providerErrorCode: providerDiagnostic?.code,
            providerOperation: providerDiagnostic?.operation.rawValue,
            providerStatusCode: providerDiagnostic?.statusCode,
            // Provider messages are untrusted response text and can echo
            // credentials or user context. Keep structured codes only.
            providerMessage: nil,
            deliveryDiagnosticCode: ending.deliveryDiagnosticCode,
            refinedText: mayPersistBody ? processedText?.refinedText : nil,
            refinementRequestID: mayPersistProviderRequestID
                ? processedText?.refinementRequestID
                : nil,
            refinementProviderID: recordsRefinementProvider
                ? snapshot?.refinementProvider.provider : nil,
            refinementModelID: recordsRefinementProvider
                ? snapshot?.refinementProvider.modelID : nil,
            refinementModeName: snapshot?.refinementMode.displayName,
            refinementPrompt: snapshot?.refinementMode.refinementInstruction,
            refinementStatus: processedText?.refinementStatus.rawValue,
            refinementFailureCode: processedText?.refinementFailure?.kind.rawValue,
            refinementFailureStatusCode: refinementDiagnostic?.statusCode,
            refinementFailureMessage: nil,
            cancelledAtStage: ending.cancelledAtStage,
            dictionarySnapshotID: snapshot?.dictionary.id,
            dictionarySnapshotEntries: snapshot?.dictionary.entries
                .map(RecordedDictionaryEntry.init) ?? [],
            dictionaryRequestContext: snapshot?.dictionaryContext,
            dictionaryReplacements: [],
            durationMilliseconds: elapsedMilliseconds(since: ending.startedAt, now: now),
            stageDurationsMilliseconds: stageDurations,
            releaseToDeliveryMilliseconds: releaseToDelivery(
                ending.outcome,
                auditedStageDurations: auditedStageDurations
            ),
            outcome: historyOutcome(ending.outcome, mayPersistBody: mayPersistBody)
        )
        return Output(record: record, notice: notice)
    }

    static func elapsedMilliseconds(since startedAt: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt) * 1_000))
    }

    /// Stages the audit times before the shortcut is released.
    private static let preReleaseStages: Set<String> = ["preparing", "recording"]

    /// Time from shortcut release to committed delivery, read from the
    /// monotonic stage audit alone.
    ///
    /// The audit starts `targetCapture` at release and closes `delivery` when
    /// the session finishes, so every audited stage after recording spans
    /// exactly that interval. Measured stage durations are not used: a
    /// streaming provider's transcription time includes the recording. Only a
    /// delivered session has this interval; cancellation, a Session Problem,
    /// and a Pending Copy Result do not.
    private static func releaseToDelivery(
        _ activity: VoiceInputActivity,
        auditedStageDurations: [String: Int]
    ) -> Int? {
        guard case .delivered = activity,
            auditedStageDurations["targetCapture"] != nil,
            auditedStageDurations["delivery"] != nil
        else { return nil }
        return
            auditedStageDurations
            .filter { !preReleaseStages.contains($0.key) }
            .values
            .reduce(0) { $0 + max(0, $1) }
    }

    /// An outcome whose text may not be persisted is stored without it.
    private static func historyOutcome(
        _ activity: VoiceInputActivity,
        mayPersistBody: Bool
    ) -> VoiceInputActivity {
        guard !mayPersistBody else { return activity }
        switch activity {
        case .pendingCopy(let id, _, let reason):
            return .pendingCopy(id, text: "", reason: reason)
        case .delivered(let id, _):
            return .delivered(id, text: "")
        default:
            return activity
        }
    }
}
