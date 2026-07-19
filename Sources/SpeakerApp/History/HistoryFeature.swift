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
              let text = HistoryPresentation.retainedText(for: record)
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
        guard let text = HistoryPresentation.retainedText(for: record) else {
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

    var body: some View {
        HistoryDashboard(
            state: HistoryDashboardState(
                records: model.records,
                totalRecordCount: model.totalRecordCount,
                notice: model.notice,
                feedback: model.feedback?.dashboardFeedback,
                isBusy: model.activeOperation != nil,
                isRedeliveryArmed: model.isRedeliveryArmed,
                retentionPolicy: model.retentionPolicy,
                isUpdatingRetention: model.isUpdatingRetention
            ),
            query: $model.query,
            actions: HistoryDashboardActions(
                refresh: { Task { await model.refresh() } },
                setRetentionPolicy: { policy in
                    Task { await model.setRetentionPolicy(policy) }
                },
                clear: { Task { _ = await model.clear() } },
                copy: { record in
                    Task { _ = await model.copy(record) }
                },
                toggleRedelivery: { record in
                    if model.isRedeliveryArmed {
                        model.cancelRedelivery()
                    } else {
                        Task { await model.redeliver(record) }
                    }
                },
                delete: { id in
                    Task { _ = await model.delete(id) }
                }
            )
        )
        .task { await model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: .speakerHistoryDidChange)
        ) { _ in
            Task { await model.refresh() }
        }
        .onDisappear { model.cancelRedelivery() }
    }
}

private extension HistoryFeedback {
    var dashboardFeedback: HistoryDashboardFeedback {
        let dashboardKind: HistoryDashboardFeedback.Kind = switch kind {
        case .information: .information
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
        return HistoryDashboardFeedback(
            kind: dashboardKind,
            message: message
        )
    }
}
