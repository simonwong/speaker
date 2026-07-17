import Foundation

public enum VoiceProviderRuntimeOperation: String, Equatable, Sendable {
    case voiceInput
    case connectionCheck
}

public enum VoiceProviderRuntimePhase: String, Equatable, Sendable {
    case connecting
    case connected
    case requestSent
    case streamingAudio
    case audioFinalized
    case awaitingFinal
}

public struct VoiceProviderRuntimeSnapshot: Equatable, Sendable {
    public let provider: String
    public let operation: VoiceProviderRuntimeOperation
    public let phase: VoiceProviderRuntimePhase
    public let requestID: String
    public let providerRequestID: String?
    public let httpStatusCode: Int?

    public init(
        provider: String,
        operation: VoiceProviderRuntimeOperation,
        phase: VoiceProviderRuntimePhase,
        requestID: String,
        providerRequestID: String? = nil,
        httpStatusCode: Int? = nil
    ) {
        self.provider = provider
        self.operation = operation
        self.phase = phase
        self.requestID = requestID
        self.providerRequestID = providerRequestID
        self.httpStatusCode = httpStatusCode
    }
}

/// Owns content-free diagnostics for provider requests that are still active.
///
/// A provider call has no application-level timeout. This state reports only
/// boundaries that Speaker or the transport has actually crossed, so a user
/// can distinguish "still sending audio" from "audio finalized; waiting for
/// final text" without guessing a root cause from elapsed time.
public actor VoiceProviderRuntimeDiagnostics {
    private struct Entry {
        var snapshot: VoiceProviderRuntimeSnapshot
        let sequence: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0

    public init() {}

    public func beginDoubao(
        requestID: String,
        operation: VoiceProviderRuntimeOperation
    ) {
        sequence &+= 1
        entries[requestID] = Entry(
            snapshot: VoiceProviderRuntimeSnapshot(
                provider: "doubao",
                operation: operation,
                phase: .connecting,
                requestID: requestID
            ),
            sequence: sequence
        )
    }

    public func updateDoubao(
        requestID: String,
        phase: VoiceProviderRuntimePhase,
        metadata: DoubaoWebSocketMetadata? = nil
    ) {
        guard var entry = entries[requestID] else { return }
        entry.snapshot = VoiceProviderRuntimeSnapshot(
            provider: "doubao",
            operation: entry.snapshot.operation,
            phase: phase,
            requestID: requestID,
            providerRequestID: metadata?.providerRequestID
                ?? entry.snapshot.providerRequestID,
            httpStatusCode: metadata?.httpStatusCode
                ?? entry.snapshot.httpStatusCode
        )
        entries[requestID] = entry
    }

    public func updateDoubaoMetadata(
        requestID: String,
        metadata: DoubaoWebSocketMetadata
    ) {
        guard var entry = entries[requestID] else { return }
        entry.snapshot = VoiceProviderRuntimeSnapshot(
            provider: "doubao",
            operation: entry.snapshot.operation,
            phase: entry.snapshot.phase,
            requestID: requestID,
            providerRequestID: metadata.providerRequestID
                ?? entry.snapshot.providerRequestID,
            httpStatusCode: metadata.httpStatusCode
                ?? entry.snapshot.httpStatusCode
        )
        entries[requestID] = entry
    }

    public func finishDoubao(requestID: String) {
        entries[requestID] = nil
    }

    public func activeSnapshot() -> VoiceProviderRuntimeSnapshot? {
        entries.values.max { lhs, rhs in
            let lhsPriority = lhs.snapshot.operation == .voiceInput ? 1 : 0
            let rhsPriority = rhs.snapshot.operation == .voiceInput ? 1 : 0
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.sequence < rhs.sequence
        }?.snapshot
    }
}
