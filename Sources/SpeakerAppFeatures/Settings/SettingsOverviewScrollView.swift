import SwiftUI

package struct SettingsOverviewScrollView<
    TopContent: View,
    SectionContent: View
>: View {
    @ObservedObject private var navigation: SettingsNavigationModel
    private let topContent: () -> TopContent
    private let sectionContent: (SettingsPage) -> SectionContent
    @Environment(\.mainWindowLayout) private var mainWindowLayout

    package init(
        navigation: SettingsNavigationModel,
        @ViewBuilder top: @escaping () -> TopContent,
        @ViewBuilder section: @escaping (SettingsPage) -> SectionContent
    ) {
        self.navigation = navigation
        topContent = top
        sectionContent = section
    }

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topContent()
                        .id(SettingsPresentationTarget.top)

                    ForEach(SettingsPage.allCases) { section in
                        sectionContent(section)
                            .id(SettingsPresentationTarget.section(section))
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(
                    .horizontal,
                    mainWindowLayout.pageHorizontalPadding
                )
                .padding(.bottom, 28)
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
