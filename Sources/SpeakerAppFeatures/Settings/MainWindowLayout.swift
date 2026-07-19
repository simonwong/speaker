import CoreGraphics
import SwiftUI

package enum MainWindowWidthClass: Equatable, Sendable {
    case compact
    case regular
}

package struct MainWindowLayout: Equatable, Sendable {
    package static let minimumContentSize = CGSize(width: 720, height: 560)
    package static let preferredContentSize = CGSize(width: 900, height: 640)
    package static let regularWidth: CGFloat = 780

    package let availableWidth: CGFloat

    package init(availableWidth: CGFloat) {
        self.availableWidth = availableWidth
    }

    package var widthClass: MainWindowWidthClass {
        availableWidth < Self.regularWidth ? .compact : .regular
    }

    package var pageHorizontalPadding: CGFloat {
        widthClass == .compact ? 18 : 24
    }

    package var overviewMetricDividerPadding: CGFloat {
        widthClass == .compact ? 18 : 34
    }

    package var usesScrollableSettingsNavigation: Bool {
        widthClass == .compact
    }
}

private struct MainWindowLayoutEnvironmentKey: EnvironmentKey {
    static let defaultValue = MainWindowLayout(
        availableWidth: MainWindowLayout.preferredContentSize.width
    )
}

package extension EnvironmentValues {
    var mainWindowLayout: MainWindowLayout {
        get { self[MainWindowLayoutEnvironmentKey.self] }
        set { self[MainWindowLayoutEnvironmentKey.self] = newValue }
    }
}
