import Foundation

/// History text is fail-closed until the release-time Accessibility target
/// has been classified. A secure target must never let provider text enter
/// an in-flight, cancelled, failed, or terminal history record.
enum HistoryTextPolicy {
    case unclassified
    case allowed
    case redacted
}

/// Everything the state machine knows when a session reaches a terminal
/// activity. The Session Record is derived from this value, not assembled in
/// the actor, so the persistence rules stay in one place.
struct VoiceInputSessionTermination: Sendable {
    let activity: VoiceInputActivity
    let id: VoiceInputSessionID
    let startedAt: Date
    let applicationName: String?
    let transcription: String?
    let finalText: String?
    var transcriptionProvider: String? = nil
    var providerRequestID: String? = nil
    var providerErrorCode: String? = nil
    var deliveryDiagnosticCode: String? = nil
    var problem: VoiceInputProblem? = nil
    var processedText: VoiceTextProcessingResult? = nil
    var processingSnapshot: VoiceTextProcessingSnapshot? = nil
    var additionalStageDurations: [String: Int] = [:]
    /// The outcome written to history when it must differ from the presented
    /// activity, for example a text-free pending copy for a secure target.
    var historyOutcome: VoiceInputActivity? = nil
}

/// Builds the terminal Session Record and the notice shown with it.
enum VoiceInputTerminalRecordBuilder {
    struct Output {
        let record: VoiceInputHistoryRecord
        let notice: VoiceInputNotice?
    }

    static func make(
        _ termination: VoiceInputSessionTermination,
        auditedStageDurations: [String: Int],
        textPolicy: HistoryTextPolicy,
        now: Date = Date()
    ) -> Output {
        let processedText = termination.processedText
        let notice: VoiceInputNotice? = if processedText?.refinementStatus == .fellBack {
            .refinementFellBack(processedText?.refinementFailure?.kind)
        } else {
            nil
        }
        let measuredStageDurations = (processedText?.stageDurationsMilliseconds ?? [:])
            .merging(termination.additionalStageDurations) { _, latest in latest }
        let stageDurations = auditedStageDurations
            .merging(measuredStageDurations) { _, measured in measured }
        let providerDiagnostic = termination.problem?.diagnostic
        let refinementDiagnostic = processedText?.refinementFailure?.providerDiagnostic
        let mayPersistBody = textPolicy == .allowed
        let mayPersistProviderRequestID = textPolicy != .redacted
        let snapshot = termination.processingSnapshot
        let record = VoiceInputHistoryRecord(
            sessionID: termination.id,
            startedAt: termination.startedAt,
            applicationName: nil,
            transcription: mayPersistBody ? termination.transcription : nil,
            finalText: mayPersistBody ? termination.finalText : nil,
            transcriptionProvider: providerDiagnostic?.provider
                ?? termination.transcriptionProvider
                ?? (processedText == nil ? nil : "doubao"),
            providerRequestID: mayPersistProviderRequestID
                ? (providerDiagnostic?.requestID ?? termination.providerRequestID)
                : nil,
            providerErrorCode: providerDiagnostic?.code ?? termination.providerErrorCode,
            providerOperation: providerDiagnostic?.operation.rawValue,
            providerStatusCode: providerDiagnostic?.statusCode,
            // Provider messages are untrusted response text and can echo
            // credentials or user context. Keep structured codes only.
            providerMessage: nil,
            deliveryDiagnosticCode: termination.deliveryDiagnosticCode,
            deepSeekText: mayPersistBody ? processedText?.deepSeekText : nil,
            deepSeekRequestID: mayPersistProviderRequestID
                ? processedText?.deepSeekRequestID
                : nil,
            refinementModeName: snapshot?.refinementMode.displayName,
            refinementPrompt: snapshot?.refinementMode.deepSeekInstruction,
            refinementStatus: processedText?.refinementStatus.rawValue,
            refinementFailureCode: processedText?.refinementFailure?.kind.rawValue,
            refinementFailureStatusCode: refinementDiagnostic?.statusCode,
            refinementFailureMessage: nil,
            dictionarySnapshotID: snapshot?.dictionary.id,
            dictionarySnapshotEntries: snapshot?.dictionary.entries
                .map(RecordedDictionaryEntry.init) ?? [],
            dictionaryRequestContext: snapshot?.dictionaryContext,
            dictionaryReplacements: [],
            durationMilliseconds: max(
                0,
                Int(now.timeIntervalSince(termination.startedAt) * 1_000)
            ),
            stageDurationsMilliseconds: stageDurations,
            outcome: historyOutcome(
                termination.historyOutcome ?? termination.activity,
                mayPersistBody: mayPersistBody
            )
        )
        return Output(record: record, notice: notice)
    }

    /// A pending copy whose text may not be persisted is stored without it.
    private static func historyOutcome(
        _ activity: VoiceInputActivity,
        mayPersistBody: Bool
    ) -> VoiceInputActivity {
        guard !mayPersistBody,
              case let .pendingCopy(id, _, reason) = activity
        else { return activity }
        return .pendingCopy(id, text: "", reason: reason)
    }
}
