import Foundation
import SpeakerCore
import SpeakerSpecSupport

actor SessionHistoryFake: SessionHistoryRecording {
    private(set) var records: [VoiceInputHistoryRecord] = []
    let failureNotice: String?

    init(failureNotice: String? = nil) {
        self.failureNotice = failureNotice
    }

    func save(_ record: VoiceInputHistoryRecord) async {
        if let index = records.firstIndex(where: { $0.sessionID == record.sessionID }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    func persistenceFailureNotice() async -> String? { failureNotice }
}

actor BlockingSessionHistoryFake: SessionHistoryRecording {
    private(set) var saveCallCount = 0
    private(set) var records: [VoiceInputHistoryRecord] = []
    private var isBlocked = true
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func save(_ record: VoiceInputHistoryRecord) async {
        saveCallCount += 1
        if isBlocked {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        if let index = records.firstIndex(where: { $0.sessionID == record.sessionID }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    func unblock() {
        isBlocked = false
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
