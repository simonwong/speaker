import AppKit
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport
import SwiftUI

@main
struct SpeakerAppUISpecs {
    @MainActor
    static func main() {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        run(
            "voice input panel has a non-activating production configuration",
            failures: &failures
        ) {
            let presenter = VoiceInputPanelPresenter { _ in Color.clear }
            defer { presenter.stop() }
            let evidence = presenter.evidence

            try expect(evidence.isBorderless)
            try expect(evidence.isNonactivating)
            try expect(evidence.becomesKeyOnlyIfNeeded)
            try expect(
                !evidence.canBecomeKey,
                "a notification-only HUD accepted keyboard focus"
            )
            try expect(!evidence.canBecomeMain)
            try expect(!evidence.hidesOnDeactivate)
            try expect(evidence.joinsAllSpaces)
            try expect(evidence.appearsOverFullScreen)
        }

        run(
            "voice input panel keeps the hosting surface transparent outside the HUD",
            failures: &failures
        ) {
            let presentation = VoiceInputHUDContractFixture.recording.presentation
            let presenter = VoiceInputPanelPresenter { presentation in
                VoiceInputHUD(
                    presentation: presentation,
                    performAction: { _ in nil },
                    routeEffect: { _ in }
                )
            }
            defer { presenter.stop() }
            presenter.present(presentation)
            let evidence = presenter.evidence

            try expect(evidence.hostingSurfaceIsLayerBacked)
            try expect(evidence.hostingSurfaceIsOpaque == false)
            try expect(
                evidence.hostingSurfaceBackgroundAlpha == 0,
                "the hosting surface added an opaque rectangular background"
            )
            let image = try presenter.renderedBitmap()
            let corners = [
                (x: 0, y: 0),
                (x: image.pixelsWide - 1, y: 0),
                (x: 0, y: image.pixelsHigh - 1),
                (x: image.pixelsWide - 1, y: image.pixelsHigh - 1),
            ]
            let cornerAlphas = corners.compactMap {
                image.colorAt(x: $0.x, y: $0.y)?.alphaComponent
            }
            try expect(cornerAlphas.count == corners.count)
            try expect(
                cornerAlphas.allSatisfy { $0 < 0.01 },
                "rendered HUD corners were not transparent: \(cornerAlphas)"
            )
        }

        run(
            "Reduce Transparency makes only the shaped HUD surface opaque",
            failures: &failures
        ) {
            let presentation = VoiceInputHUDContractFixture.recording.presentation
            let presenter = VoiceInputPanelPresenter { presentation in
                VoiceInputHUD(
                    presentation: presentation,
                    performAction: { _ in nil },
                    routeEffect: { _ in }
                )
                .environment(\.adaptiveGlassSurfaceStyleOverride, .opaque)
            }
            defer { presenter.stop() }
            presenter.present(presentation)
            let image = try presenter.renderedBitmap()
            let centerAlpha = image.colorAt(
                x: image.pixelsWide / 2,
                y: image.pixelsHigh / 2
            )?.alphaComponent ?? 0
            let cornerAlpha = image.colorAt(x: 0, y: 0)?.alphaComponent ?? 1

            try expect(
                centerAlpha > 0.99,
                "Reduce Transparency left the HUD centre translucent: \(centerAlpha)"
            )
            try expect(
                cornerAlpha < 0.01,
                "opaque fallback added a rectangular backing: \(cornerAlpha)"
            )
        }

        run(
            "legacy HUD fallback keeps an active behind-window material",
            failures: &failures
        ) {
            let presentation = VoiceInputHUDContractFixture.recording.presentation
            let presenter = VoiceInputPanelPresenter { presentation in
                VoiceInputHUD(
                    presentation: presentation,
                    performAction: { _ in nil },
                    routeEffect: { _ in }
                )
                .environment(\.adaptiveGlassSurfaceStyleOverride, .systemMaterial)
            }
            defer { presenter.stop() }
            presenter.present(presentation)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))

