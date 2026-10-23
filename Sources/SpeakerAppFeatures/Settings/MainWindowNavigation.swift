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
    package static let dictionaryTitle = "词库"
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

    /// ⌘1 to ⌘5 follow the tab bar's order.
    package var commandNumber: Int {
        Self.allCases.firstIndex(of: self)! + 1
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
                .frame(height: SpeakerSpacing.s)
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

    package init(selection: Binding<MainWindowTab>) {
        _selection = selection
    }

    package var body: some View {
        HStack(spacing: SpeakerSpacing.hairline) {
            ForEach(MainWindowTab.allCases) { tab in
                MainWindowTabButton(
                    title: tab.title,
                    isSelected: selection == tab,
                    indicator: indicator
                ) {
                    selection = tab
                }
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
}

/// One page in the tab bar. The selected page carries the sliding capsule;
/// an unselected page answers the pointer with the faint hover fill.
private struct MainWindowTabButton: View {
    let title: String
    let isSelected: Bool
    let indicator: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SpeakerTypography.body)
                .padding(.horizontal, SpeakerSpacing.m)
                .padding(.vertical, SpeakerSpacing.xs)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(SpeakerFill.selected)
                            .overlay {
                                // Increase Contrast outlines the selection
                                // instead of darkening its fill.
                                if contrast == .increased {
                                    Capsule().strokeBorder(
                                        SpeakerStroke.hairline(increasedContrast: true),
                                        lineWidth: 1
                                    )
                                }
                            }
                            .matchedGeometryEffect(id: "selection", in: indicator)
                    } else if isHovered {
                        Capsule().fill(SpeakerFill.subtle)
                    }
                }
                .contentShape(Capsule())
                .animation(reduceMotion ? nil : SpeakerMotion.feedback, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

package enum AboutSection: String, CaseIterable, Identifiable, Sendable {
    case project
    case author
    case privacyBoundary
    case diagnostics

    package var id: String { rawValue }

    package static let projectTitle = "项目"
    package static let authorTitle = "作者"
    package static let privacyBoundaryTitle = "隐私边界"
    package static let diagnosticsTitle = "诊断"

    package var title: String {
        switch self {
        case .project: Self.projectTitle
        case .author: Self.authorTitle
        case .privacyBoundary: Self.privacyBoundaryTitle
        case .diagnostics: Self.diagnosticsTitle
        }
    }
}
