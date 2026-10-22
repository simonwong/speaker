import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

@MainActor
enum VoiceInputFeedbackSpecs {
    static func run(failures: inout [String]) async {
        await runAsync(
            "voice feedback hides too-short and silent recording problems", failures: &failures
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
                try expect(
                    hidden && !menuVisible && !consumesEscape,
                    "\(error) left a visible or Escape-owning prompt")
                try expect(!failureAnnouncement, "\(error) still announced a problem")
            }
        }

        await runAsync(
            "voice feedback dismisses an informational problem on its own", failures: &failures
        ) {
            let sessions = makeSessions(error: .conversionFailed)
            let experience = VoiceInputExperience(
                sessions: sessions,
                problemAutoDismissDelay: .milliseconds(200),
                announce: { _ in })
            experience.start()
            try await finishRecording(experience)
            let shown = await eventually(before: .seconds(2)) {
                if case .problem = experience.state.overlay { true } else { false }
            }
            let dismissed = await eventually(before: .seconds(2)) {
                experience.state.diagnosticCode == "idle"
            }
            let releasesEscape = !experience.shortcutTarget.shouldConsumeEscape()
            await experience.shutdown()
            try expect(shown, "the problem never became visible")
            try expect(dismissed && releasesEscape, "the problem stayed on screen")
        }

        await runAsync(
            "voice feedback holds an informational problem while the pointer rests on it",
            failures: &failures
        ) {
            let sessions = makeSessions(error: .conversionFailed)
            let experience = VoiceInputExperience(
                sessions: sessions,
                problemAutoDismissDelay: .milliseconds(200),
                announce: { _ in })
            experience.start()
            try await finishRecording(experience)
            let shown = await eventually(before: .seconds(2)) {
                if case .problem = experience.state.overlay { true } else { false }
            }
            experience.holdProblem(true)
            try await Task.sleep(for: .milliseconds(500))
            let held = if case .problem = experience.state.overlay { true } else { false }
            experience.holdProblem(false)
            let dismissed = await eventually(before: .seconds(2)) {
                experience.state.diagnosticCode == "idle"
            }
            await experience.shutdown()
            try expect(shown, "the problem never became visible")
            try expect(held, "the problem dismissed under the pointer")
            try expect(dismissed, "the problem stayed after the pointer left")
        }

        for error in [AudioCaptureError?.none, .microphonePermissionDenied] {
            await runAsync(
                "voice feedback keeps \(String(describing: error)) until the user acts",
                failures: &failures
            ) {
                let sessions = makeSessions(error: error)
                let experience = VoiceInputExperience(
                    sessions: sessions,
                    problemAutoDismissDelay: .milliseconds(50),
                    announce: { _ in })
                experience.start()
                try await finishRecording(experience)
                let shown = await eventually(before: .seconds(2)) {
                    experience.state.menu.dismissAction != nil
                }
                try await Task.sleep(for: .milliseconds(400))
                let stillShown = experience.state.menu.dismissAction != nil
                await experience.shutdown()
                try expect(shown && stillShown, "an actionable prompt dismissed itself")
            }
        }

        for error in [AudioCaptureError?.none, .microphonePermissionDenied, .conversionFailed] {
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
            "voice feedback offers the recognition result only while refinement is pending",
            failures: &failures
        ) {
            for stage in [VoiceInputProcessingStage.transcribing, .refining] {
                let processor = HangingVoiceTextProcessor(
                    reportedStage: stage,
                    confirmedText: stage == .refining ? "已识别的文字" : nil
                )
                let delivery = TextDeliveryFake(result: .delivered)
                let sessions = VoiceInputSessions(
                    audioCapture: AudioCaptureFake(),
                    targetCapture: TargetCaptureFake(
                        result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                    ),
                    textProcessor: processor,
                    delivery: delivery,
                    clipboard: ClipboardFake(),
                    history: SessionHistoryFake()
                )
                let experience = VoiceInputExperience(sessions: sessions, announce: { _ in })
                experience.start()
                try await finishRecording(experience)
                let reachedStage = await eventually(before: .seconds(2)) {
                    experience.state.diagnosticCode == "processing.\(stage)"
                }
                try expect(reachedStage, "processing never reached \(stage)")
                guard
                    case .processing(_, let cancel, let useRecognition) = experience.state.overlay
                else {
                    throw SpecFailure(message: "processing overlay missing")
                }
                guard let useRecognition else {
                    try expect(stage != .refining, "pending refinement offered no shortcut")
                    experience.perform(cancel)
                    await experience.shutdown()
                    continue
                }
                try expect(stage == .refining, "\(stage) offered the recognition result")
                experience.perform(useRecognition)
                let delivered = await eventually(before: .seconds(2)) {
                    await delivery.deliveredTexts == ["已识别的文字"]
                }
                let cancelled = await eventually(before: .seconds(2)) {
                    await processor.cancellationCount == 1
                }
                await experience.shutdown()
                try expect(delivered, "the recognition result was not delivered")
                try expect(cancelled, "pending refinement kept running")
            }
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

        await runAsync(
            "voice feedback keeps a secure target's text off the HUD and still copies it",
            failures: &failures
        ) {
            let clipboard = ClipboardFake(succeeds: false)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.secureTarget)),
                transcriber: SpeechTranscriberFake(text: "Secret sentinel"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake()
            )
            var announcements: [String] = []
            let experience = VoiceInputExperience(
                sessions: sessions, announce: { announcements.append($0) })
            experience.start()
            try await finishRecording(experience)
            let retained = await eventually(before: .seconds(2)) {
                if case .pendingCopy = experience.state.overlay { true } else { false }
            }
            try expect(retained, "the secure result was not retained")
            guard
                case .pendingCopy(_, let shownText, _, let copy, _, _) = experience.state.overlay
            else { throw SpecFailure(message: "pending copy overlay missing") }
            experience.perform(copy)
            let failedOnce = await eventually(before: .seconds(2)) {
                if case .pendingCopy(_, _, _, _, _, true) = experience.state.overlay {
                    true
                } else {
                    false
                }
            }
            guard
                case .pendingCopy(_, let retryText, let retryTitle, let retry, _, _) =
                    experience.state.overlay
            else { throw SpecFailure(message: "retry overlay missing") }
            await clipboard.setSucceeds(true)
            experience.perform(retry)
            let copied = await eventually(before: .seconds(2)) {
                await clipboard.copiedTexts.count == 2
            }
            let copiedTexts = await clipboard.copiedTexts
            let privacies = await clipboard.copiedPrivacies
            await experience.shutdown()

