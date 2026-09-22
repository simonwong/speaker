import Foundation

public actor AudioCaptureCompletionGate: Equatable {
    private enum State { case pending, accepted, rejected }
    private var state = State.pending
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    public init() {}

    public nonisolated static func == (
        lhs: AudioCaptureCompletionGate, rhs: AudioCaptureCompletionGate
    ) -> Bool {
        lhs === rhs
    }

    public func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                switch state {
                case .accepted: continuation.resume()
                case .rejected: continuation.resume(throwing: CancellationError())
                case .pending: waiters[id] = continuation
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func accept() {
        guard case .pending = state else { return }
        state = .accepted
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    public func reject() {
        guard case .pending = state else { return }
        state = .rejected
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
