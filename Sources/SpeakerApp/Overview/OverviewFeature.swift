import Combine
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

@MainActor
final class OverviewModel: ObservableObject {
    @Published private(set) var summary: VoiceInputUsageSummary = .empty

    private let store: any LocalSessionHistoryStoring

    init(store: any LocalSessionHistoryStoring) {
        self.store = store
    }

    func refresh() async {
        summary = await store.usageStatistics()
    }
}

struct OverviewView: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        OverviewDashboard(summary: model.summary)
            .task { await model.refresh() }
            .onReceive(
                NotificationCenter.default.publisher(for: .speakerHistoryDidChange)
            ) { _ in
                Task { await model.refresh() }
            }
    }
}