            try expect(
                shownText == PendingCopyReason.secureTargetConcealedText
                    && retryText == PendingCopyReason.secureTargetConcealedText,
                "the HUD showed a secure target's text")
            try expect(failedOnce && retryTitle == "重试复制", "the failed copy offered no retry")
            try expect(
                copied && copiedTexts == ["Secret sentinel", "Secret sentinel"],
                "the copy button did not copy the retained text")
            try expect(
                privacies == [.concealed, .concealed],
                "a secure target's copy was not concealed")
            try expect(
                !announcements.contains { $0.contains("Secret sentinel") },
                "a secure target's text reached an announcement")
        }

        await runAsync(
            "voice feedback names the App holding Secure Event Input once per note",
            failures: &failures
        ) {
            var announcements: [String] = []
            var lookups = 0
            let experience = VoiceInputExperience(
                sessions: makeSessions(),
                secureInputNoticeDuration: .milliseconds(300),
                secureInputHolderName: {
                    lookups += 1
                    return "Terminal"
                },
                announce: { announcements.append($0) })
            experience.start()
            for _ in 0..<5 {
                experience.shortcutTarget.secureInputBlockedPress()
            }
            let expected = SecureInputBlockedNotice.title(holderName: "Terminal")
            let shown = await eventually(before: .seconds(2)) {
                experience.state.overlay == .notice(title: expected)
            }
            try await Task.sleep(for: .milliseconds(100))
            let announcedWhileShown = announcements
            let lookupsWhileShown = lookups
            let hidden = await eventually(before: .seconds(2)) {
                experience.state.overlay == .hidden
            }
            experience.shortcutTarget.secureInputBlockedPress()
            let shownAgain = await eventually(before: .seconds(2)) {
                experience.state.overlay == .notice(title: expected)
            }
            let announcedAfter = announcements
            await experience.shutdown()

            try expect(expected.contains("Terminal"), "the note did not name the App")
            try expect(shown, "a refused press showed no note")
            try expect(
                announcedWhileShown == [expected] && lookupsWhileShown == 1,
                "repeated presses repeated the note")
            try expect(hidden, "the note stayed on screen")
            try expect(
                shownAgain && announcedAfter == [expected, expected],
                "a press after the note closed showed nothing")
        }

        await runAsync(
            "voice feedback uses a general note when the holding App is unknown",
            failures: &failures
        ) {
            let experience = VoiceInputExperience(
                sessions: makeSessions(),
                announce: { _ in })
            experience.start()
            experience.shortcutTarget.secureInputBlockedPress()
            let shown = await eventually(before: .seconds(2)) {
                experience.state.overlay
                    == .notice(title: SecureInputBlockedNotice.genericTitle)
            }
            await experience.shutdown()
            try expect(shown, "the general note did not appear")
            try expect(
                SecureInputBlockedNotice.title(holderName: "  ")
                    == SecureInputBlockedNotice.genericTitle,
                "a blank App name produced a broken note")
        }

        await runAsync(
            "voice feedback keeps a retained result over the Secure Event Input note",
            failures: &failures
        ) {
            let experience = VoiceInputExperience(
                sessions: makeSessions(),
                secureInputHolderName: { "Terminal" },
                announce: { _ in })
            experience.start()
            try await finishRecording(experience)
            let retained = await eventually(before: .seconds(2)) {
                if case .pendingCopy = experience.state.overlay { true } else { false }
            }
            try expect(retained, "the result was not retained")
            let before = experience.state.overlay
            experience.shortcutTarget.secureInputBlockedPress()
            try await Task.sleep(for: .milliseconds(200))
            let after = experience.state.overlay
            await experience.shutdown()
            try expect(after == before, "the note replaced the retained result")
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
        guard case .recording(_, _, let finish, _) = experience.state.overlay else {
            throw SpecFailure(message: "recording action missing")
        }
        experience.perform(finish)
    }
}
