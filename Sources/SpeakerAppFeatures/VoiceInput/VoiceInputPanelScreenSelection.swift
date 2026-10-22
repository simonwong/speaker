import CoreGraphics
import Foundation

/// Chooses the display that shows the Voice Input HUD.
///
/// The HUD appears where the user is working: on the display that holds the
/// largest part of the frontmost App's front window, otherwise on the display
/// under the pointer. `nil` leaves the choice to the main screen.
package enum VoiceInputPanelScreenSelection {
    package struct Display: Equatable, Sendable {
        /// `CGDisplayBounds`: global Quartz coordinates, origin at the top
        /// left of the main display, the same space as window bounds.
        package let quartzBounds: CGRect
        /// `NSScreen.frame`: AppKit coordinates, the same space as the pointer.
        package let frame: CGRect

        package init(quartzBounds: CGRect, frame: CGRect) {
            self.quartzBounds = quartzBounds
            self.frame = frame
        }
    }

    package static func displayIndex(
        frontWindowBounds: CGRect?,
        pointer: CGPoint,
        displays: [Display]
    ) -> Int? {
        if let frontWindowBounds,
            let best = displays.indices.max(by: { lhs, rhs in
                intersectionArea(displays[lhs].quartzBounds, frontWindowBounds)
                    < intersectionArea(displays[rhs].quartzBounds, frontWindowBounds)
            }),
            intersectionArea(displays[best].quartzBounds, frontWindowBounds) > 0
        {
            return best
        }
        // Same edges as `NSMouseInRect` for an unflipped rectangle.
        return displays.firstIndex { display in
            pointer.x >= display.frame.minX && pointer.x < display.frame.maxX
                && pointer.y > display.frame.minY && pointer.y <= display.frame.maxY
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
