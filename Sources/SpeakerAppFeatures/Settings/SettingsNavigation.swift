import Combine

/// The settings page is one scrolling grouped form; these groups are its
/// sections in display order and double as scroll anchors for deep links.
package enum SettingsGroup: String, CaseIterable, Hashable, Identifiable, Sendable {
    case shortcut
    case permissions
    case apiKeys
    case refinement
    case general
    case localData

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .shortcut: "快捷键"
        case .permissions: "权限"
        case .apiKeys: "API Key"
        case .refinement: "整理"
        case .general: "通用"
        case .localData: "本地数据"
        }
    }
}

package enum SettingsPresentationTarget: Equatable, Hashable {
    case top
    case section(SettingsGroup)
}

package struct SettingsPresentationRequest: Equatable {
    package let sequence: UInt
    package let target: SettingsPresentationTarget
}

@MainActor
package final class SettingsNavigationModel: ObservableObject {
    @Published package private(set) var presentationRequest:
        SettingsPresentationRequest?
    private var nextPresentationSequence: UInt = 0

    package var presentationRevision: UInt { nextPresentationSequence }

    package init() {}

    package func open(_ group: SettingsGroup) {
        requestPresentation(of: .section(group))
    }

    package func openTop() {
        requestPresentation(of: .top)
    }

    package func completePresentation(_ request: SettingsPresentationRequest) {
        guard presentationRequest == request else { return }
        presentationRequest = nil
    }

    private func requestPresentation(of target: SettingsPresentationTarget) {
        nextPresentationSequence += 1
        presentationRequest = SettingsPresentationRequest(
            sequence: nextPresentationSequence,
            target: target
        )
    }
}
