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
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
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
    let reduceMotion: Bool
    let copy: () -> Void
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
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                    .padding(.top, 2)

                Text(presentation.text)
                    .font(.system(size: 12.5))
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
                            }
                            .disabled(isBusy)
                            .help("复制")
                            .accessibilityLabel("复制")
                        }
                        Button {
                            confirmsDelete = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(isBusy)
                        .help("删除")
                        .accessibilityLabel("删除")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: toggleDetails)

            if isExpanded {
                HistoryExpandedRecord(
                    record: record,
                    presentation: presentation
                )
                .padding(.top, 2)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            Color.primary.opacity(isHovered || isExpanded ? 0.045 : 0),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    presentation.status.label,
                    systemImage: presentation.status.icon
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(presentation.status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    presentation.status.color.opacity(0.12),
                    in: Capsule()
                )
                Text(metadataLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HistoryTextBlock(
                title: "豆包转录",
                text: record.transcription ?? "无",
                isPlaceholder: record.transcription == nil
            )

            if showsRefinementBlock {
                HistoryTextBlock(
                    title: "DeepSeek 整理",
                    text: record.deepSeekText ?? "无",
                    isPlaceholder: record.deepSeekText == nil
                )
            }

            if !record.stageDurationsMilliseconds.isEmpty {
                Text("阶段耗时：\(stageDurationsLine)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let diagnosticsLine {
                Text(diagnosticsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .textSelection(.enabled)
    }

    private var metadataLine: String {
        [
            record.startedAt.formatted(date: .abbreviated, time: .shortened),
            record.refinementModeName ?? "默认顺滑",
            "\(record.durationMilliseconds) ms",
        ].joined(separator: " · ")
    }

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

    private var diagnosticsLine: String? {
        var parts: [String] = []
        if let providerRequestID = record.providerRequestID {
            parts.append(
                "\(record.transcriptionProvider ?? "转录提供商") 请求 ID：\(providerRequestID)"
            )
        }
        if let deepSeekRequestID = record.deepSeekRequestID {
            parts.append("DeepSeek 请求 ID：\(deepSeekRequestID)")
        }
        if let deliveryDiagnosticCode = record.deliveryDiagnosticCode {
            parts.append("送达诊断：\(deliveryDiagnosticCode)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
