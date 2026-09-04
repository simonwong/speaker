import SwiftUI

/// The settings page's single scrolling grouped form. Every group is visible
/// top-to-bottom; deep links only scroll the matching group into view.
package struct SettingsOverviewScrollView<SectionContent: View>: View {
    @ObservedObject private var navigation: SettingsNavigationModel
    private let sectionContent: (SettingsGroup) -> SectionContent
    @Environment(\.mainWindowLayout) private var mainWindowLayout

    package init(
        navigation: SettingsNavigationModel,
        @ViewBuilder section: @escaping (SettingsGroup) -> SectionContent
    ) {
        self.navigation = navigation
        sectionContent = section
    }

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: SpeakerSurfaceMetrics.sectionSpacing
                ) {
                    ForEach(SettingsGroup.allCases) { group in
                        sectionContent(group)
                            .id(SettingsPresentationTarget.section(group))
                    }
                }
                .frame(maxWidth: SpeakerSurfaceMetrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(
                    .horizontal,
                    mainWindowLayout.pageHorizontalPadding
                )
                .padding(.top, SpeakerSurfaceMetrics.pageTopPadding)
                .padding(.bottom, SpeakerSurfaceMetrics.pageBottomPadding)
                .id(SettingsPresentationTarget.top)
            }
            .onChange(of: navigation.presentationRequest) { _, request in
                guard let request else { return }
                navigate(to: request.target, proxy: proxy)
                navigation.completePresentation(request)
            }
            .task {
                let requestAtAppearance = navigation.presentationRequest
                let revisionAtAppearance = navigation.presentationRevision
                await Task.yield()
                guard !Task.isCancelled else { return }
                if let requestAtAppearance {
                    navigate(
                        to: requestAtAppearance.target,
                        proxy: proxy,
                        animated: false
                    )
                    navigation.completePresentation(requestAtAppearance)
                } else if navigation.presentationRevision
                    == revisionAtAppearance
                {
                    navigate(to: .top, proxy: proxy, animated: false)
                }
            }
        }
    }

    private func navigate(
        to target: SettingsPresentationTarget,
        proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .top)
            }
        } else {
            proxy.scrollTo(target, anchor: .top)
        }
    }
}
