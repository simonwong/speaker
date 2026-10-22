import Foundation
import SpeakerCore
import os

/// Routes the one physical global shortcut between mutually exclusive Speaker
/// interactions.
///
/// Voice input remains the default owner. A temporary exclusive interaction
/// can claim shortcut press/release and Escape without changing either live
/// shortcut monitor. Mouse confirmation crosses the same one-shot state
/// machine, so simultaneous inputs cannot commit twice.
///
/// The router's state lives in one lock. The voice target and every
/// interaction callback are called outside it, so a target that consults the
/// router while answering cannot deadlock it.
package final class GlobalVoiceInteractionRouter: Sendable {
    package typealias Confirm = @MainActor @Sendable () async -> Bool
    package typealias Cancel = @MainActor @Sendable () -> Void

    private struct ExclusiveInteraction: Sendable {
        let id: UUID
        let confirm: Confirm
        let cancel: Cancel
        var isConfirming: Bool
    }

    private struct State: Sendable {
        var exclusive: ExclusiveInteraction?
        var suppressNextRelease = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let voiceTarget: VoiceTriggerTarget

    package init(voiceTarget: VoiceTriggerTarget) {
        self.voiceTarget = voiceTarget
    }

    /// The target the live shortcut monitors call. Each read builds a new
    /// value; every copy routes through this router's one state.
    package var shortcutTarget: VoiceTriggerTarget {
        VoiceTriggerTarget(
            receive: { [weak self] trigger in
                self?.receive(trigger)
            },
            shouldConsumeEscape: { [weak self] in
                self?.shouldConsumeEscape ?? false
            },
            secureInputBlockedPress: { [voiceTarget] in
                voiceTarget.secureInputBlockedPress()
            }
        )
    }

    /// The live monitors watch `Esc` only after a shortcut press arms their
    /// key tap. An interaction begun while Speaker is idle therefore cannot
    /// be cancelled with `Esc` until a shortcut press arms it.
    @MainActor
    @discardableResult
    package func beginExclusiveInteraction(
        confirm: @escaping Confirm,
        cancel: @escaping Cancel
    ) -> Bool {
        guard !voiceTarget.shouldConsumeEscape() else { return false }
        let displaced = state.withLock { state -> Cancel? in
            let displaced = state.exclusive?.cancel
            state.exclusive = ExclusiveInteraction(
                id: UUID(),
                confirm: confirm,
                cancel: cancel,
                isConfirming: false
            )
            state.suppressNextRelease = false
            return displaced
        }
        displaced?()
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
        state.withLock { $0.exclusive != nil }
    }

    private var shouldConsumeEscape: Bool {
        hasExclusiveInteraction || voiceTarget.shouldConsumeEscape()
    }

    private func receive(_ trigger: GlobalVoiceTrigger) {
        switch trigger {
        case .pressed:
            let isExclusive = state.withLock { state -> Bool in
                guard state.exclusive != nil else { return false }
                state.suppressNextRelease = true
                return true
            }
            if isExclusive {
                _ = beginConfirmation()
            } else {
                voiceTarget.receive(.pressed)
            }
        case .released:
            let suppressed = state.withLock { state -> Bool in
                guard state.suppressNextRelease else { return false }
                state.suppressNextRelease = false
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
        let request = state.withLock { state -> (UUID, Confirm)? in
            guard var interaction = state.exclusive,
                !interaction.isConfirming
            else { return nil }
            interaction.isConfirming = true
            state.exclusive = interaction
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
        state.withLock { state in
            guard var interaction = state.exclusive,
                interaction.id == id
            else { return }
            if accepted {
                state.exclusive = nil
            } else {
                interaction.isConfirming = false
                state.exclusive = interaction
            }
        }
    }

    private func removeExclusiveInteraction() -> Cancel? {
        state.withLock { state in
            let cancel = state.exclusive?.cancel
            state.exclusive = nil
            // A shortcut press already owned by the displaced interaction must
            // keep its matching release out of the voice gesture state machine.
            return cancel
        }
    }
}
