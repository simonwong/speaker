import AppKit
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport
import SwiftUI

enum RefinementSelectionUISpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "refinement cards ring the mode in use in coral and an open editor in gold",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "speaker-refinement-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = LocalFileProviderCredentialStore(
                fileURL: directory.appendingPathComponent("keys.json"))
            try await store.save(apiKey: "synthetic-key", for: .deepSeek)
            let model = RefinementSettingsModel(
                service: CredentialedTextRefiner(credentials: store),
                configuration: VoiceInputConfigurationController(),
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: directory.appendingPathComponent("settings.json")))
            await model.load()
            let hosting = NSHostingView(
                rootView: RefinementSettingsPage(model: model).frame(width: 720, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .environment(\.colorScheme, .light).tint(.blue)
                    // This spec checks which card ends up ringed. Its async
                    // run loop cannot advance SwiftUI animations, so it renders
                    // each selection without the change animation.
                    .transaction { $0.disablesAnimations = true })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            defer {
                window.orderOut(nil)
                window.close()
            }
            let clicks: [RefinementChoice] = [
                .defaultSmooth, .conciseCleanup, .fullRewrite, .custom, .defaultSmooth, .custom,
            ]
            for choice in clicks {
                let index = RefinementChoice.allCases.firstIndex(of: choice)!
                let previouslyActiveMode = model.mode
                pumpUI()
                hosting.layoutSubtreeIfNeeded()
                let titles = ["默认顺滑", "精简清理", "完整重写", "自定义"]
                guard let button = cardButton(named: titles[index], in: hosting) else {
                    throw SpecFailure(message: "missing refinement card \(choice.id)")
                }
                try expect(button.accessibilityPerformPress(), "card click was rejected")
                var lastBitmap: NSBitmapImageRep?
                var selected = HighlightedCards(count: 0, firstColumn: nil)
                var editing = HighlightedCards(count: 0, firstColumn: nil)
                // Opening the Custom editor leaves the previous mode in use:
                // that card keeps the coral ring and the Custom card turns
                // gold. Every other click selects its own card.
                var expectedSelected: Int?
                var expectedEditing: Int?
                let rendered = await eventually(before: .seconds(2)) {
                    pumpUI()
                    hosting.layoutSubtreeIfNeeded()
                    hosting.displayIfNeeded()
                    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
                    else { return false }
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    lastBitmap = bitmap
                    expectedSelected = RefinementChoice.allCases.firstIndex(of: model.choice)
                    expectedEditing = choice == .custom && model.choice != .custom ? index : nil
                    selected = highlightedCards(in: bitmap, matching: isCoral)
                    editing = highlightedCards(in: bitmap, matching: isGold)
                    // Selecting a mode saves before it takes effect, so the old
                    // mode's ring alone does not mean the click was handled.
                    return (choice == .custom || model.choice == choice)
                        && selected.count == 1 && selected.firstColumn == expectedSelected
                        && editing.count == (expectedEditing == nil ? 0 : 1)
                        && editing.firstColumn == expectedEditing
                }
                guard let bitmap = lastBitmap else {
                    throw SpecFailure(message: "cannot render refinement cards")
                }
                if let root = ProcessInfo.processInfo.environment["SPEAKER_UI_CAPTURE_DIR"],
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    let url = URL(fileURLWithPath: root)
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true)
                    try png.write(to: url.appendingPathComponent("refinement-\(choice.id).png"))
                }
                try expect(
                    selected.count == 1,
                    "refinement cards showed \(selected.count) coral rings at once")
                try expect(
                    rendered,
                    "clicking \(choice.id) did not render its rings before the deadline")
                if choice == .custom {
                    try expect(
                        model.mode == previouslyActiveMode,
                        "opening an unfinished custom editor changed the active mode")
                } else {
                    try expect(
                        model.choice == choice, "clicking \(choice.id) did not put it in use")
                }
                try expect(
                    selected.firstColumn == expectedSelected,
                    "clicking \(choice.id) put the coral ring on column \(String(describing: selected.firstColumn)) instead of the mode in use"
                )
                try expect(
                    editing.count == (expectedEditing == nil ? 0 : 1)
                        && editing.firstColumn == expectedEditing,
                    "clicking \(choice.id) left \(editing.count) gold rings, first at column \(String(describing: editing.firstColumn))"
                )
            }
            await model.shutdown()
        }
    }
    private struct HighlightedCards {
        var count: Int
        var firstColumn: Int?
    }

    /// Whether one pixel belongs to a ring of the colour being counted.
    private typealias RingColor =
        @MainActor (_ x: Int, _ y: Int, _ bitmap: NSBitmapImageRep) -> Bool

    @MainActor
    private static func highlightedCards(
        in bitmap: NSBitmapImageRep, matching isRing: RingColor
    ) -> HighlightedCards {
        var result = HighlightedCards(count: 0, firstColumn: nil)
        // Scan every row: a thin horizontal border can fall between sampled rows.
        for y in 0..<bitmap.pixelsHigh {
            guard rowMayContainHighlight(y, in: bitmap, matching: isRing) else { continue }
            var spans = 0
            var length = 0
            for x in 0..<bitmap.pixelsWide {
                if isRing(x, y, bitmap) {
                    length += 1
                } else {
                    if length > 90 {
                        spans += 1
                        if result.firstColumn == nil {
                            result.firstColumn = (x - length / 2) * 4 / bitmap.pixelsWide
                        }
                    }
                    length = 0
                }
            }
            if length > 90 { spans += 1 }
            result.count = max(result.count, spans)
        }
        return result
    }

    @MainActor
    private static func rowMayContainHighlight(
        _ y: Int, in bitmap: NSBitmapImageRep, matching isRing: RingColor
    ) -> Bool {
        var consecutive = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
            consecutive = isRing(x, y, bitmap) ? consecutive + 1 : 0
            // Every span longer than 90 pixels contains at least 11 samples.
            if consecutive >= 11 { return true }
        }
        return false
    }

    /// Only the saturated coral selection ring counts: a highlighted card's
    /// faint tint fill is cut by its own text and must not read as a second
    /// card. Coral and gold both lean red over blue; green sits low for coral
    /// and near the middle for gold. That ratio does not change as a ring's
    /// edge pixels blend into the ground, so it separates the two.
    @MainActor
    private static func isCoral(x: Int, y: Int, in bitmap: NSBitmapImageRep) -> Bool {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        let redOverBlue = color.redComponent - color.blueComponent
        return redOverBlue > 0.3
            && color.redComponent > color.greenComponent
            && color.greenComponent - color.blueComponent < 0.35 * redOverBlue
    }

    /// The gold ring of a card whose editor is open while another mode is in
    /// use.
    @MainActor
    private static func isGold(x: Int, y: Int, in bitmap: NSBitmapImageRep) -> Bool {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        let redOverBlue = color.redComponent - color.blueComponent
        return redOverBlue > 0.15
            && color.redComponent > color.greenComponent
            && color.greenComponent - color.blueComponent > 0.45 * redOverBlue
    }

    @MainActor
    private static func cardButton(named title: String, in view: NSView) -> (
        any NSAccessibilityButton
    )? {
        if let button = view as? any NSAccessibilityButton, button.accessibilityLabel() == title {
            return button
        }
        for child in view.subviews {
            if let button = cardButton(named: title, in: child) { return button }
        }
        return nil
    }
    @MainActor
    private static func pumpUI() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

}
