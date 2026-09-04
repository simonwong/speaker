import Foundation
import SpeakerCore
import SpeakerSpecSupport

/// How Doubao error codes, handshake headers, and message wording become a
/// failure kind. Codes decide; wording only fills in when no code is known.
enum DoubaoFailureClassifierSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        run("a known Doubao error code classifies the same way in any language", failures: &failures) {
            let wordings = ["server busy", "服务器繁忙", "", "rate limit exceeded", "unauthorized api key"]
            for wording in wordings {
                let failure = DoubaoFailureClassifier.providerFailure(
                    code: 55_000_031,
                    message: wording,
                    providerRequestID: "req"
                )
                try expect(failure.kind == .serverBusy, "\"\(wording)\" changed 55000031 into \(failure.kind)")
                try expect(failure.providerStatusCode == "55000031")
                try expect(failure.providerRequestID == "req")
            }

            let table: [(UInt32, DoubaoASRFailureKind)] = [
                (20_000_003, .silence),
                (45_000_002, .emptyAudio),
                (45_000_081, .serviceUnavailable),
                (45_000_151, .invalidAudioFormat),
                (55_012_345, .serviceUnavailable),
            ]
            for (code, kind) in table {
                let failure = DoubaoFailureClassifier.providerFailure(
                    code: code,
                    message: "resource not activated",
                    providerRequestID: nil
                )
                try expect(failure.kind == kind, "\(code) with a resource message became \(failure.kind)")
            }
        }

        run("Doubao's shared parameter error code is split by its message", failures: &failures) {
            let cases: [(String, DoubaoASRFailureKind)] = [
                ("resource not activated", .resourceNotActivated),
                ("该资源未开通", .resourceNotActivated),
                ("invalid api key", .invalidCredential),
                ("鉴权失败", .invalidCredential),
                ("missing field uid", .invalidRequest),
            ]
            for (message, kind) in cases {
                let failure = DoubaoFailureClassifier.providerFailure(
                    code: 45_000_001,
                    message: message,
                    providerRequestID: nil
                )
                try expect(failure.kind == kind, "45000001 \"\(message)\" became \(failure.kind)")
            }
        }

        run("message wording decides only when Doubao sends no known code", failures: &failures) {
            let cases: [(UInt32?, String?, DoubaoASRFailureKind)] = [
                (nil, "限流", .rateLimited),
                (nil, "Too Many Requests", .rateLimited),
                (nil, "qps limit", .rateLimited),
                (nil, "Authentication failed", .invalidCredential),
                (nil, "no permission for resource", .resourceNotActivated),
                (nil, "something else", .invalidResponse),
                (nil, nil, .invalidResponse),
                (49_999_999, "access key rejected", .invalidCredential),
                (49_999_999, "unexplained", .invalidResponse),
            ]
            for (code, message, kind) in cases {
                let failure = DoubaoFailureClassifier.providerFailure(
                    code: code,
                    message: message,
                    providerRequestID: nil
                )
                try expect(
                    failure.kind == kind,
                    "\(String(describing: code)) \"\(message ?? "nil")\" became \(failure.kind)"
                )
            }
        }

        run("handshake status codes classify transport failures ahead of wording", failures: &failures) {
            let error = URLError(.badServerResponse)

            let headerCode = DoubaoFailureClassifier.transportFailure(
                error,
                metadata: .init(
                    httpStatusCode: 200,
                    providerRequestID: "log-1",
                    providerMessage: "rate limit",
                    providerStatusCode: "55000031"
                ),
                fallbackRequestID: "fallback"
            )
            try expect(headerCode.kind == .serverBusy, "X-Api-Status-Code lost to wording: \(headerCode.kind)")
            try expect(headerCode.providerStatusCode == "55000031")
            try expect(headerCode.providerRequestID == "log-1")
            try expect(headerCode.message == "rate limit")

            let statuses: [(Int, String, DoubaoASRFailureKind)] = [
                (401, "resource not activated", .invalidCredential),
                (403, "forbidden", .invalidCredential),
                (429, "slow down", .rateLimited),
                (503, "unauthorized", .serviceUnavailable),
            ]
            for (status, message, kind) in statuses {
                let failure = DoubaoFailureClassifier.transportFailure(
                    error,
                    metadata: .init(httpStatusCode: status, providerMessage: message),
                    fallbackRequestID: "fallback"
                )
                try expect(failure.kind == kind, "HTTP \(status) \"\(message)\" became \(failure.kind)")
                try expect(failure.providerStatusCode == String(status))
                try expect(failure.providerRequestID == "fallback")
            }

            let worded = DoubaoFailureClassifier.transportFailure(
                error,
                metadata: .init(httpStatusCode: 400, providerMessage: "资源未开通"),
                fallbackRequestID: "fallback"
            )
            try expect(worded.kind == .resourceNotActivated, "unclassified status ignored the wording")
        }

        run("Doubao transport failures without a handshake carry only structured network codes", failures: &failures) {
            let timedOut = DoubaoFailureClassifier.transportFailure(
                URLError(.timedOut),
                metadata: .init(),
                fallbackRequestID: "fallback"
            )
            try expect(timedOut.kind == .network)
            try expect(timedOut.providerStatusCode == "url.timedOut")
            try expect(timedOut.message == String(describing: URLError.Code.timedOut))

            let closed = DoubaoFailureClassifier.transportFailure(
                URLError(.networkConnectionLost),
                metadata: .init(webSocketCloseCode: 1006),
                fallbackRequestID: "fallback"
            )
            try expect(closed.providerStatusCode == "websocket.close.1006")

            struct LocalError: Error {}
            let opaque = DoubaoFailureClassifier.transportFailure(
                LocalError(),
                metadata: .init(),
                fallbackRequestID: "fallback"
            )
            try expect(opaque.kind == .network)
            try expect(opaque.providerStatusCode == nil && opaque.message == nil, "an opaque error leaked text")
        }

        run("Doubao error payload message is read from message, error, or msg", failures: &failures) {
            try expect(DoubaoFailureClassifier.errorMessage(from: Data(#"{"message":"a"}"#.utf8)) == "a")
            try expect(DoubaoFailureClassifier.errorMessage(from: Data(#"{"error":"b"}"#.utf8)) == "b")
            try expect(DoubaoFailureClassifier.errorMessage(from: Data(#"{"msg":"c"}"#.utf8)) == "c")
            try expect(DoubaoFailureClassifier.errorMessage(from: Data("plain text".utf8)) == "plain text")
            try expect(DoubaoFailureClassifier.errorMessage(from: Data(#"{"code":1}"#.utf8)) == nil)
        }
    }
}
