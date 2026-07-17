import Foundation
import SpeakerCore

/// Produces the only diagnostic text Speaker places on the clipboard.
///
/// The interface accepts product state and an optional history record, while
/// the implementation deliberately selects only structured, non-content
/// fields. Transcript text, prompts, dictionary entries, provider messages,
/// credentials and target application names never cross this seam.
package enum SpeakerDiagnosticReport {
    package struct Snapshot: Sendable {
        package let version: String
        package let build: String
        package let bundleIdentifier: String
        package let signingMode: String
        package let operatingSystem: String
        package let credentialStorage: String
        package let accessibility: PermissionState
        package let microphone: PermissionState
        package let shortcut: String
        package let activity: String
        package let refinement: String
        package let doubaoConfigured: Bool
        package let doubaoResource: String
        package let deepSeekConfigured: Bool
        package let deepSeekVerified: Bool
        package let historyRecordCount: Int
        package let historyPersistence: String
        package let activeProvider: VoiceProviderRuntimeSnapshot?
        package let latestRecord: VoiceInputHistoryRecord?

        package init(
            version: String,
            build: String,
            bundleIdentifier: String,
            signingMode: String,
            operatingSystem: String,
            credentialStorage: String,
            accessibility: PermissionState,
            microphone: PermissionState,
            shortcut: String,
            activity: String,
            refinement: String,
            doubaoConfigured: Bool,
            doubaoResource: String,
            deepSeekConfigured: Bool,
            deepSeekVerified: Bool,
            historyRecordCount: Int,
            historyPersistence: String,
            activeProvider: VoiceProviderRuntimeSnapshot? = nil,
            latestRecord: VoiceInputHistoryRecord?
        ) {
            self.version = version
            self.build = build
            self.bundleIdentifier = bundleIdentifier
            self.signingMode = signingMode
            self.operatingSystem = operatingSystem
            self.credentialStorage = credentialStorage
            self.accessibility = accessibility
            self.microphone = microphone
            self.shortcut = shortcut
            self.activity = activity
            self.refinement = refinement
            self.doubaoConfigured = doubaoConfigured
            self.doubaoResource = doubaoResource
            self.deepSeekConfigured = deepSeekConfigured
            self.deepSeekVerified = deepSeekVerified
            self.historyRecordCount = historyRecordCount
            self.historyPersistence = historyPersistence
            self.activeProvider = activeProvider
            self.latestRecord = latestRecord
        }
    }

    package static func make(from snapshot: Snapshot) -> String {
        var lines = [
            "Speaker diagnostics",
            "version: \(clean(snapshot.version)) (\(clean(snapshot.build)))",
            "bundle: \(clean(snapshot.bundleIdentifier))",
            "signingMode: \(clean(snapshot.signingMode))",
            "macOS: \(clean(snapshot.operatingSystem))",
            "credentialStorage: \(clean(snapshot.credentialStorage))",
            "accessibility: \(snapshot.accessibility)",
            "microphone: \(snapshot.microphone)",
            "shortcut: \(clean(snapshot.shortcut))",
            "activity: \(clean(snapshot.activity))",
            "refinement: \(clean(snapshot.refinement))",
            "doubaoConfigured: \(snapshot.doubaoConfigured)",
            "doubaoResource: \(clean(snapshot.doubaoResource))",
            "deepSeekConfigured: \(snapshot.deepSeekConfigured)",
            "deepSeekVerified: \(snapshot.deepSeekVerified)",
            "historyRecords: \(max(0, snapshot.historyRecordCount))",
            "historyPersistence: \(clean(snapshot.historyPersistence))",
        ]

        if let active = snapshot.activeProvider {
            lines.append(
                "activeProvider: \(clean(active.provider))"
            )
            lines.append(
                "activeProviderOperation: \(active.operation.rawValue)"
            )
            lines.append(
                "activeProviderPhase: \(active.phase.rawValue)"
            )
            lines.append(
                "activeProviderRequestID: \(clean(active.requestID))"
            )
            append(
                "activeProviderServerRequestID",
                value: active.providerRequestID,
                to: &lines
            )
            if let status = active.httpStatusCode {
                lines.append("activeProviderHTTPStatus: \(status)")
            }
        }

        if let record = snapshot.latestRecord {
            lines.append("latestSessionOutcome: \(outcomeCode(record.outcome))")
            lines.append(
                "latestSessionDurationMs: \(max(0, record.durationMilliseconds))"
            )
            append(
                "latestSessionStages",
                value: stageDurations(record.stageDurationsMilliseconds),
                to: &lines
            )
            append(
                "latestProvider",
                value: record.transcriptionProvider,
                to: &lines
            )
            append(
                "latestProviderOperation",
                value: record.providerOperation,
                to: &lines
            )
            append(
                "latestProviderRequestID",
                value: record.providerRequestID,
                to: &lines
            )
            append(
                "latestProviderCode",
                value: record.providerErrorCode,
                to: &lines
            )
            append(
                "latestProviderStatus",
                value: record.providerStatusCode,
                to: &lines
            )
            append(
                "latestDeliveryDiagnostic",
                value: record.deliveryDiagnosticCode,
                to: &lines
            )
            append(
                "latestDeepSeekRequestID",
                value: record.deepSeekRequestID,
                to: &lines
            )
            append(
                "latestDeepSeekCode",
                value: record.refinementFailureCode,
                to: &lines
            )
            append(
                "latestDeepSeekStatus",
                value: record.refinementFailureStatusCode,
                to: &lines
            )
            append(
                "latestCancelledAtStage",
                value: record.cancelledAtStage,
                to: &lines
            )
        }

        return lines.joined(separator: "\n")
    }

    private static func append(
        _ key: String,
        value: String?,
        to lines: inout [String]
    ) {
        guard let value = cleanOptional(value) else { return }
        lines.append("\(key): \(value)")
    }

    private static func stageDurations(
        _ durations: [String: Int]
    ) -> String? {
        guard !durations.isEmpty else { return nil }
        return durations
            .map { (clean($0.key), max(0, $0.value)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: ",")
    }

    private static func outcomeCode(
        _ outcome: VoiceInputActivity
    ) -> String {
        switch outcome {
        case .idle: "idle"
        case .preparing: "preparing"
        case .recording: "recording"
        case let .processing(_, stage, _): "processing.\(stage)"
        case .delivered: "delivered"
        case let .pendingCopy(_, _, reason): "pendingCopy.\(reason.rawValue)"
        case .cancelled: "cancelled"
        case let .failed(_, failure): "failed.\(failure.rawValue)"
        }
    }

    private static func clean(_ value: String) -> String {
        cleanOptional(value) ?? "unknown"
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar)
                ? " "
                : String(scalar)
        }.joined()
        let collapsed = sanitized
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(300))
    }
}
