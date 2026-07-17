import AppKit
import Combine
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

struct HistoryFeedback: Equatable {
    enum Kind: Equatable {
        case information
        case success
        case warning
        case error
    }

    let id: UUID
    let kind: Kind
    let message: String
}

enum HistoryOperation: Equatable {
    case copying(VoiceInputSessionID)
    case deleting(VoiceInputSessionID)
    case clearing
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var records: [VoiceInputHistoryRecord] = []
    @Published private(set) var totalRecordCount = 0
    @Published var query = ""
    @Published private(set) var notice: String?
    @Published private(set) var feedback: HistoryFeedback?
    @Published private(set) var activeOperation: HistoryOperation?
    @Published private(set) var isRedeliveryArmed = false
    @Published private(set) var retentionPolicy: HistoryRetentionPolicy = .forever
    @Published private(set) var isUpdatingRetention = false

    let store: any LocalSessionHistoryStoring
    private let targets: AccessibilityInputTargets
    private let settingsStore: VersionedLocalAppSettingsStore
    private let clipboard: any ClipboardWriting
    private let announce: (String) -> Void
    private let interactionRouter: GlobalVoiceInteractionRouter
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var confirmationClickMonitor: Any?
    private var feedbackTask: Task<Void, Never>?
    private var redeliveryID: UUID?
    private var redeliveryCommitGate: DeliveryCommitGate?
    private var redeliveryTarget = HistoryRedeliveryTargetState()
    private var pendingConfirmationProcessID: Int32?

    init(
        store: any LocalSessionHistoryStoring,
        targets: AccessibilityInputTargets,
        settingsStore: VersionedLocalAppSettingsStore,
        clipboard: any ClipboardWriting,
        announce: @escaping (String) -> Void,
        interactionRouter: GlobalVoiceInteractionRouter
    ) {
        self.store = store
        self.targets = targets
        self.settingsStore = settingsStore
        self.clipboard = clipboard
        self.announce = announce
        self.interactionRouter = interactionRouter
    }

    func refresh() async {
        records = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? await store.allRecords()
            : await store.search(query)
        let status = await store.persistenceStatus()
        totalRecordCount = status.recordCount
        retentionPolicy = await store.currentRetentionPolicy()
        switch status.notice {
        case let .corruptedDataPreserved(_, reason): notice = "已保留损坏的历史文件：\(reason)"
        case let .corruptedRecordsSkipped(count): notice = "有 \(count) 条历史记录已损坏，已跳过；其他记录仍可使用。"
        case let .privacyMigrationFailed(reason): notice = "旧版历史隐私清理未完成：\(reason)"
        case let .writeFailed(reason): notice = "历史写入失败：\(reason)"
        case nil:
            if !isRedeliveryArmed {
                notice = nil
            }
        }
    }

    @discardableResult
    func copy(_ record: VoiceInputHistoryRecord) async -> Bool {
        guard activeOperation == nil,
              let text = record.finalText ?? record.transcription,
              !text.isEmpty
        else { return false }
        activeOperation = .copying(record.sessionID)
        defer { activeOperation = nil }
        guard await clipboard.copy(text) else {
            publishFeedback(
                .error,
                "无法写入剪贴板，请重试。"
            )
            return false
        }
        publishFeedback(.success, "文字已复制")
        return true
    }

    @discardableResult
    func delete(_ id: VoiceInputSessionID) async -> Bool {
        guard activeOperation == nil else { return false }
        activeOperation = .deleting(id)
        defer { activeOperation = nil }
        guard await store.delete(sessionID: id) else {
            publishFeedback(
                .error,
                "无法删除这条会话记录，请重试。"
            )
            await refresh()
            return false
        }
        await refresh()
        publishFeedback(.success, "会话记录已删除")
        return true
    }

    @discardableResult
    func clear() async -> Bool {
        guard activeOperation == nil else { return false }
        let deletedCount = totalRecordCount
        activeOperation = .clearing
        defer { activeOperation = nil }
        guard await store.clear() else {
            publishFeedback(
                .error,
                "无法清空会话历史，请检查本地存储后重试。"
            )
            await refresh()
            return false
        }
        await refresh()
        publishFeedback(
            .success,
            "已清空 \(deletedCount) 条会话记录"
        )
        return true
    }

