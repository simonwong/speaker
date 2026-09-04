import Foundation
import SpeakerCore

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
    private var requestCount = 0

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

    /// Sleep requests made so far, cancelled or not.
    var sleepRequestCount: Int {
        lock.withLock { requestCount }
    }

    /// Sleepers still suspended.
    var pendingSleepCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(for duration: Duration) async throws {
        let requestID = lock.withLock {
            defer { requestCount += 1 }
            return requestCount
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = lock.withLock {
                    if honoursCancellation, Task.isCancelled { return true }
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
            let sleeper = lock.withLock { sleepers.removeValue(forKey: requestID) }
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

    /// Resumes one sleep request by its order of arrival, whether or not its
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
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// Suspends until the surrounding task is cancelled, then throws
/// `CancellationError`. Fakes use it where a request must stay in flight
/// until the code under specification cancels it; a case that awaits the
/// result must bound the wait so a cancellation regression fails the case
/// instead of hanging the run.
func suspendUntilCancelled() async throws -> Never {
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
