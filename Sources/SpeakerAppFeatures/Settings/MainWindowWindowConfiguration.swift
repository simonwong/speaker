import AppKit
import SwiftUI

@MainActor
package enum MainWindowWindowConfiguration {
    package static func apply(to window: NSWindow) {
        window.contentMinSize = MainWindowLayout.minimumContentSize
    }
}

package struct MainWindowWindowConfigurator: NSViewRepresentable {
    package init() {}

    package func makeNSView(context: Context) -> NSView {
        let view = MainWindowConfigurationView()
        view.scheduleConfiguration()
        return view
    }

    package func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MainWindowConfigurationView)?.scheduleConfiguration()
    }
}

@MainActor
private final class MainWindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyConfiguration()
    }

    func applyConfiguration() {
        guard let window else { return }
        MainWindowWindowConfiguration.apply(to: window)
    }

    func scheduleConfiguration() {
        DispatchQueue.main.async { [weak self] in
            self?.applyConfiguration()
        }
    }
}
