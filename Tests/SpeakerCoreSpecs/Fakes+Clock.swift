import Foundation
import SpeakerCore
import SpeakerSpecSupport

/// Suspends until the surrounding task is cancelled, then throws
/// `CancellationError`; it never returns normally. Fakes use it where a
/// request must stay in flight until the code under specification cancels
/// it. A case that awaits such a request bounds the wait with `finishes`
/// so a cancellation regression fails the case instead of hanging the run.
func suspendUntilCancelled() async throws {
    let gate = CancellationGate()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.park(continuation)
        }
    } onCancel: {
        gate.cancel()
    }
    throw CancellationError()
}

private final class CancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func park(_ continuation: CheckedContinuation<Void, Error>) {
        let resumeNow = lock.withLock {
            if cancelled { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume(throwing: CancellationError()) }
    }

    func cancel() {
        let parked = lock.withLock {
            cancelled = true
            defer { continuation = nil }
            return continuation
        }
        parked?.resume(throwing: CancellationError())
    }
}

/// Whether `task` finishes, by any outcome, before `timeout` elapses.
func finishes<Success: Sendable>(
    _ task: Task<Success, any Error>,
    before timeout: Duration
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = try? await task.value
            return true
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        return finished
    }
}

/// Lets already-scheduled tasks run before a case asserts that something
/// has NOT happened. It proves nothing about liveness: to assert that
/// something does happen, wait for it with `eventually` instead.
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

/// A gate a fake waits at until the case opens it. Opening is sticky, so a
/// waiter that arrives late passes straight through.
actor OneShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
