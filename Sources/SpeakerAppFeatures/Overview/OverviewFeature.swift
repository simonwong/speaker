import Combine
import Foundation
import SpeakerCore
import SwiftUI

/// The Overview tab's state: one usage snapshot and the moment it describes.
@MainActor
package final class OverviewModel: ObservableObject {
    @Published package private(set) var summary: VoiceInputUsageSummary = .empty
    /// The moment the last refresh read the store. Week, voiceprint, and
    /// heatmap windows are pinned to it instead of the wall clock.
    @Published package private(set) var referenceDate: Date
    /// Whether a refresh has completed. The Overview entrance waits for the
    /// first one and never replays, because the model outlives page switches.
    @Published package private(set) var hasRefreshed = false

    private let store: any LocalSessionHistoryStoring
    private let now: () -> Date
    private var refreshID = UUID()

    package init(
        store: any LocalSessionHistoryStoring,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
        referenceDate = now()
    }

    package var dashboardState: OverviewDashboardState {
        OverviewDashboardState(
            summary: summary,
            referenceDate: referenceDate,
            isLoaded: hasRefreshed
        )
    }

    package func refresh() async {
        let id = UUID()
        refreshID = id
        let date = now()
        let snapshot = await store.usageStatistics()
        guard refreshID == id else { return }
        referenceDate = date
        summary = snapshot
        hasRefreshed = true
    }
}

package struct OverviewView: View {
    @ObservedObject var model: OverviewModel

    package init(model: OverviewModel) {
        self.model = model
    }

    package var body: some View {
        OverviewDashboard(state: model.dashboardState)
            .task { await model.refresh() }
            .onReceive(
                NotificationCenter.default.publisher(for: .speakerHistoryDidChange)
            ) { _ in
                Task { await model.refresh() }
            }
    }
}
