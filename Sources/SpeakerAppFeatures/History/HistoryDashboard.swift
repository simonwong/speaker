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
    package let isRedeliveryArmed: Bool
    package let retentionPolicy: HistoryRetentionPolicy
    package let isUpdatingRetention: Bool

    package init(
        records: [VoiceInputHistoryRecord],
        totalRecordCount: Int,
        notice: String?,
        feedback: HistoryDashboardFeedback?,
        isBusy: Bool,
        isRedeliveryArmed: Bool,
        retentionPolicy: HistoryRetentionPolicy,
        isUpdatingRetention: Bool
    ) {
        self.records = records
        self.totalRecordCount = totalRecordCount
        self.notice = notice
        self.feedback = feedback
        self.isBusy = isBusy
        self.isRedeliveryArmed = isRedeliveryArmed
        self.retentionPolicy = retentionPolicy
        self.isUpdatingRetention = isUpdatingRetention
    }
}

package struct HistoryDashboardActions {
    package let refresh: () -> Void
    package let setRetentionPolicy: (HistoryRetentionPolicy) -> Void
    package let clear: () -> Void
    package let copy: (VoiceInputHistoryRecord) -> Void
    package let toggleRedelivery: (VoiceInputHistoryRecord) -> Void
    package let delete: (VoiceInputSessionID) -> Void

    package init(
        refresh: @escaping () -> Void,
        setRetentionPolicy: @escaping (HistoryRetentionPolicy) -> Void,
        clear: @escaping () -> Void,
        copy: @escaping (VoiceInputHistoryRecord) -> Void,
        toggleRedelivery: @escaping (VoiceInputHistoryRecord) -> Void,
        delete: @escaping (VoiceInputSessionID) -> Void
    ) {
        self.refresh = refresh
        self.setRetentionPolicy = setRetentionPolicy
        self.clear = clear
        self.copy = copy
        self.toggleRedelivery = toggleRedelivery
        self.delete = delete
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
                TextField("搜索历史记录…", text: $query)
                    .textFieldStyle(.plain)
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
            .frame(height: 32)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
            }

            Menu {
                Button("刷新", systemImage: "arrow.clockwise", action: actions.refresh)
                Picker(
                    "保留历史",
                    selection: Binding(
                        get: { state.retentionPolicy },
                        set: { policy in
                            actions.setRetentionPolicy(policy)
                        }
                    )
                ) {
                    ForEach(HistoryRetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .disabled(state.isUpdatingRetention)
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
            .help("刷新、保留与清空历史")
            .accessibilityLabel("历史选项")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
                    ? "完成第一次语音输入后，会话记录会显示在这里。"
                    : "尝试缩短关键词，或清空搜索后查看全部记录。"
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.day) { section in
                    Text(section.title)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                        .padding(.horizontal, 10)

                    ForEach(
                        Array(section.records.enumerated()),
                        id: \.element.sessionID
                    ) { index, record in
                        HistoryRecordRow(
                            record: record,
                            isExpanded: expandedRecordID == record.sessionID,
                            isBusy: state.isBusy,
                            isRedeliveryArmed: state.isRedeliveryArmed,
                            reduceMotion: reduceMotion,
                            copy: { actions.copy(record) },
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
                            toggleRedelivery: {
                                actions.toggleRedelivery(record)
                            },
                            delete: {
                                actions.delete(record.sessionID)
                            }
                        )

                        if index < section.records.count - 1 {
                            Divider()
                                .opacity(0.45)
                                .padding(.leading, 72)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
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
            .font(.caption)
            .foregroundStyle(feedback.kind.color)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(feedback.message)
        } else if let notice = state.notice {
            Divider()
            Label(
                notice,
                systemImage: state.isRedeliveryArmed
                    ? "arrow.up.forward.app.fill"
                    : "exclamationmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(state.isRedeliveryArmed ? Color.secondary : .red)
            .padding(8)
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
    let isRedeliveryArmed: Bool
    let reduceMotion: Bool
    let copy: () -> Void
    let toggleDetails: () -> Void
    let toggleRedelivery: () -> Void
    let delete: () -> Void
    @State private var isHovered = false
    @FocusState private var actionsFocused: Bool

    private var presentation: HistoryRecordRowPresentation {
        HistoryPresentation.row(for: record)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(presentation.time)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)

                Text(presentation.applicationName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Color.primary.opacity(0.065),
                        in: Capsule()
                    )

                Text(presentation.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(
                        presentation.canCopy ? Color.primary : .secondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if presentation.canCopy {
                        Button("复制", action: copy)
                            .disabled(isBusy)
                            .focused($actionsFocused)
                            .accessibilityHint("复制这条会话记录的最终文字")
                    }
                    Button(isExpanded ? "收起" : "详情", action: toggleDetails)
                        .focused($actionsFocused)
                        .accessibilityHint(
                            isExpanded
                                ? "收起这条 Session Record 的完整信息"
                                : "在本行下方展开完整信息"
                        )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .opacity(isHovered || isExpanded || actionsFocused ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: isHovered
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(
                Color.primary.opacity(isHovered || isExpanded ? 0.045 : 0),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .onHover { isHovered = $0 }

            if isExpanded {
                HistoryExpandedRecord(
                    record: record,
                    presentation: presentation,
                    isRedeliveryArmed: isRedeliveryArmed,
                    isBusy: isBusy,
                    copy: copy,
                    redeliver: toggleRedelivery,
                    delete: delete
                )
                .padding(.leading, 64)
                .padding(.trailing, 10)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct HistoryExpandedRecord: View {
    let record: VoiceInputHistoryRecord
    let presentation: HistoryRecordRowPresentation
    let isRedeliveryArmed: Bool
    let isBusy: Bool
    let copy: () -> Void
    let redeliver: () -> Void
    let delete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(record.outcome.historyLabel, systemImage: record.outcome.icon)
                    .font(.headline)
                Spacer()
                Text(record.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HistoryTextBlock(
                title: "完整文字",
                text: presentation.text,
                isPlaceholder: !presentation.canCopy
            )

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                metadataRow("来源", presentation.applicationName)
                metadataRow("结果", record.outcome.historyLabel)
                metadataRow("整理模式", record.refinementModeName ?? "默认顺滑")
                metadataRow("总耗时", "\(record.durationMilliseconds) ms")
                if !record.stageDurationsMilliseconds.isEmpty {
                    metadataRow(
                        "阶段耗时",
                        record.stageDurationsMilliseconds
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key) \($0.value) ms" }
                            .joined(separator: " · ")
                    )
                }
            }

            if record.refinementStatus == "fellBack" {
                Label(
                    "进一步整理未完成，已保留豆包结果",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            DisclosureGroup("查看处理过程") {
                VStack(alignment: .leading, spacing: 12) {
                    HistoryTextBlock(
                        title: "豆包转录",
                        text: record.transcription ?? "无",
                        isPlaceholder: record.transcription == nil
                    )
                    if record.deepSeekText != nil
                        || record.refinementStatus != nil
                    {
                        HistoryTextBlock(
                            title: "DeepSeek 整理",
                            text: record.deepSeekText ?? "无",
                            isPlaceholder: record.deepSeekText == nil
                        )
                    }
                }
                .padding(.top, 8)
            }

            DisclosureGroup("技术详情") {
                VStack(alignment: .leading, spacing: 9) {
                    technicalDetails
                }
                .padding(.top, 8)
            }

            HStack {
                if presentation.canCopy {
                    Button("复制文字", action: copy)
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                        .accessibilityHint("复制最终文字到剪贴板")
                    Button(
                        isRedeliveryArmed
                            ? "取消重新输入"
                            : "重新输入到光标处",
                        action: redeliver
                    )
                    .disabled(isBusy)
                }
                Spacer()
                Button("删除…", role: .destructive) {
                    confirmsDelete = true
                }
                .disabled(isBusy)
            }
        }
        .padding(16)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .textSelection(.enabled)
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

    private func metadataRow(
        _ label: String,
        _ value: String
    ) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var technicalDetails: some View {
        if let refinementPrompt = record.refinementPrompt {
            HistoryTextBlock(
                title: "整理提示词快照",
                text: refinementPrompt,
                isPlaceholder: false
            )
        }
        if !record.dictionarySnapshotEntries.isEmpty {
            Text("词库快照").font(.headline)
            ForEach(record.dictionarySnapshotEntries) { entry in
                Text(
                    entry.aliases.isEmpty
                        ? entry.canonicalTerm
                        : "\(entry.canonicalTerm) ← \(entry.aliases.joined(separator: "、"))"
                )
            }
            if let context = record.dictionaryRequestContext {
                LabeledContent("发送词数", value: "\(context.hotwords.count)")
                LabeledContent("省略词数", value: "\(context.omissions.count)")
            }
        }
        if !record.dictionaryReplacements.isEmpty {
            Text("词库替换").font(.headline)
            ForEach(record.dictionaryReplacements, id: \.utf16Location) { replacement in
                Text("\(replacement.matchedText) → \(replacement.canonicalTerm)")
            }
        }
        if let providerRequestID = record.providerRequestID {
            LabeledContent(
                "\(record.transcriptionProvider ?? "转录提供商") 请求 ID",
                value: providerRequestID
            )
        }
        if let providerOperation = record.providerOperation {
            LabeledContent("问题发生阶段", value: providerOperation)
        }
        if let providerErrorCode = record.providerErrorCode {
            LabeledContent("服务错误代码", value: providerErrorCode)
        }
        if let providerStatusCode = record.providerStatusCode {
            LabeledContent("服务状态码", value: providerStatusCode)
        }
        if let deliveryDiagnosticCode = record.deliveryDiagnosticCode {
            LabeledContent("送达诊断", value: deliveryDiagnosticCode)
        }
        if let deepSeekRequestID = record.deepSeekRequestID {
            LabeledContent("DeepSeek 请求 ID", value: deepSeekRequestID)
        }
        if let refinementFailureCode = record.refinementFailureCode {
            LabeledContent("DeepSeek 错误代码", value: refinementFailureCode)
        }
        if let statusCode = record.refinementFailureStatusCode {
            LabeledContent("DeepSeek 状态码", value: statusCode)
        }
        if let cancelledAtStage = record.cancelledAtStage {
            LabeledContent("取消时阶段", value: cancelledAtStage)
        }
    }
}

private struct HistoryTextBlock: View {
    let title: String
    let text: String
    let isPlaceholder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }
}

private extension HistoryRetentionPolicy {
    var displayName: String {
        switch self {
        case .thirtyDays: "最近 30 天"
        case .ninetyDays: "最近 90 天"
        case .oneYear: "最近一年"
        case .forever: "不按日期清理"
        }
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
