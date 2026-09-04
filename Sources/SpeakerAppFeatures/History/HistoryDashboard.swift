import Foundation
import SpeakerCore
import SwiftUI

package struct HistoryDashboardFeedback: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case information
        case success
        case warning
        case error
    }

    package let id: UUID
    package let kind: Kind
    package let message: String

    package init(id: UUID, kind: Kind, message: String) {
        self.id = id
        self.kind = kind
        self.message = message
    }
}

package struct HistoryDashboardState: Equatable, Sendable {
    package let records: [VoiceInputHistoryRecord]
    package let totalRecordCount: Int
    package let notice: String?
    package let feedback: HistoryDashboardFeedback?
    package let isBusy: Bool

    package init(
        records: [VoiceInputHistoryRecord],
        totalRecordCount: Int,
        notice: String?,
        feedback: HistoryDashboardFeedback?,
        isBusy: Bool
    ) {
        self.records = records
        self.totalRecordCount = totalRecordCount
        self.notice = notice
        self.feedback = feedback
        self.isBusy = isBusy
    }
}

package struct HistoryDashboardActions {
    package let refresh: () -> Void
    package let clear: () -> Void
    package let copy: (VoiceInputHistoryRecord) -> Void
    package let delete: (VoiceInputSessionID) -> Void
    package let addDictionaryEntry: (String) -> Void

    package init(
        refresh: @escaping () -> Void,
        clear: @escaping () -> Void,
        copy: @escaping (VoiceInputHistoryRecord) -> Void,
        delete: @escaping (VoiceInputSessionID) -> Void,
        addDictionaryEntry: @escaping (String) -> Void = { _ in }
    ) {
        self.refresh = refresh
        self.clear = clear
        self.copy = copy
        self.delete = delete
        self.addDictionaryEntry = addDictionaryEntry
    }
}

