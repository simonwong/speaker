import Foundation
import SpeakerCore
import SpeakerSpecSupport

/// A `VoiceInputClock` the specification advances by hand.
///
/// Sleepers resume only when the clock passes their deadline or, when the
/// clock honours cancellation, when their task is cancelled. A stubborn
/// clock ignores cancellation so a specification can resume a deadline the
/// session already abandoned and prove the stale wake-up is ignored.
///
/// Session deadlines and the HUD and History timers sleep on an injected
/// `VoiceInputClock`, so a case drives them with `advance(by:)` instead of
/// waiting for real time to pass.
public final class ManualVoiceInputClock: VoiceInputClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let honoursCancellation: Bool
    private var now: Duration
    private var sleepers: [UUID: Sleeper] = [:]
    private var requests: [(id: UUID, duration: Duration)] = []
    private var cancelledCount = 0

    public init(honoursCancellation: Bool = true, startingAt now: Duration = .zero) {
        self.honoursCancellation = honoursCancellation
        self.now = now
    }

    public var monotonicNow: Duration {
        lock.withLock { now }
    }

    public var date: Date {
        Date(timeIntervalSinceReferenceDate: monotonicNow.timeInterval)
    }

    /// Every duration requested so far, in arrival order, cancelled or not.
    public var sleepRequests: [Duration] {
        lock.withLock { requests.map(\.duration) }
    }

    public var sleepRequestCount: Int {
        lock.withLock { requests.count }
    }

    /// Sleepers still suspended.
    public var pendingSleepCount: Int {
        lock.withLock { sleepers.count }
    }

    /// Sleepers ended by task cancellation.
    public var cancelledSleepCount: Int {
        lock.withLock { cancelledCount }
    }

    public func sleep(for duration: Duration) async throws {
        let requestID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = lock.withLock {
                    requests.append((id: requestID, duration: duration))
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
    public func advance(by duration: Duration) {
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
    public func resume(sleepRequest requestIndex: Int) -> Bool {
        let sleeper: Sleeper? = lock.withLock {
            guard requests.indices.contains(requestIndex) else { return nil }
            return sleepers.removeValue(forKey: requests[requestIndex].id)
        }
        sleeper?.continuation.resume()
        return sleeper != nil
    }

    public func waitUntilSleepRequestCount(
        _ expected: Int,
        before timeout: Duration = .seconds(2)
    ) async throws {
        let ready = await eventually(before: timeout) { self.sleepRequestCount >= expected }
        try expect(
            ready, "expected \(expected) registered clock sleeps, observed \(sleepRequestCount)")
    }

    public func waitUntilPendingSleepCount(
        _ expected: Int,
        before timeout: Duration = .seconds(2)
    ) async throws {
        let ready = await eventually(before: timeout) { self.pendingSleepCount >= expected }
        try expect(
            ready, "expected \(expected) pending clock sleeps, observed \(pendingSleepCount)")
    }

    public func waitUntilCancelledSleepCount(
        _ expected: Int,
        before timeout: Duration = .seconds(2)
    ) async throws {
        let ready = await eventually(before: timeout) { self.cancelledSleepCount >= expected }
        try expect(
            ready, "expected \(expected) cancelled clock sleeps, observed \(cancelledSleepCount)")
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
