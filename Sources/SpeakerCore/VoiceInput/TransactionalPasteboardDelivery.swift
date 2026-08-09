@preconcurrency import AppKit
@preconcurrency import Carbon
import CoreGraphics
import Foundation

package enum PasteboardTransactionMarker {
    package static let type = NSPasteboard.PasteboardType(
        "com.local.speaker.paste-session"
    )
}

/// Bounds data retained by Speaker for rollback. AppKit exposes each
/// representation only as a complete `Data` value, so one value may be
/// materialized by the system before its size can be checked.
package struct PasteboardSnapshotBudget: Equatable, Sendable {
    package let maximumItemCount: Int
    package let maximumRepresentationCount: Int
    package let maximumBytesPerRepresentation: Int
    package let maximumTotalBytes: Int

    package init(
        maximumItemCount: Int,
        maximumRepresentationCount: Int,
        maximumBytesPerRepresentation: Int,
        maximumTotalBytes: Int
    ) {
        precondition(maximumItemCount >= 0)
        precondition(maximumRepresentationCount >= 0)
        precondition(maximumBytesPerRepresentation >= 0)
        precondition(maximumTotalBytes >= 0)
        self.maximumItemCount = maximumItemCount
        self.maximumRepresentationCount = maximumRepresentationCount
        self.maximumBytesPerRepresentation = maximumBytesPerRepresentation
        self.maximumTotalBytes = maximumTotalBytes
    }

    package static let standard = Self(
        maximumItemCount: 64,
        maximumRepresentationCount: 256,
        maximumBytesPerRepresentation: 16 * 1_024 * 1_024,
        maximumTotalBytes: 32 * 1_024 * 1_024
    )
}

package struct PasteboardSnapshot: Equatable, Sendable {
    package let items: [[String: Data]]
    fileprivate let changeCount: Int

    @MainActor
    package static func capture(
        from pasteboard: ClipboardPasteboardAccess,
        budget: PasteboardSnapshotBudget
    ) -> Self? {
        let capturedChangeCount = pasteboard.changeCount()
        let itemCount = pasteboard.itemCount()
        guard itemCount <= budget.maximumItemCount else { return nil }

        var representationCount = 0
        var totalBytes = 0
        var items: [[String: Data]] = []
        items.reserveCapacity(itemCount)

        for itemIndex in 0..<itemCount {
            guard let types = pasteboard.itemTypes(itemIndex) else {
                return nil
            }
            guard types.count
                <= budget.maximumRepresentationCount - representationCount
            else { return nil }
            representationCount += types.count

            var representations: [String: Data] = [:]
            representations.reserveCapacity(types.count)
            for type in types {
                guard representations[type] == nil,
                      let data = pasteboard.data(itemIndex, type),
                      data.count <= budget.maximumBytesPerRepresentation,
                      data.count <= budget.maximumTotalBytes - totalBytes
                else { return nil }
                representations[type] = data
                totalBytes += data.count
            }
            items.append(representations)
        }

        guard pasteboard.changeCount() == capturedChangeCount else { return nil }
        return Self(items: items, changeCount: capturedChangeCount)
    }
}

package struct PasteboardReplacementTransaction: Sendable {
    private let snapshot: PasteboardSnapshot
    private let marker: String
    private let ownedChangeCount: Int
    private let pasteboard: ClipboardPasteboardAccess

    @MainActor
    package static func prepare(
        text: String,
        pasteboard: ClipboardPasteboardAccess,
        budget: PasteboardSnapshotBudget = .standard
    ) -> Self? {
        guard let snapshot = PasteboardSnapshot.capture(
            from: pasteboard,
            budget: budget
        ), pasteboard.changeCount() == snapshot.changeCount else { return nil }

        let marker = UUID().uuidString
        let clearedChangeCount = pasteboard.clearContents()
        guard pasteboard.writeText(text, marker) else {
            if pasteboard.changeCount() == clearedChangeCount {
                _ = restore(snapshot, to: pasteboard)
            }
            return nil
        }
        return Self(
            snapshot: snapshot,
            marker: marker,
            ownedChangeCount: pasteboard.changeCount(),
            pasteboard: pasteboard
        )
    }

    @MainActor
    package func verifies(_ text: String) -> Bool {
        stillOwnsPasteboard() && pasteboard.readString() == text
    }

    @MainActor
    @discardableResult
    package func restoreIfOwned() -> Bool {
        guard stillOwnsPasteboard() else { return false }
        return Self.restore(snapshot, to: pasteboard)
    }

    @MainActor
    package func stillOwnsPasteboard() -> Bool {
        PasteboardTransactionOwnership.ownsPasteboard(
            currentChangeCount: pasteboard.changeCount(),
            currentMarker: pasteboard.readMarker(),
            ownedChangeCount: ownedChangeCount,
            marker: marker
        )
    }

    @MainActor
    private static func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: ClipboardPasteboardAccess
    ) -> Bool {
        _ = pasteboard.clearContents()
        return snapshot.items.isEmpty || pasteboard.writeItems(snapshot.items)
    }
}

