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

package struct MainWindowLayoutContainer<Content: View>: View {
    private let content: Content

    package init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    package var body: some View {
        GeometryReader { geometry in
            content
                .environment(
                    \.mainWindowLayout,
                    MainWindowLayout(availableWidth: geometry.size.width)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: MainWindowLayout.minimumContentSize.width,
            minHeight: MainWindowLayout.minimumContentSize.height
        )
        .background(MainWindowWindowConfigurator())
    }
}
