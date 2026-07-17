import Foundation
import SpeakerCore

/// Routes the one physical global shortcut between mutually exclusive Speaker
/// interactions.
///
/// Voice input remains the default owner. A temporary exclusive interaction
/// can claim shortcut press/release and Escape without changing either live
/// shortcut monitor. Mouse confirmation crosses the same one-shot state
/// machine, so simultaneous inputs cannot commit twice.
package final class GlobalVoiceInteractionRouter: @unchecked Sendable {
    package typealias Confirm = @MainActor @Sendable () async -> Bool
    package typealias Cancel = @MainActor @Sendable () -> Void

    private struct ExclusiveInteraction {
        let id: UUID
        let confirm: Confirm
        let cancel: Cancel
        var isConfirming: Bool
    }

    private let lock = NSLock()
    private let voiceTarget: VoiceTriggerTarget
    private var exclusive: ExclusiveInteraction?
    private var suppressNextRelease = false

    package init(voiceTarget: VoiceTriggerTarget) {
        self.voiceTarget = voiceTarget
    }

    package lazy var shortcutTarget = VoiceTriggerTarget(
        receive: { [weak self] trigger in
            self?.receive(trigger)
        },
        shouldConsumeEscape: { [weak self] in
            self?.shouldConsumeEscape ?? false
        }
    )

    @MainActor
    @discardableResult
    package func beginExclusiveInteraction(
        confirm: @escaping Confirm,
        cancel: @escaping Cancel
    ) -> Bool {
        let transition = lock.withLock { () -> (Bool, Cancel?) in
            guard !voiceTarget.shouldConsumeEscape() else {
                return (false, nil)
            }
            let displaced = exclusive?.cancel
            exclusive = ExclusiveInteraction(
                id: UUID(),
                confirm: confirm,
                cancel: cancel,
                isConfirming: false
            )
            suppressNextRelease = false
            return (true, displaced)
        }
        guard transition.0 else { return false }
        transition.1?()
        return true
    }

    /// Requests the same confirmation used by a shortcut press.
    ///
    /// AppKit adapters call this after an explicit target click. Returning
    /// immediately is intentional; completion and stale-result fencing stay
    /// inside this module.
    @discardableResult
    package func confirmExclusiveInteraction() -> Bool {
        beginConfirmation()
    }

    @MainActor
    package func cancelExclusiveInteraction() {
        let cancel = removeExclusiveInteraction()
        cancel?()
    }

    package var hasExclusiveInteraction: Bool {
        lock.withLock { exclusive != nil }
    }

    private var shouldConsumeEscape: Bool {
        lock.withLock {
            exclusive != nil || voiceTarget.shouldConsumeEscape()
        }
    }

    private func receive(_ trigger: GlobalVoiceTrigger) {
        switch trigger {
        case .pressed:
            let isExclusive = lock.withLock { () -> Bool in
                guard exclusive != nil else { return false }
                suppressNextRelease = true
                return true
            }
            if isExclusive {
                _ = beginConfirmation()
            } else {
                voiceTarget.receive(.pressed)
            }
        case .released:
            let suppressed = lock.withLock { () -> Bool in
                guard suppressNextRelease else { return false }
                suppressNextRelease = false
                return true
            }
            if !suppressed {
                voiceTarget.receive(.released)
            }
        case .cancel:
            let cancel = removeExclusiveInteraction()
            if let cancel {
                Task { @MainActor in cancel() }
            } else {
                voiceTarget.receive(.cancel)
            }
        case .monitorRecovered:
            let cancel = removeExclusiveInteraction()
            if let cancel {
                Task { @MainActor in cancel() }
            } else {
                voiceTarget.receive(.monitorRecovered)
            }
        }
    }

    @discardableResult
    private func beginConfirmation() -> Bool {
        let request = lock.withLock { () -> (UUID, Confirm)? in
            guard var interaction = exclusive,
                  !interaction.isConfirming
            else { return nil }
            interaction.isConfirming = true
            exclusive = interaction
            return (interaction.id, interaction.confirm)
        }
        guard let (id, confirm) = request else { return false }

        Task { @MainActor [weak self] in
            let accepted = await confirm()
            self?.finishConfirmation(id: id, accepted: accepted)
        }
        return true
    }

    private func finishConfirmation(id: UUID, accepted: Bool) {
        lock.withLock {
            guard var interaction = exclusive,
                  interaction.id == id
            else { return }
            if accepted {
                exclusive = nil
            } else {
                interaction.isConfirming = false
                exclusive = interaction
            }
        }
    }

    private func removeExclusiveInteraction() -> Cancel? {
        lock.withLock {
            let cancel = exclusive?.cancel
            exclusive = nil
            // A shortcut press already owned by the displaced interaction must
            // keep its matching release out of the voice gesture state machine.
            return cancel
        }
    }
}
