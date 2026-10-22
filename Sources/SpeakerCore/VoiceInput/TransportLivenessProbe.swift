import AppKit
import Foundation
import Network
import os

/// Events after which an open connection may have vanished without its close
/// ever reaching Speaker: the Mac woke from sleep, or its network path
/// changed (Wi-Fi switch, VPN up or down, link lost or restored).
public protocol TransportLivenessSignals: Sendable {
    /// Yields once per event until the consumer stops iterating.
    func events() -> AsyncStream<Void>
}

/// The transport liveness probe for an open recognition WebSocket while a
/// Voice Input Session is Waiting For Result.
///
/// A probe is one WebSocket ping. Only the transport's answer decides: a ping
/// that fails means the connection is lost, and a ping still unanswered
/// decides nothing, so local elapsed time never becomes a failure. The
/// interval only schedules the next ping. A wake or network path change asks
/// for a ping at once; the event itself is never a failure. At most one ping
/// is in flight; requests that arrive meanwhile collapse into one follow-up.
public struct TransportLivenessProbe: Sendable {
    package static let defaultInterval: Duration = .seconds(15)

    private let interval: Duration
    private let clock: any VoiceInputClock
    private let signals: any TransportLivenessSignals

    package init(
        interval: Duration = defaultInterval,
        clock: any VoiceInputClock,
        signals: any TransportLivenessSignals
    ) {
        self.interval = interval
        self.clock = clock
        self.signals = signals
    }

    /// Pings on the continuous clock and on system wake and network path
    /// changes.
    public static var live: TransportLivenessProbe {
        TransportLivenessProbe(
            clock: ContinuousVoiceInputClock(), signals: SystemTransportLivenessSignals())
    }

    /// Probes until a ping fails, then throws that ping's error. It never
    /// returns normally; cancellation throws `CancellationError`.
    package func watch(_ ping: @escaping @Sendable () async throws -> Void) async throws {
        let (requests, request) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let interval = interval
        let clock = clock
        let signals = signals
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    try await clock.sleep(for: interval)
                    request.yield()
                }
            }
            group.addTask {
                for await _ in signals.events() { request.yield() }
            }
            group.addTask {
                for await _ in requests {
                    try Task.checkCancellation()
                    try await ping()
                }
            }
            while try await group.next() != nil {}
        }
        throw CancellationError()
    }
}

/// Wake notifications from `NSWorkspace` and path updates from
/// `NWPathMonitor`. The monitor's first update describes the path the
/// connection opened on, so only later updates count as changes.
public struct SystemTransportLivenessSignals: TransportLivenessSignals {
    public init() {}

    public func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observation = SystemTransportObservation(onEvent: { continuation.yield() })
            continuation.onTermination = { _ in observation.stop() }
        }
    }
}

/// `@unchecked` because the notification token is not `Sendable`; `lock`
/// guards it and the first-path flag.
private final class SystemTransportObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var sawInitialPath = false

    init(onEvent: @escaping @Sendable () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in onEvent() }
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            let isChange = lock.withLock {
                defer { sawInitialPath = true }
                return sawInitialPath
            }
            if isChange { onEvent() }
        }
        monitor.start(queue: DispatchQueue(label: "speaker.transport-liveness"))
    }

    func stop() {
        let observer = lock.withLock {
            defer { wakeObserver = nil }
            return wakeObserver
        }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        monitor.cancel()
    }
}

extension URLSessionWebSocketTask {
    /// Sends one ping and returns when its pong arrives. Throws the
    /// transport's error when the connection fails first. A pong that never
    /// arrives is not an error, so cancellation returns at once rather than
    /// waiting for an answer that may never be reported.
    func livenessPing() async throws {
        try Task.checkCancellation()
        let outcome = PingOutcome()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                outcome.install(continuation)
                sendPing { error in outcome.finish(error) }
            }
        } onCancel: {
            outcome.finish(CancellationError())
        }
    }
}

/// Resumes a ping's continuation exactly once, whichever of the pong
/// handler or cancellation arrives first.
private final class PingOutcome: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, Error>?
        var result: Result<Void, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let early = state.withLock { state -> Result<Void, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func finish(_ error: (any Error)?) {
        let pending = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard state.result == nil else { return nil }
            state.result = error.map { .failure($0) } ?? .success(())
            defer { state.continuation = nil }
            return state.continuation
        }
        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}
