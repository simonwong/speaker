import Foundation
import SpeakerCore

/// A recorder double that counts every lifecycle call of a Voice Input Session.
///
/// `delaysStart` suspends `start()` until `resumeStart()`, so a case can observe the window
/// between shortcut activation and an active recorder. Without it the recorder starts
/// immediately, which is what a case that only needs a working recorder wants.
public actor AudioCaptureFake: AudioCapturing {
    public let delaysStart: Bool
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var cancelCount = 0
    public private(set) var isActive = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var activeStartID: UUID?
    private var cancelledStartIDs: Set<UUID> = []
    private var activePreparedOperation: AudioCaptureStart?
    private let prepareOperation: (@Sendable () -> AudioCaptureStart)?

    public init(
        delaysStart: Bool = false,
        prepareStart: (@Sendable () -> AudioCaptureStart)? = nil
    ) {
        self.delaysStart = delaysStart
        prepareOperation = prepareStart
    }

    public nonisolated func prepareStart() -> AudioCaptureStart {
        let id = UUID()
        let operation = prepareOperation?()
        return AudioCaptureStart(
            start: { try await self.start(id: id, preparedOperation: operation) },
            cancel: { await self.cancel(id: id, preparedOperation: operation) }
        )
    }

    public func start() async throws {
        try await prepareStart().start()
    }

    private func start(id: UUID, preparedOperation: AudioCaptureStart?) async throws {
        guard !cancelledStartIDs.contains(id) else { throw CancellationError() }
        startCount += 1
        activeStartID = id
        activePreparedOperation = preparedOperation
        if delaysStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        guard activeStartID == id else { throw CancellationError() }
        try await preparedOperation?.start()
        guard activeStartID == id else { throw CancellationError() }
        isActive = true
    }

    public func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    public func stop() async throws -> CapturedAudio {
        stopCount += 1
        activeStartID = nil
        activePreparedOperation = nil
        isActive = false
        return CapturedAudio(
            data: Data([0x52, 0x49, 0x46, 0x46]),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    public func cancel() async {
        let operation = activePreparedOperation
        activeStartID = nil
        activePreparedOperation = nil
        cancelCount += 1
        isActive = false
        await operation?.cancel()
    }

    private func cancel(id: UUID, preparedOperation: AudioCaptureStart?) async {
        cancelledStartIDs.insert(id)
        guard activeStartID == id else {
            await preparedOperation?.cancel()
            return
        }
        await cancel()
    }
}
