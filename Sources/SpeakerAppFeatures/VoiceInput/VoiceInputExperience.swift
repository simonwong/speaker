import Combine
import Foundation
import SpeakerCore

private final class VoiceTriggerIntakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var allowsSessionTriggers = true

    func accepts(_ trigger: GlobalVoiceTrigger) -> Bool {
        lock.withLock {
            guard accepting else { return false }
            return switch trigger {
            case .pressed, .released:
                allowsSessionTriggers
            case .cancel, .monitorRecovered:
                true
            }
        }
    }

    var isAcceptingEscapeEvents: Bool {
        lock.withLock { accepting }
    }

    func setAllowsSessionTriggers(_ allowed: Bool) {
        lock.withLock { allowsSessionTriggers = allowed }
    }

    func close() {
        lock.withLock {
            accepting = false
            allowsSessionTriggers = false
        }
    }
}

package struct VoiceInputExperienceAction: Equatable, Sendable {
    fileprivate enum Operation: Equatable, Sendable {
        case cancel
        case copyRetainedText
        case dismissResult
        case requestRecovery
    }

    fileprivate let sessionID: VoiceInputSessionID
    fileprivate let operation: Operation
}

package enum VoiceInputExperienceEffect: Equatable, Sendable {
    case openSpeechSettings
}

package struct VoiceInputMenuPresentation: Equatable, Sendable {
    package struct Status: Equatable, Sendable {
        package let title: String
        package let icon: String
    }

    package let status: Status?
    package let notice: String?
    package let cancelAction: VoiceInputExperienceAction?
    package let copyRetainedTextTitle: String?
    package let copyRetainedTextAction: VoiceInputExperienceAction?
    package let dismissAction: VoiceInputExperienceAction?
    package let recoveryAction: VoiceInputExperienceAction?
}

package enum VoiceInputOverlayPresentation: Equatable, Sendable {
    case hidden
    case recording(
        peakPower: Float?,
        cancelAction: VoiceInputExperienceAction
    )
    case processing(
        title: String,
        cancelAction: VoiceInputExperienceAction
    )
    case pendingCopy(
        title: String,
        text: String,
        copyButtonTitle: String,
        copyAction: VoiceInputExperienceAction,
        dismissAction: VoiceInputExperienceAction
    )
    case problem(
        icon: String,
        title: String,
        guidance: String,
        recoveryAction: VoiceInputExperienceAction?,
        dismissAction: VoiceInputExperienceAction
    )
}

/// Stable inputs for exercising the production HUD through AppKit's
/// accessibility tree. These fixtures deliberately create opaque experience
/// capabilities inside their owning module; UI specs can press the real
/// controls without widening the capability initializer used by the App.
package enum VoiceInputHUDContractFixture: CaseIterable, Sendable {
    case processing
    case recording
    case pendingCopy
    case problem

    package var presentation: VoiceInputOverlayPresentation {
        let sessionID = VoiceInputSessionID()
        let cancel = VoiceInputExperienceAction(
            sessionID: sessionID,
            operation: .cancel
        )
        let dismiss = VoiceInputExperienceAction(
            sessionID: sessionID,
            operation: .dismissResult
        )
        let copy = VoiceInputExperienceAction(
            sessionID: sessionID,
            operation: .copyRetainedText
        )
        let recover = VoiceInputExperienceAction(
            sessionID: sessionID,
            operation: .requestRecovery
        )

        return switch self {
        case .processing:
            .processing(title: "正在转成文字", cancelAction: cancel)
        case .recording:
            .recording(peakPower: -18, cancelAction: cancel)
        case .pendingCopy:
            .pendingCopy(
                title: "这个输入框需要手动粘贴",
                text: "这是保留的转录文字。",
                copyButtonTitle: "复制",
                copyAction: copy,
                dismissAction: dismiss
            )
        case .problem:
            .problem(
                icon: "exclamationmark.triangle",
                title: "辅助功能权限不可用",
                guidance: "请在系统设置中允许 Speaker。",
                recoveryAction: recover,
                dismissAction: dismiss
            )
        }
    }
}

