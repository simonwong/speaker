import Foundation
import SpeakerCore

/// The one home for user-visible sentences more than one surface shows.
///
/// Wording that the settings page, the onboarding window and the runtime all
/// present lives here so the same fact can never reach the user in two
/// different sentences. Copy owned by a single surface stays with that view.
package enum SpeakerCopy {
    /// Doubao connection status wording. The settings page and the onboarding
    /// window read the same entries through `DoubaoStatusPresentation`.
    package enum DoubaoStatus {
        package static let loading = "正在读取本机配置"
        package static let unconfigured = "未配置"
        package static let configured = "已配置"
        package static let checking = "正在检查连接"
        package static let success = "连接成功"
    }

    /// The result of copying the diagnostic report. About and the runtime
    /// report the same sentence, including the promise about what the report
    /// never contains.
    package enum Diagnostics {
        package static let copied = "诊断信息已复制，不包含文字、音频或 API Key。"
        package static let copyFailed = "复制失败，请重试。"
    }

    /// Local-data erase failure explanations: one sentence per reason,
    /// whichever entry point reports the failure.
    package enum LocalDataErase {
        package static let incomplete = "本地数据未能全部清除，请重试。"

        package static func failureMessage(
            _ failure: SpeakerDataErasureFailure
        ) -> String {
            guard let issue = failure.issues.first else { return incomplete }
            return message(for: issue.reason)
        }

        package static func message(
            for reason: SpeakerDataErasureReason
        ) -> String {
            switch reason {
            case .accessDenied:
                "macOS 拒绝删除部分数据，请检查文件权限后重试。"
            case .interactionUnavailable:
                "无法访问凭据存储，请解锁 Mac 后重试。"
            case .busy:
                "本地历史仍在使用中，未删除数据库。请重试。"
            case .unsafePath:
                "待删除路径未通过安全校验，Speaker 已停止清除。"
            case .verificationMismatch:
                "清除结果未通过验证，Speaker 没有报告成功；请重试。"
            case .io:
                "部分本地数据无法删除，请关闭可能占用文件的程序后重试。"
            }
        }
    }

    /// Notices the startup sequence publishes about recovered or migrated
    /// local data. Wording lives here so the runtime only dispatches.
    package enum Startup {
        package static let historyPrivacyScrubIncomplete =
            "旧版会话历史的隐私清理未完成；Speaker 已保留明确错误供你处理。"
        package static let interruptedSessionsNotReconciled =
            "上次运行中断的会话历史未能完成恢复，请在“关于”中复制诊断信息。"
        package static let legacyDictionaryCleanupFailed =
            "个人词库已迁移，但旧版词库文件未能删除。"
        package static let legacyDictionaryMigrationFailed =
            "旧版个人词库未能迁移，原文件仍保留。"

        package static func settingsRecovered(backupName: String) -> String {
            "设置文件已恢复为默认值，原文件保留在 \(backupName)。"
        }

        package static func legacyDictionaryNotice(
            _ outcome: PersonalDictionaryMigrationOutcome
        ) -> String? {
            switch outcome {
            case .notNeeded, .primaryAlreadyExists, .migrated:
                nil
            case .migratedLegacyCleanupFailed:
                legacyDictionaryCleanupFailed
            case .failed:
                legacyDictionaryMigrationFailed
            }
        }

        package static func legacyHistoryNotice(
            _ outcome: LegacyHistoryMigrationOutcome
        ) -> String? {
            switch outcome {
            case .notNeeded, .migrated:
                nil
            case .migratedLegacyFileRemains:
                "会话历史已迁移，但旧版 history.json 未能删除。"
            case let .legacyCorrupted(backupName):
                "旧版历史文件损坏，已保留为 \(backupName)。"
            case .legacyProtectionFailed:
                "旧版会话历史的文件权限无法收紧，已停止迁移并保留原文件。"
            case .legacyNotReady:
                "旧版会话历史尚未满足安全迁移条件，原文件仍保留。"
            case .importRefused:
                "旧版会话历史尚未完成迁移，原文件仍保留。"
            }
        }
    }
}