            let effects = presenter.visualEffectEvidence
            try expect(effects.count == 1, "found \(effects.count) material views")
            guard let effect = effects.first else { return }
            try expect(effect.material == .hudWindow)
            try expect(effect.blendingMode == .behindWindow)
            try expect(effect.state == .active)
        }

        run(
            "Liquid Glass HUD keeps an adaptive behind-window backing",
            failures: &failures
        ) {
            let presentation = VoiceInputHUDContractFixture.recording.presentation
            let presenter = VoiceInputPanelPresenter { presentation in
                VoiceInputHUD(
                    presentation: presentation,
                    performAction: { _ in nil },
                    routeEffect: { _ in }
                )
                .environment(\.adaptiveGlassSurfaceStyleOverride, .liquidGlass)
            }
            defer { presenter.stop() }
            presenter.present(presentation)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))

            let effects = presenter.visualEffectEvidence
            try expect(effects.count == 1, "found \(effects.count) material views")
            guard let effect = effects.first else { return }
            try expect(effect.material == .hudWindow)
            try expect(effect.blendingMode == .behindWindow)
            try expect(effect.state == .active)
        }

        run(
            "Increase Contrast strengthens the rendered HUD boundary",
            failures: &failures
        ) {
            let standard = try renderedHUDBitmap(increasedContrast: false)
            let increased = try renderedHUDBitmap(increasedContrast: true)
            let standardLuminance = hudTopBorderLuminance(standard)
            let increasedLuminance = hudTopBorderLuminance(increased)

            try expect(
                increasedLuminance > standardLuminance + 0.01,
                "boundary luminance did not increase: \(standardLuminance) -> \(increasedLuminance)"
            )
        }

        run(
            "Speaker menu bar artwork uses adaptive template rendering",
            failures: &failures
        ) {
            let fallback = SpeakerMenuBarIconArtwork.fallbackImage
            try expect(
                fallback.isTemplate,
                "menu bar fallback was not a template image"
            )
            guard let fallbackData = fallback.tiffRepresentation,
                  let fallbackBitmap = NSBitmapImageRep(data: fallbackData)
            else {
                throw SpecFailure(message: "could not render menu bar fallback")
            }
            let fallbackVisiblePixels = (0..<fallbackBitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<fallbackBitmap.pixelsWide).filter { x in
                    (fallbackBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08
                }.count
            }
            try expect(
                fallbackVisiblePixels >= 12,
                "menu bar fallback rendered empty"
            )

            for state in [
                MenuBarIconState.ready,
                .recording,
                .needsPermission,
            ] {
                let image = SpeakerMenuBarIconArtwork.image(for: state)
                try expect(
                    image.isTemplate,
                    "\(state) menu bar artwork was not a template image"
                )
                try expect(
                    image.size == NSSize(width: 20, height: 18),
                    "\(state) menu bar artwork used size \(image.size)"
                )
            }
        }

        run(
            "Speaker menu bar mark stays legible and stateful at status-item size",
            failures: &failures
        ) {
            var renderedStates: [Data] = []
            for (state, expectedLabel) in [
                (MenuBarIconState.ready, "Speaker"),
                (.recording, "Speaker，正在录音"),
                (.needsPermission, "Speaker，需要完成权限设置"),
            ] {
                let hostingView = NSHostingView(rootView:
                    SpeakerMenuBarLabel(state: state)
                        .frame(width: 20, height: 18)
                )
                hostingView.frame = NSRect(x: 0, y: 0, width: 20, height: 18)
                hostingView.layoutSubtreeIfNeeded()
                try expect(
                    accessibilityLabels(in: hostingView).contains(expectedLabel),
                    "\(state) mark did not expose \(expectedLabel)"
                )

                guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
                    in: hostingView.bounds
                ) else {
                    throw SpecFailure(message: "could not render menu bar mark")
                }
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

                let visiblePixels = (0..<bitmap.pixelsHigh).flatMap { y in
                    (0..<bitmap.pixelsWide).compactMap { x -> NSPoint? in
                        guard let color = bitmap.colorAt(x: x, y: y),
                              color.alphaComponent > 0.08
                        else { return nil }
                        return NSPoint(x: x, y: y)
                    }
                }
                try expect(
                    visiblePixels.count >= 24,
                    "\(state) mark was not legible at status-item size"
                )
                let visibleX = visiblePixels.map(\.x)
                let visibleY = visiblePixels.map(\.y)
                guard let minX = visibleX.min(), let maxX = visibleX.max(),
                      let minY = visibleY.min(), let maxY = visibleY.max()
                else {
                    throw SpecFailure(message: "menu bar mark rendered no bounds")
                }
                try expect(
                    maxX - minX >= 13 && maxY - minY >= 6,
                    "\(state) mark used undersized bounds \(minX)...\(maxX), \(minY)...\(maxY)"
                )
                let corners = [
                    (0, 0),
                    (bitmap.pixelsWide - 1, 0),
                    (0, bitmap.pixelsHigh - 1),
                    (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1),
                ]
                try expect(
                    corners.allSatisfy { x, y in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.01
                    },
                    "\(state) mark did not preserve a transparent outer background"
                )
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw SpecFailure(message: "could not encode menu bar mark")
                }
                renderedStates.append(png)
            }

            try expect(
                Set(renderedStates).count == renderedStates.count,
                "menu bar states rendered as one indistinguishable mark"
            )
        }

        run(
            "Speaker identity tiles expose product identity only without adjacent text",
            failures: &failures
        ) {
            let named = NSHostingView(rootView:
                SpeakerIdentityTile(size: 44, accessibility: .named)
            )
            named.frame = NSRect(x: 0, y: 0, width: 44, height: 44)
            let namedWindow = NSWindow(
                contentRect: named.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            namedWindow.contentView = named

            let redundant = NSHostingView(rootView:
                SpeakerIdentityTile(size: 30, accessibility: .hidden)
            )
            redundant.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
            let redundantWindow = NSWindow(
                contentRect: redundant.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            redundantWindow.contentView = redundant
            defer {
                namedWindow.close()
                redundantWindow.close()
            }

            namedWindow.orderFrontRegardless()
            redundantWindow.orderFrontRegardless()
            named.layoutSubtreeIfNeeded()
            redundant.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))

            let namedLabels = accessibilityLabels(in: named)
            let redundantLabels = accessibilityLabels(in: redundant)
            try expect(
                namedLabels.contains("Speaker"),
                "named identity tile exposed labels \(namedLabels)"
            )
            try expect(
                !redundantLabels.contains("Speaker"),
                "redundant identity tile exposed labels \(redundantLabels)"
            )
        }

        run(
            "ordering the voice input panel does not activate or make it key",
            failures: &failures
        ) {
            let app = NSApplication.shared
            let wasActive = app.isActive
            let keyWindowBefore = app.keyWindow
            let presenter = VoiceInputPanelPresenter { _ in Color.clear }
            defer { presenter.stop() }

            presenter.present(
                VoiceInputHUDContractFixture.processing.presentation
            )
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
                !presenter.evidence.isKeyWindow,
                "the non-activating HUD became the key window"
            )
        }

        run(
            "every voice HUD transition applies the destination geometry",
            failures: &failures
        ) {
            let presentations: [(VoiceInputOverlayPresentation, CGSize)] = [
                (
                    VoiceInputHUDContractFixture.processing.presentation,
                    CGSize(width: 128, height: 44)
                ),
                (
                    VoiceInputHUDContractFixture.recording.presentation,
                    CGSize(width: 128, height: 44)
                ),
                (
                    VoiceInputHUDContractFixture.pendingCopy.presentation,
                    CGSize(width: 394, height: 54)
                ),
                (
                    VoiceInputHUDContractFixture.problem.presentation,
                    CGSize(width: 330, height: 54)
                ),
            ]
            let presenter = VoiceInputPanelPresenter { presentation in
                VoiceInputHUD(
                    presentation: presentation,
                    performAction: { _ in nil },
                    routeEffect: { _ in }
                )
            }
            defer { presenter.stop() }

            for (source, _) in presentations {
                presenter.present(source)
                for (destination, expectedSize) in presentations {
                    presenter.present(destination)
                    let evidence = presenter.evidence
                    try expect(
                        evidence.windowSize == expectedSize,
                        "the window retained source geometry when switching presentation"
                    )
                    try expect(
                        evidence.contentSize == expectedSize,
                        "the content retained source geometry when switching presentation"
                    )
                }
            }
        }

        run(
            "voice HUD presenter keeps a re-shown panel after stale dismissal",
            failures: &failures
        ) {
            var completeDismissal: (() -> Void)?
            let presenter = VoiceInputPanelPresenter(
                reduceMotion: { false },
                scheduleDismissal: { _, completion in
                    completeDismissal = completion
                }
            ) { presentation in
                VoiceInputHUD(
                    presentation: presentation,
                    performAction: { _ in nil },
                    routeEffect: { _ in }
                )
            }
            defer { presenter.stop() }

            presenter.present(VoiceInputHUDContractFixture.recording.presentation)
            presenter.present(.hidden)
            presenter.present(VoiceInputHUDContractFixture.problem.presentation)
            completeDismissal?()

            try expect(presenter.evidence.isVisible)
            try expect(
                presenter.evidence.windowSize == CGSize(width: 330, height: 54)
            )
        }

        run(
            "voice HUD presenter respects Reduce Motion during dismissal",
            failures: &failures
        ) {
            let animated = VoiceInputPanelPresenter(
                reduceMotion: { false }
            ) { _ in Color.clear }
            defer { animated.stop() }
            animated.present(
                VoiceInputHUDContractFixture.recording.presentation
            )
            animated.present(.hidden)
            try expect(animated.evidence.isCollapsingActivity)

            let reduced = VoiceInputPanelPresenter(
                reduceMotion: { true }
            ) { _ in Color.clear }
            defer { reduced.stop() }
            reduced.present(
                VoiceInputHUDContractFixture.recording.presentation
            )
            reduced.present(.hidden)
            try expect(!reduced.evidence.isCollapsingActivity)
        }

        run(
            "every voice HUD presentation completes dismissal",
            failures: &failures
        ) {
            let presenter = VoiceInputPanelPresenter(
                reduceMotion: { false },
                scheduleDismissal: { _, completion in completion() }
            ) { _ in Color.clear }
            defer { presenter.stop() }

            for fixture in VoiceInputHUDContractFixture.allCases {
                presenter.present(fixture.presentation)
                presenter.present(.hidden)
                try expect(
                    !presenter.evidence.isVisible,
                    "\(fixture) did not complete dismissal"
                )
            }
        }

        run(
            "production voice HUD exposes labelled actionable controls",
            failures: &failures
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
            "dictionary chip exposes a labelled delete action",
            failures: &failures
        ) {
            let recorder = DictionaryActionRecorder()
            let hostingView = NSHostingView(rootView: DictionaryEntryChip(
                word: "Speaker",
                onDelete: recorder.record
            ))
            hostingView.frame = NSRect(x: 0, y: 0, width: 180, height: 60)
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 180, height: 60),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let buttons = accessibilityButtons(in: hostingView)
            let button = buttons.first {
                $0.label == "删除词条 Speaker"
            }

            try expect(
                button != nil,
                "dictionary delete action has no AX label; found \(buttons.map(\.label))"
            )
            try expect(button?.press() == true, "dictionary delete action cannot be pressed")
            try expect(recorder.performedActions == 1)
        }

        run(
            "dictionary chip exposes omission and quality guidance",
            failures: &failures
        ) {
            let hostingView = NSHostingView(rootView: DictionaryEntryChip(
                word: "1234567890",
                isOmitted: true,
                qualityHint: .tooLong,
                onDelete: {}
            ))
            hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 80),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let labels = accessibilityLabels(in: hostingView)

            try expect(
                labels.contains { $0.contains("不会发送") },
                "dictionary omission guidance is not exposed; found \(labels)"
            )
            try expect(
                labels.contains { $0.contains("建议少于 10 个字符") },
                "dictionary quality guidance is not exposed; found \(labels)"
            )
        }

        run(
            "onboarding window remains usable on the available screen",
            failures: &failures
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

            try expect(window.title == OnboardingWindowFactory.windowTitle)
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
            "main window keeps one minimum without changing its current geometry",
            failures: &failures
        ) {
            let window = NSWindow(
                contentRect: NSRect(
                    x: -10_000,
                    y: -10_000,
                    width: 900,
                    height: 640
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            defer { window.close() }
            let sizeBeforeConfiguration = window.frame.size

            MainWindowWindowConfiguration.apply(to: window)

            let expectedMinimum = CGSize(width: 720, height: 560)
            let expectedFrameMinimum = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: expectedMinimum)
            ).size
            try expect(
                window.minSize == expectedFrameMinimum,
                "frame minimum is \(window.minSize)"
            )
            try expect(
                window.contentMinSize == expectedMinimum,
                "content minimum is \(window.contentMinSize)"
            )
            try expect(
                window.frame.size == sizeBeforeConfiguration,
                "configuring a tab changed the existing window geometry"
            )
        }

        run(
            "main window SwiftUI bridge applies the production minimum",
            failures: &failures
        ) {
            let window = NSWindow(
                contentRect: NSRect(
                    x: -10_000,
                    y: -10_000,
                    width: 900,
                    height: 640
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(
                rootView: MainWindowWindowConfigurator()
            )
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }

            let expectedMinimum = CGSize(width: 720, height: 560)
            let deadline = Date().addingTimeInterval(1)
            while window.contentMinSize != expectedMinimum, Date() < deadline {
                RunLoop.current.run(
                    until: min(deadline, Date().addingTimeInterval(0.01))
                )
            }

            try expect(
                window.contentMinSize == expectedMinimum,
                "SwiftUI bridge left content minimum at \(window.contentMinSize)"
            )
        }

        run(
            "switching every main window tab preserves minimum and default geometry",
            failures: &failures
        ) {
            let selection = MainWindowSelectionFixture()
            let window = NSWindow(
                contentRect: NSRect(
                    x: -10_000,
                    y: -10_000,
                    width: 900,
                    height: 640
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(
                rootView: MainWindowGeometryFixture(selection: selection)
            )
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))

            for contentSize in [
                CGSize(width: 720, height: 560),
                CGSize(width: 900, height: 640),
            ] {
                window.setContentSize(contentSize)
                let expectedFrame = window.frame

                for tab in MainWindowTab.allCases {
                    selection.selection = tab
                    RunLoop.current.run(
                        until: Date().addingTimeInterval(0.02)
                    )
                    try expect(
                        window.frame == expectedFrame,
                        "\(tab) changed \(contentSize) to \(window.frame.size)"
                    )
                }
            }
        }

        run(
            "settings overview shows the top before explicit section navigation",
            failures: &failures
        ) {
            let navigation = SettingsNavigationModel()
            let window = NSWindow(
                contentRect: NSRect(
                    x: -10_000,
                    y: -10_000,
                    width: 360,
                    height: 220
                ),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(
                rootView: SettingsOverviewScrollFixture(
                    navigation: navigation
                )
            )
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))

            guard let scrollView = firstScrollView(in: window.contentView) else {
                throw SpecFailure(message: "settings fixture has no scroll view")
            }
            let initialDistance = verticalDistanceFromTop(scrollView)
            try expect(
                initialDistance < 1,
                "ordinary settings opened \(initialDistance)pt below the top"
            )

            let explicitNavigation = SettingsNavigationModel()
            explicitNavigation.open(.permissions)
            window.contentView = NSHostingView(
                rootView: SettingsOverviewScrollFixture(
                    navigation: explicitNavigation
                )
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            guard let explicitScrollView = firstScrollView(
                in: window.contentView
            ) else {
                throw SpecFailure(
                    message: "explicit settings fixture has no scroll view"
                )
            }
            let deadline = Date().addingTimeInterval(1)
            while verticalDistanceFromTop(explicitScrollView) < 100,
                  Date() < deadline
            {
                RunLoop.current.run(
                    until: min(deadline, Date().addingTimeInterval(0.01))
                )
            }
            try expect(
                verticalDistanceFromTop(explicitScrollView) >= 100,
                "explicit permission navigation did not move the viewport; "
                    + "request=\(String(describing: explicitNavigation.presentationRequest)), "
                    + "visible=\(explicitScrollView.documentVisibleRect), "
                    + "document=\(String(describing: explicitScrollView.documentView?.bounds))"
            )
            try expect(explicitNavigation.presentationRequest == nil)
        }

        run(
            "main window tabs keep the native style without separators",
            failures: &failures
        ) {
            let selection = MainWindowSelectionFixture()
            let window = NSWindow(
                contentRect: NSRect(
                    x: -10_000,
                    y: -10_000,
                    width: 900,
                    height: 640
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(
                rootView: MainWindowGeometryFixture(selection: selection)
            )
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))

            guard let frameView = window.contentView?.superview,
                  let tabs = segmentedControls(in: frameView).first(where: {
                      $0.segmentCount == MainWindowTab.allCases.count
                  }) else {
                throw SpecFailure(
                    message: "top tabs were replaced with a custom control"
                )
            }
            try expect(
                tabs.segmentStyle == .automatic,
                "top tabs changed the native automatic style"
            )
            guard let mask = tabs.superview?.layer?.mask as? CAShapeLayer,
                  let path = mask.path else {
                throw SpecFailure(message: "top tab separators were still visible")
            }
            let segmentWidth = tabs.superview!.bounds.width
                / CGFloat(tabs.segmentCount)
            try expect(
                path.contains(CGPoint(x: segmentWidth / 2, y: 10)),
                "separator mask hid tab content"
            )
            try expect(
                !path.contains(CGPoint(x: segmentWidth, y: 10)),
                "separator mask kept an internal divider"
            )
        }

        run(
            "contribution heatmap lays out 52 Monday-first weeks with today in the final column",
            failures: &failures
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
                calendar: calendar
            )

            try expect(heatmap.columns.count == 52)
            try expect(heatmap.columns.allSatisfy { $0.count == 7 })
            try expect(heatmap.columns.flatMap { $0 }.count == 364)
            try expect(heatmap.hasData)
            // First row of the first column is a Monday (Gregorian weekday 2).
            try expect(
                calendar.component(.weekday, from: heatmap.columns[0][0].date) == 2
            )
            // Today sits in the final column.
            try expect(
                heatmap.columns[51].contains { $0.date == today && !$0.isFuture }
            )
            let todayCell = heatmap.columns.flatMap { $0 }.first { $0.date == today }
            try expect(todayCell?.recognizedCharacterCount == 1_000)
            try expect(todayCell?.level == 3)
            // Everything past today is a hidden future cell.
            let futureCells = heatmap.columns.flatMap { $0 }.filter { $0.date > today }
            try expect(futureCells.allSatisfy { $0.isFuture && $0.level == 0 })
            try expect(heatmap.monthLabels.first?.column == 0)
            try expect(
                zip(heatmap.monthLabels, heatmap.monthLabels.dropFirst())
                    .allSatisfy { next in
                        next.1.column - next.0.column >= 4
                    }
            )
        }

        run(
            "contribution heatmap cells resize to fill the available width",
            failures: &failures
        ) {
            let compact = ContributionHeatmapLayout(
                availableWidth: 480,
                columnCount: ContributionHeatmap.defaultWeekCount
            )
            let wide = ContributionHeatmapLayout(
                availableWidth: 604,
                columnCount: ContributionHeatmap.defaultWeekCount
            )

            try expect(compact.cellLength > 0)
            try expect(compact.cellLength < wide.cellLength)
            try expect(abs(compact.gridWidth - 480) < 0.001)
            try expect(abs(wide.gridWidth - 604) < 0.001)
            try expect(
                abs(
                    wide.leadingOffset(forColumn: 51)
                        + wide.cellLength
                        - wide.availableWidth
                ) < 0.001
            )
        }

        run(
            "empty usage summary yields a heatmap with no data",
            failures: &failures
        ) {
            let heatmap = ContributionHeatmap.build(
                summary: .empty,
                now: Date()
            )
            try expect(heatmap.columns.count == 52)
            try expect(!heatmap.hasData)
            try expect(
                heatmap.columns.flatMap { $0 }.allSatisfy {
                    $0.recognizedCharacterCount == 0 && $0.level == 0
                }
            )
        }

        run(
            "usage presentation formats duration, keyboard savings and heatmap shades",
            failures: &failures
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

        run(
            "overview weekly characters include Monday through today only",
            failures: &failures
        ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let now = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 19, hour: 15
            ))!
            let daily = [
                (12, 9_999),
                (13, 400),
                (18, 600),
                (19, 800),
                (20, 7_777),
            ].map { day, count in
                VoiceInputDailyUsage(
                    day: calendar.date(from: DateComponents(
                        year: 2026, month: 7, day: day
                    ))!,
                    recognizedCharacterCount: count,
                    speakingMilliseconds: 0,
                    sessionCount: 1
                )
            }
            let summary = VoiceInputUsageSummary(
                totalRecognizedCharacterCount: 19_576,
                totalSpeakingMilliseconds: 0,
                totalSessionCount: daily.count,
                daily: daily
            )

            try expect(
                VoiceInputUsagePresentation.recognizedCharacterCountThisWeek(
                    summary: summary,
                    now: now,
                    calendar: calendar
                ) == 1_800
            )
        }

        run(
            "overview voiceprint fills the latest 18 calendar days",
            failures: &failures
        ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let now = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 19, hour: 15
            ))!
            let daily = [
                (1, 111),
                (2, 200),
                (18, 1_800),
                (19, 1_900),
                (20, 2_000),
            ].map { day, count in
                VoiceInputDailyUsage(
                    day: calendar.date(from: DateComponents(
                        year: 2026, month: 7, day: day
                    ))!,
                    recognizedCharacterCount: count,
                    speakingMilliseconds: 0,
                    sessionCount: 1
                )
            }
            let summary = VoiceInputUsageSummary(
                totalRecognizedCharacterCount: 6_011,
                totalSpeakingMilliseconds: 0,
                totalSessionCount: daily.count,
                daily: daily
            )
            let expected = [
                200,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0,
                1_800,
                1_900,
            ]
            let counts = VoiceInputUsagePresentation
                .recentRecognizedCharacterCounts(
                    summary: summary,
                    now: now,
                    calendar: calendar,
                    days: 18
                )

            try expect(counts == expected)
        }

        run(
            "history records are grouped by local day in reverse chronological order",
            failures: &failures
        ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let now = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 20, hour: 15
            ))!
            let todayMorningID = VoiceInputSessionID()
            let todayAfternoonID = VoiceInputSessionID()
            let yesterdayID = VoiceInputSessionID()
            let olderID = VoiceInputSessionID()
            let records = [
                makeHistoryRecord(
                    id: olderID,
                    startedAt: calendar.date(from: DateComponents(
                        year: 2026, month: 7, day: 17, hour: 10
                    ))!
                ),
                makeHistoryRecord(
                    id: todayMorningID,
                    startedAt: calendar.date(from: DateComponents(
                        year: 2026, month: 7, day: 20, hour: 9
                    ))!
                ),
                makeHistoryRecord(
                    id: yesterdayID,
                    startedAt: calendar.date(from: DateComponents(
                        year: 2026, month: 7, day: 19, hour: 20
                    ))!
                ),
                makeHistoryRecord(
                    id: todayAfternoonID,
                    startedAt: calendar.date(from: DateComponents(
                        year: 2026, month: 7, day: 20, hour: 14
                    ))!
                ),
            ]
            let sections = HistoryPresentation.sections(
                records: records,
                now: now,
                calendar: calendar
            )

            try expect(
                sections.map(\.title) == [
                    HistoryPresentation.todaySectionTitle,
                    HistoryPresentation.yesterdaySectionTitle,
                    "7月17日",
                ]
            )
            try expect(
                sections.map { $0.records.map(\.sessionID) } == [
                    [todayAfternoonID, todayMorningID],
                    [yesterdayID],
                    [olderID],
                ]
            )
        }

        run(
            "history list hides cancelled and textless records",
            failures: &failures
        ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let startedAt = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 20, hour: 9, minute: 5
            ))!
            let textID = VoiceInputSessionID()
            let cancelledID = VoiceInputSessionID()
            let secureID = VoiceInputSessionID()
            let recordingLimitID = VoiceInputSessionID()
            let textRecord = makeHistoryRecord(
                id: textID,
                startedAt: startedAt,
                applicationName: "备忘录",
                transcription: "豆包初稿",
                finalText: "最终正文"
            )
            let cancelledRecord = VoiceInputHistoryRecord(
                sessionID: cancelledID,
                startedAt: startedAt,
                applicationName: nil,
                transcription: "取消前已确认的转录",
                finalText: nil,
                cancelledAtStage: "transcribing",
                outcome: .cancelled(cancelledID)
            )
            let secureRecord = VoiceInputHistoryRecord(
                sessionID: secureID,
                startedAt: startedAt,
                applicationName: "密码输入",
                transcription: nil,
                finalText: nil,
                outcome: .pendingCopy(
                    secureID,
                    text: "",
                    reason: .secureTarget
                )
            )
            let recordingLimitRecord = VoiceInputHistoryRecord(
                sessionID: recordingLimitID,
                startedAt: startedAt,
                applicationName: nil,
                transcription: nil,
                finalText: nil,
                transcriptionProvider: "local",
                providerErrorCode: "recording.limit_reached",
                outcome: .failed(
                    recordingLimitID,
                    .recordingLimitReached
                )
            )

            let filtered = HistoryPresentation.filteredRecords(
                [textRecord, cancelledRecord, secureRecord, recordingLimitRecord],
                query: ""
            )

            try expect(filtered.map(\.sessionID) == [textID])
        }

        run(
            "history rows present the four delivery states",
            failures: &failures
        ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let startedAt = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 20, hour: 9, minute: 5
            ))!
            let deliveredID = VoiceInputSessionID()
            let unconfirmedID = VoiceInputSessionID()
            let fallbackID = VoiceInputSessionID()
            let pendingID = VoiceInputSessionID()
            let deliveredRecord = makeHistoryRecord(
                id: deliveredID,
                startedAt: startedAt,
                transcription: "豆包初稿",
                finalText: "最终正文"
            )
            let unconfirmedRecord = VoiceInputHistoryRecord(
                sessionID: unconfirmedID,
                startedAt: startedAt,
                applicationName: "备忘录",
                transcription: "豆包初稿",
                finalText: "未确认正文",
                deliveryDiagnosticCode: "pasteReceipt.unconfirmed",
                outcome: .delivered(
                    unconfirmedID,
                    applicationName: "备忘录",
                    text: "未确认正文"
                )
            )
            let fallbackRecord = VoiceInputHistoryRecord(
                sessionID: fallbackID,
                startedAt: startedAt,
                applicationName: "备忘录",
                transcription: "豆包初稿",
                finalText: "回退正文",
                refinementStatus: "fellBack",
                outcome: .delivered(
                    fallbackID,
                    applicationName: "备忘录",
                    text: "回退正文"
                )
            )
            let unconfirmedFallbackRecord = VoiceInputHistoryRecord(
                sessionID: VoiceInputSessionID(),
                startedAt: startedAt,
                applicationName: "备忘录",
                transcription: "豆包初稿",
                finalText: "未确认回退正文",
                deliveryDiagnosticCode: "pasteReceipt.unconfirmed",
                refinementStatus: "fellBack",
                outcome: .delivered(
                    deliveredID,
                    applicationName: "备忘录",
                    text: "未确认回退正文"
                )
            )
            let pendingRecord = VoiceInputHistoryRecord(
                sessionID: pendingID,
                startedAt: startedAt,
                applicationName: nil,
                transcription: "豆包初稿",
                finalText: "待复制正文",
                outcome: .pendingCopy(
                    pendingID,
                    text: "待复制正文",
                    reason: .missingTarget
                )
            )

            try expect(HistoryPresentation.status(for: deliveredRecord) == .delivered)
            try expect(
                HistoryPresentation.status(for: unconfirmedRecord)
                    == .deliveryUnconfirmed
            )
            try expect(
                HistoryPresentation.status(for: fallbackRecord)
                    == .refinementFellBack
            )
            try expect(
                HistoryPresentation.status(for: unconfirmedFallbackRecord)
                    == .deliveryUnconfirmed
            )
            try expect(HistoryPresentation.status(for: pendingRecord) == .pendingCopy)
            try expect(
                HistoryRecordStatus.delivered.label
                    == HistoryRecordStatus.deliveredLabel
            )
            try expect(
                HistoryRecordStatus.deliveryUnconfirmed.label
                    == HistoryRecordStatus.deliveryUnconfirmedLabel
            )
            try expect(
                HistoryRecordStatus.refinementFellBack.label
                    == HistoryRecordStatus.refinementFellBackLabel
            )
            try expect(
                HistoryRecordStatus.pendingCopy.label
                    == HistoryRecordStatus.pendingCopyLabel
            )

            let deliveredRow = HistoryPresentation.row(
                for: deliveredRecord,
                calendar: calendar
            )
            let unconfirmedRow = HistoryPresentation.row(
                for: unconfirmedRecord,
                calendar: calendar
            )
            let pendingRow = HistoryPresentation.row(
                for: pendingRecord,
                calendar: calendar
            )

            try expect(deliveredRow.text == "最终正文")
            try expect(deliveredRow.time == "09:05")
            try expect(deliveredRow.canCopy)
            try expect(deliveredRow.status == .delivered)
            try expect(!deliveredRow.status.showsStatusIcon)
            try expect(!unconfirmedRow.status.showsStatusIcon)
            try expect(pendingRow.status.showsStatusIcon)
            try expect(pendingRow.canCopy)
        }

        run(
            "history search matches retained text and delivery diagnostics without exposing target application",
            failures: &failures
        ) {
            let hiddenTranscriptID = VoiceInputSessionID()
            let bodyID = VoiceInputSessionID()
            let appID = VoiceInputSessionID()
            let deliveryDiagnosticID = VoiceInputSessionID()
            let records = [
                makeHistoryRecord(
                    id: hiddenTranscriptID,
                    startedAt: Date(timeIntervalSince1970: 300),
                    applicationName: "备忘录",
                    transcription: "只在原始转录出现的暗号",
                    finalText: "屏幕展示的最终正文"
                ),
                makeHistoryRecord(
                    id: bodyID,
                    startedAt: Date(timeIntervalSince1970: 200),
                    applicationName: "邮件",
                    transcription: "初稿",
                    finalText: "需要搜索的正文"
                ),
                makeHistoryRecord(
                    id: appID,
                    startedAt: Date(timeIntervalSince1970: 100),
                    applicationName: "Safari",
                    transcription: "网页内容",
                    finalText: nil
                ),
                makeHistoryRecord(
                    id: deliveryDiagnosticID,
                    startedAt: Date(timeIntervalSince1970: 50),
                    applicationName: "TextEdit",
                    transcription: "普通正文",
                    finalText: "普通正文",
                    deliveryDiagnosticCode: "pasteReceipt.unconfirmed"
                ),
            ]

            try expect(
                HistoryPresentation.filteredRecords(
                    records,
                    query: "暗号"
                ).isEmpty
            )
            try expect(
                HistoryPresentation.filteredRecords(
                    records,
                    query: "搜索的正文"
                ).map(\.sessionID) == [bodyID]
            )
            try expect(
                HistoryPresentation.filteredRecords(
                    records,
                    query: "safari"
                ).isEmpty
            )
            try expect(
                HistoryPresentation.filteredRecords(
                    records,
                    query: "pasteReceipt.unconfirmed"
                ).map(\.sessionID) == [deliveryDiagnosticID]
            )
        }

        SpecSummary.finish(failures: failures, label: "AppKit UI specs")
    }
}

