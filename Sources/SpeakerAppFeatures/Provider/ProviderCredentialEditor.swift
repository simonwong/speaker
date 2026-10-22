import Combine
import Foundation
import SpeakerCore

/// One credential namespace as Settings reaches it: whether a Key is stored,
/// and how to save or delete it. Speech recognition stores each namespace
/// under its own `ProviderID`; text refinement goes through its service so a
/// Custom Key stays bound to its base URL.
package struct ProviderCredentialNamespace: Sendable {
    package let hasKey: @Sendable () async throws -> Bool
    package let save: @Sendable (String) async throws -> Void
    package let delete: @Sendable () async throws -> Void

    package init(
        hasKey: @escaping @Sendable () async throws -> Bool,
        save: @escaping @Sendable (String) async throws -> Void,
        delete: @escaping @Sendable () async throws -> Void
    ) {
        self.hasKey = hasKey
        self.save = save
        self.delete = delete
    }

    /// The namespace stored directly under `id`. A blank stored value counts
    /// as no Key.
    package static func stored(
        in credentials: any ProviderCredentialStoring,
        for id: ProviderID
    ) -> Self {
        Self(
            hasKey: {
                try await credentials.apiKey(for: id)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            },
            save: { try await credentials.save(apiKey: $0, for: id) },
            delete: { try await credentials.deleteAPIKey(for: id) })
    }
}

/// The outcome of the last explicit connection check of the stored Key.
package enum ProviderConnectionCheckState: Equatable, Sendable {
    case unchecked
    case checking
    case verified(requestID: String?)
    case failed(String)
}

/// The Key editor every provider model in Settings shares: the unsaved
/// draft, whether the current namespace holds a Key, the one Key write
/// allowed at a time, and the last connection check.
///
/// It hides result ordering. A read, write, or check that finishes after
/// the namespace changed, the Key changed, or shutdown began is discarded;
/// a newer draft typed during a save survives it. Saving or deleting drops
/// any earlier verification. After `shutdown` nothing is read, written, or
/// checked, and `shutdown` returns only once the last write and check have
/// settled. Callers own their own preconditions (a valid profile, no other
/// mutation in progress) and what follows a successful write.
@MainActor
package final class ProviderCredentialEditor: ObservableObject {
    @Published package var draft = ""
    @Published package private(set) var hasStoredKey = false
    @Published package private(set) var isUpdating = false
    @Published package private(set) var connection: ProviderConnectionCheckState = .unchecked
    /// The last failed Key read, save, or delete, as the user sees it.
    @Published package private(set) var failure: String?

    private var namespace: ProviderCredentialNamespace?
    /// Bumped whenever the namespace or its stored Key changes, so a read or
    /// write that started earlier cannot report into the new state.
    private var keyGeneration: UInt64 = 0
    /// Bumped whenever a connection result would no longer describe the
    /// stored Key and the provider's current settings.
    private var checkGeneration: UInt64 = 0
    private var isShutdown = false
    private var activeOperations = 0
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var checkTask: Task<Void, Never>?
    private var cancelledChecks: [Task<Void, Never>] = []

    package init(namespace: ProviderCredentialNamespace? = nil) {
        self.namespace = namespace
    }

    /// Points the editor at another namespace, for example after a provider,
    /// region, or profile change. The draft, failure, and verification belong
    /// to the previous namespace and are dropped. `hasStoredKey` is the value
    /// the caller already read for the new namespace, or false until
    /// `refresh` reads it.
    package func retarget(
        to namespace: ProviderCredentialNamespace?,
        hasStoredKey: Bool = false
    ) {
        keyGeneration &+= 1
        invalidateConnection()
        self.namespace = namespace
        self.hasStoredKey = namespace != nil && hasStoredKey
        draft = ""
        failure = nil
    }

    /// Reads whether the namespace holds a Key. A verification survives while
    /// the Key is still there; a failed check and an earlier failure are
    /// cleared. A Key that cannot be read counts as absent.
    package func refresh() async {
        guard !isUpdating, !isShutdown, let namespace else { return }
        beginOperation()
        defer { finishOperation() }
        let token = keyGeneration
        do {
            let exists = try await namespace.hasKey()
            guard token == keyGeneration, !isShutdown else { return }
            hasStoredKey = exists
            failure = nil
            if !exists {
                invalidateConnection()
            } else if case .failed = connection {
                connection = .unchecked
            }
        } catch {
            guard token == keyGeneration, !isShutdown else { return }
            hasStoredKey = false
            invalidateConnection()
            failure = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// Saves the draft. Returns true only when the Key was stored and the
    /// result still applies, so the caller can follow up.
    @discardableResult
    package func save() async -> Bool {
        await write { namespace, draft in
            try await namespace.save(draft)
            return true
        }
    }

    /// Deletes the stored Key. Returns true only when it was deleted and the
    /// result still applies.
    @discardableResult
    package func delete() async -> Bool {
        await write { namespace, _ in
            try await namespace.delete()
            return false
        }
    }

    /// Starts an explicit check of the stored Key. A check already running is
    /// cancelled and allowed to finish before the new request is sent.
    package func checkConnection(
        _ probe: @escaping @Sendable () async throws -> String?,
        describeFailure: @escaping @MainActor (Error) -> String
    ) {
        guard !isUpdating, !isShutdown, hasStoredKey else { return }
        invalidateConnection()
        let token = checkGeneration
        let pending = cancelledChecks
        cancelledChecks = []
        connection = .checking
        checkTask = Task { @MainActor [weak self] in
            for task in pending { await task.value }
            guard !Task.isCancelled else { return }
            let result: Result<String?, Error>
            do {
                result = .success(try await probe())
            } catch {
                result = .failure(error)
            }
            guard let self, token == checkGeneration, !isShutdown, hasStoredKey,
                !Task.isCancelled
            else { return }
            checkTask = nil
            switch result {
            case .success(let requestID): connection = .verified(requestID: requestID)
            case .failure(let error): connection = .failed(describeFailure(error))
            }
        }
    }

    /// Drops the current verification, for example when the provider's
    /// resource or profile changes, and cancels a check in flight.
    package func invalidateConnection() {
        checkGeneration &+= 1
        if let checkTask {
            checkTask.cancel()
            cancelledChecks.append(checkTask)
        }
        checkTask = nil
        connection = .unchecked
    }

    package func discardDraft() { draft = "" }

    /// Refuses every later operation, clears the draft, and waits for the
    /// write and checks already in flight.
    package func shutdown() async {
        isShutdown = true
        keyGeneration &+= 1
        invalidateConnection()
        draft = ""
        let checks = cancelledChecks
        cancelledChecks = []
        for task in checks { await task.value }
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { shutdownWaiters.append($0) }
    }

    private func write(
        _ operation: (ProviderCredentialNamespace, String) async throws -> Bool
    ) async -> Bool {
        guard !isUpdating, !isShutdown, let namespace else { return false }
        beginOperation()
        defer { finishOperation() }
        isUpdating = true
        defer { isUpdating = false }
        let submitted = draft
        keyGeneration &+= 1
        let token = keyGeneration
        invalidateConnection()
        do {
            let stored = try await operation(namespace, submitted)
            guard token == keyGeneration, !isShutdown else { return false }
            if draft == submitted { draft = "" }
            hasStoredKey = stored
            failure = nil
            return true
        } catch {
            guard token == keyGeneration, !isShutdown else { return false }
            failure = SpeakerCopy.Failure.message(for: error)
            return false
        }
    }

    private func beginOperation() {
        activeOperations += 1
    }

    private func finishOperation() {
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