private enum PasteboardTransactionOwnership {
    static func ownsPasteboard(
        currentChangeCount: Int,
        currentMarker: String?,
        ownedChangeCount: Int,
        marker: String
    ) -> Bool {
        currentChangeCount == ownedChangeCount && currentMarker == marker
    }
}

package struct PasteCommandEventPlan: Sendable {
    package enum Transition: Equatable, Sendable {
        case commandDown
        case vDown
        case vUp
        case commandUp
    }

    package let sourceStateID: CGEventSourceStateID
    package let transitions: [Transition]

    package static let standard = Self(
        sourceStateID: .combinedSessionState,
        transitions: [
            .commandDown,
            .vDown,
            .vUp,
            .commandUp,
        ]
    )
}

package struct PasteboardDeliveryTransaction: Sendable {
    private let replacement: PasteboardReplacementTransaction
    private let conditionalRestoreDelay: Duration
    private let sleepBeforeRestore:
        @Sendable (Duration) async throws -> Void
    private let conditionalRestoreDidFinish: @Sendable () async -> Void

    package static func prepare(
        text: String,
        pasteboard: ClipboardPasteboardAccess = .live,
        snapshotBudget: PasteboardSnapshotBudget = .standard,
        conditionalRestoreDelay: Duration = .milliseconds(500),
        sleepBeforeRestore:
            @escaping @Sendable (Duration) async throws -> Void = { duration in
                try await Task.sleep(for: duration)
            },
        conditionalRestoreDidFinish:
            @escaping @Sendable () async -> Void = {}
    ) async -> Self? {
        await MainActor.run {
            guard let replacement = PasteboardReplacementTransaction.prepare(
                text: text,
                pasteboard: pasteboard,
                budget: snapshotBudget
            ) else { return nil }
            guard replacement.verifies(text) else {
                replacement.restoreIfOwned()
                return nil
            }
            return Self(
                replacement: replacement,
                conditionalRestoreDelay: conditionalRestoreDelay,
                sleepBeforeRestore: sleepBeforeRestore,
                conditionalRestoreDidFinish: conditionalRestoreDidFinish
            )
        }
    }

    package static func ownsPasteboard(
        currentChangeCount: Int,
        currentMarker: String?,
        ownedChangeCount: Int,
        marker: String
    ) -> Bool {
        PasteboardTransactionOwnership.ownsPasteboard(
            currentChangeCount: currentChangeCount,
            currentMarker: currentMarker,
            ownedChangeCount: ownedChangeCount,
            marker: marker
        )
    }

    package func restoreIfOwned() async {
        _ = await MainActor.run {
            replacement.restoreIfOwned()
        }
    }

    package func stillOwnsPasteboard() async -> Bool {
        await MainActor.run {
            replacement.stillOwnsPasteboard()
        }
    }

    package func scheduleConditionalRestore() {
        Task { @MainActor in
            do {
                try await sleepBeforeRestore(conditionalRestoreDelay)
            } catch {
                return
            }
            replacement.restoreIfOwned()
            await conditionalRestoreDidFinish()
        }
    }

    package static func postCommandV() async -> Bool {
        let plan = PasteCommandEventPlan.standard
        guard let source = CGEventSource(stateID: plan.sourceStateID) else {
            return false
        }
        let events = plan.transitions.compactMap { transition -> CGEvent? in
            let descriptor: (keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) =
                switch transition {
                case .commandDown:
                    (CGKeyCode(kVK_Command), true, .maskCommand)
                case .vDown:
                    (CGKeyCode(kVK_ANSI_V), true, .maskCommand)
                case .vUp:
                    (CGKeyCode(kVK_ANSI_V), false, .maskCommand)
                case .commandUp:
                    (CGKeyCode(kVK_Command), false, [])
                }
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: descriptor.keyCode,
                keyDown: descriptor.keyDown
            ) else { return nil }
            event.flags = descriptor.flags
            return event
        }
        guard events.count == plan.transitions.count else { return false }

        for (index, event) in events.enumerated() {
            event.post(tap: .cghidEventTap)
            if index < events.index(before: events.endIndex) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return true
    }
}
