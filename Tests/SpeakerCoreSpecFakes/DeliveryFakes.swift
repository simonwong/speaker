import Foundation
import SpeakerCore

/// A delivery double that records the delivered text and answers with one injected outcome.
///
/// `commitsBeforeDelivering` selects the adapter contract under test. A delivering adapter
/// commits the `DeliveryCommitGate` before it mutates the Input Target; an adapter that never
/// reaches a mutation, such as one that reports a Pending Copy Result, must leave the gate
/// pending so User Cancellation can still win.
public actor TextDeliveryFake: TextDelivering {
    public let result: DeliveryOutcome
    public let commitsBeforeDelivering: Bool
    public private(set) var deliveredTexts: [String] = []

    public init(result: DeliveryOutcome, commitsBeforeDelivering: Bool = true) {
        self.result = result
        self.commitsBeforeDelivering = commitsBeforeDelivering
    }

    public func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        if commitsBeforeDelivering {
            guard await commitGate.commit() else {
                return .pendingCopy(.deliveryFailed)
            }
        }
        deliveredTexts.append(text)
        return result
    }
}

/// A clipboard double that records every copied text and reports one fixed outcome.
public actor ClipboardFake: ClipboardWriting {
    public private(set) var copiedTexts: [String] = []
    private let succeeds: Bool

    public init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    public func copy(_ text: String) async -> Bool {
        copiedTexts.append(text)
        return succeeds
    }
}