package struct VoiceInputExperienceState: Equatable, Sendable {
    package let revision: UInt64
    package let menu: VoiceInputMenuPresentation
    package let overlay: VoiceInputOverlayPresentation
    package let isRecording: Bool
    package let diagnosticCode: String

    fileprivate static let idle = VoiceInputExperienceState(
        revision: 0,
        menu: .init(
            status: nil,
            notice: nil,
            cancelAction: nil,
            copyRetainedTextTitle: nil,
            copyRetainedTextAction: nil,
            dismissAction: nil,
            recoveryAction: nil
        ),
        overlay: .hidden,
        isRecording: false,
        diagnosticCode: "idle"
    )
}

#if DEBUG
package enum VoiceInputVisualScenario: String, Sendable {
    case recording
    case processing
    case pendingCopy = "pending-copy"
    case problem
}
#endif

/// Owns the user-facing voice interaction behind one state + action interface.
///
/// Views cannot send raw session commands or infer whether a stale control is
/// still valid. Every action is a capability tied to the session that created
/// it. Shortcut ordering, immediate Esc ownership, session observation,
/// presentation projection, VoiceOver phase deduplication and shutdown are
/// hidden behind this seam.
@MainActor
package final class VoiceInputExperience: ObservableObject {
    package typealias Announce = @MainActor (String) -> Void

    @Published package private(set) var state = VoiceInputExperienceState.idle
    package let shortcutTarget: VoiceTriggerTarget

    private struct AnnouncementKey: Equatable {
        let sessionID: VoiceInputSessionID
        let phase: String
    }

    private let sessions: VoiceInputSessions
    private let dispatcher: VoiceInputTriggerDispatcher
    private let escapeGate: EscapeCancellationGate
    private let triggerIntakeGate: VoiceTriggerIntakeGate
    private let announce: Announce
    private var observationTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var currentPresentation = VoiceInputPresentation(
        revision: 0,
        activity: .idle
    )
    private var lastAnnouncementKey: AnnouncementKey?
    private var lastAnnouncedNoticeRevision: UInt64?
    private var isShuttingDown = false
    private var shutdownTask: Task<Void, Never>?

    package init(
        sessions: VoiceInputSessions,
        releaseCaptureHint:
            @escaping @Sendable () -> InputTargetCaptureHint? = { nil },
        announce: @escaping Announce
    ) {
        self.sessions = sessions
        self.announce = announce
        let dispatcher = VoiceInputTriggerDispatcher(
            sessions: sessions,
            releaseCaptureHint: releaseCaptureHint
        )
        self.dispatcher = dispatcher
        let escapeGate = EscapeCancellationGate()
        self.escapeGate = escapeGate
        let triggerIntakeGate = VoiceTriggerIntakeGate()
        self.triggerIntakeGate = triggerIntakeGate
        shortcutTarget = VoiceTriggerTarget(
            receive: { trigger in
                guard triggerIntakeGate.accepts(trigger) else { return }
                if trigger == .pressed {
                    // Esc must belong to Speaker before the asynchronous
                    // session publishes `.preparing`.
                    escapeGate.setActive(true)
                }
                dispatcher.send(trigger)
            },
            shouldConsumeEscape: {
                triggerIntakeGate.isAcceptingEscapeEvents
                    && escapeGate.shouldConsumeEscape
            }
        )
    }

    package func start() {
        guard observationTask == nil, !isShuttingDown else { return }
        let sessions = sessions
        observationTask = Task { [weak self] in
            let stream = await sessions.observe()
            for await presentation in stream {
                guard !Task.isCancelled else { return }
                self?.apply(presentation)
            }
        }
    }

#if DEBUG
    package func presentVisualScenario(_ scenario: VoiceInputVisualScenario) {
        NSLog("Speaker visual scenario presenting: \(scenario.rawValue)")
        let sessionID = VoiceInputSessionID()
        let cancel = VoiceInputExperienceAction(
            sessionID: sessionID,
            operation: .cancel
        )
        let dismiss = VoiceInputExperienceAction(
            sessionID: sessionID,
            operation: .dismissResult
        )
        let copy = VoiceInputExperienceAction(
            sessionID: sessionID,
            operation: .copyRetainedText
        )
        let overlay: VoiceInputOverlayPresentation
        let menuStatus: VoiceInputMenuPresentation.Status?
        let isRecording: Bool
        let diagnosticCode: String

        switch scenario {
        case .recording:
            overlay = .recording(peakPower: -18, cancelAction: cancel)
            menuStatus = .init(title: "正在录音", icon: "mic.fill")
            isRecording = true
            diagnosticCode = "visual.recording"
        case .processing:
            overlay = .processing(
                title: "正在转成文字",
                cancelAction: cancel
            )
            menuStatus = .init(title: "正在转成文字…", icon: "sparkles")
            isRecording = false
            diagnosticCode = "visual.processing"
        case .pendingCopy:
            overlay = .pendingCopy(
                title: "这个输入框需要手动粘贴",
                text: "这是保留的转录文字，用于检查待复制状态。",
                copyButtonTitle: "复制",
                copyAction: copy,
                dismissAction: dismiss
            )
            menuStatus = .init(
                title: "这个输入框需要手动粘贴",
                icon: "doc.on.clipboard"
            )
            isRecording = false
            diagnosticCode = "visual.pendingCopy"
        case .problem:
            overlay = .problem(
                icon: "wifi.exclamationmark",
                title: "网络连接不可用",
                guidance: "请检查网络连接后重新录音。",
                recoveryAction: nil,
                dismissAction: dismiss
            )
            menuStatus = .init(
                title: "网络连接不可用",
                icon: "wifi.exclamationmark"
            )
            isRecording = false
            diagnosticCode = "visual.problem"
        }

        state = VoiceInputExperienceState(
            revision: state.revision &+ 1,
            menu: .init(
                status: menuStatus,
                notice: nil,
                cancelAction: scenario == .recording || scenario == .processing
                    ? cancel
                    : nil,
                copyRetainedTextTitle: scenario == .pendingCopy
                    ? "复制保留的文字"
                    : nil,
                copyRetainedTextAction: scenario == .pendingCopy ? copy : nil,
                dismissAction: scenario == .pendingCopy || scenario == .problem
                    ? dismiss
                    : nil,
                recoveryAction: nil
            ),
            overlay: overlay,
            isRecording: isRecording,
            diagnosticCode: diagnosticCode
        )
        NSLog("Speaker visual scenario published: \(diagnosticCode)")
    }
#endif

    @discardableResult
    package func perform(
        _ action: VoiceInputExperienceAction
    ) -> VoiceInputExperienceEffect? {
        guard !isShuttingDown, accepts(action) else { return nil }
        switch action.operation {
        case .cancel:
            enqueue { [sessions] in
                await sessions.cancel(expectedSessionID: action.sessionID)
            }
            return nil
        case .copyRetainedText:
            enqueue { [sessions] in
                await sessions.copyPendingResult(
                    expectedSessionID: action.sessionID
                )
            }
            return nil
        case .dismissResult:
            enqueue { [sessions] in
                await sessions.dismissResult(
                    expectedSessionID: action.sessionID
                )
            }
            return nil
        case .requestRecovery:
            enqueue { [sessions] in
                await sessions.dismissResult(
                    expectedSessionID: action.sessionID
                )
            }
            return .openSpeechSettings
        }
    }

    package func shutdown() async {
        if isShuttingDown {
            await shutdownTask?.value
            finishShutdown()
            return
        }
        isShuttingDown = true
        triggerIntakeGate.close()
        escapeGate.setActive(false)
        let commandTask = commandTask
        let dispatcher = dispatcher
        let observationTask = observationTask
        let shutdownTask = Task {
            await commandTask?.value
            await dispatcher.shutdown()
            observationTask?.cancel()
            await observationTask?.value
        }
        self.shutdownTask = shutdownTask
        await shutdownTask.value
        finishShutdown()
    }

    private func finishShutdown() {
        observationTask = nil
        shutdownTask = nil
        state = .idle
    }

    private func enqueue(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let previousTask = commandTask
        commandTask = Task {
            await previousTask?.value
            await operation()
        }
    }

    private func accepts(_ action: VoiceInputExperienceAction) -> Bool {
        guard currentPresentation.activity.sessionID == action.sessionID else {
            return false
        }
        return switch (action.operation, currentPresentation.activity) {
        case (.cancel, .preparing),
             (.cancel, .recording),
             (.cancel, .processing),
             (.copyRetainedText, .pendingCopy),
             (.dismissResult, .pendingCopy),
             (.dismissResult, .failed):
            true
        case let (.requestRecovery, .failed(_, failure)):
            failure.needsSettings
        case (.cancel, .idle),
             (.cancel, .delivered),
             (.cancel, .pendingCopy),
             (.cancel, .cancelled),
             (.cancel, .failed),
             (.copyRetainedText, _),
             (.dismissResult, _),
             (.requestRecovery, _):
            false
        }
    }

    private func apply(_ presentation: VoiceInputPresentation) {
        guard !isShuttingDown else { return }
        currentPresentation = presentation
        let allowsSessionTriggers = switch presentation.activity {
        case .processing, .pendingCopy:
            false
        case .idle, .preparing, .recording, .delivered, .cancelled, .failed:
            true
        }
        triggerIntakeGate.setAllowsSessionTriggers(allowsSessionTriggers)
        escapeGate.setActive(presentation.activity.isActive)
        state = Self.makeState(from: presentation)
        announceTransitionIfNeeded(presentation.activity)
        announceNoticeIfNeeded(presentation)
    }

    private func announceTransitionIfNeeded(_ activity: VoiceInputActivity) {
        guard let key = Self.announcementKey(for: activity),
              key != lastAnnouncementKey,
              let message = activity.accessibilityAnnouncement
        else { return }
        lastAnnouncementKey = key
        announce(message)
    }

    private func announceNoticeIfNeeded(_ presentation: VoiceInputPresentation) {
        guard let notice = presentation.notice,
              lastAnnouncedNoticeRevision != presentation.revision
        else { return }
        lastAnnouncedNoticeRevision = presentation.revision
        announce(notice.userMessage)
    }

    private static func makeState(
        from presentation: VoiceInputPresentation
    ) -> VoiceInputExperienceState {
        let activity = presentation.activity
        // Idle notices are one-shot feedback effects (for example, successful
        // copy). They are announced below but must not become stale menu state.
        let retainedMenuNotice: String? = if case .idle = activity {
            nil
        } else {
            presentation.notice?.userMessage
        }
        let sessionID = activity.sessionID
        let cancelAction = sessionID.map {
            VoiceInputExperienceAction(sessionID: $0, operation: .cancel)
        }
        let menuStatus: VoiceInputMenuPresentation.Status? = switch activity {
        case .idle, .delivered, .cancelled:
            nil
        case .preparing, .recording, .processing:
            .init(title: activity.compactTitle, icon: activity.icon)
        case let .pendingCopy(_, _, reason):
            .init(title: reason.userTitle, icon: activity.icon)
        case let .failed(_, failure):
            .init(title: failure.userTitle, icon: failure.userIcon)
        }
        let copyAction: VoiceInputExperienceAction? = {
            guard case let .pendingCopy(id, _, _) = activity else { return nil }
            return VoiceInputExperienceAction(
                sessionID: id,
                operation: .copyRetainedText
            )
        }()
        let dismissAction: VoiceInputExperienceAction? = {
            switch activity {
            case let .pendingCopy(id, _, _), let .failed(id, _):
                VoiceInputExperienceAction(
                    sessionID: id,
                    operation: .dismissResult
                )
            default:
                nil
            }
        }()
        let recoveryAction: VoiceInputExperienceAction? = {
            guard case let .failed(id, failure) = activity,
                  failure.needsSettings
            else { return nil }
            return VoiceInputExperienceAction(
                sessionID: id,
                operation: .requestRecovery
            )
        }()

        return VoiceInputExperienceState(
            revision: presentation.revision,
            menu: .init(
                status: menuStatus,
                notice: retainedMenuNotice,
                cancelAction: activity.isActive ? cancelAction : nil,
                copyRetainedTextTitle: activity.pendingCopyReason
                    == .deliveryUnconfirmed
                    ? "确认未输入后复制"
                    : copyAction.map { _ in "复制保留的文字" },
                copyRetainedTextAction: copyAction,
                dismissAction: dismissAction,
                recoveryAction: recoveryAction
            ),
            overlay: makeOverlay(
                activity: activity,
                peakPower: presentation.recordingTelemetry?.peakPower
            ),
            isRecording: activity.isRecording,
            diagnosticCode: diagnosticCode(for: activity)
        )
    }

    private static func makeOverlay(
        activity: VoiceInputActivity,
        peakPower: Float?
    ) -> VoiceInputOverlayPresentation {
        switch activity {
        case .idle, .delivered, .cancelled:
            .hidden
        case let .preparing(id):
            .processing(
                title: activity.compactTitle,
                cancelAction: .init(sessionID: id, operation: .cancel)
            )
        case let .recording(id):
            .recording(
                peakPower: peakPower,
                cancelAction: .init(sessionID: id, operation: .cancel)
            )
        case let .processing(id, _, _):
            .processing(
                title: activity.compactTitle,
                cancelAction: .init(sessionID: id, operation: .cancel)
            )
        case let .pendingCopy(id, text, reason):
            .pendingCopy(
                title: reason.userTitle,
                text: text,
                copyButtonTitle: reason == .deliveryUnconfirmed
                    ? "确认未输入后复制"
                    : "复制",
                copyAction: .init(
                    sessionID: id,
                    operation: .copyRetainedText
                ),
                dismissAction: .init(
                    sessionID: id,
                    operation: .dismissResult
                )
            )
        case let .failed(id, failure):
            .problem(
                icon: failure.userIcon,
                title: failure.userTitle,
                guidance: failure.userGuidance,
                recoveryAction: failure.needsSettings
                    ? .init(sessionID: id, operation: .requestRecovery)
                    : nil,
                dismissAction: .init(
                    sessionID: id,
                    operation: .dismissResult
                )
            )
        }
    }

    private static func diagnosticCode(for activity: VoiceInputActivity) -> String {
        switch activity {
        case .idle: "idle"
        case .preparing: "preparing"
        case .recording: "recording"
        case let .processing(_, stage, _): "processing.\(stage)"
        case .delivered: "delivered"
        case let .pendingCopy(_, _, reason): "pendingCopy.\(reason.rawValue)"
        case .cancelled: "cancelled"
        case let .failed(_, failure): "failed.\(failure.rawValue)"
        }
    }

    private static func announcementKey(
        for activity: VoiceInputActivity
    ) -> AnnouncementKey? {
        guard let sessionID = activity.sessionID else { return nil }
        switch activity {
        case .preparing:
            return nil
        case let .processing(_, stage, _)
            where stage == .capturingTarget || stage == .delivering:
            return nil
        case .idle, .recording, .processing, .delivered, .pendingCopy,
             .cancelled, .failed:
            break
        }
        let phase: String = switch activity {
        case .idle: "idle"
        case .preparing: "preparing"
        case .recording: "recording"
        case let .processing(_, stage, _): "processing.\(stage)"
        case .delivered: "delivered"
        case let .pendingCopy(_, _, reason): "pendingCopy.\(reason.rawValue)"
        case .cancelled: "cancelled"
        case let .failed(_, failure): "failed.\(failure.rawValue)"
        }
        return AnnouncementKey(sessionID: sessionID, phase: phase)
    }
}
