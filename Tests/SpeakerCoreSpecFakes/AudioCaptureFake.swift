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

    public init(delaysStart: Bool = false) {
        self.delaysStart = delaysStart
    }

    public func start() async throws {
        startCount += 1
        if delaysStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        isActive = true
    }

    public func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    public func stop() async throws -> CapturedAudio {
        stopCount += 1
        isActive = false
        return CapturedAudio(
            data: Data([0x52, 0x49, 0x46, 0x46]),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    public func cancel() async {
        cancelCount += 1
        isActive = false
    }
}
