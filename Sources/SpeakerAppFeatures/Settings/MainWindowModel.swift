import Combine
import SwiftUI

/// Shared selection for the single tabbed main window. The menu bar writes the
/// desired tab before opening the window; the window observes it.
@MainActor
package final class MainWindowModel: ObservableObject {
    package static let windowID = "speaker-main"

    @Published package var selection: MainWindowTab = .overview
    /// Set by ⌘F until the History page has focused its search field.
    @Published package private(set) var historySearchRequested = false

    package init() {}

    package func select(_ tab: MainWindowTab) {
        selection = tab
    }

    package func requestHistorySearch() {
        selection = .history
        historySearchRequested = true
    }

    package func historySearchFocused() {
        historySearchRequested = false
    }
}
