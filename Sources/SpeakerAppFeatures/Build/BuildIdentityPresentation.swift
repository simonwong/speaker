import Foundation

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
    package let processID: Int32
    package let reportURL: URL

    package init?(
        arguments: [String],
        signingMode: SpeakerSigningMode
    ) {
        guard signingMode.permitsLocalDeliverySmoke,
              let processIndex = arguments.firstIndex(
                of: "--speaker-delivery-smoke-pid"
              ), arguments.indices.contains(processIndex + 1),
              let processID = Int32(arguments[processIndex + 1]),
              processID > 0,
              let reportIndex = arguments.firstIndex(
                of: "--speaker-delivery-smoke-report"
              ), arguments.indices.contains(reportIndex + 1)
        else {
            return nil
        }
        let reportURL = URL(
            fileURLWithPath: arguments[reportIndex + 1]
        ).standardizedFileURL
        let temporaryRoot = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).standardizedFileURL
        guard reportURL.deletingLastPathComponent().standardizedFileURL
                == temporaryRoot,
              reportURL.pathExtension == "txt"
        else {
            return nil
        }
        self.processID = processID
        self.reportURL = reportURL
    }
}
