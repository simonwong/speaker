import AppKit
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport
import SwiftUI

enum RefinementSelectionUISpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("refinement cards highlight only the active mode", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "speaker-refinement-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = LocalFileProviderCredentialStore(
                fileURL: directory.appendingPathComponent("keys.json"))
            try await store.save(apiKey: "synthetic-key", for: .deepSeek)
            let model = RefinementSettingsModel(
                service: CredentialedDeepSeekTextRefiner(credentials: store),
                configuration: VoiceInputConfigurationController(),
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: directory.appendingPathComponent("settings.json")))
            await model.load()
            let hosting = NSHostingView(
                rootView: RefinementSettingsPage(model: model).frame(width: 900, alignment: .top)
                    .environment(\.colorScheme, .light).tint(.blue))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            for choice in RefinementChoice.allCases {
                await model.select(choice)
                let rendered = await eventually(before: .seconds(2)) {
                    pumpUI()
                    hosting.layoutSubtreeIfNeeded()
                    return hosting.bounds.width > 0
                }
                try expect(rendered)
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
                else { throw SpecFailure(message: "cannot render refinement cards") }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let root = ProcessInfo.processInfo.environment["SPEAKER_UI_CAPTURE_DIR"],
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    let url = URL(fileURLWithPath: root)
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true)
                    try png.write(to: url.appendingPathComponent("refinement-\(choice.id).png"))
                }
                // Long blue spans are the card borders or background, excluding icons and text.
                var maximumHighlightedCards = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                    var spans = 0
                    var length = 0
                    for x in 0..<bitmap.pixelsWide {
                        let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                        let blue =
                            color.map {
                                $0.blueComponent - $0.redComponent > 0.035
                                    && $0.blueComponent > $0.greenComponent
                            } ?? false
                        if blue {
                            length += 1
                        } else {
                            if length > 90 { spans += 1 }
                            length = 0
                        }
                    }
                    if length > 90 { spans += 1 }
                    maximumHighlightedCards = max(maximumHighlightedCards, spans)
                }
                try expect(
                    maximumHighlightedCards == 1,
                    "refinement cards showed \(maximumHighlightedCards) simultaneous highlights")
            }
            await model.shutdown()
        }
    }
    @MainActor
    private static func pumpUI() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

}
