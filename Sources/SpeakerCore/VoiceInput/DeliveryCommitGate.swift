import Foundation

public actor DeliveryCommitGate {
    private enum State: Equatable { case pending, committed, cancelled }
    private var state = State.pending

    public init() {}

    public func commit() -> Bool {
        guard state == .pending else { return state == .committed }
        state = .committed
        return true
    }

    /// Returns true only when cancellation wins before the mutation commit.
    public func cancel() -> Bool {
        guard state == .pending else { return false }
        state = .cancelled
        return true
    }
}

actor DeliveryResolution {
    private var outcome: DeliveryOutcome?
    private var continuation: CheckedContinuation<DeliveryOutcome, Never>?

    func wait() async -> DeliveryOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ outcome: DeliveryOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

/// Settles a session's text processing exactly once. The processing task and
/// the user's request to skip refinement race; the first result wins and the
/// later one is discarded.
actor TextProcessingResolution {
    private var result: Result<VoiceTextProcessingResult, any Error>?
    private var continuation: CheckedContinuation<VoiceTextProcessingResult, any Error>?

    func wait() async throws -> VoiceTextProcessingResult {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Returns true only for the result that settles processing.
    @discardableResult
    func resolve(_ result: Result<VoiceTextProcessingResult, any Error>) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
        return true
    }
}
