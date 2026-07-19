import AppKit
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

@main
struct SpeakerAppUISpecs {
    @MainActor
    static func main() {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []
        var executed = 0

        run(
            "voice input panel has a non-activating production configuration",
            failures: &failures,
            executed: &executed
        ) {
            let size = VoiceInputPanelLayout.processing.size
            let panel = VoiceInputPanelFactory.make(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: size.width,
                    height: size.height
                )
            )
            defer { panel.close() }

            try expect(panel.styleMask.contains(.borderless))
            try expect(panel.styleMask.contains(.nonactivatingPanel))
            try expect(panel.becomesKeyOnlyIfNeeded)
            try expect(
                !panel.canBecomeKey,
                "a notification-only HUD accepted keyboard focus"
            )
            try expect(!panel.canBecomeMain)
            try expect(!panel.hidesOnDeactivate)
            try expect(
                panel.collectionBehavior.contains(.canJoinAllSpaces)
            )
            try expect(
                panel.collectionBehavior.contains(.fullScreenAuxiliary)
            )
        }

        run(
            "ordering the voice input panel does not activate or make it key",
            failures: &failures,
            executed: &executed
        ) {
            let app = NSApplication.shared
            let wasActive = app.isActive
            let keyWindowBefore = app.keyWindow
            let size = VoiceInputPanelLayout.processing.size
            let panel = VoiceInputPanelFactory.make(
                contentRect: NSRect(
                    x: -10_000,
                    y: -10_000,
                    width: size.width,
                    height: size.height
                )
            )
            defer {
                panel.orderOut(nil)
                panel.close()
            }

            panel.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))

            try expect(
                app.isActive == wasActive,
                "ordering the HUD changed application activation"
            )
            try expect(
                app.keyWindow === keyWindowBefore,
                "ordering the HUD replaced the existing key window"
            )
            try expect(
                !panel.isKeyWindow,
                "the non-activating HUD became the key window"
            )
        }

        run(
            "every voice HUD transition applies the destination geometry",
            failures: &failures,
            executed: &executed
        ) {
            let layouts: [VoiceInputPanelLayout] = [
                .processing,
                .recording,
                .pendingCopy,
                .problem,
            ]
            let panel = VoiceInputPanelFactory.make(
                contentRect: NSRect(
                    origin: .zero,
                    size: VoiceInputPanelLayout.processing.size
                )
            )
            defer { panel.close() }

            for source in layouts {
                VoiceInputPanelFactory.apply(source, to: panel)
                for destination in layouts {
                    VoiceInputPanelFactory.apply(destination, to: panel)
                    try expect(
                        panel.frame.size == destination.size,
                        "the window retained \(source) geometry when switching to \(destination)"
                    )
                    try expect(
                        panel.contentView?.frame.size == destination.size,
                        "the content retained \(source) geometry when switching to \(destination)"
                    )
                }
            }
        }

        run(
            "production voice HUD exposes labelled actionable controls",
            failures: &failures,
            executed: &executed
        ) {
            try verifyHUDControls(
                fixture: .processing,
                expectedLabels: ["取消语音输入"]
            )
            try verifyHUDControls(
                fixture: .recording,
                expectedLabels: ["取消语音输入"]
            )
            try verifyHUDControls(
                fixture: .pendingCopy,
                expectedLabels: ["复制", "关闭待复制文字"]
            )
            try verifyHUDControls(
                fixture: .problem,
                expectedLabels: ["关闭错误提示"]
            )
        }

        run(
            "onboarding window remains usable on the available screen",
            failures: &failures,
            executed: &executed
        ) {
            let visibleFrame = NSRect(
                x: 0,
                y: 0,
                width: 580,
                height: 520
            )
            let contentView = NSView(frame: .zero)
            let window = OnboardingWindowFactory.make(
                visibleFrame: visibleFrame,
                contentView: contentView
            )
            defer { window.close() }
            let layout = OnboardingWindowLayout(
                visibleFrame: visibleFrame
            )

            try expect(window.title == "开始使用 Speaker")
            try expect(window.styleMask.contains(.titled))
            try expect(window.styleMask.contains(.closable))
            try expect(window.styleMask.contains(.miniaturizable))
            try expect(window.styleMask.contains(.resizable))
            try expect(window.styleMask.contains(.fullSizeContentView))
            try expect(window.titlebarAppearsTransparent)
            try expect(!window.isReleasedWhenClosed)
            try expect(window.minSize == layout.effectiveMinimumSize)
            try expect(
                window.contentMinSize == layout.effectiveMinimumSize
            )
            try expect(window.contentView === contentView)
            try expect(
                window.contentView?.frame.size == layout.initialSize,
                "the onboarding window ignored the constrained screen size"
            )
        }

        run(
            "contribution heatmap lays out 26 Monday-first weeks with today in the final column",
            failures: &failures,
            executed: &executed
        ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let now = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 19, hour: 15
            ))!
            let today = calendar.startOfDay(for: now)
            let summary = VoiceInputUsageSummary(
                totalRecognizedCharacterCount: 1_000,
                totalSpeakingMilliseconds: 60_000,
                totalSessionCount: 1,
                daily: [VoiceInputDailyUsage(
                    day: today,
                    recognizedCharacterCount: 1_000,
                    speakingMilliseconds: 60_000,
                    sessionCount: 1
                )]
            )
            let heatmap = ContributionHeatmap.build(
                summary: summary,
                now: now,
                calendar: calendar,
                weeks: 26
            )

            try expect(heatmap.columns.count == 26)
            try expect(heatmap.columns.allSatisfy { $0.count == 7 })
            try expect(heatmap.columns.flatMap { $0 }.count == 182)
            try expect(heatmap.hasData)
            // First row of the first column is a Monday (Gregorian weekday 2).
            try expect(
                calendar.component(.weekday, from: heatmap.columns[0][0].date) == 2
            )
            // Today sits in the final column.
            try expect(
                heatmap.columns[25].contains { $0.date == today && !$0.isFuture }
            )
            let todayCell = heatmap.columns.flatMap { $0 }.first { $0.date == today }
            try expect(todayCell?.recognizedCharacterCount == 1_000)
            try expect(todayCell?.level == 3)
            // Everything past today is a hidden future cell.
            let futureCells = heatmap.columns.flatMap { $0 }.filter { $0.date > today }
            try expect(futureCells.allSatisfy { $0.isFuture && $0.level == 0 })
            try expect(heatmap.monthLabels.first?.column == 0)
        }

        run(
            "empty usage summary yields a heatmap with no data",
            failures: &failures,
            executed: &executed
        ) {
            let heatmap = ContributionHeatmap.build(
                summary: .empty,
                now: Date()
            )
            try expect(heatmap.columns.count == 26)
            try expect(!heatmap.hasData)
            try expect(
                heatmap.columns.flatMap { $0 }.allSatisfy {
                    $0.recognizedCharacterCount == 0 && $0.level == 0
                }
            )
        }

        run(
            "usage presentation formats duration, keyboard savings and heatmap shades",
            failures: &failures,
            executed: &executed
        ) {
            let duration = VoiceInputUsagePresentation.speakingDuration(
                milliseconds: (14 * 3_600 + 22 * 60 + 8) * 1_000
            )
            try expect(
                duration == .init(hours: 14, minutes: 22, seconds: 8)
            )
            try expect(
                VoiceInputUsagePresentation.speakingDuration(milliseconds: -5)
                    == .init(hours: 0, minutes: 0, seconds: 0)
            )

            // 132,480 recognized characters ≈ 9.2 hours at 240 chars/min.
            let hours = VoiceInputUsagePresentation.keyboardSavedHours(
                recognizedCharacterCount: 132_480
            )
            try expect(abs(hours - 9.2) < 0.05)
            try expect(
                VoiceInputUsagePresentation.keyboardSavedHours(
                    recognizedCharacterCount: 0
                ) == 0
            )

            try expect(VoiceInputUsagePresentation.heatmapLevel(recognizedCharacterCount: 0) == 0)
            try expect(VoiceInputUsagePresentation.heatmapLevel(recognizedCharacterCount: 399) == 1)
            try expect(VoiceInputUsagePresentation.heatmapLevel(recognizedCharacterCount: 400) == 2)
            try expect(VoiceInputUsagePresentation.heatmapLevel(recognizedCharacterCount: 899) == 2)
            try expect(VoiceInputUsagePresentation.heatmapLevel(recognizedCharacterCount: 900) == 3)
            try expect(VoiceInputUsagePresentation.heatmapLevel(recognizedCharacterCount: 1_499) == 3)
            try expect(VoiceInputUsagePresentation.heatmapLevel(recognizedCharacterCount: 1_500) == 4)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let date = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 9
            ))!
            let description = VoiceInputUsagePresentation.heatmapCellDescription(
                date: date,
                recognizedCharacterCount: 1_204,
                calendar: calendar
            )
            try expect(description.hasPrefix("7月9日 · "))
            try expect(description.hasSuffix(" 字"))
            try expect(description.contains("204"))
        }

        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(
                    Data("FAIL: \(failure)\n".utf8)
                )
            }
            Darwin.exit(1)
        }

        print("PASS: \(executed) AppKit UI specs")
    }
}

