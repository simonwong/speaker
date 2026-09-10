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
    /// The moment the snapshot was taken. Day grouping reads it instead of the
    /// wall clock, so 今天 and 昨天 stay pinned to the state a specification
    /// hands the view.
    package let referenceDate: Date

    package init(
        records: [VoiceInputHistoryRecord],
        totalRecordCount: Int,
        notice: String?,
        feedback: HistoryDashboardFeedback?,
        isBusy: Bool,
        referenceDate: Date
    ) {
        self.records = records
        self.totalRecordCount = totalRecordCount
        self.notice = notice
        self.feedback = feedback
        self.isBusy = isBusy
        self.referenceDate = referenceDate
    }

    package func sections(
        calendar: Calendar = .current
    ) -> [HistoryDaySection] {
        HistoryPresentation.sections(
            records: records,
            now: referenceDate,
            calendar: calendar
        )
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
    /// Hover lives here, not in the row, so only one row can read as hovered
    /// and so a row divider knows whether either neighbour is lit.
    @State private var hoveredRecordID: VoiceInputSessionID?
    @State private var confirmsClear = false
    @FocusState private var searchIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
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
        // Every other tab sits on the window ground through `SpeakerPage`;
        // History composes its own chrome, so it paints the same ground here.
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: state.records.map(\.sessionID)) { _, ids in
            if let expandedRecordID, !ids.contains(expandedRecordID) {
                self.expandedRecordID = nil
            }
            if let hoveredRecordID, !ids.contains(hoveredRecordID) {
                self.hoveredRecordID = nil
            }
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
                    .focused($searchIsFocused)
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
                .strokeBorder(
                    searchBorderColor,
                    lineWidth: searchIsFocused ? 1.5 : 0.5
                )
            }
            .animation(reduceMotion ? nil : .historyHover, value: searchIsFocused)

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
                    .font(.title3)
                    .foregroundStyle(.secondary)
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

    private var searchBorderColor: Color {
        if searchIsFocused { return .accentColor.opacity(0.7) }
        return Color.primary.opacity(contrast == .increased ? 0.28 : 0.08)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyState: some View {
        SpeakerEmptyState(
            title: isSearching ? "没有找到匹配记录" : "还没有会话记录",
            description: isSearching
                ? "尝试缩短关键词，或清空搜索后查看全部记录。"
                : "完成第一次语音输入后，记录会出现在这里。",
            systemImage: isSearching ? "magnifyingglass" : "clock.arrow.circlepath"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.day) { section in
                    sectionHeader(section)

                    ForEach(
                        Array(section.records.enumerated()),
                        id: \.element.sessionID
                    ) { index, record in
                        row(for: record)

                        if index < section.records.count - 1 {
                            rowDivider(
                                isHidden: isHighlighted(record.sessionID)
                                    || isHighlighted(
                                        section.records[index + 1].sessionID
                                    )
                            )
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

    private func sectionHeader(_ section: HistoryDaySection) -> some View {
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
    }

    private func row(for record: VoiceInputHistoryRecord) -> some View {
        HistoryRecordRow(
            record: record,
            isExpanded: expandedRecordID == record.sessionID,
            isHovered: hoveredRecordID == record.sessionID,
            isBusy: state.isBusy,
            reduceMotion: reduceMotion,
            setHovered: { hovering in
                if hovering {
                    hoveredRecordID = record.sessionID
                } else if hoveredRecordID == record.sessionID {
                    hoveredRecordID = nil
                }
            },
            copy: { actions.copy(record) },
            addDictionaryEntry: actions.addDictionaryEntry,
            toggleDetails: {
                withAnimation(reduceMotion ? nil : .historyExpand) {
                    expandedRecordID =
                        expandedRecordID == record.sessionID
                        ? nil
                        : record.sessionID
                }
            },
            delete: { actions.delete(record.sessionID) }
        )
    }

    /// A divider between two rows fades out while either neighbour carries the
    /// hover or expanded fill, so the fill reads as one continuous shape.
    private func rowDivider(isHidden: Bool) -> some View {
        Divider()
            .opacity(isHidden ? 0 : 0.45)
            .padding(.leading, 64)
            .animation(reduceMotion ? nil : .historyHover, value: isHidden)
    }

    /// True while a row carries the hover or expanded fill.
    private func isHighlighted(_ id: VoiceInputSessionID) -> Bool {
        hoveredRecordID == id || expandedRecordID == id
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let footer {
            Divider()
            Label(footer.message, systemImage: footer.icon)
                .font(SpeakerTypography.caption)
                .foregroundStyle(footer.color)
                .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(footer.message)
        }
    }

    /// Transient feedback outranks the persistent store notice.
    private var footer: HistoryFooterLine? {
        if let feedback = state.feedback {
            return HistoryFooterLine(
                message: feedback.message,
                icon: feedback.kind.systemImage,
                color: feedback.kind.color
            )
        }
        if let notice = state.notice {
            return HistoryFooterLine(
                message: notice,
                icon: "exclamationmark.circle.fill",
                color: .red
            )
        }
        return nil
    }

    private var sections: [HistoryDaySection] {
        state.sections()
    }
}

/// The one line the tab can print under the list: whichever of the transient
/// feedback and the persistent store notice is showing.
private struct HistoryFooterLine {
    let message: String
    let icon: String
    let color: Color
}

/// The tab's two motion rungs. Callers still gate them on Reduce Motion.
extension Animation {
    fileprivate static let historyHover = Animation.easeOut(duration: 0.12)
    fileprivate static let historyExpand = Animation.easeOut(duration: 0.18)
}

private struct HistoryRecordRow: View {
    let record: VoiceInputHistoryRecord
    let isExpanded: Bool
    let isHovered: Bool
    let isBusy: Bool
    let reduceMotion: Bool
    let setHovered: (Bool) -> Void
    let copy: () -> Void
    let addDictionaryEntry: (String) -> Void
    let toggleDetails: () -> Void
    let delete: () -> Void
    @State private var confirmsDelete = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// Collapsed rows all reserve two lines, so the list keeps one rhythm and
    /// no row changes height when the pointer arrives.
    private static let collapsedLineLimit = 2

    private var presentation: HistoryRecordRowPresentation {
        HistoryPresentation.row(for: record)
    }

    private var showsActions: Bool { isHovered || isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(presentation.time)
                    .font(SpeakerTypography.mono)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                    .padding(.top, 2)

                recordText

                if presentation.status.showsStatusIcon {
                    Image(systemName: presentation.status.icon)
                        .font(SpeakerTypography.body)
                        .foregroundStyle(presentation.status.color)
                        .padding(.top, 2)
                        .help(presentation.status.label)
                        .accessibilityLabel(presentation.status.label)
                }

                // The action cluster always occupies its width, whether or not
                // it is visible: revealing it must never reflow the text.
                rowActions
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(fillOpacity))
        )
        .onHover(perform: setHovered)
        .animation(reduceMotion ? nil : .historyHover, value: isHovered)
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

    private var fillOpacity: Double {
        let increased = contrast == .increased
        if isExpanded { return increased ? 0.12 : 0.06 }
        if isHovered { return increased ? 0.09 : 0.04 }
        return 0
    }

    @ViewBuilder
    private var recordText: some View {
        let text = Text(presentation.text)
            .font(SpeakerTypography.body)
            .lineSpacing(2)

        if isExpanded {
            text
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            text
                .lineLimit(Self.collapsedLineLimit, reservesSpace: true)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The cluster keeps its width whether or not a button is in it, so the
    /// text column never resizes; the buttons themselves only exist while
    /// visible, staying out of the focus ring and the accessibility tree.
    private var rowActions: some View {
        HStack(spacing: HistoryRowActionButton.spacing) {
            if showsActions {
                if presentation.canCopy {
                    HistoryRowActionButton(
                        symbol: "doc.on.doc",
                        label: "复制",
                        isEnabled: !isBusy,
                        action: copy
                    )
                }
                HistoryRowActionButton(
                    symbol: "trash",
                    label: "删除",
                    isEnabled: !isBusy
                ) {
                    confirmsDelete = true
                }
            }
        }
        .frame(width: HistoryRowActionButton.clusterWidth, alignment: .trailing)
    }
}

/// One icon button in a record row, with its own hover fill so the pointer
/// lands on something that answers back.
private struct HistoryRowActionButton: View {
    static let spacing: CGFloat = 2
    private static let side: CGFloat = 24
    /// Two buttons plus the gap: the width a row reserves for the cluster.
    static let clusterWidth = side * 2 + spacing

    let symbol: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.iconTileCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // A glyph centred in a fixed hit box: the size belongs to the
                // box, not to the text ladder.
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.side, height: Self.side)
                .background(
                    shape.fill(
                        Color.primary.opacity(
                            isHovered && isEnabled ? 0.09 : 0
                        )
                    )
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
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

extension HistoryDashboardFeedback.Kind {
    fileprivate var systemImage: String {
        switch self {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .information: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
