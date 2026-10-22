import AppKit
import CoreGraphics

/// Finds the frontmost App's front window through the window server's window
/// list.
///
/// An Accessibility query asks the App itself and waits for its answer, so a
/// hung App can stall the caller. The window list comes from the window
/// server instead. Reading only owner, layer, alpha, and bounds needs no
/// permission; window titles, which need Screen Recording, are never read.
package enum FrontmostWindowLocator {
    package struct WindowListEntry: Equatable, Sendable {
        package let ownerProcessID: pid_t
        package let layer: Int
        package let alpha: Double
        /// Global Quartz coordinates: origin at the top left of the main display.
        package let bounds: CGRect

        package init(ownerProcessID: pid_t, layer: Int, alpha: Double, bounds: CGRect) {
            self.ownerProcessID = ownerProcessID
            self.layer = layer
            self.alpha = alpha
            self.bounds = bounds
        }

        init?(windowInfo: [String: Any]) {
            guard
                let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
                let layer = windowInfo[kCGWindowLayer as String] as? NSNumber,
                let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return nil }
            let alpha = windowInfo[kCGWindowAlpha as String] as? NSNumber
            self.init(
                ownerProcessID: ownerProcessID.int32Value,
                layer: layer.intValue,
                alpha: alpha?.doubleValue ?? 1,
                bounds: bounds
            )
        }
    }

    /// The front window bounds of the frontmost App other than Speaker, in
    /// global Quartz coordinates.
    package static func frontmostWindowBounds() -> CGRect? {
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != getpid(),
            let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        return frontWindowBounds(
            of: application.processIdentifier,
            in: windowInfo.compactMap(WindowListEntry.init(windowInfo:))
        )
    }

    /// The window list is ordered front to back. The first visible
    /// document-level window of the process is its front window; menus,
    /// panels above it, and transparent helper windows are skipped.
    package static func frontWindowBounds(
        of processID: pid_t,
        in windows: [WindowListEntry]
    ) -> CGRect? {
        windows.first { window in
            window.ownerProcessID == processID
                && window.layer == 0
                && window.alpha > 0
                && window.bounds.width > 1
                && window.bounds.height > 1
        }?.bounds
    }
}
