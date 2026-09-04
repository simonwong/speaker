import Foundation

/// Elapsed-time accounting for the stages one Voice Input Session passes
/// through, driven by the monotonic readings the caller passes in. The audit
/// belongs to a single session at a time; calls carrying another session's
/// identifier are ignored so a late event from a finished session cannot
/// pollute the next one.
struct VoiceInputStageAudit {
    private var sessionID: VoiceInputSessionID?
    private var stageName: String?
    private var stageStartedAt: Duration?
    private var stageDurations: [String: Int] = [:]
    private var applicationName: String?

    /// The stage currently being timed, if any.
    var currentStage: String? { stageName }

    mutating func begin(id: VoiceInputSessionID, stage: String, now: Duration) {
        sessionID = id
        stageName = stage
        stageStartedAt = now
        stageDurations = [:]
        applicationName = nil
    }

    mutating func advance(
        id: VoiceInputSessionID,
        stage: String,
        applicationName: String? = nil,
        now: Duration
    ) {
        guard sessionID == id else { return }
        accumulateCurrentStage(now: now)
        stageName = stage
        stageStartedAt = now
        if let applicationName {
            self.applicationName = applicationName
        }
    }

    /// Closes the audit for `id` and returns what was measured. Returns empty
    /// results for any other session.
    mutating func finish(
        id: VoiceInputSessionID,
        now: Duration
    ) -> (applicationName: String?, stageDurations: [String: Int]) {
        guard sessionID == id else { return (nil, [:]) }
        accumulateCurrentStage(now: now)
        let result = (applicationName, stageDurations)
        sessionID = nil
        stageName = nil
        stageStartedAt = nil
        stageDurations = [:]
        applicationName = nil
        return result
    }

    private mutating func accumulateCurrentStage(now: Duration) {
        guard let stage = stageName, let startedAt = stageStartedAt else { return }
        stageDurations[stage, default: 0] += max(.zero, now - startedAt)
            .wholeMillisecondsClamped
    }
}

extension Duration {
    /// Whole milliseconds, saturating instead of trapping on absurd inputs.
    var wholeMillisecondsClamped: Int {
        let components = components
        return Int(clamping:
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }
}
