import Foundation
import SpeakerCore
import SpeakerSpecSupport

let specAudio = CapturedAudio(
    data: Data([0x52, 0x49, 0x46, 0x46]),
    duration: .seconds(1),
    peakPower: -10
)

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

actor CompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

struct FileProtectionFailure: Error {}

func usageRecord(
    startedAt: Date,
    text: String?,
    recordingMs: Int
) -> VoiceInputHistoryRecord {
    let id = VoiceInputSessionID(rawValue: UUID())
    return VoiceInputHistoryRecord(
        sessionID: id,
        startedAt: startedAt,
        applicationName: "Notes",
        transcription: text,
        finalText: text,
        stageDurationsMilliseconds: recordingMs > 0 ? ["recording": recordingMs] : [:],
        outcome: .delivered(id, applicationName: "Notes", text: text ?? "")
    )
}

extension VoiceInputActivity {
    var failure: VoiceInputFailure? {
        if case let .failed(_, failure) = self { failure } else { nil }
    }

    var isCancelled: Bool {
        if case .cancelled = self { true } else { false }
    }

    var isRecordingFailed: Bool {
        if case .failed(_, .recordingFailed) = self { true } else { false }
    }
}

func terminalPresentation(
    from stream: AsyncStream<VoiceInputPresentation>
) -> Task<VoiceInputPresentation?, Never> {
    Task {
        for await presentation in stream {
            if presentation.activity.isTerminal {
                return presentation
            }
        }
        return nil
    }
}

func firstTerminalPresentation(
    from stream: AsyncStream<VoiceInputPresentation>,
    before timeout: Duration
) async -> VoiceInputPresentation? {
    await withTaskGroup(of: VoiceInputPresentation?.self) { group in
        group.addTask {
            for await presentation in stream {
                if presentation.activity.isTerminal {
                    return presentation
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
