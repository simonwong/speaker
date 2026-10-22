import Foundation
import SpeakerCore

/// The one source of trigger sequences for specifications. Like
/// `VoiceInputTriggerDispatcher`, every edge takes the next number, so an
/// Escape always fences against the press that came before it.
private final class SpecTriggerSequence: @unchecked Sendable {
    static let shared = SpecTriggerSequence()

    private let lock = NSLock()
    private var last: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            last &+= 1
            return last
        }
    }
}

/// Shortcut edges for specifications that do not need the gesture state
/// machine. Each one crosses the same `VoiceInputSessions` entry point the
/// dispatcher calls in production.
extension VoiceInputSessions {
    /// A recording press, as the dispatcher delivers it.
    package nonisolated func dispatchPress(audioStart: AudioCaptureStart? = nil) async {
        await press(triggerSequence: SpecTriggerSequence.shared.next(), audioStart: audioStart)
    }

    /// Ends recording, as the dispatcher delivers it: the call returns once
    /// the session has accepted the release, not when processing finishes.
    package nonisolated func dispatchRelease(captureHint: InputTargetCaptureHint? = nil) async {
        await releaseFromDispatcher(captureHint: captureHint)
    }

    /// Escape, as the dispatcher delivers it: cancels an unfinished session or
    /// dismisses a retained result.
    package nonisolated func dispatchEscape() async {
        await handleEscape(triggeredAtSequence: SpecTriggerSequence.shared.next())
    }

    /// Releases and then waits for the published presentation that ends the
    /// session that was recording or processing at the release. A release
    /// while the recorder is still starting is only remembered by the session,
    /// so this returns at once and the press completes the session instead.
    @discardableResult
    package nonisolated func releaseAndAwaitTerminal(
        captureHint: InputTargetCaptureHint? = nil
    ) async -> VoiceInputPresentation? {
        var presentations = await observe().makeAsyncIterator()
        let current = await presentations.next()
        await releaseFromDispatcher(captureHint: captureHint)
        guard let current else { return nil }
        let id: VoiceInputSessionID
        switch current.activity {
        case .recording(let sessionID), .processing(let sessionID, _):
            id = sessionID
        default:
            return current
        }
        var latest = current
        while latest.activity.sessionID == id, !latest.activity.isTerminal {
            guard let next = await presentations.next() else { return nil }
            latest = next
        }
        return latest
    }
}