    func setRetentionPolicy(_ policy: HistoryRetentionPolicy) async {
        guard policy != retentionPolicy, !isUpdatingRetention else { return }
        isUpdatingRetention = true
        defer { isUpdatingRetention = false }
        do {
            try await settingsStore.updateHistoryRetention(policy)
            retentionPolicy = policy
            guard await store.applyRetentionPolicy(policy, now: Date()) else {
                notice = "保留设置已保存，但旧记录尚未完成清理；Speaker 会在后续写入或下次启动时重试。"
                publishFeedback(
                    .warning,
                    notice ?? "历史清理尚未完成。"
                )
                return
            }
            await refresh()
        } catch {
            notice = error.localizedDescription
            publishFeedback(.error, "无法保存历史保留设置，请重试。")
        }
    }

    func redeliver(_ record: VoiceInputHistoryRecord) async {
        guard let text = record.finalText ?? record.transcription, !text.isEmpty else {
            notice = "这条记录没有可重新送达的文本。"
            return
        }
        cancelRedelivery()
        let redeliveryID = UUID()
        self.redeliveryID = redeliveryID
        redeliveryTarget.reset()
        pendingConfirmationProcessID = nil
        isRedeliveryArmed = true
        notice = "切换到目标 App，聚焦输入框后再次按语音快捷键；也可以直接点击输入位置。"
        announce("重新输入已准备。切换到目标应用，聚焦输入框后再次按语音快捷键；按 Esc 取消。")
        guard interactionRouter.beginExclusiveInteraction(
            confirm: { [weak self] in
                guard let self else { return false }
                guard let expectedProcessID =
                        self.consumeConfirmationProcessID()
                else {
                    self.notice = "请先切换到目标 App 并聚焦输入框，再次按语音快捷键确认。"
                    return false
                }
                return await self.completeRedelivery(
                    text,
                    redeliveryID: redeliveryID,
                    expectedProcessID: expectedProcessID
                )
            },
            cancel: { [weak self] in
                self?.cancelRedeliveryFromRouter(announceResult: true)
            }
        ) else {
            self.redeliveryID = nil
            isRedeliveryArmed = false
            publishFeedback(
                .warning,
                "请先结束或取消当前语音输入，再重新输入历史文字。"
            )
            return
        }
        observeTargetApplication()
        observeExplicitInputClick()
    }

