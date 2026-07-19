import Combine

package enum SettingsPage: String, CaseIterable, Identifiable {
    case shortcut
    case permissions
    case apiKeys
    case refinement
    case general

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .shortcut: "快捷键"
        case .permissions: "权限"
        case .apiKeys: "API Key"
        case .refinement: "整理"
        case .general: "通用"
        }
    }

    package var subtitle: String {
        switch self {
        case .shortcut: "选择开始语音输入的全局快捷键"
        case .permissions: "检查麦克风与辅助功能授权"
        case .apiKeys: "配置豆包与可选的 DeepSeek 凭据"
        case .refinement: "选择识别后文字的整理程度"
        case .general: "启动、历史保留与软件更新"
        }
    }

    package var icon: String {
        switch self {
        case .shortcut: "keyboard"
        case .permissions: "checkmark.shield"
        case .apiKeys: "key.fill"
        case .refinement: "text.alignleft"
        case .general: "switch.2"
        }
    }
}

@MainActor
package final class SettingsNavigationModel: ObservableObject {
    @Published package var page: SettingsPage

    package init(page: SettingsPage = .shortcut) {
        self.page = page
    }

    package func open(_ page: SettingsPage) {
        self.page = page
    }
}
