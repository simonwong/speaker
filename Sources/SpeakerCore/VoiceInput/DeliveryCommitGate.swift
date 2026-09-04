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
