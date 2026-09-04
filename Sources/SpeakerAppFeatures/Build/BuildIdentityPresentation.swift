import Foundation

package struct SpeakerBuildIdentity: Equatable, Sendable {
    package let version: String
    package let build: String
    package let sourceRevision: String

    package init(
        version: String?,
        build: String?,
        sourceRevision: String?
    ) {
        self.version = Self.displayValue(version)
        self.build = Self.displayValue(build)
        self.sourceRevision = Self.displayValue(sourceRevision)
    }

    package static var current: SpeakerBuildIdentity {
        SpeakerBuildInfoReader.main.buildIdentity
    }

    package var displayText: String {
        "版本 \(version)（\(build)）· 源码 \(sourceRevision)"
    }

    private static func displayValue(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return "—" }
        return value
    }
}

/// The one reader of the build facts recorded in the running bundle.
///
/// Views ask this for the version line and the signing mode instead of
/// reaching into `Bundle.main` themselves, and a specification injects its own
/// info values without a bundle.
package struct SpeakerBuildInfoReader: Sendable {
    private let infoValue: @Sendable (String) -> String?

    package init(infoValue: @escaping @Sendable (String) -> String?) {
        self.infoValue = infoValue
    }

    /// Reads the bundle the app is running from.
    package static let main = SpeakerBuildInfoReader { key in
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    package var buildIdentity: SpeakerBuildIdentity {
        SpeakerBuildIdentity(
            version: infoValue("CFBundleShortVersionString"),
            build: infoValue("CFBundleVersion"),
            sourceRevision: infoValue("SpeakerSourceRevision")
        )
    }

    package var signingMode: SpeakerSigningMode {
        SpeakerSigningMode(infoValue: infoValue("SpeakerSigningMode"))
    }
}

package enum SpeakerSigningMode: Equatable, Sendable {
    case developmentAdHoc
    case developmentSigned
    case developerID
    case unknown

    package init(infoValue: String?) {
        switch infoValue {
        case "development-ad-hoc":
            self = .developmentAdHoc
        case "development-signed":
            self = .developmentSigned
        case "developer-id":
            self = .developerID
        default:
            self = .unknown
        }
    }

    package var diagnosticValue: String {
        switch self {
        case .developmentAdHoc:
            "development-ad-hoc"
        case .developmentSigned:
            "development-signed"
        case .developerID:
            "developer-id"
        case .unknown:
            "unknown"
        }
    }

    package var displayName: String {
        switch self {
        case .developmentAdHoc:
            "本机开发签名"
        case .developmentSigned:
            "本机具名签名"
        case .developerID:
            "正式发布签名"
        case .unknown:
            "未识别的签名"
        }
    }

    package var permissionIdentityIsStable: Bool {
        switch self {
        case .developerID:
            true
        case .developmentAdHoc, .developmentSigned, .unknown:
            false
        }
    }

    package var permitsLocalDeliverySmoke: Bool {
        switch self {
        case .developmentAdHoc, .developmentSigned:
            true
        case .developerID, .unknown:
            false
        }
    }

    package var permissionIdentityNotice: String? {
        switch self {
        case .developmentAdHoc:
            return """
            当前是本机开发签名。重新构建后，macOS 可能要求重新授予麦克风和辅助功能权限；\
            如果列表中已有 Speaker，请先移除旧项，再添加当前安装的 Speaker.app。
            """
        case .unknown:
            return "当前构建的签名身份无法确认，麦克风和辅助功能授权可能无法跨版本保持。"
        case .developmentSigned:
            return "本机开发构建只有持续使用同一个代码签名 identity，才能保持麦克风和辅助功能权限。"
        case .developerID:
            return nil
        }
    }
}

package struct DeliverySmokeLaunchRequest: Equatable, Sendable {
    package let processID: Int32?
    package let reportURL: URL
    package let captureOnly: Bool
    package let usesFrontmostTarget: Bool
    package let exercisesVoiceSession: Bool
    package let triggerURL: URL?

    package init?(
        arguments: [String],
        signingMode: SpeakerSigningMode
    ) {
        guard signingMode.permitsLocalDeliverySmoke,
              let reportIndex = arguments.firstIndex(
                of: "--speaker-delivery-smoke-report"
              ), arguments.indices.contains(reportIndex + 1)
        else {
            return nil
        }
        let captureOnly = arguments.contains(
            "--speaker-delivery-smoke-capture-only"
        )
        let exercisesVoiceSession = arguments.contains(
            "--speaker-delivery-smoke-session"
        )
        let usesFrontmostTarget = captureOnly || arguments.contains(
            "--speaker-delivery-smoke-frontmost"
        )
        let processID: Int32?
        if usesFrontmostTarget {
            processID = nil
        } else {
            guard let processIndex = arguments.firstIndex(
                of: "--speaker-delivery-smoke-pid"
            ), arguments.indices.contains(processIndex + 1),
                  let parsedProcessID = Int32(arguments[processIndex + 1]),
                  parsedProcessID > 0
            else { return nil }
            processID = parsedProcessID
        }
        let reportURL = URL(
            fileURLWithPath: arguments[reportIndex + 1]
        ).standardizedFileURL
        let reportDirectory = reportURL.deletingLastPathComponent()
            .standardizedFileURL
        let temporaryRoot = reportDirectory.deletingLastPathComponent().path
        guard ["/private/tmp", "/tmp"].contains(temporaryRoot),
              reportDirectory.lastPathComponent.hasPrefix(
                  "speaker-delivery-smoke-"
              ),
              reportURL.lastPathComponent == "report.txt"
        else {
            return nil
        }
        let triggerURL = arguments.contains(
            "--speaker-delivery-smoke-trigger"
        ) ? reportDirectory.appendingPathComponent("trigger.txt") : nil
        self.processID = processID
        self.reportURL = reportURL
        self.captureOnly = captureOnly
        self.usesFrontmostTarget = usesFrontmostTarget
        self.exercisesVoiceSession = exercisesVoiceSession
        self.triggerURL = triggerURL
    }
}
