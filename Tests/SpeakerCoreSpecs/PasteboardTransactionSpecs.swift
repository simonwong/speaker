import Foundation
import SpeakerCore
import SpeakerSpecSupport

/// Automatic delivery borrows the user's clipboard for one Command-V and must
/// hand it back exactly as it was found. These cases drive the snapshot, the
/// replacement transaction, and the restore coordinator through a stand-in
/// pasteboard, so ownership is decided by the transaction marker and the
/// change count rather than by whatever the real system pasteboard holds.
enum PasteboardTransactionSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        let originalItems = [
            [
                "public.utf8-plain-text": Data("原始剪贴板".utf8),
                "public.rtf": Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D]),
                "public.html": Data("<b>原始剪贴板</b>".utf8),
            ],
            ["public.png": Data([0x89, 0x50, 0x4E, 0x47])],
        ]

        await runAsync(
            "clipboard snapshot keeps every representation of every item",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)

            guard
                let snapshot = PasteboardSnapshot.capture(
                    from: pasteboard.access,
                    budget: .standard
                )
            else {
                throw SpecFailure(
                    message: "a clipboard within budget produced no snapshot"
                )
            }

            try expect(
                snapshot.items == originalItems,
                "the snapshot dropped a representation: \(snapshot.items)"
            )
            try expect(
                pasteboard.clearCount == 0,
                "capturing a snapshot mutated the clipboard"
            )
        }

        await runAsync(
            "clipboard snapshot refuses a clipboard that changes mid-capture",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(
                items: originalItems,
                mutatesWhileReadingRepresentations: true
            )

            let snapshot = PasteboardSnapshot.capture(
                from: pasteboard.access,
                budget: .standard
            )

            try expect(
                snapshot == nil,
                "a clipboard that changed mid-capture produced a snapshot"
            )
            try expect(
                pasteboard.clearCount == 0,
                "an incoherent snapshot still mutated the clipboard"
            )
        }

        await runAsync(
            "clipboard restore returns the snapshot while ownership holds",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            guard
                let transaction = PasteboardReplacementTransaction.prepare(
                    text: "Speaker 文本",
                    pasteboard: pasteboard.access
                )
            else {
                throw SpecFailure(
                    message: "the replacement transaction refused a safe clipboard"
                )
            }

            try expect(transaction.verifies("Speaker 文本"))
            try expect(transaction.stillOwnsPasteboard())
            try expect(
                pasteboard.items
                    == [["public.utf8-plain-text": Data("Speaker 文本".utf8)]],
                "the replacement did not reach the clipboard"
            )

            let restored = transaction.restoreIfOwned()
            try expect(restored, "an owned transaction refused to restore")
            try expect(
                pasteboard.items == originalItems,
                "restore did not reproduce every representation"
            )

            let restoredTwice = transaction.restoreIfOwned()
            try expect(
                !restoredTwice,
                "the transaction restored again over its own restore"
            )
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "clipboard restore leaves a newer clipboard owner untouched",
            failures: &failures
        ) {
            let externalItems = [
                ["public.utf8-plain-text": Data("用户新复制".utf8)]
            ]
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            guard
                let transaction = PasteboardReplacementTransaction.prepare(
                    text: "Speaker 文本",
                    pasteboard: pasteboard.access
                )
            else {
                throw SpecFailure(
                    message: "the replacement transaction refused a safe clipboard"
                )
            }

            pasteboard.replaceExternally(with: externalItems)

            try expect(!transaction.stillOwnsPasteboard())
            try expect(!transaction.verifies("Speaker 文本"))
            let restored = transaction.restoreIfOwned()
            try expect(
                !restored,
                "the transaction claimed a restore it no longer owned"
            )
            try expect(
                pasteboard.items == externalItems,
                "restore overwrote a newer clipboard owner"
            )
        }

        await runAsync(
            "clipboard restore coordinator finishes a reserved restore before shutdown returns",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let sleeper = ControlledPasteboardRestoreSleep()
            guard
                let transaction = await PasteboardDeliveryTransaction.prepare(
                    text: "Speaker 文本",
                    pasteboard: pasteboard.access,
                    sleepBeforeRestore: { duration in
                        try await sleeper.sleep(for: duration)
                    },
                    conditionalRestoreDidFinish: {
                        await sleeper.markRestoreCompleted()
                    }
                )
            else {
                throw SpecFailure(
                    message: "the delivery transaction refused a safe clipboard"
                )
            }

            let coordinator = PasteboardRestoreCoordinator()
            guard let reservation = await coordinator.reserve() else {
                throw SpecFailure(
                    message: "a fresh coordinator refused a reservation"
                )
            }
            await coordinator.schedule(transaction, reservation: reservation)
            await sleeper.waitUntilStarted()

            let completion = CompletionFlag()
            let shutdown = Task {
                await coordinator.shutdown()
                await completion.markComplete()
            }
            await settle()
            let completedEarly = await completion.isComplete
            try expect(
                !completedEarly,
                "shutdown returned while a restore was still pending"
            )

            await sleeper.resume()
            await shutdown.value
            try expect(
                pasteboard.items == originalItems,
                "the pending restore did not return the user's clipboard"
            )

            let lateReservation = await coordinator.reserve()
            try expect(
                lateReservation == nil,
                "the coordinator reserved a restore after shutdown"
            )
        }

        await runAsync(
            "clipboard restore coordinator releases an abandoned reservation",
            failures: &failures
        ) {
            let coordinator = PasteboardRestoreCoordinator()
            guard let reservation = await coordinator.reserve() else {
                throw SpecFailure(
                    message: "a fresh coordinator refused a reservation"
                )
            }

            let completion = CompletionFlag()
            let shutdown = Task {
                await coordinator.shutdown()
                await completion.markComplete()
            }
            await settle()
            let completedEarly = await completion.isComplete
            try expect(
                !completedEarly,
                "shutdown returned while a reservation was outstanding"
            )

            await coordinator.abandon(reservation)
            await shutdown.value
            let completed = await completion.isComplete
            try expect(
                completed,
                "abandoning the last reservation left shutdown waiting"
            )
        }
    }
}
