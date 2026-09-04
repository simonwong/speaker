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

        package static func settingsLoadFailed(
            _ failure: AppSettingsLoadFailure
        ) -> String {
            switch failure {
            case .protectionFailed:
                "无法保护设置文件权限，已停止加载本机设置。"
            case let .readFailed(detail):
                "无法安全读取设置文件，已停止加载：\(detail)"
            case let .preservationFailed(detail):
                "Settings could not be recovered: \(detail)"
            }
        }

        package static func credentialMigrationIncomplete(
            providers: [ProviderID]
        ) -> String? {
            guard !providers.isEmpty else { return nil }
            let names = providers.map(\.rawValue).joined(separator: "、")
            return "\(names) 的旧凭据尚未完成安全迁移；已保留可用的 Keychain 凭据，请在解锁 Mac 后重试。"
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

    /// Local history notices. The urgent sentence is shown from the menu bar
    /// after a session; the page sentences are shown on the History page.
    package enum History {
        package static func reason(_ reason: LocalHistoryFailureReason) -> String {
            switch reason {
            case .databaseUnavailable:
                "本地历史数据库不可用。"
            case let .detail(detail):
                detail
            }
        }

        package static func urgentNotice(
            _ notice: LocalHistoryPersistenceNotice
        ) -> String {
            switch notice {
            case let .privacyMigrationFailed(failure):
                "旧版会话历史的隐私清理失败：\(reason(failure))"
            case let .writeFailed(detail):
                "会话历史写入失败：\(detail)"
            case let .corruptedRecordsSkipped(count):
                "有 \(count) 条本地历史记录已损坏，其他记录仍可使用。"
            case .corruptedDataPreserved, .recoveryArchivePruneFailed:
                pageNotice(notice)
            }
        }

        package static func pageNotice(
            _ notice: LocalHistoryPersistenceNotice
        ) -> String {
            switch notice {
            case let .corruptedDataPreserved(_, detail):
                "已保留损坏的历史文件：\(detail)"
            case let .corruptedRecordsSkipped(count):
                "有 \(count) 条历史记录已损坏，已跳过；其他记录仍可使用。"
            case let .privacyMigrationFailed(failure):
                "旧版历史隐私清理未完成：\(reason(failure))"
            case let .writeFailed(detail):
                "历史写入失败：\(detail)"
            case let .recoveryArchivePruneFailed(detail):
                "旧的历史损坏备份未能清理：\(detail)"
            }
        }
    }

    /// One sentence per structured SpeakerCore failure. Errors SpeakerCore
    /// does not own (system errors) fall back to their own description.
    package enum Failure {
        package static func message(for error: any Error) -> String {
            switch error {
            case let error as ProviderCredentialStoreError:
                message(for: error)
            case let error as AppSettingsStoreError:
                message(for: error)
            case let error as PersonalDictionaryStoreError:
                message(for: error)
            case let error as PersonalDictionaryValidationError:
                message(for: error)
            case let error as TextRefinementModeValidationError:
                message(for: error)
            default:
                error.localizedDescription
            }
        }

        package static func message(for error: ProviderCredentialStoreError) -> String {
            switch error {
            case .emptyAPIKey:
                "API Key 不能为空。"
            case .apiKeyTooLarge:
                "API Key 超出本机凭据存储允许的大小。"
            case .accessDenied:
                "无法访问本机凭据存储。"
            case .interactionUnavailable:
                "本机凭据存储当前不可用，请解锁 Mac 后重试。"
            case .malformedStoredValue:
                "已保存的 API Key 无法读取，请删除后重新保存。"
            case .conflictingStoredValues:
                "检测到多个旧凭据来源保存了不同的 API Key，已停止自动迁移并保留原数据。"
            case .storageUnavailable:
                "保存 API Key 失败，请稍后重试。"
            }
        }

        package static func message(for error: AppSettingsStoreError) -> String {
            switch error {
            case let .writeFailed(reason):
                "无法保存 Speaker 设置：\(reason)"
            case let .sourceUnreadable(failure):
                "原设置文件无法安全读取，已保留原文件且拒绝覆盖："
                    + Startup.settingsLoadFailed(failure)
            }
        }

        package static func message(for error: PersonalDictionaryStoreError) -> String {
            switch error {
            case .readFailed:
                "无法读取本机个人词库。"
            case .writeFailed:
                "无法保存本机个人词库。"
            case .privacyProtectionFailed:
                "无法把个人词库限制为仅当前用户可读，已停止加载。"
            case .corruptionPreservationFailed:
                "个人词库文件已损坏且无法保留副本，已停止加载。"
            }
        }

        package static func message(for error: PersonalDictionaryValidationError) -> String {
            error.issues.first.map(message(for:)) ?? "个人词库无效。"
        }

        package static func message(for issue: PersonalDictionaryValidationIssue) -> String {
            switch issue {
            case .emptyWord:
                "词条不能为空。"
            case let .duplicateWord(word, _):
                "词条“\(word)”已存在。"
            }
        }

        package static func message(for error: TextRefinementModeValidationError) -> String {
            switch error {
            case .emptyCustomName:
                "规则名称不能为空。"
            case .customNameTooLong:
                "规则名称不能超过 \(TextRefinementMode.maximumCustomNameLength) 个字符。"
            case .emptyCustomPrompt:
                "整理规则不能为空。"
            case .customPromptTooLong:
                "整理规则不能超过 \(TextRefinementMode.maximumCustomPromptLength) 个字符。"
            }
        }
    }
}