private func makeHistoryRecord(
    id: VoiceInputSessionID,
    startedAt: Date,
    applicationName: String? = "备忘录",
    transcription: String? = "测试文字",
    finalText: String? = "测试文字",
    deliveryDiagnosticCode: String? = nil
) -> VoiceInputHistoryRecord {
    VoiceInputHistoryRecord(
        sessionID: id,
        startedAt: startedAt,
        applicationName: applicationName,
        transcription: transcription,
        finalText: finalText,
        deliveryDiagnosticCode: deliveryDiagnosticCode,
        outcome: .delivered(
            id,
            applicationName: applicationName ?? "当前输入框",
            text: finalText ?? transcription ?? ""
        )
    )
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
private final class DictionaryActionRecorder {
    private(set) var performedActions = 0

    func record() {
        performedActions += 1
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
    let presenter = VoiceInputPanelPresenter { presentation in
        VoiceInputHUD(
            presentation: presentation,
            performAction: recorder.perform,
            routeEffect: recorder.route
        )
    }
    defer { presenter.stop() }
    presenter.present(presentation)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))

    let buttons = presenter.accessibilityButtonEvidence
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
            presenter.pressAccessibilityButton(label: expectedLabel),
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

@MainActor
private func accessibilityLabels(in root: NSView) -> [String] {
    root.layoutSubtreeIfNeeded()
    var visited = Set<ObjectIdentifier>()
    var labels: [String] = []

    func visit(_ view: NSView) {
        let identifier = ObjectIdentifier(view)
        guard visited.insert(identifier).inserted else { return }
        if view.isAccessibilityElement(), let label = view.accessibilityLabel() {
            labels.append(label)
        }
        for child in view.accessibilityChildren() ?? [] {
            if let childView = child as? NSView {
                visit(childView)
            } else if let childElement = child as? NSAccessibilityElement,
                      let label = childElement.accessibilityLabel()
            {
                labels.append(label)
            }
        }
        view.subviews.forEach(visit)
    }

    visit(root)
    return labels
}

@MainActor
private func segmentedControls(in root: NSView) -> [NSSegmentedControl] {
    var controls: [NSSegmentedControl] = []

    func visit(_ view: NSView) {
        if let control = view as? NSSegmentedControl {
            controls.append(control)
        }
        view.subviews.forEach(visit)
    }

    visit(root)
    return controls
}

@MainActor
private func renderedHUDBitmap(
    increasedContrast: Bool
) throws -> NSBitmapImageRep {
    let presentation = VoiceInputHUDContractFixture.recording.presentation
    let presenter = VoiceInputPanelPresenter { presentation in
        VoiceInputHUD(
            presentation: presentation,
            performAction: { _ in nil },
            routeEffect: { _ in }
        )
        .environment(\.adaptiveGlassSurfaceStyleOverride, .opaque)
        .environment(
            \.voiceInputHUDIncreasedContrastOverride,
            increasedContrast
        )
        .environment(\.colorScheme, .dark)
    }
    defer { presenter.stop() }
    presenter.present(presentation)
    return try presenter.renderedBitmap()
}

private func hudTopBorderLuminance(_ bitmap: NSBitmapImageRep) -> Double {
    let scale = Double(bitmap.pixelsHigh) / 44
    let centerX = bitmap.pixelsWide / 2
    let centerY = Int((39 * scale).rounded())
    let samples = (-2...2).flatMap { yOffset in
        (-2...2).compactMap { xOffset -> Double? in
            guard let color = bitmap.colorAt(
                x: centerX + xOffset,
                y: centerY + yOffset
            )?.usingColorSpace(.sRGB) else { return nil }
            return 0.2126 * color.redComponent
                + 0.7152 * color.greenComponent
                + 0.0722 * color.blueComponent
        }
    }
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0, +) / Double(samples.count)
}

