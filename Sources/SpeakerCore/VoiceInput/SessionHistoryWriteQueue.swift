import Foundation

/// The terminal activity a history write was queued for, so a persistence
/// failure can be attached to the presentation the user is still looking at.
struct TerminalHistoryPresentation: Sendable {
    let activity: VoiceInputActivity
    let notice: VoiceInputNotice?
}

/// Serializes history writes per session.
///
/// Each session has at most one in-flight write; a newer record for the same
/// session waits for the older one so records reach storage in the order they
/// were produced. Completion is token-fenced: a completion that arrives after a
/// newer write replaced it is ignored. The owner drives shutdown convergence
/// through `firstPending` and `discard(_:for:)` until the queue is empty.
struct SessionHistoryWriteQueue {
    typealias Completion = @Sendable (
        _ token: UUID,
        _ persistenceNotice: LocalHistoryPersistenceNotice?
    ) async -> Void

    private var tasks: [VoiceInputSessionID: Task<Void, Never>] = [:]
    private var tokens: [VoiceInputSessionID: UUID] = [:]

    var isEmpty: Bool { tasks.isEmpty }

    /// Any write that has not reported completion yet.
    var firstPending: (sessionID: VoiceInputSessionID, task: Task<Void, Never>)? {
        tasks.first.map { ($0.key, $0.value) }
    }

    /// Queues `record` behind the session's previous write and returns the new
    /// task. `completion` runs after the write, with the notice the store
    /// reports when `reportsPersistenceFailure` is set.
    @discardableResult
    mutating func enqueue(
        _ record: VoiceInputHistoryRecord,
        into history: any SessionHistoryRecording,
        reportsPersistenceFailure: Bool,
        completion: @escaping Completion
    ) -> Task<Void, Never> {
        let previous = tasks[record.sessionID]
        let token = UUID()
        tokens[record.sessionID] = token
        let task = Task {
            await previous?.value
            await history.save(record)
            let persistenceNotice = reportsPersistenceFailure
                ? await history.persistenceFailureNotice()
                : nil
            await completion(token, persistenceNotice)
        }
        tasks[record.sessionID] = task
        return task
    }

    /// Marks the write identified by `token` as finished. Returns false when a
    /// newer write for the session has already replaced it.
    mutating func complete(sessionID: VoiceInputSessionID, token: UUID) -> Bool {
        guard tokens[sessionID] == token else { return false }
        tasks[sessionID] = nil
        tokens[sessionID] = nil
        return true
    }

    /// Drops `task` if it is still the session's registered write. Used after
    /// awaiting a task whose completion could not report back.
    mutating func discard(_ task: Task<Void, Never>, for sessionID: VoiceInputSessionID) {
        guard tasks[sessionID] == task else { return }
        tasks[sessionID] = nil
        tokens[sessionID] = nil
    }
}
