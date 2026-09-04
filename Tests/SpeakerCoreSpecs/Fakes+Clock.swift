import Foundation
import SpeakerCore
import SpeakerSpecSupport

/// A `VoiceInputClock` the specification advances by hand.
///
/// Sleepers resume only when the clock passes their deadline or, when the
/// clock honours cancellation, when their task is cancelled. A stubborn
/// clock ignores cancellation so a specification can resume a deadline the
/// session already abandoned and prove the stale wake-up is ignored.
final class ManualVoiceInputClock: VoiceInputClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let honoursCancellation: Bool
    private var now: Duration
    private var sleepers: [Int: Sleeper] = [:]
    private var requests: [Duration] = []
    private var cancelledCount = 0

    init(honoursCancellation: Bool = true, startingAt now: Duration = .zero) {
        self.honoursCancellation = honoursCancellation
        self.now = now
    }

    var monotonicNow: Duration {
        lock.withLock { now }
    }

    var date: Date {
        Date(timeIntervalSinceReferenceDate: monotonicNow.timeInterval)
    }

    /// Every duration requested so far, in arrival order, cancelled or not.
    var sleepRequests: [Duration] {
        lock.withLock { requests }
    }

    var sleepRequestCount: Int {
        lock.withLock { requests.count }
    }

    /// Sleepers still suspended.
    var pendingSleepCount: Int {
        lock.withLock { sleepers.count }
    }

    /// Sleepers ended by task cancellation.
    var cancelledSleepCount: Int {
        lock.withLock { cancelledCount }
    }

    func sleep(for duration: Duration) async throws {
        let requestID = lock.withLock {
            requests.append(duration)
            return requests.count - 1
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = lock.withLock {
                    if honoursCancellation, Task.isCancelled {
                        cancelledCount += 1
                        return true
                    }
                    sleepers[requestID] = Sleeper(
                        deadline: now + duration,
                        continuation: continuation
                    )
                    return false
                }
                if alreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            guard honoursCancellation else { return }
            let sleeper = lock.withLock {
                let sleeper = sleepers.removeValue(forKey: requestID)
                if sleeper != nil { cancelledCount += 1 }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and resumes every sleeper whose deadline has
    /// passed.
    func advance(by duration: Duration) {
        let due = lock.withLock {
            now += duration
            let due = sleepers.filter { $0.value.deadline <= now }
            for key in due.keys { sleepers.removeValue(forKey: key) }
            return due.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    /// Resumes one sleep request by its order of arrival whether or not its
    /// deadline has passed. Returns false when that request is not suspended.
    @discardableResult
    func resume(sleepRequest requestID: Int) -> Bool {
        let sleeper = lock.withLock { sleepers.removeValue(forKey: requestID) }
        sleeper?.continuation.resume()
        return sleeper != nil
    }

    func waitUntilSleepRequestCount(_ expected: Int) async {
        while sleepRequestCount < expected { await Task.yield() }
    }

    func waitUntilPendingSleepCount(_ expected: Int) async {
        while pendingSleepCount < expected { await Task.yield() }
    }

    func waitUntilCancelledSleepCount(_ expected: Int) async {
        while cancelledSleepCount < expected { await Task.yield() }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

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
