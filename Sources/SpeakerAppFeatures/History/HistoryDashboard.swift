import Foundation
import SpeakerCore
import SwiftUI

#if DEBUG
    private struct HistoryHoveredRecordOverrideKey: EnvironmentKey {
        static let defaultValue: VoiceInputSessionID? = nil
    }

    private struct HistoryRowFrameObserverKey: EnvironmentKey {
        static let defaultValue: (@MainActor @Sendable (VoiceInputSessionID, CGRect) -> Void)? = nil
    }

    extension EnvironmentValues {
        package var historyRowFrameObserver:
            (@MainActor @Sendable (VoiceInputSessionID, CGRect) -> Void)?
        {
            get { self[HistoryRowFrameObserverKey.self] }
            set { self[HistoryRowFrameObserverKey.self] = newValue }
        }

        package var historyHoveredRecordOverride: VoiceInputSessionID? {
            get { self[HistoryHoveredRecordOverrideKey.self] }
            set { self[HistoryHoveredRecordOverrideKey.self] = newValue }
        }
    }

#endif

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

    package init(
        refresh: @escaping () -> Void,
        clear: @escaping () -> Void,
        copy: @escaping (VoiceInputHistoryRecord) -> Void,
        delete: @escaping (VoiceInputSessionID) -> Void
    ) {
        self.refresh = refresh
        self.clear = clear
        self.copy = copy
        self.delete = delete
    }
}

