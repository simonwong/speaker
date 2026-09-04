import Foundation

/// The clock a Voice Input Session reads.
///
/// Stage durations and the recording limit use the monotonic reading so a
/// wall-clock adjustment never shortens or extends a session. Record
/// timestamps use the wall clock. Production injects the continuous clock; a
/// specification injects a clock it advances by hand.
public protocol VoiceInputClock: Sendable {
    /// Monotonic time since an origin the clock chooses.
    var monotonicNow: Duration { get }
    /// The wall-clock time stored in Session Records.
    var date: Date { get }
    /// Suspends until `duration` passes on the monotonic clock. Throws
    /// `CancellationError` when the task is cancelled first.
    func sleep(for duration: Duration) async throws
}

/// The production clock: `ContinuousClock` for durations and `Date` for
/// timestamps.
package struct ContinuousVoiceInputClock: VoiceInputClock {
    private let origin = ContinuousClock.now

    package init() {}

    package var monotonicNow: Duration { origin.duration(to: .now) }

    package var date: Date { Date() }

    package func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
