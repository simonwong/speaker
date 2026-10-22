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

/// Carries a refused press from the event callback to the experience, which
/// does not exist yet when the shortcut target is built.
@MainActor
private final class SecureInputPressRelay {
    var blockedPress: (() -> Void)?
}

package struct VoiceInputExperienceAction: Equatable, Sendable {
    fileprivate enum Operation: Equatable, Sendable {
        case cancel
        case finishRecording
        case useRecognitionResult
        case copyRetainedText
        case dismissResult
        case requestRecovery
    }

    fileprivate let sessionID: VoiceInputSessionID
    fileprivate let operation: Operation
}

package enum VoiceInputExperienceEffect: Equatable, Sendable {
    case openSettings(SettingsGroup)
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
        cancelAction: VoiceInputExperienceAction,
        finishAction: VoiceInputExperienceAction,
        remainingSeconds: Int? = nil
    )
    /// `useRecognitionAction` is present only while refinement is pending.
    case processing(
        title: String,
        cancelAction: VoiceInputExperienceAction,
        useRecognitionAction: VoiceInputExperienceAction? = nil
    )
    case pendingCopy(
        title: String,
        text: String,
        copyButtonTitle: String,
        copyAction: VoiceInputExperienceAction,
        dismissAction: VoiceInputExperienceAction,
        copyFailed: Bool = false
    )
    case problem(
        icon: String,
        title: String,
        guidance: String,
        recoveryAction: VoiceInputExperienceAction?,
        dismissAction: VoiceInputExperienceAction
    )
    /// A short, non-interactive note after a delivery that still needs
    /// saying, such as refinement falling back to the recognition result.
    /// It closes on its own.
    case notice(title: String)
}