/// The complete History tab presentation. App composition supplies one state
/// snapshot and semantic actions; grouping, copy, detail, and empty-state UI
/// stay behind this interface.
package struct HistoryDashboard: View {
    let state: HistoryDashboardState
    private let sections: [HistoryDaySection]
    @Binding private var query: String
    let actions: HistoryDashboardActions
    @State private var expandedRecordID: VoiceInputSessionID?
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
        self.sections = state.sections()
        _query = query
        self.actions = actions
    }

    package var body: some View {
        // The list is the root view, so the window hides its title bar
        // separator while the list sits at the top, exactly as the scrolling
        // tabs do. The search bar and the status line ride in the safe area
        // instead of stacking above and below behind rules of their own.
        content
            .safeAreaInset(edge: .top, spacing: 0) { historyToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusFooter }
            .background(Color.historyGround)
            .onChange(of: state.records.map(\.sessionID)) { _, ids in
                if let expandedRecordID, !ids.contains(expandedRecordID) {
                    self.expandedRecordID = nil
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

    @ViewBuilder
    private var content: some View {
        if state.records.isEmpty {
            emptyState
        } else {
            historyList
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
            .frame(height: 28)
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
                Image(systemName: "ellipsis")
                    // A glyph centred in a fixed hit box, matched to the search
                    // field's height: the size belongs to the box.
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("刷新与清空历史")
            .accessibilityLabel("历史选项")
        }
        .frame(maxWidth: SpeakerSurfaceMetrics.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
        .padding(.vertical, 10)
        // Opaque, because the list scrolls under it.
        .background(Color.historyGround)
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
            LazyVStack(
                alignment: .leading,
                spacing: HistoryRecordRow.spacing,
                pinnedViews: [.sectionHeaders]
            ) {
                ForEach(sections, id: \.day) { section in
                    Section {
                        ForEach(section.records, id: \.sessionID) { record in
                            row(for: record)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .frame(maxWidth: SpeakerSurfaceMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
            .padding(.bottom, SpeakerSurfaceMetrics.pageBottomPadding)
        }
    }

    /// The day heading stays pinned while its own records scroll, so a long
    /// day never loses its date. Its ground is opaque for the same reason.
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
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .background(Color.historyGround)
    }

    private func row(for record: VoiceInputHistoryRecord) -> some View {
        HistoryRecordRow(
            record: record,
            presentation: HistoryPresentation.row(for: record),
            isExpanded: expandedRecordID == record.sessionID,
            isBusy: state.isBusy,
            reduceMotion: reduceMotion,
            copy: { actions.copy(record) },
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

    /// The status line reads as a tinted banner on the ground rather than a
    /// strip behind a rule, so the tab carries no horizontal lines at all.
    @ViewBuilder
    private var statusFooter: some View {
        if let footer {
            Label(footer.message, systemImage: footer.icon)
                .font(SpeakerTypography.caption)
                .foregroundStyle(footer.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    footer.color.opacity(0.10),
                    in: RoundedRectangle(
                        cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
                        style: .continuous
                    )
                )
                .frame(maxWidth: SpeakerSurfaceMetrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
                .padding(.vertical, 10)
                .background(Color.historyGround)
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

extension Color {
    /// The ground every other tab reaches through `SpeakerPage`. The search
    /// bar, the pinned day headings, and the status line each paint it, so the
    /// list scrolls under them and still reads as one surface.
    fileprivate static let historyGround = Color(nsColor: .windowBackgroundColor)
}

private struct HistoryRecordRow: View {
    let record: VoiceInputHistoryRecord
    let presentation: HistoryRecordRowPresentation
    let isExpanded: Bool
    let isBusy: Bool
    let reduceMotion: Bool
    let copy: () -> Void
    let toggleDetails: () -> Void
    let delete: () -> Void
    @State private var pointerIsInside = false
    @State private var confirmsDelete = false
    #if DEBUG
        @Environment(\.historyHoveredRecordOverride) private var hoverOverride
        @Environment(\.historyRowFrameObserver) private var frameObserver
    #endif
    @Environment(\.colorSchemeContrast) private var contrast

    /// The gap between two rows. Rows carry no rule between them: the hover
    /// fill is what tells the pointer which record it is on.
    static let spacing: CGFloat = 2

    /// A collapsed row shows at most two lines. It does not reserve them: the
    /// action cluster holds its width whether or not it is visible, so the
    /// text column never resizes and a row's line count never changes under
    /// the pointer.
    private static let collapsedLineLimit = 2

    private var isHovered: Bool {
        #if DEBUG
            if let hoverOverride { return hoverOverride == record.sessionID }
        #endif
        return pointerIsInside
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

                if let problem = presentation.problem {
                    Image(systemName: problem.icon)
                        .font(SpeakerTypography.body)
                        .foregroundStyle(problem.color)
                        .padding(.top, 2)
                        .help(problem.label)
                        .accessibilityLabel(problem.label)
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
                    presentation: presentation
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(shape.fill(Color.primary.opacity(fillOpacity)))
        // Nothing rules one record off from the next, so Increase Contrast
        // gets the boundary back as a border around each record.
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            }
        }
        #if DEBUG
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                frameObserver?(record.sessionID, frame)
            }
        #endif
        .onHover { pointerIsInside = $0 }
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

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    private var fillOpacity: Double {
        let increased = contrast == .increased
        if isExpanded { return increased ? 0.12 : 0.06 }
        if isHovered { return increased ? 0.09 : 0.04 }
        return 0
    }

    @ViewBuilder
    private var recordText: some View {
        if isExpanded {
            HStack(spacing: 8) {
                Text(presentation.canCopy ? (record.refinementModeName ?? "默认顺滑") : "错误详情")
                    .font(SpeakerTypography.bodyEmphasis)
                Image(systemName: "chevron.up")
                    .font(SpeakerTypography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(presentation.previewText)
                .font(SpeakerTypography.body)
                .lineSpacing(2)
                .lineLimit(Self.collapsedLineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The cluster reserves both dimensions when its buttons are hidden, so the
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
        .frame(
            width: HistoryRowActionButton.clusterWidth,
            height: HistoryRowActionButton.side,
            alignment: .trailing
        )
    }
}

/// One icon button in a record row, with its own hover fill so the pointer
/// lands on something that answers back.
private struct HistoryRowActionButton: View {
    static let spacing: CGFloat = 2
    static let side: CGFloat = 24
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

package struct HistoryExpandedRecord: View {
    private let record: VoiceInputHistoryRecord
    private let presentation: HistoryRecordRowPresentation

    package init(record: VoiceInputHistoryRecord, presentation: HistoryRecordRowPresentation) {
        self.record = record
        self.presentation = presentation
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let problem = presentation.problem {
                    Label(problem.label, systemImage: problem.icon)
                        .font(SpeakerTypography.footnote.weight(.medium))
                        .foregroundStyle(problem.color)
                }
                Text(metadataLine)
                    .font(SpeakerTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.canCopy {
                Text(presentation.text)
                    .font(SpeakerTypography.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if case .failed(let failure) = presentation.problem {
                Text(failure.userGuidance)
                    .font(SpeakerTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let transcription = record.transcription,
                !transcription.isEmpty, transcription != presentation.text
            {
                stageResult(title: "豆包转录", text: transcription)
            }

            if let refinement = record.deepSeekText,
                !refinement.isEmpty, refinement != presentation.text,
                refinement != record.transcription
            {
                stageResult(title: "\(record.refinementProviderLabel) 整理", text: refinement)
            }

            if !diagnosticLines.isEmpty {
                DisclosureGroup("诊断信息") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(diagnosticLines, id: \.self) { line in
                            diagnosticText(line)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .textSelection(.enabled)
                }
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    private func stageResult(title: String, text: String) -> some View {
        DisclosureGroup(title) {
            Text(text)
                .font(SpeakerTypography.body)
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .textSelection(.enabled)
        }
        .font(SpeakerTypography.footnote)
        .foregroundStyle(.secondary)
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
                    label: "\(record.refinementProviderLabel) 请求 ID：",
                    identifier: deepSeekRequestID
                )
            )
        }
        if let code = record.providerErrorCode {
            lines.append(DiagnosticLine(label: "语音识别错误：", identifier: code))
        }
        if let code = record.refinementFailureCode {
            lines.append(DiagnosticLine(label: "文字整理错误：", identifier: code))
        }
        return lines
    }

    private var metadataLine: String {
        [
            record.startedAt.formatted(date: .abbreviated, time: .shortened),
            record.refinementModelID.map { "\(record.refinementProviderLabel) · \($0)" },
            Self.durationText(milliseconds: record.durationMilliseconds),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// The metadata line reads in seconds; stage diagnostics keep raw ms.
    private static func durationText(milliseconds: Int) -> String {
        String(format: "%.1f 秒", Double(max(0, milliseconds)) / 1_000)
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