    private func observeTargetApplication() {
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRedeliveryArmed else { return }
                self.observeActivatedApplication(application)
            }
        }
        terminationObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRedeliveryArmed else { return }
                let removed = self.redeliveryTarget.terminated(
                    processIdentifier: application.processIdentifier
                )
                if removed {
                    self.notice = "目标 App 已退出。请切换到其他 App 并聚焦输入框；按 Esc 取消。"
                }
            }
        }
        synchronizeTargetWithFrontmostApplication()
    }

    private func observeExplicitInputClick() {
        confirmationClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            let eventType = event.type
            Task { @MainActor [weak self] in
                guard let self,
                      self.isRedeliveryArmed
                else { return }
                await Task.yield()
                self.synchronizeTargetWithFrontmostApplication()
                let frontmostProcessIdentifier = NSWorkspace.shared
                    .frontmostApplication?.processIdentifier
                switch eventType {
                case .leftMouseDown:
                    self.redeliveryTarget.mouseDown(
                        frontmostProcessIdentifier: frontmostProcessIdentifier
                    )
                case .leftMouseUp:
                    guard let processIdentifier =
                            self.redeliveryTarget.mouseUp(
                                frontmostProcessIdentifier:
                                    frontmostProcessIdentifier
                            )
                    else { return }
                    self.pendingConfirmationProcessID = processIdentifier
                    let started = self.interactionRouter
                        .confirmExclusiveInteraction()
                    if !started,
                       self.pendingConfirmationProcessID == processIdentifier
                    {
                        self.pendingConfirmationProcessID = nil
                    }
                default:
                    break
                }
            }
        }
        if confirmationClickMonitor == nil {
            notice = "无法监听鼠标点击；仍可聚焦输入框后再次按语音快捷键确认。"
            publishFeedback(.warning, notice ?? "鼠标确认不可用。")
        }
    }

    func cancelRedelivery() {
        guard isRedeliveryArmed
            || activationObserver != nil
            || terminationObserver != nil
            || confirmationClickMonitor != nil
        else { return }
        interactionRouter.cancelExclusiveInteraction()
        if isRedeliveryArmed {
            cancelRedeliveryFromRouter(announceResult: true)
        }
    }

    private func cancelRedeliveryFromRouter(announceResult: Bool) {
        let wasActive = isRedeliveryArmed
        let commitGate = redeliveryCommitGate
        redeliveryCommitGate = nil
        redeliveryID = nil
        pendingConfirmationProcessID = nil
        redeliveryTarget.reset()
        isRedeliveryArmed = false
        removeTargetApplicationObservers()
        removeConfirmationClickMonitor()
        notice = nil
        if let commitGate {
            Task { _ = await commitGate.cancel() }
        }
        if wasActive, announceResult {
            publishFeedback(.information, "重新输入已取消")
        }
    }

    func shutdown() {
        interactionRouter.cancelExclusiveInteraction()
        if isRedeliveryArmed
            || activationObserver != nil
            || terminationObserver != nil
            || confirmationClickMonitor != nil
        {
            cancelRedeliveryFromRouter(announceResult: false)
        }
    }

    private func removeConfirmationClickMonitor() {
        if let confirmationClickMonitor {
            NSEvent.removeMonitor(confirmationClickMonitor)
        }
        confirmationClickMonitor = nil
    }

    private func completeRedelivery(
        _ text: String,
        redeliveryID: UUID,
        expectedProcessID: Int32
    ) async -> Bool {
        guard isRedeliveryArmed,
              self.redeliveryID == redeliveryID
        else { return false }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == expectedProcessID,
              !isSpeaker(application)
        else {
            synchronizeTargetWithFrontmostApplication()
            notice = "目标 App 已发生变化。请聚焦新的输入位置后再次确认。"
            return false
        }

        notice = "正在重新输入到 \(application.localizedName ?? "目标 App")…"
        let commitGate = DeliveryCommitGate()
        redeliveryCommitGate = commitGate
        let target = await targets.capture(
            expectedProcessID: expectedProcessID
        )
        guard isRedeliveryArmed,
              self.redeliveryID == redeliveryID
        else {
            _ = await commitGate.cancel()
            return true
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == expectedProcessID
        else {
            if case let .writable(snapshot) = target {
                await targets.discard(snapshot)
            }
            _ = await commitGate.cancel()
            redeliveryCommitGate = nil
            synchronizeTargetWithFrontmostApplication()
            notice = "目标 App 已发生变化。请聚焦新的输入位置后再次确认。"
            return false
        }
        removeTargetApplicationObservers()
        removeConfirmationClickMonitor()
        switch target {
        case let .writable(snapshot):
            let outcome = await targets.deliver(
                text,
                to: snapshot,
                commitGate: commitGate
            )
            guard isRedeliveryArmed,
                  self.redeliveryID == redeliveryID
            else { return true }
            finishRedelivery()
            switch outcome {
            case .delivered:
                publishFeedback(.success, "文字已重新输入")
            case let .pendingCopy(reason),
                 let .pendingCopyDiagnosed(reason, _):
                publishFeedback(
                    .warning,
                    "\(reason.userTitle)，请使用“复制文字”。"
                )
            }
        case let .unavailable(reason):
            finishRedelivery()
            publishFeedback(
                .warning,
                "\(reason.userTitle)，请使用“复制文字”。"
            )
        }
        return true
    }

    private func finishRedelivery() {
        redeliveryCommitGate = nil
        redeliveryID = nil
        pendingConfirmationProcessID = nil
        redeliveryTarget.reset()
        isRedeliveryArmed = false
        notice = nil
        removeTargetApplicationObservers()
        removeConfirmationClickMonitor()
    }

    private func consumeConfirmationProcessID() -> Int32? {
        if let pendingConfirmationProcessID {
            self.pendingConfirmationProcessID = nil
            return pendingConfirmationProcessID
        }
        synchronizeTargetWithFrontmostApplication()
        return redeliveryTarget.shortcutConfirmation(
            frontmostProcessIdentifier: NSWorkspace.shared
                .frontmostApplication?.processIdentifier
        )
    }

    private func synchronizeTargetWithFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            redeliveryTarget.reset()
            return
        }
        observeActivatedApplication(application)
    }

    private func observeActivatedApplication(
        _ application: NSRunningApplication
    ) {
        redeliveryTarget.activated(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName,
            isSpeaker: isSpeaker(application)
        )
        if let candidate = redeliveryTarget.candidate {
            notice = "已切换到 \(candidate.applicationName)。聚焦输入框后再次按语音快捷键，或直接点击输入位置。"
        } else {
            notice = "切换到目标 App，聚焦输入框后再次按语音快捷键；按 Esc 取消。"
        }
    }

    private func isSpeaker(_ application: NSRunningApplication) -> Bool {
        if application.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        {
            return true
        }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        return application.bundleIdentifier == bundleIdentifier
    }

    private func removeTargetApplicationObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let activationObserver {
            center.removeObserver(activationObserver)
        }
        if let terminationObserver {
            center.removeObserver(terminationObserver)
        }
        activationObserver = nil
        terminationObserver = nil
    }

    private func publishFeedback(
        _ kind: HistoryFeedback.Kind,
        _ message: String
    ) {
        let feedback = HistoryFeedback(
            id: UUID(),
            kind: kind,
            message: message
        )
        self.feedback = feedback
        announce(message)
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled,
                  self?.feedback?.id == feedback.id
            else { return }
            self?.feedback = nil
        }
    }

}


struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var selection: VoiceInputSessionID?
    @State private var confirmsClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索文字或应用", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.refresh() } }
                Button("搜索") { Task { await model.refresh() } }
                Button("刷新") { Task { await model.refresh() } }
                Picker("保留", selection: Binding(
                    get: { model.retentionPolicy },
                    set: { policy in
                        Task { await model.setRetentionPolicy(policy) }
                    }
                )) {
                    ForEach(HistoryRetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 145)
                .disabled(model.isUpdatingRetention)
                .help("所有选项最多保留 10000 条，防止本地文件无限增长。")
                Button("全部清空", role: .destructive) {
                    confirmsClear = true
                }
                .disabled(model.totalRecordCount == 0)
            }
            .padding(12)

            Divider()

            if model.records.isEmpty {
                ContentUnavailableView(
                    model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "还没有会话记录"
                        : "没有找到匹配记录",
                    systemImage: model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "clock.arrow.circlepath"
                        : "magnifyingglass",
                    description: Text(
                        model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "完成第一次语音输入后，豆包与可选 DeepSeek 的阶段结果会显示在这里。"
                            : "尝试缩短关键词，或清空搜索后查看全部记录。"
                    )
                )
            } else {
                NavigationSplitView {
                    List(model.records, id: \.sessionID, selection: $selection) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(record.finalText ?? record.transcription ?? record.outcome.historyLabel)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Label(record.outcome.historyLabel, systemImage: record.outcome.icon)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(record.startedAt.formatted()) · \(record.applicationName ?? "无目标")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(record.sessionID)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            record.finalText
                                ?? record.transcription
                                ?? record.outcome.historyLabel
                        )
                        .accessibilityValue(
                            "\(record.outcome.historyLabel)，\(record.applicationName ?? "无目标")，\(record.startedAt.formatted())"
                        )
                        .accessibilityHint("选择后可查看、复制、重新输入或删除")
                    }
                } detail: {
                    if let record = selectedRecord {
                        HistoryDetailView(
                            record: record,
                            isRedeliveryArmed: model.isRedeliveryArmed,
                            isBusy: model.activeOperation != nil,
                            copy: {
                                Task { await model.copy(record) }
                            },
                            redeliver: {
                                if model.isRedeliveryArmed {
                                    model.cancelRedelivery()
                                } else {
                                    Task { await model.redeliver(record) }
                                }
                            },
                            delete: {
                                let replacement = replacementSelection(
                                    afterDeleting: record.sessionID
                                )
                                Task {
                                    if await model.delete(record.sessionID) {
                                        selection = replacement
                                    }
                                }
                            }
                        )
                    } else {
                        ContentUnavailableView("选择一条会话", systemImage: "text.magnifyingglass")
                    }
                }
            }

            if let feedback = model.feedback {
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
            } else if let notice = model.notice {
                Divider()
                Label(
                    notice,
                    systemImage: model.isRedeliveryArmed
                        ? "arrow.up.forward.app.fill"
                        : "exclamationmark.circle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(
                        model.isRedeliveryArmed ? Color.secondary : .red
                    )
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: .speakerHistoryDidChange)
        ) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: model.records.map(\.sessionID)) { _, ids in
            if let selection, ids.contains(selection) {
                return
            }
            selection = ids.first
        }
        .onDisappear { model.cancelRedelivery() }
        .confirmationDialog(
            "清空所有会话历史？",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("清空历史", role: .destructive) {
                Task {
                    if await model.clear() {
                        selection = nil
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文字记录会从本机永久删除，此操作无法撤销。")
        }
    }

    private var selectedRecord: VoiceInputHistoryRecord? {
        guard let selection else { return nil }
        return model.records.first { $0.sessionID == selection }
    }

    private func replacementSelection(
        afterDeleting id: VoiceInputSessionID
    ) -> VoiceInputSessionID? {
        guard let index = model.records.firstIndex(
            where: { $0.sessionID == id }
        ) else {
            return model.records.first?.sessionID
        }
        if model.records.indices.contains(index + 1) {
            return model.records[index + 1].sessionID
        }
        if index > 0 {
            return model.records[index - 1].sessionID
        }
        return nil
    }
}

private struct HistoryDetailView: View {
    let record: VoiceInputHistoryRecord
    let isRedeliveryArmed: Bool
    let isBusy: Bool
    let copy: () -> Void
    let redeliver: () -> Void
    let delete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(record.outcome.historyLabel, systemImage: record.outcome.icon)
                            .font(.headline)
                        Text(record.startedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(record.applicationName ?? "未指定应用")
                        Text(record.refinementModeName ?? "默认顺滑")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HistoryTextBlock(
                    title: "最终文字",
                    text: record.finalText ?? record.transcription
                )

                if record.refinementStatus == "fellBack" {
                    Label("进一步整理未完成，已保留豆包结果", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange, .primary)
                }

                DisclosureGroup("查看处理过程") {
                    VStack(alignment: .leading, spacing: 14) {
                        HistoryTextBlock(title: "豆包转录", text: record.transcription)
                        if record.deepSeekText != nil || record.refinementStatus != nil {
                            HistoryTextBlock(title: "DeepSeek 整理", text: record.deepSeekText)
                        }
                    }
                    .padding(.top, 10)
                }

                DisclosureGroup("技术详情") {
                    VStack(alignment: .leading, spacing: 10) {
                        technicalDetails
                    }
                    .padding(.top, 10)
                }

                HStack {
                    Button("复制文字", action: copy)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isBusy
                            || (record.finalText == nil
                                && record.transcription == nil)
                    )
                    .accessibilityHint("复制最终文字到剪贴板")
                    Button(
                        isRedeliveryArmed ? "取消重新输入" : "重新输入到光标处",
                        action: redeliver
                    )
                        .disabled(
                            isBusy
                                || (record.finalText == nil
                                    && record.transcription == nil)
                        )
                    Spacer()
                    Button("删除…", role: .destructive) {
                        confirmsDelete = true
                    }
                    .disabled(isBusy)
                }
            }
            .padding(24)
            .textSelection(.enabled)
        }
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

    @ViewBuilder
    private var technicalDetails: some View {
        LabeledContent("总耗时", value: "\(record.durationMilliseconds) ms")
        if !record.stageDurationsMilliseconds.isEmpty {
            LabeledContent(
                "阶段耗时",
                value: record.stageDurationsMilliseconds
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value) ms" }
                    .joined(separator: " · ")
            )
        }
        if let refinementPrompt = record.refinementPrompt {
            HistoryTextBlock(title: "整理提示词快照", text: refinementPrompt)
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
            LabeledContent(
                "送达诊断",
                value: deliveryDiagnosticCode
            )
        }
        if let deepSeekRequestID = record.deepSeekRequestID {
            LabeledContent("DeepSeek 请求 ID", value: deepSeekRequestID)
        }
        if let refinementFailureCode = record.refinementFailureCode {
            LabeledContent("DeepSeek 错误代码", value: refinementFailureCode)
        }
        if let refinementFailureStatusCode = record.refinementFailureStatusCode {
            LabeledContent("DeepSeek 状态码", value: refinementFailureStatusCode)
        }
        if let cancelledAtStage = record.cancelledAtStage {
            LabeledContent("取消时阶段", value: cancelledAtStage)
        }
    }

}

private struct HistoryTextBlock: View {
    let title: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text ?? "无")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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

private extension HistoryFeedback.Kind {
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
