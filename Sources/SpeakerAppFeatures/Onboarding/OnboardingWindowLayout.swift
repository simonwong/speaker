import CoreGraphics

package struct OnboardingWindowLayout: Equatable, Sendable {
    package static let preferredSize = CGSize(width: 640, height: 620)
    package static let minimumSize = CGSize(width: 520, height: 480)
    package static let screenMargin: CGFloat = 32

    package let initialSize: CGSize
    package let effectiveMinimumSize: CGSize
    package let availableSize: CGSize

    package init(visibleFrame: CGRect) {
        let available = CGSize(
            width: max(360, visibleFrame.width - Self.screenMargin * 2),
            height: max(360, visibleFrame.height - Self.screenMargin * 2)
        )
        availableSize = available
        initialSize = CGSize(
            width: min(Self.preferredSize.width, available.width),
            height: min(Self.preferredSize.height, available.height)
        )
        effectiveMinimumSize = CGSize(
            width: min(Self.minimumSize.width, available.width),
            height: min(Self.minimumSize.height, available.height)
        )
    }
}
