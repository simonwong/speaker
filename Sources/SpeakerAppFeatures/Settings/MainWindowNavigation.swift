package enum MainWindowTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case history
    case settings
    case dictionary
    case about

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .overview: "概览"
        case .history: "历史"
        case .settings: "设置"
        case .dictionary: "词典"
        case .about: "关于"
        }
    }

    package var icon: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        case .dictionary: "text.book.closed"
        case .about: "info.circle"
        }
    }
}

package enum AboutSection: String, CaseIterable, Identifiable, Sendable {
    case privacyBoundary
    case localData
    case version

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .privacyBoundary: "隐私边界"
        case .localData: "本地数据"
        case .version: "版本"
        }
    }

    package var icon: String {
        switch self {
        case .privacyBoundary: "hand.raised.fill"
        case .localData: "externaldrive.badge.xmark"
        case .version: "waveform"
        }
    }
}