/// Stable inputs for exercising the production HUD through AppKit's
/// accessibility tree. These fixtures deliberately create opaque experience
/// capabilities inside their owning module; UI specs can press the real
/// controls without widening the capability initializer used by the App.
package enum VoiceInputHUDContractFixture: CaseIterable, Sendable {
    case processing
    case refining
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
        case .refining:
            .processing(
                title: "正在整理文字",
                cancelAction: cancel,
                useRecognitionAction: .init(sessionID: sessionID, operation: .useRecognitionResult)
            )
        case .recording:
            .recording(
                peakPower: -18,
                cancelAction: cancel,
                finishAction: .init(sessionID: sessionID, operation: .finishRecording)
            )
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

    fileprivate func hidingOverlay() -> VoiceInputExperienceState {
        showingOverlay(.hidden)
    }

    fileprivate func showingOverlay(
        _ overlay: VoiceInputOverlayPresentation
    ) -> VoiceInputExperienceState {
        VoiceInputExperienceState(
            revision: revision,
            menu: menu,
            overlay: overlay,
            isRecording: isRecording,
            diagnosticCode: diagnosticCode
        )
    }

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
    package typealias Announce = AccessibilityAnnounce

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
    private let releaseCaptureHint: @Sendable () -> InputTargetCaptureHint?
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
    private let problemAutoDismissDelay: Duration
    private var problemAutoDismissSessionID: VoiceInputSessionID?
    private var problemAutoDismissTask: Task<Void, Never>?
    private var problemHeld = false
    private var noticeHideTask: Task<Void, Never>?
    private let secureInputHolderName: @MainActor () -> String?
    private let secureInputNoticeDuration: Duration
    private var secureInputNoticeTitle: String?
    private var secureInputNoticeHideTask: Task<Void, Never>?

    /// How long a delivery notice stays before the HUD closes.
    package static let defaultNoticeDuration: Duration = .seconds(2)
    private let noticeDuration: Duration

    /// How long the note about a press refused by Secure Event Input stays.
    /// It names the App to leave, so it stays longer than a delivery notice.
    package static let defaultSecureInputNoticeDuration: Duration = .seconds(4)

    /// How long a Session Problem without a settings recovery stays on screen
    /// before it dismisses itself.
    package static let defaultProblemAutoDismissDelay: Duration = .seconds(5)

    package init(
        sessions: VoiceInputSessions,
        releaseCaptureHint:
            @escaping @Sendable () -> InputTargetCaptureHint? = { nil },
        problemAutoDismissDelay: Duration = defaultProblemAutoDismissDelay,
        noticeDuration: Duration = defaultNoticeDuration,
        secureInputNoticeDuration: Duration = defaultSecureInputNoticeDuration,
        secureInputHolderName: @escaping @MainActor () -> String? = { nil },
        announce: @escaping Announce
    ) {
        self.sessions = sessions
        self.problemAutoDismissDelay = problemAutoDismissDelay
        self.noticeDuration = noticeDuration
        self.secureInputNoticeDuration = secureInputNoticeDuration
        self.secureInputHolderName = secureInputHolderName
        self.announce = announce
        self.releaseCaptureHint = releaseCaptureHint
        let dispatcher = VoiceInputTriggerDispatcher(
            sessions: sessions,
            releaseCaptureHint: releaseCaptureHint
        )
        self.dispatcher = dispatcher
        let escapeGate = EscapeCancellationGate()
        self.escapeGate = escapeGate
        let triggerIntakeGate = VoiceTriggerIntakeGate()
        self.triggerIntakeGate = triggerIntakeGate
        let secureInputRelay = SecureInputPressRelay()
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
            },
            secureInputBlockedPress: {
                // A press the session would refuse anyway gets no note.
                guard triggerIntakeGate.accepts(.pressed) else { return }
                Task { @MainActor in secureInputRelay.blockedPress?() }
            }
        )
        secureInputRelay.blockedPress = { [weak self] in
            self?.showSecureInputNotice()
        }
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
                overlay = .recording(
                    peakPower: -18,
                    cancelAction: cancel,
                    finishAction: .init(sessionID: sessionID, operation: .finishRecording)
                )
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
        case .finishRecording:
            let captureHint = releaseCaptureHint()
            enqueue { [sessions] in
                await sessions.finishRecording(
                    expectedSessionID: action.sessionID,
                    captureHint: captureHint
                )
            }
            return nil
        case .cancel:
            enqueue { [sessions] in
                await sessions.cancel(expectedSessionID: action.sessionID)
            }
            return nil
        case .useRecognitionResult:
            enqueue { [sessions] in
                await sessions.useRecognitionResult(expectedSessionID: action.sessionID)
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
            guard
                case .failed(_, let failure) = currentPresentation.activity,
                let destination = failure.settingsDestination
            else { return nil }
            enqueue { [sessions] in
                await sessions.dismissResult(
                    expectedSessionID: action.sessionID
                )
            }
            return .openSettings(destination)
        }
    }

    package func shutdown() async {
        if isShuttingDown {
            await shutdownTask?.value
            finishShutdown()
            return
        }
        isShuttingDown = true
        cancelProblemAutoDismiss()
        noticeHideTask?.cancel()
        secureInputNoticeHideTask?.cancel()
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
            (.finishRecording, .recording),
            (.cancel, .recording),
            (.cancel, .processing),
            (.useRecognitionResult, .processing(_, .refining, _)),
            (.copyRetainedText, .pendingCopy),
            (.dismissResult, .pendingCopy),
            (.dismissResult, .failed):
            true
        case (.requestRecovery, .failed(_, let failure)):
            failure.needsSettings
        case (.cancel, .idle),
            (.cancel, .delivered),
            (.cancel, .pendingCopy),
            (.cancel, .cancelled),
            (.cancel, .failed),
            (.copyRetainedText, _),
            (.finishRecording, _),
            (.useRecognitionResult, _),
            (.dismissResult, _),
            (.requestRecovery, _):
            false
        }
    }

    /// A shortcut press refused because another App holds Secure Event
    /// Input. Speaker cannot record then, so it says why and names that App
    /// when the system reports it. Presses repeated while the note is up
    /// neither restart it nor announce it again, and a retained result or
    /// problem on screen keeps its place.
    private func showSecureInputNotice() {
        guard !isShuttingDown, secureInputNoticeTitle == nil else { return }
        switch state.overlay {
        case .hidden, .notice:
            break
        case .recording, .processing, .pendingCopy, .problem:
            return
        }
        let title = SecureInputBlockedNotice.title(holderName: secureInputHolderName())
        secureInputNoticeTitle = title
        noticeHideTask?.cancel()
        noticeHideTask = nil
        state = state.showingOverlay(.notice(title: title))
        announce(title)
        let duration = secureInputNoticeDuration
        secureInputNoticeHideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.secureInputNoticeTitle != nil else { return }
            self.secureInputNoticeTitle = nil
            self.secureInputNoticeHideTask = nil
            self.state = self.state.hidingOverlay()
        }
    }

    /// An idle presentation keeps the Secure Event Input note on screen;
    /// anything the session shows replaces it.
    private func keepSecureInputNoticeIfIdle() {
        guard let title = secureInputNoticeTitle else { return }
        if case .hidden = state.overlay {
            state = state.showingOverlay(.notice(title: title))
            return
        }
        secureInputNoticeTitle = nil
        secureInputNoticeHideTask?.cancel()
        secureInputNoticeHideTask = nil
    }

    private func apply(_ presentation: VoiceInputPresentation) {
        guard !isShuttingDown else { return }
        currentPresentation = presentation
        // pendingCopy stays open on purpose: pressing the shortcut while a
        // notice is up dismisses it and starts a fresh session instead of
        // silently ignoring the user. Only in-flight processing keeps the
        // gate shut, because a stray press there would race the session's
        // own completion.
        let allowsSessionTriggers =
            switch presentation.activity {
            case .processing:
                false
            case .idle, .preparing, .recording, .delivered, .cancelled, .failed,
                .pendingCopy:
                true
            }
        triggerIntakeGate.setAllowsSessionTriggers(allowsSessionTriggers)
        state = Self.makeState(from: presentation)
        keepSecureInputNoticeIfIdle()
        escapeGate.setActive(presentation.activity.isActive || state.menu.dismissAction != nil)
        announceTransitionIfNeeded(presentation.activity)
        announceNoticeIfNeeded(presentation)
        scheduleProblemAutoDismissIfNeeded(presentation.activity)
        scheduleNoticeHideIfNeeded()
    }

    /// A delivery notice closes the HUD on its own; any later presentation
    /// replaces it first.
    private func scheduleNoticeHideIfNeeded() {
        noticeHideTask?.cancel()
        noticeHideTask = nil
        // The Secure Event Input note keeps its own timer.
        guard secureInputNoticeTitle == nil, case .notice = state.overlay else { return }
        let revision = state.revision
        let duration = noticeDuration
        noticeHideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self,
                self.state.revision == revision,
                case .notice = self.state.overlay
            else { return }
            self.state = self.state.hidingOverlay()
        }
    }

    /// A visible problem that only informs the user closes on its own. One
    /// that offers settings recovery stays until the user acts on it, and the
    /// timer dismisses only the session that started it.
    private func scheduleProblemAutoDismissIfNeeded(_ activity: VoiceInputActivity) {
        guard case .failed(let id, let failure) = activity,
            !Self.endsSilently(activity),
            !failure.needsSettings
        else {
            cancelProblemAutoDismiss()
            problemHeld = false
            return
        }
        guard problemAutoDismissSessionID != id else { return }
        cancelProblemAutoDismiss()
        problemAutoDismissSessionID = id
        guard !problemHeld else { return }
        let delay = problemAutoDismissDelay
        problemAutoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.perform(.init(sessionID: id, operation: .dismissResult))
        }
    }

    /// The pointer resting on a problem pauses its dismissal, so the guidance
    /// tooltip can be read; leaving restarts the full delay.
    package func holdProblem(_ held: Bool) {
        guard problemHeld != held else { return }
        problemHeld = held
        guard case .failed = currentPresentation.activity else { return }
        problemAutoDismissTask?.cancel()
        problemAutoDismissTask = nil
        if !held {
            problemAutoDismissSessionID = nil
            scheduleProblemAutoDismissIfNeeded(currentPresentation.activity)
        }
    }

    private func cancelProblemAutoDismiss() {
        problemAutoDismissTask?.cancel()
        problemAutoDismissTask = nil
        problemAutoDismissSessionID = nil
    }

    private func announceTransitionIfNeeded(_ activity: VoiceInputActivity) {
        guard !Self.endsSilently(activity),
            let key = Self.announcementKey(for: activity),
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
        if endsSilently(activity) {
            return VoiceInputExperienceState(
                revision: presentation.revision,
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
                diagnosticCode: diagnosticCode(for: activity)
            )
        }
        // Idle notices are one-shot feedback effects (for example, successful
        // copy). They are announced below but must not become stale menu state.
        let retainedMenuNotice: String? =
            switch activity {
            case .idle:
                nil
            case .failed(_, let failure):
                failure.userGuidance
            default:
                presentation.notice?.userMessage
            }
        let sessionID = activity.sessionID
        let cancelAction = sessionID.map {
            VoiceInputExperienceAction(sessionID: $0, operation: .cancel)
        }
        let menuStatus: VoiceInputMenuPresentation.Status? =
            switch activity {
            case .idle, .delivered, .cancelled:
                nil
            case .preparing, .recording, .processing:
                .init(title: activity.compactTitle, icon: activity.icon)
            case .pendingCopy(_, _, let reason):
                .init(title: reason.userTitle, icon: activity.icon)
            case .failed(_, let failure):
                .init(title: failure.userTitle, icon: failure.userIcon)
            }
        let copyAction: VoiceInputExperienceAction? = {
            guard case .pendingCopy(let id, _, _) = activity else { return nil }
            return VoiceInputExperienceAction(
                sessionID: id,
                operation: .copyRetainedText
            )
        }()
        let dismissAction: VoiceInputExperienceAction? = {
            switch activity {
            case .pendingCopy(let id, _, _), .failed(let id, _):
                VoiceInputExperienceAction(
                    sessionID: id,
                    operation: .dismissResult
                )
            default:
                nil
            }
        }()
        let recoveryAction: VoiceInputExperienceAction? = {
            guard case .failed(let id, let failure) = activity,
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
                notice: presentation.notice,
                telemetry: presentation.recordingTelemetry
            ),
            isRecording: activity.isRecording,
            diagnosticCode: diagnosticCode(for: activity)
        )
    }

    private static func endsSilently(_ activity: VoiceInputActivity) -> Bool {
        switch activity {
        case .failed(_, .providerReturnedNoText), .failed(_, .recordingTooShort),
            .failed(_, .localSilenceDetected):
            true
        default:
            false
        }
    }

    /// The recording HUD counts down only through the last stretch before
    /// the recording limit, so ordinary dictation never shows a clock.
    package static let recordingCountdownMilliseconds = 30_000

    /// Whole seconds left, rounded up so the count never reads 0 while
    /// recording continues; `nil` outside the countdown.
    package static func countdownSeconds(remainingMilliseconds: Int?) -> Int? {
        guard let remainingMilliseconds,
            remainingMilliseconds <= recordingCountdownMilliseconds
        else { return nil }
        return max(1, (remainingMilliseconds + 999) / 1_000)
    }

    private static func makeOverlay(
        activity: VoiceInputActivity,
        notice: VoiceInputNotice?,
        telemetry: RecordingTelemetry?
    ) -> VoiceInputOverlayPresentation {
        switch activity {
        case .delivered:
            notice?.hudTitle.map { .notice(title: $0) } ?? .hidden
        case .idle, .cancelled:
            .hidden
        case .preparing(let id):
            .processing(
                title: activity.compactTitle,
                cancelAction: .init(sessionID: id, operation: .cancel)
            )
        case .recording(let id):
            .recording(
                peakPower: telemetry?.peakPower,
                cancelAction: .init(sessionID: id, operation: .cancel),
                finishAction: .init(sessionID: id, operation: .finishRecording),
                remainingSeconds: countdownSeconds(
                    remainingMilliseconds: telemetry?.remainingMilliseconds
                )
            )
        case .processing(let id, let stage, _):
            .processing(
                title: activity.compactTitle,
                cancelAction: .init(sessionID: id, operation: .cancel),
                useRecognitionAction: stage == .refining
                    ? .init(sessionID: id, operation: .useRecognitionResult) : nil
            )
        case .pendingCopy(let id, let text, let reason):
            .pendingCopy(
                title: reason.userTitle,
                text: reason.isSecureTarget
                    ? PendingCopyReason.secureTargetConcealedText : text,
                copyButtonTitle: reason == .deliveryUnconfirmed
                    ? "确认未输入后复制"
                    : (reason.isClipboardFailure ? "重试复制" : "复制"),
                copyAction: .init(
                    sessionID: id,
                    operation: .copyRetainedText
                ),
                dismissAction: .init(
                    sessionID: id,
                    operation: .dismissResult
                ),
                copyFailed: reason.isClipboardFailure
            )
        case .failed(let id, let failure):
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
        case .processing(_, let stage, _): "processing.\(stage)"
        case .delivered: "delivered"
        case .pendingCopy(_, _, let reason): "pendingCopy.\(reason.rawValue)"
        case .cancelled: "cancelled"
        case .failed(_, let failure): "failed.\(failure.rawValue)"
        }
    }

    private static func announcementKey(
        for activity: VoiceInputActivity
    ) -> AnnouncementKey? {
        guard let sessionID = activity.sessionID else { return nil }
        switch activity {
        case .preparing:
            return nil
        case .processing(_, let stage, _)
        where stage == .capturingTarget || stage == .delivering:
            return nil
        case .idle, .recording, .processing, .delivered, .pendingCopy,
            .cancelled, .failed:
            break
        }
        let phase: String =
            switch activity {
            case .idle: "idle"
            case .preparing: "preparing"
            case .recording: "recording"
            case .processing(_, let stage, _): "processing.\(stage)"
            case .delivered: "delivered"
            case .pendingCopy(_, _, let reason): "pendingCopy.\(reason.rawValue)"
            case .cancelled: "cancelled"
            case .failed(_, let failure): "failed.\(failure.rawValue)"
            }
        return AnnouncementKey(sessionID: sessionID, phase: phase)
    }
}