@MainActor
private final class HUDActionRecorder {
    private(set) var performedActions = 0
    private(set) var routedEffects = 0

    func perform(
        _ action: VoiceInputExperienceAction
    ) -> VoiceInputExperienceEffect? {
        performedActions += 1
        return .openSpeechSettings
    }

    func route(_ effect: VoiceInputExperienceEffect) {
        routedEffects += 1
    }
}

@MainActor
private func verifyHUDControls(
    fixture: VoiceInputHUDContractFixture,
    expectedLabels: [String],
    expectedRoutedEffects: Int = 0
) throws {
    let recorder = HUDActionRecorder()
    let presentation = fixture.presentation
    guard let layout = VoiceInputPanelLayout(presentation) else {
        throw SpecFailure(message: "fixture unexpectedly produced a hidden HUD")
    }
    let hostingView = NSHostingView(rootView: VoiceInputHUD(
        presentation: presentation,
        performAction: recorder.perform,
        routeEffect: recorder.route
    ))
    hostingView.frame = NSRect(origin: .zero, size: layout.size)
    let window = VoiceInputPanelFactory.make(
        contentRect: NSRect(
            x: -10_000,
            y: -10_000,
            width: layout.size.width,
            height: layout.size.height
        )
    )
    window.contentView = hostingView
    defer {
        window.orderOut(nil)
        window.close()
    }

    window.orderFrontRegardless()
    hostingView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))

    let buttons = accessibilityButtons(in: hostingView)
    let labels = buttons.compactMap(\.label)
    try expect(
        labels.count == expectedLabels.count,
        "expected buttons \(expectedLabels), found \(labels)"
    )

    for expectedLabel in expectedLabels {
        guard let button = buttons.first(where: {
            $0.label == expectedLabel
        }) else {
            throw SpecFailure(
                message: "missing accessibility button \(expectedLabel); found \(labels)"
            )
        }
        let frame = button.frame
        try expect(
            frame.width >= 22 && frame.height >= 22,
            "\(expectedLabel) has an undersized hit target: \(frame)"
        )
        let actionCount = recorder.performedActions
        try expect(
            button.press(),
            "\(expectedLabel) did not expose the press action"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        try expect(
            recorder.performedActions == actionCount + 1,
            "pressing \(expectedLabel) did not execute its production action"
        )
    }

    try expect(
        recorder.routedEffects == expectedRoutedEffects,
        "fixture routed \(recorder.routedEffects) effects instead of \(expectedRoutedEffects)"
    )
}

private struct AccessibilityButton {
    let label: String?
    let frame: NSRect
    let press: () -> Bool
}

@MainActor
private func accessibilityButtons(in root: NSView) -> [AccessibilityButton] {
    root.layoutSubtreeIfNeeded()
    var visited = Set<ObjectIdentifier>()
    var buttons: [AccessibilityButton] = []

    func visit(_ view: NSView) {
        let identifier = ObjectIdentifier(view)
        guard visited.insert(identifier).inserted else { return }
        if view.isAccessibilityElement(),
           let button = view as? NSAccessibilityButton
        {
            buttons.append(AccessibilityButton(
                label: button.accessibilityLabel(),
                frame: button.accessibilityFrame(),
                press: button.accessibilityPerformPress
            ))
        }
        view.subviews.forEach(visit)
    }

    visit(root)
    return buttons
}

private struct SpecFailure: Error {
    let message: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed"
) throws {
    guard condition() else { throw SpecFailure(message: message) }
}

@MainActor
private func run(
    _ name: String,
    failures: inout [String],
    executed: inout Int,
    body: () throws -> Void
) {
    executed += 1
    do {
        try body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}
