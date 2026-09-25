import SwiftUI

package enum MainWindowTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case history
    case dictionary
    case settings
    case about

    package var id: String { rawValue }

    package static let overviewTitle = "概览"
    package static let historyTitle = "历史"
    package static let settingsTitle = "设置"
    package static let dictionaryTitle = "词典"
    package static let aboutTitle = "关于"

    package var title: String {
        switch self {
        case .overview: Self.overviewTitle
        case .history: Self.historyTitle
        case .settings: Self.settingsTitle
        case .dictionary: Self.dictionaryTitle
        case .about: Self.aboutTitle
        }
    }
}

/// The main window's five destinations. A tab bar in the title bar picks one,
/// and only that page fills the window, so no tab-view bezel sits between the
/// toolbar and the page.
package struct MainWindowTabs<Page: View>: View {
    @Binding private var selection: MainWindowTab
    private let page: (MainWindowTab) -> Page

    package init(
        selection: Binding<MainWindowTab>,
        @ViewBuilder page: @escaping (MainWindowTab) -> Page
    ) {
        _selection = selection
        self.page = page
    }

    package var body: some View {
        page(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The title bar is transparent, so a scrolled page stops at its
            // edge and fades into the window ground instead of passing
            // behind the window controls and tabs.
            .clipped()
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(nsColor: .windowBackgroundColor).opacity(0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            // One ground under the title bar and the page.
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    MainWindowTabBar(selection: $selection)
                }
            }
    }
}

/// The title-bar page switcher. A segmented control draws a hairline between
/// every pair of unselected segments; this bar draws only the selected
/// capsule, which slides to the new page, on the toolbar's own glass.
/// Assistive technologies still meet a segmented picker.
package struct MainWindowTabBar: View {
    @Binding private var selection: MainWindowTab
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    package init(selection: Binding<MainWindowTab>) {
        _selection = selection
    }

    package var body: some View {
        HStack(spacing: 2) {
            ForEach(MainWindowTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    label(for: tab)
                }
                .buttonStyle(.plain)
            }
        }
        // Only the indicator slides; the page itself swaps at once.
        .animation(reduceMotion ? nil : SpeakerMotion.change, value: selection)
        .accessibilityRepresentation {
            Picker("页面", selection: $selection) {
                ForEach(MainWindowTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func label(for tab: MainWindowTab) -> some View {
        Text(tab.title)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background {
                if selection == tab {
                    Capsule()
                        .fill(Color.primary.opacity(contrast == .increased ? 0.2 : 0.1))
                        .matchedGeometryEffect(id: "selection", in: indicator)
                }
            }
            .contentShape(Capsule())
    }
}

package enum AboutSection: String, CaseIterable, Identifiable, Sendable {
    case privacyBoundary
    case version

    package var id: String { rawValue }

    package static let privacyBoundaryTitle = "隐私边界"
    package static let versionTitle = "版本"

    package var title: String {
        switch self {
        case .privacyBoundary: Self.privacyBoundaryTitle
        case .version: Self.versionTitle
        }
    }

    package var icon: String {
        switch self {
        case .privacyBoundary: "hand.raised.fill"
        case .version: "info.circle"
        }
    }
}