@MainActor
private final class MainWindowSelectionFixture: ObservableObject {
    @Published var selection: MainWindowTab = .overview
}

private struct MainWindowGeometryFixture: View {
    @ObservedObject var selection: MainWindowSelectionFixture

    var body: some View {
        MainWindowLayoutContainer {
            TabView(selection: $selection.selection) {
                ForEach(MainWindowTab.allCases) { tab in
                    Color.clear
                        .frame(
                            minWidth: tab == .dictionary ? 980 : 200,
                            minHeight: tab == .about ? 700 : 200
                        )
                        .tabItem {
                            Label(tab.title, systemImage: tab.icon)
                        }
                        .tag(tab)
                }
            }
            .background(MainWindowTabSeparatorHider())
        }
    }
}

private struct SettingsOverviewScrollFixture: View {
    @ObservedObject var navigation: SettingsNavigationModel

    var body: some View {
        SettingsOverviewScrollView(navigation: navigation) { group in
            VStack(spacing: 0) {
                Text("Settings \(group.rawValue) marker")
                Color.clear.frame(height: 220)
            }
        }
    }
}

@MainActor
private func firstScrollView(in root: NSView?) -> NSScrollView? {
    guard let root else { return nil }
    if let scrollView = root as? NSScrollView { return scrollView }
    return root.subviews.lazy.compactMap(firstScrollView(in:)).first
}

@MainActor
private func verticalDistanceFromTop(_ scrollView: NSScrollView) -> CGFloat {
    guard let documentView = scrollView.documentView else { return .infinity }
    let visibleRect = documentView.visibleRect
    if documentView.isFlipped {
        return visibleRect.minY - documentView.bounds.minY
    }
    return documentView.bounds.maxY - visibleRect.maxY
}

