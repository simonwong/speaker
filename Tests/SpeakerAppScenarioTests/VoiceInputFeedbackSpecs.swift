import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

@MainActor
enum VoiceInputFeedbackSpecs {
    static func run(failures: inout [String]) async {
        await runAsync(
            "voice feedback hides only too-short recording problems", failures: &failures
        ) {
            for error in [AudioCaptureError.tooShort, .silent] {
                var announcements: [String] = []
                let history = SessionHistoryFake()
                let sessions = makeSessions(error: error, history: history)
                let experience = VoiceInputExperience(
                    sessions: sessions, announce: { announcements.append($0) })
                experience.start()
                try await finishRecording(experience)
                let terminal = await eventually(before: .seconds(2)) {
                    experience.state.diagnosticCode.hasPrefix("failed.")
                }
                try expect(terminal)
                let hidden = experience.state.overlay == .hidden
                let consumesEscape = experience.shortcutTarget.shouldConsumeEscape()
                let menuVisible = experience.state.menu.status != nil
                let failureAnnouncement = announcements.contains {
                    $0.contains(error == .tooShort ? "太短" : "声音")
                }
                let retainedFailure = await eventually(before: .seconds(2)) {
                    await history.records.contains {
                        if case .failed(_, let failure) = $0.outcome {
                            failure == VoiceInputProblem(audioCaptureError: error).failure
                        } else {
                            false
                        }
                    }
                }
                await experience.shutdown()
                try expect(retainedFailure, "local rejection lost its terminal Session Record")
                if error == .tooShort {
                    try expect(
                        hidden && !menuVisible && !consumesEscape,
                        "too-short recording left a visible or Escape-owning prompt")
                    try expect(
                        !failureAnnouncement, "too-short recording still announced a problem")
                } else {
                    try expect(
                        !hidden && menuVisible,
                        "silence was incorrectly hidden with too-short input")
                }
            }
        }

        for error in [AudioCaptureError?.none, .microphonePermissionDenied, .silent] {
            await runAsync(
                "voice feedback Escape dismisses \(String(describing: error))", failures: &failures
            ) {
                let sessions = makeSessions(error: error)
                let experience = VoiceInputExperience(sessions: sessions, announce: { _ in })
                experience.start()
                try await finishRecording(experience)
                let terminal = await eventually(before: .seconds(2)) {
                    experience.state.menu.dismissAction != nil
                }
                try expect(terminal)
                let consumesEscape = experience.shortcutTarget.shouldConsumeEscape()
                experience.shortcutTarget.receive(.cancel)
                let dismissed = await eventually(before: .seconds(2)) {
                    experience.state.diagnosticCode == "idle"
                }
                await experience.shutdown()
                try expect(
                    consumesEscape,
                    "Escape passed through to the focused app while a prompt was visible")
                try expect(dismissed, "the global Escape path left the prompt visible")
            }
        }

        await runAsync(
            "voice feedback Escape dismisses a failure while recorder cleanup is pending",
            failures: &failures
        ) {
            let audio = AudioCaptureFake(delaysCancel: true)
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "unused"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: history)
            let experience = VoiceInputExperience(sessions: sessions, announce: { _ in })
            experience.start()
            experience.shortcutTarget.receive(.pressed)
            let observing = await eventually(before: .seconds(2)) {
                await audio.isObservingFailures
            }
            await audio.emitFailure(.deviceConfigurationChanged)
            let pending = await eventually(before: .seconds(2)) {
                let cleanupPending = await audio.hasPendingCancel
                return cleanupPending && experience.state.menu.dismissAction != nil
            }
            experience.shortcutTarget.receive(.cancel)
            let dismissed = await eventually(before: .seconds(2)) {
                experience.state.diagnosticCode == "idle"
            }
            let cleanupStillPending = await audio.hasPendingCancel
            await sessions.send(.pressed, triggerSequence: 100)
            let startsBeforeCleanup = await audio.startCount
            await audio.resumeCancel()
            let recorded = await eventually(before: .seconds(2)) {
                await history.records.contains {
                    if case .failed(_, .audioDeviceChanged) = $0.outcome { true } else { false }
                }
            }
            let afterCleanup = await activity(of: sessions)
            let staysDismissed = experience.state.overlay == .hidden
            await sessions.send(.pressed, triggerSequence: 101)
            let startsAfterCleanup = await audio.startCount
            let newActivity = await activity(of: sessions)
            await experience.shutdown()

            try expect(observing && pending, "failure did not reach paused recorder cleanup")
            try expect(
                dismissed && cleanupStillPending,
                "Escape waited for recorder cleanup before dismissing the failure")
            try expect(
                startsBeforeCleanup == 1, "dismissal allowed recording before cleanup completed")
            try expect(recorded, "dismissal lost the terminal failure Session Record")
            try expect(
                afterCleanup == .idle && staysDismissed, "cleanup resurfaced the dismissed failure")
            try expect(
                startsAfterCleanup == 2 && newActivity.isRecording,
                "recording did not recover after cleanup")
        }

        await runAsync(
            "voice feedback late Escape cannot cancel or dismiss a newer session",
            failures: &failures
        ) {
            let sessions = makeSessions()
            await sessions.send(.pressed, triggerSequence: 10)
            await sessions.send(.released)
            guard case .pendingCopy = await activity(of: sessions) else {
                throw SpecFailure(message: "first retained result missing")
            }
            await sessions.handleEscape(triggeredAtSequence: 11)
            let dismissed = await activity(of: sessions)
            try expect(dismissed == .idle)

            await sessions.send(.pressed, triggerSequence: 20)
            await sessions.handleEscape(triggeredAtSequence: 11)
            guard case .recording = await activity(of: sessions) else {
                throw SpecFailure(message: "late Escape cancelled the new recording")
            }
            await sessions.send(.released)
            await sessions.handleEscape(triggeredAtSequence: 11)
            guard case .pendingCopy = await activity(of: sessions) else {
                throw SpecFailure(message: "late Escape dismissed the new retained result")
            }
            await sessions.handleEscape(triggeredAtSequence: 21)
            let finalActivity = await activity(of: sessions)
            try expect(finalActivity == .idle)
            await sessions.shutdown()
        }
    }

    private static func activity(of sessions: VoiceInputSessions) async -> VoiceInputActivity {
        let stream = await sessions.observe()
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()!.activity
    }

    private static func makeSessions(
        error: AudioCaptureError? = nil,
        history: SessionHistoryFake = SessionHistoryFake()
    ) -> VoiceInputSessions {
        VoiceInputSessions(
            audioCapture: AudioCaptureFake(stopError: error),
            targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
            transcriber: SpeechTranscriberFake(text: "Retained text"),
            delivery: TextDeliveryFake(
                result: .pendingCopy(.deliveryFailed), commitsBeforeDelivering: false),
            clipboard: ClipboardFake(),
            history: history
        )
    }

    private static func finishRecording(_ experience: VoiceInputExperience) async throws {
        experience.shortcutTarget.receive(.pressed)
        let recording = await eventually(before: .seconds(2)) { experience.state.isRecording }
        try expect(recording)
        guard case .recording(_, _, let finish) = experience.state.overlay else {
            throw SpecFailure(message: "recording action missing")
        }
        experience.perform(finish)
    }
}
