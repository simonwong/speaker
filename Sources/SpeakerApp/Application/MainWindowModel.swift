import Combine
import SpeakerAppFeatures
import SwiftUI

/// Shared selection for the single tabbed main window. The menu bar writes the
/// desired tab before opening the window; the window observes it.
@MainActor
final class MainWindowModel: ObservableObject {
    static let windowID = "speaker-main"

    @Published var selection: MainWindowTab = .overview

    func select(_ tab: MainWindowTab) {
        selection = tab
    }
}
