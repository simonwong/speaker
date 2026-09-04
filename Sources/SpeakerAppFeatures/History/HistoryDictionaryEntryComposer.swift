import Foundation
import SpeakerCore
import SwiftUI

package struct HistoryDictionaryEntryComposerState: Equatable, Sendable {
    package let candidates: [String]

    package init?(transcription: String?) {
        guard let transcription,
              !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        candidates = DictionaryEntryCandidateExtractor.candidates(in: transcription)
    }
}

@MainActor
package enum HistoryDictionaryEntryAddition {
    package static func perform(
        word: String,
        using dictionary: DictionarySettingsModel
    ) async -> HistoryDashboardFeedback {
        if await dictionary.add(word: word) {
            let savedWord = DictionaryEntry(word: word).word
            return HistoryDashboardFeedback(
                id: UUID(),
                kind: .success,
                message: "词条“\(savedWord)”已加入个人词库。"
            )
        }
        return HistoryDashboardFeedback(
            id: UUID(),
            kind: .warning,
            message: dictionary.notice ?? "无法保存词条，请重试。"
        )
    }
}

package struct HistoryDictionaryEntryComposer: View {
    private let state: HistoryDictionaryEntryComposerState?
    private let isBusy: Bool
    private let addEntry: (String) -> Void
    @State private var draftWord = ""

    package init(
        transcription: String?,
        isBusy: Bool,
        addEntry: @escaping (String) -> Void
    ) {
        state = HistoryDictionaryEntryComposerState(
            transcription: transcription
        )
        self.isBusy = isBusy
        self.addEntry = addEntry
    }

    @ViewBuilder
    package var body: some View {
        if let state {
            VStack(alignment: .leading, spacing: 8) {
                Label("加入词库", systemImage: "text.badge.plus")
                    .font(SpeakerTypography.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                if !state.candidates.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(state.candidates, id: \.self) { candidate in
                                Button {
                                    draftWord = candidate
                                } label: {
                                    Text(candidate)
                                        .font(SpeakerTypography.footnote)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(
                                            Color.primary.opacity(0.05),
                                            in: Capsule()
                                        )
                                        .overlay {
                                            Capsule().stroke(
                                                Color.primary.opacity(0.08),
                                                lineWidth: 0.5
                                            )
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("选择候选词条 \(candidate)")
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("输入词条", text: $draftWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button(action: save) {
                        Label("保存", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }
            }
            .padding(10)
            .background(
                Color.primary.opacity(0.03),
                in: RoundedRectangle(
                    cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
                    style: .continuous
                )
            )
        }
    }

    private func save() {
        addEntry(draftWord)
    }
}
