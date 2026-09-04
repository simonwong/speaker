import Foundation
import SpeakerCore

/// A Session Record store double that keeps every saved record in memory.
///
/// `failureNotice` is the persistence notice the store reports back to the caller, and
/// `failureNoticeDelay` holds that answer open so a case can prove the notice is projected
/// when it arrives rather than when the session ends.
public actor SessionHistoryFake: SessionHistoryRecording {
    public private(set) var records: [VoiceInputHistoryRecord] = []
    public let failureNotice: LocalHistoryPersistenceNotice?
    public let failureNoticeDelay: Duration?

    public init(
        failureNotice: LocalHistoryPersistenceNotice? = nil,
        failureNoticeDelay: Duration? = nil
    ) {
        self.failureNotice = failureNotice
        self.failureNoticeDelay = failureNoticeDelay
    }

    public func save(_ record: VoiceInputHistoryRecord) async {
        if let index = records.firstIndex(where: { $0.sessionID == record.sessionID }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    public func persistenceFailureNotice() async -> LocalHistoryPersistenceNotice? {
        if let failureNoticeDelay {
            try? await Task.sleep(for: failureNoticeDelay)
        }
        return failureNotice
    }
}
