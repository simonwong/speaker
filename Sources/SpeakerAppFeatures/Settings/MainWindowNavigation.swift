import AppKit
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

package struct MainWindowTabSeparatorHider: NSViewRepresentable {
    package init() {}

    package func makeNSView(context: Context) -> NSView {
        MainWindowTabSeparatorConfiguratorView()
    }

    package func updateNSView(_ nsView: NSView, context: Context) {
        guard
            let configurator = nsView
                as? MainWindowTabSeparatorConfiguratorView
        else { return }
        configurator.scheduleConfiguration()
    }
}

private final class MainWindowTabSeparatorConfiguratorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    override func layout() {
        super.layout()
        scheduleConfiguration()
    }

    func scheduleConfiguration() {
        DispatchQueue.main.async { [weak self] in
            self?.removeSeparators()
        }
    }

    private func removeSeparators() {
        guard let frameView = window?.contentView?.superview,
            let tabs = segmentedControls(in: frameView).first(where: {
                $0.segmentCount == MainWindowTab.allCases.count
                    && $0.segmentStyle == .automatic
            }),
            let container = tabs.superview
        else { return }

        container.wantsLayer = true
        let mask = CAShapeLayer()
        mask.frame = container.bounds
        let path = CGMutablePath()
        let segmentWidth =
            container.bounds.width
            / CGFloat(tabs.segmentCount)
        let gap: CGFloat = 1

        for index in 0..<tabs.segmentCount {
            let leadingGap = index == 0 ? 0 : gap / 2
            let trailingGap = index == tabs.segmentCount - 1 ? 0 : gap / 2
            path.addRect(
                CGRect(
                    x: CGFloat(index) * segmentWidth + leadingGap,
                    y: 0,
                    width: segmentWidth - leadingGap - trailingGap,
                    height: container.bounds.height
                ))
        }

        mask.path = path
        mask.fillColor = NSColor.black.cgColor
        container.layer?.mask = mask
    }

    private func segmentedControls(in root: NSView) -> [NSSegmentedControl] {
        var controls: [NSSegmentedControl] = []

        func visit(_ view: NSView) {
            if let control = view as? NSSegmentedControl {
                controls.append(control)
            }
            view.subviews.forEach(visit)
        }

        visit(root)
        return controls
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
        case .version: "waveform"
        }
    }
}
