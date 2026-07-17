import Combine

package enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case speech
    case refinement
    case dictionary
    case permissions
    case about

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .general: "通用"
        case .speech: "语音识别"
        case .refinement: "文本整理"
        case .dictionary: "个人词库"
        case .permissions: "系统权限"
        case .about: "关于"
        }
    }

    package var subtitle: String {
        switch self {
        case .general: "快捷键、录音方式与启动选项"
        case .speech: "语音识别服务与连接状态"
        case .refinement: "按需要选择文字的整理程度"
        case .dictionary: "维护专有名词和常见口语别名"
        case .permissions: "检查麦克风与辅助功能授权"
        case .about: "版本、隐私、本地数据与问题诊断"
        }
    }

    package var icon: String {
        switch self {
        case .general: "switch.2"
        case .speech: "waveform"
        case .refinement: "text.alignleft"
        case .dictionary: "text.book.closed"
        case .permissions: "checkmark.shield"
        case .about: "info.circle"
        }
    }
}

@MainActor
package final class SettingsNavigationModel: ObservableObject {
    @Published package var page: SettingsPage

    package init(page: SettingsPage = .general) {
        self.page = page
    }

    package func open(_ page: SettingsPage) {
        self.page = page
    }
}
