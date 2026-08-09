@preconcurrency import AppKit
@preconcurrency import Carbon
import CoreGraphics
import Foundation

package enum PasteboardTransactionMarker {
    package static let type = NSPasteboard.PasteboardType(
        "com.local.speaker.paste-session"
    )
}

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
        let itemTypes = pasteboard.itemTypes()
        guard itemTypes.count <= budget.maximumItemCount else { return nil }

        var representationCount = 0
        var totalBytes = 0
        var items: [[String: Data]] = []
        items.reserveCapacity(itemTypes.count)

        for (itemIndex, types) in itemTypes.enumerated() {
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
        PasteboardDeliveryTransaction.ownsPasteboard(
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
    private static let markerType = PasteboardTransactionMarker.type

    private let snapshot: [[String: Data]]
    private let marker: String
    private let ownedChangeCount: Int

    package static func prepare(text: String) async -> Self? {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            let snapshot = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type.rawValue, $0) }
                })
            }
            let marker = UUID().uuidString
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string),
                  item.setString(marker, forType: markerType)
            else { return nil }
            let clearedChangeCount = pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else {
                if pasteboard.changeCount == clearedChangeCount {
                    restore(snapshot, to: pasteboard)
                }
                return nil
            }
            return Self(
                snapshot: snapshot,
                marker: marker,
                ownedChangeCount: pasteboard.changeCount
            )
        }
    }

    package static func ownsPasteboard(
        currentChangeCount: Int,
        currentMarker: String?,
        ownedChangeCount: Int,
        marker: String
    ) -> Bool {
        currentChangeCount == ownedChangeCount && currentMarker == marker
    }

    package func restoreIfOwned() async {
        await MainActor.run { restoreIfOwnedOnMainActor() }
    }

    package func stillOwnsPasteboard() async -> Bool {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            return Self.ownsPasteboard(
                currentChangeCount: pasteboard.changeCount,
                currentMarker: pasteboard.string(forType: Self.markerType),
                ownedChangeCount: ownedChangeCount,
                marker: marker
            )
        }
    }

    package func scheduleConditionalRestore() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            restoreIfOwnedOnMainActor()
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

    @MainActor
    private func restoreIfOwnedOnMainActor() {
        let pasteboard = NSPasteboard.general
        guard Self.ownsPasteboard(
            currentChangeCount: pasteboard.changeCount,
            currentMarker: pasteboard.string(forType: Self.markerType),
            ownedChangeCount: ownedChangeCount,
            marker: marker
        )
        else { return }

        Self.restore(snapshot, to: pasteboard)
    }

    @MainActor
    private static func restore(
        _ snapshot: [[String: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: .init(type))
            }
            return item
        }
        _ = pasteboard.writeObjects(items)
    }
}
