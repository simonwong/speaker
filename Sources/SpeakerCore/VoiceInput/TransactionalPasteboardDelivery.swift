@preconcurrency import AppKit
@preconcurrency import Carbon
import CoreGraphics
import Foundation

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
    private static let markerType = NSPasteboard.PasteboardType(
        "com.local.speaker.paste-session"
    )

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
