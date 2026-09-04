import Foundation

public struct VoiceInputSessionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package enum VoiceInputCommand: Sendable {
    case pressed
    case released
    case cancel
    case copyPendingResult
    case dismissResult
}

/// Content-free identity frozen inside the physical stop-gesture callback.
///
/// Full Accessibility inspection remains asynchronous, but it must resolve to
/// this exact process. Switching to another App after ending the recording
/// therefore fails closed instead of capturing the newer App.
public struct InputTargetCaptureHint: Equatable, Sendable {
    public let processID: Int32
    package let targetToken: UUID?

    public init(processID: Int32) {
        self.processID = processID
        targetToken = nil
    }

    package init(processID: Int32, targetToken: UUID) {
        self.processID = processID
        self.targetToken = targetToken
    }
}

public enum VoiceInputProcessingStage: Equatable, Sendable {
    case capturingTarget
    case transcribing
    case refining
    case delivering
}

public enum PendingCopyReason: String, Equatable, Sendable {
    case missingTarget
    case accessibilityPermissionMissing
    case secureTarget
    case unsupportedTarget
    case invalidatedTarget
    case changedTarget
    case deliveryFailed
    case targetApplicationUnresponsive
    /// Kept only so history written by older builds remains decodable.
    case deliveryTimedOut
    case deliveryUnconfirmed
    case clipboardFailed
}

public enum VoiceInputActivity: Equatable, Sendable {
    case idle
    case preparing(VoiceInputSessionID)
    case recording(VoiceInputSessionID)
    case processing(
        VoiceInputSessionID,
        VoiceInputProcessingStage,
        applicationName: String?
    )
    case delivered(
        VoiceInputSessionID,
        applicationName: String,
        text: String
    )
    case pendingCopy(
        VoiceInputSessionID,
        text: String,
        reason: PendingCopyReason
    )
    case cancelled(VoiceInputSessionID)
    case failed(VoiceInputSessionID, VoiceInputFailure)

    public var isRecording: Bool {
        if case .recording = self { true } else { false }
    }

    public var isDelivered: Bool {
        if case .delivered = self { true } else { false }
    }

    public var isTerminal: Bool {
        switch self {
        case .delivered, .pendingCopy, .cancelled, .failed:
            true
        case .idle, .preparing, .recording, .processing:
            false
        }
    }

    public var stage: VoiceInputProcessingStage? {
        if case let .processing(_, stage, _) = self { stage } else { nil }
    }

    public var pendingCopyReason: PendingCopyReason? {
        if case let .pendingCopy(_, _, reason) = self { reason } else { nil }
    }

    public var pendingText: String? {
        if case let .pendingCopy(_, text, _) = self { text } else { nil }
    }

    package var sessionID: VoiceInputSessionID? {
        switch self {
        case .idle:
            nil
        case let .preparing(id),
             let .recording(id),
             let .processing(id, _, _),
             let .delivered(id, _, _),
             let .pendingCopy(id, _, _),
             let .cancelled(id),
             let .failed(id, _):
            id
        }
    }
}

public enum VoiceInputNotice: Equatable, Sendable {
    case copied
    case refinementFellBack(DeepSeekRefinementFailureKind?)
    case persistenceFailure(String)
}

public struct VoiceInputPresentation: Equatable, Sendable {
    public let revision: UInt64
    public let activity: VoiceInputActivity
    public let recordingTelemetry: RecordingTelemetry?
    public let notice: VoiceInputNotice?

    public init(
        revision: UInt64,
        activity: VoiceInputActivity,
        recordingTelemetry: RecordingTelemetry? = nil,
        notice: VoiceInputNotice? = nil
    ) {
        self.revision = revision
        self.activity = activity
        self.recordingTelemetry = recordingTelemetry
        self.notice = notice
    }
}

public struct RecordingTelemetry: Equatable, Sendable {
    public let elapsedMilliseconds: Int
    public let peakPower: Float

    public init(elapsedMilliseconds: Int, peakPower: Float) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.peakPower = peakPower
    }
}

public struct CapturedAudio: Equatable, Sendable {
    public let data: Data
    public let duration: Duration
    public let peakPower: Float

    public init(data: Data, duration: Duration, peakPower: Float) {
        self.data = data
        self.duration = duration
        self.peakPower = peakPower
    }
}

public struct InputTargetSnapshot: Equatable, Hashable, Sendable {
    public let id: UUID
    public let applicationName: String

    public init(id: UUID, applicationName: String) {
        self.id = id
        self.applicationName = applicationName
    }
}

public enum InputTargetCaptureResult: Equatable, Sendable {
    case writable(InputTargetSnapshot)
    case unavailable(PendingCopyReason)
}

public struct TranscriptionResult: Equatable, Sendable {
    public let text: String
    public let providerRequestID: String?

    public init(text: String, providerRequestID: String?) {
        self.text = text
        self.providerRequestID = providerRequestID
    }
}

