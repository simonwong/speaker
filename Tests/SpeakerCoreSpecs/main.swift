import Foundation
import Darwin
import SpeakerCore

@main
struct SpeakerCoreSpecs {
    @MainActor
    static func main() async {
        var failures: [String] = []

        run("initial snapshot comes from permission access", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .notDetermined)
            )

            let model = PermissionModel(access: access)

            try expect(model.snapshot == .init(
                accessibility: .denied,
                microphone: .notDetermined
            ))
            try expect(!model.snapshot.allGranted)
        }

        run("refresh publishes current permission snapshot", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .denied)
            )
            let model = PermissionModel(access: access)
            access.snapshot = .init(accessibility: .granted, microphone: .granted)

            model.refresh()

            try expect(model.snapshot == .init(
                accessibility: .granted,
                microphone: .granted
            ))
            try expect(model.snapshot.allGranted)
        }

        await runAsync("request updates snapshot with provider result", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .granted)
            )
            access.requestResults[.accessibility] = .init(
                accessibility: .granted,
                microphone: .granted
            )
            let model = PermissionModel(access: access)

            await model.request(.accessibility)

            try expect(access.requestedPermissions == [.accessibility])
            try expect(model.snapshot == .init(
                accessibility: .granted,
                microphone: .granted
            ))
        }

        await runAsync("hold and release delivers deterministic transcript", failures: &failures) {
            let audio = AudioCaptureFake()
            let targets = TargetCaptureFake(
                result: .writable(.init(
                    id: UUID(),
                    applicationName: "TextEdit"
                ))
            )
            let transcriber = SpeechTranscriberFake(text: "你好，SwiftUI。")
            let delivery = TextDeliveryFake(result: .delivered)
            let clipboard = ClipboardFake()
            let history = SessionHistoryFake()
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                transcriber: transcriber,
                delivery: delivery,
                clipboard: clipboard,
                history: history
            )
            let presentations = await sessions.observe()
            let terminal = Task { () -> [VoiceInputPresentation] in
                var values: [VoiceInputPresentation] = []
                for await presentation in presentations {
                    values.append(presentation)
                    if presentation.activity.isTerminal {
                        break
                    }
                }
                return values
            }

            await sessions.send(.pressed)
            await sessions.send(.released)

            let values = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            let records = await history.records

            try expect(values.contains { $0.activity.isRecording })
            try expect(values.contains { $0.activity.stage == .transcribing })
            try expect(values.last?.activity.isDelivered == true)
            try expect(zip(values, values.dropFirst()).allSatisfy { $0.revision < $1.revision })
            try expect(deliveredTexts == ["你好，SwiftUI。"])
            try expect(records.count == 1)
            try expect(records.first?.finalText == "你好，SwiftUI。")
        }

        await runAsync("release during recorder startup still completes once", failures: &failures) {
            let audio = AudioCaptureFake(delaysStart: true)
            let targets = TargetCaptureFake(
                result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
            )
            let transcriber = SpeechTranscriberFake(text: "短按也不会丢。")
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: targets,
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let press = Task { await sessions.send(.pressed) }
            while await audio.startCount == 0 {
                await Task.yield()
            }
            await sessions.send(.released)
            await audio.resumeStart()
            await press.value
            await Task.yield()

            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts

            try expect(stopCount == 1)
            try expect(deliveredTexts == ["短按也不会丢。"])
        }

        await runAsync("cancel during recorder startup cleans late recording", failures: &failures) {
            let audio = AudioCaptureFake(delaysStart: true)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "不应出现"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            let press = Task { await sessions.send(.pressed) }
            while await audio.startCount == 0 {
                await Task.yield()
            }
            await sessions.send(.cancel)
            await audio.resumeStart()
            await press.value

            let isActive = await audio.isActive
            try expect(!isActive)
        }

        await runAsync("recording watchdog finishes and submits session", failures: &failures) {
            let audio = AudioCaptureFake()
            let watchdog = RecordingWatchdogFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "已自动提交。"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                watchdog: watchdog
            )
            let presentations = await sessions.observe()
            let terminal = Task { () -> VoiceInputPresentation? in
                for await presentation in presentations {
                    if presentation.activity.isTerminal {
                        return presentation
                    }
                }
                return nil
            }

            await sessions.send(.pressed)
            while await watchdog.waitCount == 0 {
                await Task.yield()
            }
            await watchdog.fire()

            let result = await terminal.value
            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts
            try expect(result?.activity.isDelivered == true)
            try expect(stopCount == 1)
            try expect(deliveredTexts == ["已自动提交。"])
        }

        await runAsync("missing target waits for explicit copy", failures: &failures) {
            let clipboard = ClipboardFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "请手动复制。"),
                delivery: delivery,
                clipboard: clipboard,
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            let copiedBefore = await clipboard.copiedTexts
            try expect(result?.activity.pendingCopyReason == .missingTarget)
            try expect(deliveredTexts.isEmpty)
            try expect(copiedBefore.isEmpty)

            await sessions.send(.copyPendingResult)
            let copiedAfter = await clipboard.copiedTexts
            try expect(copiedAfter == ["请手动复制。"])
        }

        await runAsync("secure target never receives automatic text", failures: &failures) {
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.secureTarget)),
                transcriber: SpeechTranscriberFake(text: "敏感文本"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            let deliveredTexts = await delivery.deliveredTexts
            try expect(result?.activity.pendingCopyReason == .secureTarget)
            try expect(deliveredTexts.isEmpty)
        }

        await runAsync("delivery failure keeps transcript pending copy", failures: &failures) {
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "结果不能丢。"),
                delivery: TextDeliveryFake(result: .pendingCopy(.invalidatedTarget)),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let terminal = terminalPresentation(from: await sessions.observe())

            await sessions.send(.pressed)
            await sessions.send(.released)

            let result = await terminal.value
            try expect(result?.activity.pendingCopyReason == .invalidatedTarget)
            try expect(result?.activity.pendingText == "结果不能丢。")
        }

        await runAsync("duplicate trigger edges submit only once", failures: &failures) {
            let audio = AudioCaptureFake()
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: audio,
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: SpeechTranscriberFake(text: "只提交一次。"),
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            await sessions.send(.pressed)
            await sessions.send(.released)
            await sessions.send(.released)

            let startCount = await audio.startCount
            let stopCount = await audio.stopCount
            let deliveredTexts = await delivery.deliveredTexts
            try expect(startCount == 1)
            try expect(stopCount == 1)
            try expect(deliveredTexts == ["只提交一次。"])
        }

        await runAsync("cancelled late transcription cannot deliver", failures: &failures) {
            let transcriber = SpeechTranscriberFake(text: "迟到结果", delaysResponse: true)
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                transcriber: transcriber,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.send(.pressed)
            let release = Task { await sessions.send(.released) }
            while await transcriber.callCount == 0 {
                await Task.yield()
            }
            await sessions.send(.cancel)
            await transcriber.resume()
            await release.value

            let deliveredTexts = await delivery.deliveredTexts
            try expect(deliveredTexts.isEmpty)
        }

        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            Darwin.exit(1)
        }

        print("PASS: 12 core specs")
    }
}

