import Foundation

/// Tracks the exact application allowed to receive a history redelivery.
///
/// AppKit activation notifications, global mouse events and shortcut presses
/// can arrive in different orders. This state machine reduces those event
/// streams to one process identifier and only accepts a complete mouse gesture
/// or shortcut confirmation when the frontmost process still matches it.
package struct HistoryRedeliveryTargetState: Equatable, Sendable {
    package struct Candidate: Equatable, Sendable {
        package let processIdentifier: Int32
        package let applicationName: String
    }

    package private(set) var candidate: Candidate?
    private var mouseDownProcessIdentifier: Int32?

    package init() {}

    package mutating func reset() {
        candidate = nil
        mouseDownProcessIdentifier = nil
    }

    package mutating func activated(
        processIdentifier: Int32,
        applicationName: String?,
        isSpeaker: Bool
    ) {
        guard !isSpeaker else {
            reset()
            return
        }
        let next = Candidate(
            processIdentifier: processIdentifier,
            applicationName: applicationName ?? "目标 App"
        )
        if candidate?.processIdentifier != processIdentifier {
            mouseDownProcessIdentifier = nil
        }
        candidate = next
    }

    @discardableResult
    package mutating func terminated(processIdentifier: Int32) -> Bool {
        guard candidate?.processIdentifier == processIdentifier else {
            return false
        }
        reset()
        return true
    }

    package mutating func mouseDown(
        frontmostProcessIdentifier: Int32?
    ) {
        guard let candidate,
              candidate.processIdentifier == frontmostProcessIdentifier
        else {
            mouseDownProcessIdentifier = nil
            return
        }
        mouseDownProcessIdentifier = candidate.processIdentifier
    }

    package mutating func mouseUp(
        frontmostProcessIdentifier: Int32?
    ) -> Int32? {
        defer { mouseDownProcessIdentifier = nil }
        guard let candidate,
              mouseDownProcessIdentifier == candidate.processIdentifier,
              frontmostProcessIdentifier == candidate.processIdentifier
        else { return nil }
        return candidate.processIdentifier
    }

    package func shortcutConfirmation(
        frontmostProcessIdentifier: Int32?
    ) -> Int32? {
        guard let candidate,
              candidate.processIdentifier == frontmostProcessIdentifier
        else { return nil }
        return candidate.processIdentifier
    }
}