/// The complete History tab presentation. App composition supplies one state
/// snapshot and semantic actions; grouping, copy, detail, and empty-state UI
/// stay behind this interface.
package struct HistoryDashboard: View {
    let state: HistoryDashboardState
    @Binding private var query: String
    let actions: HistoryDashboardActions
    @State private var expandedRecordID: VoiceInputSessionID?
    @State private var confirmsClear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mainWindowLayout) private var mainWindowLayout

    package init(
        state: HistoryDashboardState,
        query: Binding<String>,
        actions: HistoryDashboardActions
    ) {
        self.state = state
        _query = query
        self.actions = actions
    }

    package var body: some View {
        VStack(spacing: 0) {
            historyToolbar
            Divider()

            if state.records.isEmpty {
                emptyState
            } else {
                historyList
            }

            statusFooter
        }
        .onChange(of: state.records.map(\.sessionID)) { _, ids in
            guard let expandedRecordID,
                  !ids.contains(expandedRecordID)
            else { return }
            self.expandedRecordID = nil
        }
        .confirmationDialog(
            "清空所有会话历史？",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("清空历史", role: .destructive, action: actions.clear)
            Button("取消", role: .cancel) {}
        } message: {
            Text("文字记录会从本机永久删除，此操作无法撤销。")
        }
    }

    private var historyToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索历史…", text: $query)
                    .textFieldStyle(.plain)
                    .font(SpeakerTypography.body)
                    .onSubmit(actions.refresh)
                if !query.isEmpty {
                    Button {
                        query = ""
                        actions.refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(
                    cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
                    style: .continuous
                )
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }

            Menu {
                Button("刷新", systemImage: "arrow.clockwise", action: actions.refresh)
                Divider()
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Label("全部清空…", systemImage: "trash")
                }
                .disabled(state.totalRecordCount == 0)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("刷新与清空历史")
            .accessibilityLabel("历史选项")
        }
        .frame(maxWidth: SpeakerSurfaceMetrics.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "还没有会话记录"
                : "没有找到匹配记录",
            systemImage: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "clock.arrow.circlepath"
                : "magnifyingglass",
            description: Text(
                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "完成第一次语音输入后，记录会出现在这里。"
                    : "尝试缩短关键词，或清空搜索后查看全部记录。"
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.day) { section in
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.title)
                            .font(SpeakerTypography.sectionHeader)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text("\(section.records.count) 条")
                            .font(SpeakerTypography.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 6)
                    .padding(.horizontal, 8)

                    ForEach(
                        Array(section.records.enumerated()),
                        id: \.element.sessionID
                    ) { index, record in
                        HistoryRecordRow(
                            record: record,
                            isExpanded: expandedRecordID == record.sessionID,
                            isBusy: state.isBusy,
                            reduceMotion: reduceMotion,
                            copy: { actions.copy(record) },
                            addDictionaryEntry: actions.addDictionaryEntry,
                            toggleDetails: {
                                withAnimation(
                                    reduceMotion
                                        ? nil
                                        : .easeOut(duration: 0.18)
                                ) {
                                    expandedRecordID = expandedRecordID
                                        == record.sessionID
                                        ? nil
                                        : record.sessionID
                                }
                            },
                            delete: {
                                actions.delete(record.sessionID)
                            }
                        )

                        if index < section.records.count - 1 {
                            Divider()
                                .opacity(0.45)
                                .padding(.leading, 64)
                        }
                    }
                }
            }
            .frame(maxWidth: SpeakerSurfaceMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
            .padding(.bottom, SpeakerSurfaceMetrics.pageBottomPadding)
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let feedback = state.feedback {
            Divider()
            Label(
                feedback.message,
                systemImage: feedback.kind.systemImage
            )
            .font(SpeakerTypography.caption)
            .foregroundStyle(feedback.kind.color)
            .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(feedback.message)
        } else if let notice = state.notice {
            Divider()
            Label(
                notice,
                systemImage: "exclamationmark.circle.fill"
            )
            .font(SpeakerTypography.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sections: [HistoryDaySection] {
        HistoryPresentation.sections(
            records: state.records,
            now: Date()
        )
    }
}

private struct HistoryRecordRow: View {
    let record: VoiceInputHistoryRecord
    let isExpanded: Bool
    let isBusy: Bool
    let reduceMotion: Bool
    let copy: () -> Void
    let addDictionaryEntry: (String) -> Void
    let toggleDetails: () -> Void
    let delete: () -> Void
    @State private var isHovered = false
    @State private var confirmsDelete = false

    private var presentation: HistoryRecordRowPresentation {
        HistoryPresentation.row(for: record)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(presentation.time)
                    .font(SpeakerTypography.mono)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                    .padding(.top, 2)

                Text(presentation.text)
                    .font(SpeakerTypography.body)
                    .lineSpacing(2)
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if presentation.status.showsStatusIcon {
                    Image(systemName: presentation.status.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(presentation.status.color)
                        .padding(.top, 2)
                        .help(presentation.status.label)
                        .accessibilityLabel(presentation.status.label)
                }

                if isHovered && !isExpanded {
                    HStack(spacing: 2) {
                        if presentation.canCopy {
                            Button(action: copy) {
                                Image(systemName: "doc.on.doc")
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .disabled(isBusy)
                            .help("复制")
                            .accessibilityLabel("复制")
                        }
                        Button {
                            confirmsDelete = true
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .disabled(isBusy)
                        .help("删除")
                        .accessibilityLabel("删除")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: toggleDetails)

            if isExpanded {
                HistoryExpandedRecord(
                    record: record,
                    presentation: presentation,
                    isBusy: isBusy,
                    addDictionaryEntry: addDictionaryEntry
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            Color.primary.opacity(isHovered || isExpanded ? 0.045 : 0),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .confirmationDialog(
            "删除这条会话记录？",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("删除记录", role: .destructive, action: delete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("记录只保存在本机，删除后无法恢复。")
        }
    }
}

private struct HistoryExpandedRecord: View {
    let record: VoiceInputHistoryRecord
    let presentation: HistoryRecordRowPresentation
    let isBusy: Bool
    let addDictionaryEntry: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    presentation.status.label,
                    systemImage: presentation.status.icon
                )
                .font(SpeakerTypography.footnote.weight(.medium))
                .foregroundStyle(presentation.status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    presentation.status.color.opacity(0.12),
                    in: Capsule()
                )
                Text(metadataLine)
                    .font(SpeakerTypography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SpeakerTextBlock(
                title: "豆包转录",
                text: record.transcription ?? "无",
                isPlaceholder: record.transcription == nil
            )

            HistoryDictionaryEntryComposer(
                transcription: record.transcription,
                isBusy: isBusy,
                addEntry: addDictionaryEntry
            )

            if showsRefinementBlock {
                SpeakerTextBlock(
                    title: "DeepSeek 整理",
                    text: record.deepSeekText ?? refinementPlaceholder,
                    isPlaceholder: record.deepSeekText == nil
                )
            }

            if !diagnosticLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(diagnosticLines, id: \.self) { line in
                        diagnosticText(line)
                    }
                }
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
    }

    /// Diagnostics stay content-free; identifiers read in the mono face.
    private func diagnosticText(_ line: DiagnosticLine) -> Text {
        guard let identifier = line.identifier else {
            return Text(line.label)
        }
        return Text(line.label)
            + Text(identifier).font(SpeakerTypography.mono)
    }

    private struct DiagnosticLine: Hashable {
        let label: String
        var identifier: String?
    }

    private var diagnosticLines: [DiagnosticLine] {
        var lines: [DiagnosticLine] = []
        if !record.stageDurationsMilliseconds.isEmpty {
            lines.append(
                DiagnosticLine(label: "阶段耗时 · \(stageDurationsLine)")
            )
        }
        if let providerRequestID = record.providerRequestID {
            lines.append(
                DiagnosticLine(
                    label: "\(record.transcriptionProvider ?? "转录提供商") 请求 ID：",
                    identifier: providerRequestID
                )
            )
        }
        if let deepSeekRequestID = record.deepSeekRequestID {
            lines.append(
                DiagnosticLine(
                    label: "DeepSeek 请求 ID：",
                    identifier: deepSeekRequestID
                )
            )
        }
        if let deliveryDiagnosticCode = record.deliveryDiagnosticCode {
            lines.append(
                DiagnosticLine(
                    label: "送达诊断：",
                    identifier: deliveryDiagnosticCode
                )
            )
        }
        return lines
    }

    private var metadataLine: String {
        [
            record.startedAt.formatted(date: .abbreviated, time: .shortened),
            record.refinementModeName ?? "默认顺滑",
            Self.durationText(milliseconds: record.durationMilliseconds),
        ].joined(separator: " · ")
    }

    /// The metadata line reads in seconds; stage diagnostics keep raw ms.
    private static func durationText(milliseconds: Int) -> String {
        String(format: "%.1f 秒", Double(max(0, milliseconds)) / 1_000)
    }

    private var refinementPlaceholder: String { "无" }

    private var showsRefinementBlock: Bool {
        record.deepSeekText != nil
            || record.refinementStatus
                == DeepSeekRefinementStatus.fellBack.rawValue
    }

    private var stageDurationsLine: String {
        record.stageDurationsMilliseconds
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value) ms" }
            .joined(separator: " · ")
    }
}

private extension HistoryDashboardFeedback.Kind {
    var systemImage: String {
        switch self {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .information: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
