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
    package let copyRecognition: (VoiceInputHistoryRecord) -> Void
    package let delete: (VoiceInputSessionID) -> Void

    package init(
        refresh: @escaping () -> Void,
        clear: @escaping () -> Void,
        copy: @escaping (VoiceInputHistoryRecord) -> Void,
        copyRecognition: @escaping (VoiceInputHistoryRecord) -> Void = { _ in },
        delete: @escaping (VoiceInputSessionID) -> Void
    ) {
        self.refresh = refresh
        self.clear = clear
        self.copy = copy
        self.copyRecognition = copyRecognition
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
    private let focusesSearch: Bool
    private let searchFocused: () -> Void
    @State private var expandedRecordID: VoiceInputSessionID?
    @State private var confirmsClear = false
    @State private var searchRefresh: Task<Void, Never>?
    @FocusState private var searchIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(
        state: HistoryDashboardState,
        query: Binding<String>,
        actions: HistoryDashboardActions,
        focusesSearch: Bool = false,
        searchFocused: @escaping () -> Void = {}
    ) {
        self.state = state
        self.sections = state.sections()
        _query = query
        self.actions = actions
        self.focusesSearch = focusesSearch
        self.searchFocused = searchFocused
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
            // ⌘F may arrive from another page; the field exists only once
            // this page is shown, so the request waits here until then.
            .task(id: focusesSearch) {
                guard focusesSearch else { return }
                searchIsFocused = true
                searchFocused()
            }
            .onChange(of: state.records.map(\.sessionID)) { _, ids in
                if let expandedRecordID, !ids.contains(expandedRecordID) {
                    self.expandedRecordID = nil
                }
            }
            .confirmationDialog(
                "清空所有历史记录？",
                isPresented: $confirmsClear,
                titleVisibility: .visible
            ) {
                Button("清空历史", role: .destructive, action: actions.clear)
                Button("取消", role: .cancel) {}
            } message: {
                Text("无法撤销。概览的累计数字会保留。")
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
        HStack(spacing: SpeakerSpacing.s) {
            HStack(spacing: SpeakerSpacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索历史…", text: $query)
                    .textFieldStyle(.plain)
                    .font(SpeakerTypography.body)
                    .focused($searchIsFocused)
                    .onSubmit(actions.refresh)
                    // Typing filters after a short pause, so a query cleared
                    // with the keyboard never leaves the list filtered.
                    .onChange(of: query) {
                        searchRefresh?.cancel()
                        searchRefresh = Task {
                            try? await Task.sleep(for: .milliseconds(200))
                            guard !Task.isCancelled else { return }
                            actions.refresh()
                        }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        actions.refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("清空搜索")
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, SpeakerSpacing.m)
            .frame(height: SpeakerControlMetrics.height)
            .speakerField(focused: searchIsFocused)

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
                    // field's height, like an icon button.
                    .font(SpeakerTypography.emphasis)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: SpeakerControlMetrics.height,
                        height: SpeakerControlMetrics.height
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("刷新与清空历史")
            .accessibilityLabel("历史选项")
        }
        .speakerPageColumn()
        // The field starts where every other tab's content starts.
        .padding(.top, SpeakerSurfaceMetrics.pageTopPadding)
        .padding(.bottom, SpeakerSpacing.s)
        // Opaque, because the list scrolls under it.
        .background(Color.historyGround)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyState: some View {
        SpeakerEmptyState(
            title: isSearching ? "没有匹配的历史记录" : "还没有历史记录",
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
            .speakerPageColumn()
            .padding(.bottom, SpeakerSurfaceMetrics.pageBottomPadding)
        }
    }

    /// The day heading stays pinned while its own records scroll, so a long
    /// day never loses its date. Its ground is opaque for the same reason.
    /// Inset by the row padding, so the date lines up with the time column.
    private func sectionHeader(_ section: HistoryDaySection) -> some View {
        Text(section.title)
            .font(SpeakerTypography.label)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpeakerSpacing.s)
            .padding(.top, SpeakerSpacing.l)
            .padding(.bottom, SpeakerSpacing.s)
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
            copyRecognition: { actions.copyRecognition(record) },
            toggleDetails: {
                withAnimation(reduceMotion ? nil : SpeakerMotion.change) {
                    expandedRecordID =
                        expandedRecordID == record.sessionID
                        ? nil
                        : record.sessionID
                }
            },
            delete: { actions.delete(record.sessionID) }
        )
    }

    /// The status line reads as a tinted notice on the ground rather than a
    /// strip behind a rule, so the tab carries no horizontal lines at all.
    @ViewBuilder
    private var statusFooter: some View {
        if let footer {
            SpeakerNotice(tone: footer.tone, text: footer.message)
                .speakerPageColumn()
                .padding(.vertical, SpeakerSpacing.s)
                .background(Color.historyGround)
                .accessibilityLabel(footer.message)
        }
    }

    /// Transient feedback outranks the persistent store notice.
    private var footer: HistoryFooterLine? {
        if let feedback = state.feedback {
            return HistoryFooterLine(message: feedback.message, tone: feedback.kind.tone)
        }
        if let notice = state.notice {
            return HistoryFooterLine(message: notice, tone: .error)
        }
        return nil
    }
}

/// The one line the tab can print under the list: whichever of the transient
/// feedback and the persistent store notice is showing.
private struct HistoryFooterLine {
    let message: String
    let tone: SpeakerTone
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
    let copyRecognition: () -> Void
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
    static let spacing = SpeakerSpacing.hairline

    /// Wide enough for "23:59" in the mono face.
    private static let timeColumnWidth: CGFloat = 44

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
            HStack(alignment: .top, spacing: SpeakerSpacing.m) {
                // A real button, so the keyboard and VoiceOver can expand a
                // record and reach its actions, not only the pointer.
                Button(action: toggleDetails) {
                    HStack(alignment: .top, spacing: SpeakerSpacing.m) {
                        Text(presentation.time)
                            .font(SpeakerTypography.mono)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.timeColumnWidth, alignment: .leading)
                            .padding(.top, SpeakerSpacing.hairline)

                        recordText

                        if let problem = presentation.problem {
                            Image(systemName: problem.icon)
                                .font(SpeakerTypography.body)
                                .foregroundStyle(problem.tone.color)
                                .padding(.top, SpeakerSpacing.hairline)
                                .help(problem.label)
                                .accessibilityLabel(problem.label)
                        } else if let note = presentation.note {
                            Image(systemName: note.icon)
                                .font(SpeakerTypography.body)
                                .foregroundStyle(.secondary)
                                .padding(.top, SpeakerSpacing.hairline)
                                .help(note.label)
                                .accessibilityLabel(note.label)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
                .accessibilityActions {
                    if presentation.canCopy, !isBusy {
                        Button("复制", action: copy)
                    }
                    if !isBusy {
                        Button("删除") { confirmsDelete = true }
                    }
                }

                // The action cluster always occupies its width, whether or not
                // it is visible: revealing it must never reflow the text.
                rowActions
            }
            .padding(.horizontal, SpeakerSpacing.s)
            .padding(.vertical, SpeakerSpacing.s)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleDetails)

            if isExpanded {
                HistoryExpandedRecord(
                    record: record,
                    presentation: presentation
                )
                .padding(.horizontal, SpeakerSpacing.s)
                .padding(.bottom, SpeakerSpacing.m)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .background(shape.fill(fill))
        // Nothing rules one record off from the next, so Increase Contrast
        // gets the boundary back as a border around each record.
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(SpeakerStroke.hairline(increasedContrast: true), lineWidth: 1)
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
        .animation(reduceMotion ? nil : SpeakerMotion.feedback, value: isHovered)
        .contextMenu {
            if presentation.canCopy {
                Button("复制", action: copy).disabled(isBusy)
            }
            if HistoryPresentation.recognitionText(for: record) != nil {
                Button("复制整理前的识别结果", action: copyRecognition).disabled(isBusy)
            }
            Button("删除…", role: .destructive) { confirmsDelete = true }
                .disabled(isBusy)
        }
        .confirmationDialog(
            "删除这条历史记录？",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("删除记录", role: .destructive, action: delete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerRadius.inner,
            style: .continuous
        )
    }

    private var fill: Color {
        if isExpanded { return SpeakerFill.selected }
        if isHovered { return SpeakerFill.subtle }
        return .clear
    }

    @ViewBuilder
    private var recordText: some View {
        if isExpanded {
            HStack(spacing: SpeakerSpacing.s) {
                Text(presentation.canCopy ? (record.refinementModeName ?? "默认顺滑") : "错误详情")
                    .font(SpeakerTypography.emphasis)
                Image(systemName: "chevron.up")
                    .font(SpeakerTypography.detail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(presentation.previewText)
                .font(SpeakerTypography.body)
                .lineSpacing(SpeakerSpacing.hairline)
                .lineLimit(Self.collapsedLineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The cluster reserves both dimensions when its buttons are hidden, so the
    /// text column never resizes; the buttons themselves only exist while
    /// visible, staying out of the focus ring and the accessibility tree.
    private var rowActions: some View {
        HStack(spacing: Self.actionSpacing) {
            if showsActions {
                if presentation.canCopy {
                    SpeakerIconButton(symbol: "doc.on.doc", label: "复制", action: copy)
                }
                SpeakerIconButton(symbol: "trash", label: "删除") {
                    confirmsDelete = true
                }
            }
        }
        .disabled(isBusy)
        .frame(
            width: Self.actionClusterWidth,
            height: SpeakerControlMetrics.height,
            alignment: .trailing
        )
    }

    private static let actionSpacing = SpeakerSpacing.s
    /// Two icon buttons plus the gap: the width a row reserves for the cluster.
    private static let actionClusterWidth = SpeakerControlMetrics.height * 2 + actionSpacing
}

package struct HistoryExpandedRecord: View {
    private let record: VoiceInputHistoryRecord
    private let presentation: HistoryRecordRowPresentation

    package init(record: VoiceInputHistoryRecord, presentation: HistoryRecordRowPresentation) {
        self.record = record
        self.presentation = presentation
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: SpeakerSpacing.m) {
            Divider()

            VStack(alignment: .leading, spacing: SpeakerSpacing.xs) {
                if let problem = presentation.problem {
                    Label(problem.label, systemImage: problem.icon)
                        .font(SpeakerTypography.detail)
                        .foregroundStyle(problem.tone.color)
                } else if let note = presentation.note {
                    Label(note.label, systemImage: note.icon)
                        .font(SpeakerTypography.detail)
                        .foregroundStyle(.secondary)
                }
                Text(metadataLine)
                    .font(SpeakerTypography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.canCopy {
                Text(presentation.text)
                    .font(SpeakerTypography.body)
                    .lineSpacing(SpeakerSpacing.xs)
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
                stageResult(title: "\(record.transcriptionProviderLabel) 识别", text: transcription)
            }

            if let refinement = record.refinedText,
                !refinement.isEmpty, refinement != presentation.text,
                refinement != record.transcription
            {
                stageResult(title: "\(record.refinementProviderLabel) 整理", text: refinement)
            }

            if !diagnosticLines.isEmpty {
                DisclosureGroup("诊断信息") {
                    VStack(alignment: .leading, spacing: SpeakerSpacing.xs) {
                        ForEach(diagnosticLines, id: \.self) { line in
                            diagnosticText(line)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, SpeakerSpacing.s)
                    .textSelection(.enabled)
                }
                .font(SpeakerTypography.detail)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func stageResult(title: String, text: String) -> some View {
        DisclosureGroup(title) {
            Text(text)
                .font(SpeakerTypography.body)
                .foregroundStyle(.primary)
                .lineSpacing(SpeakerSpacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SpeakerSpacing.s)
                .textSelection(.enabled)
        }
        .font(SpeakerTypography.detail)
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
                    label: "\(record.transcriptionProviderLabel) 请求 ID：",
                    identifier: providerRequestID
                )
            )
        }
        if let refinementRequestID = record.refinementRequestID {
            lines.append(
                DiagnosticLine(
                    label: "\(record.refinementProviderLabel) 请求 ID：",
                    identifier: refinementRequestID
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
            record.transcriptionModelID.map { "\(record.transcriptionProviderLabel) · \($0)" },
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
    fileprivate var tone: SpeakerTone {
        switch self {
        case .information: .neutral
        case .success: .ok
        case .warning: .warning
        case .error: .error
        }
    }
}
