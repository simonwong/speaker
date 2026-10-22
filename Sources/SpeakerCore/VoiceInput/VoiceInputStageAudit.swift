import Foundation

/// Elapsed-time accounting for the stages one Voice Input Session passes
/// through, driven by the monotonic readings the caller passes in. Each
/// session owns its audit, so a finished session's audit ends with it.
struct VoiceInputStageAudit {
    private var stageName: String?
    private var stageStartedAt: Duration?
    private var stageDurations: [String: Int] = [:]

    init(stage: String, now: Duration) {
        stageName = stage
        stageStartedAt = now
    }

    /// The stage currently being timed, if any.
    var currentStage: String? { stageName }

    mutating func advance(stage: String, now: Duration) {
        accumulateCurrentStage(now: now)
        stageName = stage
        stageStartedAt = now
    }

    /// Closes the audit and returns what was measured. A closed audit
    /// measures nothing more.
    mutating func finish(now: Duration) -> [String: Int] {
        accumulateCurrentStage(now: now)
        let result = stageDurations
        stageName = nil
        stageStartedAt = nil
        stageDurations = [:]
        return result
    }

    private mutating func accumulateCurrentStage(now: Duration) {
        guard let stage = stageName, let startedAt = stageStartedAt else { return }
        stageDurations[stage, default: 0] +=
            max(.zero, now - startedAt)
            .wholeMillisecondsClamped
    }
}

extension Duration {
    /// Whole milliseconds, saturating instead of trapping on absurd inputs.
    var wholeMillisecondsClamped: Int {
        let components = components
        return Int(
            clamping:
                components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }
}
