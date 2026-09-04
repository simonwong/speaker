import Combine
import SwiftUI

/// Shared selection for the single tabbed main window. The menu bar writes the
/// desired tab before opening the window; the window observes it.
@MainActor
package final class MainWindowModel: ObservableObject {
    package static let windowID = "speaker-main"

    @Published package var selection: MainWindowTab = .overview

    package init() {}

    package func select(_ tab: MainWindowTab) {
        selection = tab
    }
}
