import Foundation

/// Turns Doubao error frames and failed handshakes into `DoubaoASRFailure`.
///
/// Structured signals decide first: the error code carried in an error frame
/// or in the `X-Api-Status-Code` header, then the HTTP status of a rejected
/// handshake. Message wording only breaks ties when no code is known, so a
/// provider changing its prompt language never changes the reason the user
/// is shown.
package enum DoubaoFailureClassifier {
    private enum CodeClassification {
        case known(DoubaoASRFailureKind)
        /// Doubao reports rejected credentials, inactive resources, and plain
        /// parameter mistakes under one shared code; only the message tells
        /// them apart.
        case sharedParameterError
        case unknown
    }

    /// Classifies an error frame received on an open socket.
    package static func providerFailure(
        code: UInt32?,
        message: String?,
        providerRequestID: String?
    ) -> DoubaoASRFailure {
        let codeString = code.map(String.init)
        return DoubaoASRFailure(
            kind: kind(
                forCode: codeString,
                httpStatusCode: nil,
                message: message,
                default: .invalidResponse
            ),
            providerStatusCode: codeString,
            providerRequestID: providerRequestID,
            message: message
        )
    }

    /// Classifies a transport error using whatever the handshake exposed.
    package static func transportFailure(
        _ error: Error,
        metadata: DoubaoWebSocketMetadata,
        fallbackRequestID: String
    ) -> DoubaoASRFailure {
        DoubaoASRFailure(
            kind: kind(
                forCode: metadata.providerStatusCode,
                httpStatusCode: metadata.httpStatusCode,
                message: metadata.providerMessage,
                default: .network
            ),
            providerStatusCode: metadata.providerStatusCode
                ?? transportStatusCode(error, metadata: metadata),
            providerRequestID: metadata.providerRequestID ?? fallbackRequestID,
            message: metadata.providerMessage ?? PrivacySafeText.networkMessage(for: error)
        )
    }

    /// Extracts the human-readable message from an error frame payload.
    package static func errorMessage(from payload: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            return (object["message"] ?? object["error"] ?? object["msg"]).map {
                String(describing: $0)
            }
        }
        return String(data: payload, encoding: .utf8)
    }

    private static func kind(
        forCode code: String?,
        httpStatusCode: Int?,
        message: String?,
        default fallback: DoubaoASRFailureKind
    ) -> DoubaoASRFailureKind {
        switch classify(code: code) {
        case let .known(kind):
            return kind
        case .sharedParameterError:
            return messageFallback(message, default: .invalidRequest)
        case .unknown:
            if let httpStatusCode, let kind = kind(forHTTPStatus: httpStatusCode) {
                return kind
            }
            return messageFallback(message, default: fallback)
        }
    }

    private static func classify(code: String?) -> CodeClassification {
        switch code {
        case nil: .unknown
        case "20000003": .known(.silence)
        case "45000001": .sharedParameterError
        case "45000002": .known(.emptyAudio)
        case "45000081": .known(.serviceUnavailable)
        case "45000151": .known(.invalidAudioFormat)
        case "55000031": .known(.serverBusy)
        case let code? where code.hasPrefix("550"): .known(.serviceUnavailable)
        default: .unknown
        }
    }

    private static func kind(forHTTPStatus status: Int) -> DoubaoASRFailureKind? {
        switch status {
        case 401, 403: .invalidCredential
        case 429: .rateLimited
        case 500...599: .serviceUnavailable
        default: nil
        }
    }

    /// Last resort when no structured code classified the failure.
    private static func messageFallback(
        _ message: String?,
        default fallback: DoubaoASRFailureKind
    ) -> DoubaoASRFailureKind {
        let normalized = message?.lowercased() ?? ""
        if messageLooksLikeResourceFailure(normalized) {
            return .resourceNotActivated
        }
        if messageLooksLikeCredentialFailure(normalized) {
            return .invalidCredential
        }
        if messageLooksLikeRateLimit(normalized) {
            return .rateLimited
        }
        return fallback
    }

    private static func transportStatusCode(
        _ error: Error,
        metadata: DoubaoWebSocketMetadata
    ) -> String? {
        if let status = metadata.httpStatusCode {
            return String(status)
        }
        if let closeCode = metadata.webSocketCloseCode {
            return "websocket.close.\(closeCode)"
        }
        guard let urlError = error as? URLError else { return nil }
        return switch urlError.code {
        case .cancelled: "url.cancelled"
        case .timedOut: "url.timedOut"
        case .cannotFindHost: "url.cannotFindHost"
        case .cannotConnectToHost: "url.cannotConnectToHost"
        case .dnsLookupFailed: "url.dnsLookupFailed"
        case .networkConnectionLost: "url.networkConnectionLost"
        case .notConnectedToInternet: "url.notConnectedToInternet"
        case .secureConnectionFailed: "url.secureConnectionFailed"
        case .serverCertificateHasBadDate:
            "url.serverCertificateHasBadDate"
        case .serverCertificateUntrusted:
            "url.serverCertificateUntrusted"
        case .serverCertificateHasUnknownRoot:
            "url.serverCertificateHasUnknownRoot"
        case .serverCertificateNotYetValid:
            "url.serverCertificateNotYetValid"
        case .clientCertificateRejected:
            "url.clientCertificateRejected"
        case .clientCertificateRequired:
            "url.clientCertificateRequired"
        default: "url.\(urlError.code.rawValue)"
        }
    }

    // Provider contract: these substrings match Doubao's own error messages
    // when no structured code is available; they are never shown to the user.
    private static func messageLooksLikeCredentialFailure(_ message: String) -> Bool {
        message.contains("api key")
            || message.contains("apikey")
            || message.contains("access key")
            || message.contains("unauthorized")
            || message.contains("authentication")
            || message.contains("鉴权")
    }

    private static func messageLooksLikeResourceFailure(_ message: String) -> Bool {
        (message.contains("resource") && (message.contains("not") || message.contains("permission")))
            || message.contains("not activated")
            || message.contains("未开通")
            || message.contains("无权限")
    }

    private static func messageLooksLikeRateLimit(_ message: String) -> Bool {
        message.contains("rate limit")
            || message.contains("too many")
            || message.contains("qps")
            || message.contains("限流")
    }
}
