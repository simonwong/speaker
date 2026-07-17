import Foundation

public enum VoiceInputFailure: String, Equatable, Sendable {
    case sessionInterrupted
    case recordingFailed
    case microphonePermissionDenied
    case transcriptionFailed
    case providerNotConfigured
    case providerAuthenticationFailed
    case providerCredentialUnavailable
    case noSpeechDetected
    case providerResourceUnavailable
    case providerRateLimited
    case providerUnavailable
    case networkUnavailable
    case audioSendBufferExhausted
    case recordingTooShort
    case localSilenceDetected
    case providerReceivedNoAudio
    case providerReturnedNoText
    case audioProcessingFailed
    case audioDeviceChanged
}

public enum VoiceProviderOperation: String, Equatable, Sendable {
    case credentialAccess
    case transcription
    case refinement
}

/// Facts reported by a provider or the operating system. This type deliberately
/// has no inferred root-cause field: an absent result remains a waiting state.
public struct VoiceProviderDiagnostic: Equatable, Sendable {
    public let provider: String
    public let operation: VoiceProviderOperation
    public let requestID: String?
    public let code: String?
    public let statusCode: String?
    public let message: String?

    public init(
        provider: String,
        operation: VoiceProviderOperation = .transcription,
        requestID: String? = nil,
        code: String? = nil,
        statusCode: String? = nil,
        message: String? = nil
    ) {
        self.provider = VoiceDiagnosticSanitizer.clean(provider, limit: 80) ?? "unknown"
        self.operation = operation
        self.requestID = VoiceDiagnosticSanitizer.clean(requestID, limit: 200)
        self.code = VoiceDiagnosticSanitizer.clean(code, limit: 200)
        self.statusCode = VoiceDiagnosticSanitizer.clean(statusCode, limit: 80)
        self.message = VoiceDiagnosticSanitizer.clean(message, limit: 1_000)
    }
}

package enum VoiceDiagnosticSanitizer {
    package static func clean(_ value: String?, limit: Int) -> String? {
        guard let value, limit > 0 else { return nil }
        let withoutControls = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = withoutControls
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(limit))
    }
}

/// The single boundary between low-level provider facts, terminal session state,
/// local history diagnostics, and user-facing wording.
public struct VoiceInputProblem: Error, Equatable, Sendable {
    public let failure: VoiceInputFailure
    public let diagnostic: VoiceProviderDiagnostic?

    public init(
        failure: VoiceInputFailure,
        diagnostic: VoiceProviderDiagnostic? = nil
    ) {
        self.failure = failure
        self.diagnostic = diagnostic
    }

    public init(doubaoFailure: DoubaoASRFailure) {
        failure = switch doubaoFailure.kind {
        case .invalidCredential: .providerAuthenticationFailed
        case .silence: .noSpeechDetected
        case .emptyAudio: .providerReceivedNoAudio
        case .emptyTranscript: .providerReturnedNoText
        case .resourceNotActivated: .providerResourceUnavailable
        case .rateLimited: .providerRateLimited
        case .network: .networkUnavailable
        case .serverBusy, .serviceUnavailable: .providerUnavailable
        case .cancelled, .invalidRequest, .invalidAudioFormat, .invalidResponse:
            .transcriptionFailed
        }
        diagnostic = VoiceProviderDiagnostic(
            provider: "doubao",
            operation: .transcription,
            requestID: doubaoFailure.providerRequestID,
            code: doubaoFailure.kind.rawValue,
            statusCode: doubaoFailure.providerStatusCode,
            message: doubaoFailure.message
        )
    }

    public init(doubaoCredentialFailure: ProviderCredentialStoreError) {
        failure = doubaoCredentialFailure == .emptyAPIKey
            ? .providerNotConfigured
            : .providerCredentialUnavailable
        diagnostic = VoiceProviderDiagnostic(
            provider: "doubao",
            operation: .credentialAccess,
            code: "credential.\(doubaoCredentialFailure.diagnosticCode)"
        )
    }

    public init(audioCaptureError: AudioCaptureError) {
        switch audioCaptureError {
        case .streamBufferExhausted:
            failure = .audioSendBufferExhausted
            diagnostic = VoiceProviderDiagnostic(
                provider: "local",
                operation: .transcription,
                code: "audio.stream_buffer_exhausted"
            )
        case .tooShort:
            failure = .recordingTooShort
            diagnostic = VoiceProviderDiagnostic(
                provider: "local",
                operation: .transcription,
                code: "audio.too_short"
            )
        case .silent:
            failure = .localSilenceDetected
            diagnostic = VoiceProviderDiagnostic(
                provider: "local",
                operation: .transcription,
                code: "audio.silent"
            )
        case .conversionFailed:
            failure = .audioProcessingFailed
            diagnostic = VoiceProviderDiagnostic(
                provider: "local",
                operation: .transcription,
                code: "audio.conversion_failed"
            )
        case .deviceConfigurationChanged:
            failure = .audioDeviceChanged
            diagnostic = VoiceProviderDiagnostic(
                provider: "local",
                operation: .transcription,
                code: "audio.device_configuration_changed"
            )
        case .microphonePermissionDenied:
            failure = .microphonePermissionDenied
            diagnostic = VoiceProviderDiagnostic(
                provider: "local",
                operation: .transcription,
                code: "audio.microphone_permission_denied"
            )
        case .alreadyRecording, .couldNotPrepare, .couldNotStart,
             .noActiveRecording:
            failure = .recordingFailed
            diagnostic = VoiceProviderDiagnostic(
                provider: "local",
                operation: .transcription,
                code: "audio.\(String(describing: audioCaptureError))"
            )
        }
    }

}

public extension DeepSeekRefinementFailure {
    var providerDiagnostic: VoiceProviderDiagnostic {
        VoiceProviderDiagnostic(
            provider: "deepseek",
            operation: .refinement,
            requestID: providerRequestID,
            code: kind.rawValue,
            statusCode: httpStatusCode.map(String.init),
            message: message
        )
    }
}