public struct DeliveryDiagnostic: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case securityRead
        case roleRead
        case fallbackEligibility
        case focusRead
        case fallbackSelection
        case valueRead
        case pastePost
        case pasteReceipt
    }

    public enum Cause: String, Equatable, Sendable {
        case invalidated
        case unsupported
        case unconfirmed
        case cancelled
        case invalidUIElement
        case attributeUnsupported
        case notImplemented
        case cannotComplete
        case other
        case notFrontmost
        case rejected
        case changed
    }

    public let stage: Stage
    public let cause: Cause

    public init(stage: Stage, cause: Cause) {
        self.stage = stage
        self.cause = cause
    }

    public var code: String {
        "\(stage.rawValue).\(cause.rawValue)"
    }
}

public enum DeliveryOutcome: Equatable, Sendable {
    case delivered
    case pasteCommandPosted(DeliveryDiagnostic)
    case pendingCopy(PendingCopyReason)
    case pendingCopyDiagnosed(
        PendingCopyReason,
        DeliveryDiagnostic
    )

    public var pendingCopyReason: PendingCopyReason? {
        switch self {
        case .delivered, .pasteCommandPosted: nil
        case let .pendingCopy(reason),
             let .pendingCopyDiagnosed(reason, _):
            reason
        }
    }

    public var deliveryDiagnostic: DeliveryDiagnostic? {
        switch self {
        case let .pasteCommandPosted(diagnostic),
             let .pendingCopyDiagnosed(_, diagnostic):
            diagnostic
        case .delivered, .pendingCopy:
            nil
        }
    }
}

public struct VoiceInputHistoryRecord: Equatable, Sendable {
    public let sessionID: VoiceInputSessionID
    public let startedAt: Date
    public let applicationName: String?
    public let transcription: String?
    public let finalText: String?
    public let transcriptionProvider: String?
    public let providerRequestID: String?
    public let providerErrorCode: String?
    public let providerOperation: String?
    public let providerStatusCode: String?
    public let providerMessage: String?
    public let deliveryDiagnosticCode: String?
    public let deepSeekText: String?
    public let deepSeekRequestID: String?
    public let refinementModeName: String?
    public let refinementPrompt: String?
    public let refinementStatus: String?
    public let refinementFailureCode: String?
    public let refinementFailureStatusCode: String?
    public let refinementFailureMessage: String?
    public let cancelledAtStage: String?
    public let dictionarySnapshotID: UUID?
    public let dictionarySnapshotEntries: [RecordedDictionaryEntry]
    public let dictionaryRequestContext: DictionaryRequestContext?
    public let dictionaryReplacements: [DictionaryReplacement]
    public let durationMilliseconds: Int
    public let stageDurationsMilliseconds: [String: Int]
    public let outcome: VoiceInputActivity

    public init(
        sessionID: VoiceInputSessionID,
        startedAt: Date,
        applicationName: String?,
        transcription: String?,
        finalText: String?,
        transcriptionProvider: String? = nil,
        providerRequestID: String? = nil,
        providerErrorCode: String? = nil,
        providerOperation: String? = nil,
        providerStatusCode: String? = nil,
        providerMessage: String? = nil,
        deliveryDiagnosticCode: String? = nil,
        deepSeekText: String? = nil,
        deepSeekRequestID: String? = nil,
        refinementModeName: String? = nil,
        refinementPrompt: String? = nil,
        refinementStatus: String? = nil,
        refinementFailureCode: String? = nil,
        refinementFailureStatusCode: String? = nil,
        refinementFailureMessage: String? = nil,
        cancelledAtStage: String? = nil,
        dictionarySnapshotID: UUID? = nil,
        dictionarySnapshotEntries: [RecordedDictionaryEntry] = [],
        dictionaryRequestContext: DictionaryRequestContext? = nil,
        dictionaryReplacements: [DictionaryReplacement] = [],
        durationMilliseconds: Int = 0,
        stageDurationsMilliseconds: [String: Int] = [:],
        outcome: VoiceInputActivity
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.applicationName = applicationName
        self.transcription = transcription
        self.finalText = finalText
        self.transcriptionProvider = transcriptionProvider
        self.providerRequestID = providerRequestID
        self.providerErrorCode = providerErrorCode
        self.providerOperation = providerOperation
        self.providerStatusCode = providerStatusCode
        self.providerMessage = providerMessage
        self.deliveryDiagnosticCode = deliveryDiagnosticCode
        self.deepSeekText = deepSeekText
        self.deepSeekRequestID = deepSeekRequestID
        self.refinementModeName = refinementModeName
        self.refinementPrompt = refinementPrompt
        self.refinementStatus = refinementStatus
        self.refinementFailureCode = refinementFailureCode
        self.refinementFailureStatusCode = refinementFailureStatusCode
        self.refinementFailureMessage = refinementFailureMessage
        self.cancelledAtStage = cancelledAtStage
        self.dictionarySnapshotID = dictionarySnapshotID
        self.dictionarySnapshotEntries = dictionarySnapshotEntries
        self.dictionaryRequestContext = dictionaryRequestContext
        self.dictionaryReplacements = dictionaryReplacements
        self.durationMilliseconds = durationMilliseconds
        self.stageDurationsMilliseconds = stageDurationsMilliseconds
        self.outcome = outcome
    }
}

extension InputTargetCaptureResult {
    var applicationName: String? {
        if case let .writable(snapshot) = self {
            snapshot.applicationName
        } else {
            nil
        }
    }
}