private actor AudioCaptureFake: AudioCapturing {
    let delaysStart: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var isActive = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(delaysStart: Bool = false) {
        self.delaysStart = delaysStart
    }

    func start() async throws {
        startCount += 1
        if delaysStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        isActive = true
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stop() async throws -> CapturedAudio {
        stopCount += 1
        isActive = false
        return CapturedAudio(
            data: Data([0x52, 0x49, 0x46, 0x46]),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    func cancel() async {
        cancelCount += 1
        isActive = false
    }
}

private actor TargetCaptureFake: InputTargetCapturing {
    let result: InputTargetCaptureResult

    init(result: InputTargetCaptureResult) {
        self.result = result
    }

    func capture() async -> InputTargetCaptureResult {
        result
    }
}

private actor SpeechTranscriberFake: SpeechTranscribing {
    let text: String
    let delaysResponse: Bool
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(text: String, delaysResponse: Bool = false) {
        self.text = text
        self.delaysResponse = delaysResponse
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        callCount += 1
        if delaysResponse {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return TranscriptionResult(text: text, providerRequestID: "local-spec")
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TextDeliveryFake: TextDelivering {
    let result: DeliveryOutcome
    private(set) var deliveredTexts: [String] = []

    init(result: DeliveryOutcome) {
        self.result = result
    }

    func deliver(_ text: String, to target: InputTargetSnapshot) async -> DeliveryOutcome {
        deliveredTexts.append(text)
        return result
    }
}

private actor ClipboardFake: ClipboardWriting {
    private(set) var copiedTexts: [String] = []

    func copy(_ text: String) async {
        copiedTexts.append(text)
    }
}

private actor SessionHistoryFake: SessionHistoryRecording {
    private(set) var records: [VoiceInputHistoryRecord] = []

    func save(_ record: VoiceInputHistoryRecord) async {
        records.append(record)
    }
}

private actor RecordingWatchdogFake: RecordingWatchdog {
    private(set) var waitCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        waitCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PermissionAccessStub: PermissionAccess {
    var snapshot: PermissionSnapshot
    var requestResults: [PermissionKind: PermissionSnapshot] = [:]
    private(set) var requestedPermissions: [PermissionKind] = []

    init(snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> PermissionSnapshot {
        snapshot
    }

    func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        requestedPermissions.append(permission)
        let result = requestResults[permission] ?? snapshot
        snapshot = result
        return result
    }
}

private struct SpecFailure: Error {
    let message: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed"
) throws {
    guard condition() else {
        throw SpecFailure(message: message)
    }
}

@MainActor
private func run(
    _ name: String,
    failures: inout [String],
    body: () throws -> Void
) {
    do {
        try body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

@MainActor
private func runAsync(
    _ name: String,
    failures: inout [String],
    body: () async throws -> Void
) async {
    do {
        try await body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

private func terminalPresentation(
    from stream: AsyncStream<VoiceInputPresentation>
) -> Task<VoiceInputPresentation?, Never> {
    Task {
        for await presentation in stream {
            if presentation.activity.isTerminal {
                return presentation
            }
        }
        return nil
    }
}
