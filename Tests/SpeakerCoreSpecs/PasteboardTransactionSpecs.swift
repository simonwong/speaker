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
        let transcriptItems = [["public.utf8-plain-text": Data("Speaker 文本".utf8)]]

        await runAsync(
            "clipboard enumeration failure preserves the original contents when copying",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(
                items: originalItems,
                itemEnumerationSucceeds: false
            )
            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)

            let copied = await writer.copy("Speaker 文本")

            try expect(!copied, "an unreadable clipboard was treated as empty")
            try expect(pasteboard.items == originalItems)
            try expect(pasteboard.clearCount == 0)
        }

        await runAsync(
            "clipboard enumeration failure refuses automatic delivery before mutation",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(
                items: originalItems,
                itemEnumerationSucceeds: false
            )

            let prepared = await PasteboardDeliveryTransaction.prepare(
                text: "Speaker 文本",
                pasteboard: pasteboard.access
            )

            try expect(preparationFailure(prepared) == .unavailable)
            try expect(pasteboard.items == originalItems)
            try expect(pasteboard.clearCount == 0)
        }

        await runAsync(
            "clipboard with no items still supports copying and conditional restoration",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: [])
            let transaction = try replacement(
                of: try capturedSnapshot(pasteboard),
                in: pasteboard
            )

            try expect(transaction.verifies("Speaker 文本"))
            try expect(transaction.restoreIfOwned())
            try expect(pasteboard.items.isEmpty)

            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)
            let copied = await writer.copy("明确复制的文字")
            try expect(copied)
            try expect(
                pasteboard.items == [["public.utf8-plain-text": Data("明确复制的文字".utf8)]]
            )
        }

        await runAsync(
            "clipboard snapshot keeps every representation of every item",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)

            let snapshot = try capturedSnapshot(pasteboard)

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
                snapshot == .failure(.unreadable),
                "a clipboard that changed mid-capture produced a snapshot"
            )
            try expect(
                pasteboard.clearCount == 0,
                "an incoherent snapshot still mutated the clipboard"
            )
        }

        run(
            "clipboard snapshot tells an oversized clipboard from an unreadable one",
            failures: &failures
        ) {
            let budget = PasteboardSnapshotBudget(
                maximumItemCount: 2,
                maximumRepresentationCount: 8,
                maximumBytesPerRepresentation: 16,
                maximumTotalBytes: 24
            )
            let oversizedRepresentation = ClipboardPasteboardFake(items: [
                ["public.tiff": Data(count: 17)]
            ])
            let oversizedTotal = ClipboardPasteboardFake(items: [
                ["public.tiff": Data(count: 16)],
                ["public.png": Data(count: 16)],
            ])
            let tooManyItems = ClipboardPasteboardFake(items: [
                ["public.utf8-plain-text": Data("一".utf8)],
                ["public.utf8-plain-text": Data("二".utf8)],
                ["public.utf8-plain-text": Data("三".utf8)],
            ])
            let unreadable = ClipboardPasteboardFake(
                items: [["public.utf8-plain-text": Data("可读".utf8), "com.example.lazy": Data()]],
                unreadableTypes: ["com.example.lazy"]
            )

            for pasteboard in [oversizedRepresentation, oversizedTotal, tooManyItems] {
                try expect(
                    PasteboardSnapshot.capture(from: pasteboard.access, budget: budget)
                        == .failure(.tooLarge),
                    "an over-budget clipboard was not reported as too large"
                )
            }
            try expect(
                PasteboardSnapshot.capture(from: unreadable.access, budget: budget)
                    == .failure(.unreadable),
                "one unreadable representation did not fail the whole snapshot"
            )
            let standardOverflow = ClipboardPasteboardFake(
                items: Array(
                    repeating: ["public.utf8-plain-text": Data("项".utf8)],
                    count: PasteboardSnapshotBudget.standard.maximumItemCount + 1
                ))
            try expect(
                PasteboardSnapshot.capture(from: standardOverflow.access, budget: .standard)
                    == .failure(.tooLarge)
            )
        }

        await runAsync(
            "automatic delivery leaves an oversized clipboard untouched",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)

            let prepared = await PasteboardDeliveryTransaction.prepare(
                text: "Speaker 文本",
                pasteboard: pasteboard.access,
                snapshotBudget: PasteboardSnapshotBudget(
                    maximumItemCount: 64,
                    maximumRepresentationCount: 256,
                    maximumBytesPerRepresentation: 4,
                    maximumTotalBytes: 32
                )
            )

            try expect(preparationFailure(prepared) == .tooLarge)
            try expect(pasteboard.items == originalItems)
            try expect(pasteboard.clearCount == 0)
            try expect(pasteboard.writePurposes.isEmpty)
        }

        await runAsync(
            "explicit copy replaces a clipboard too large to set aside",
            failures: &failures
        ) {
            let oversizedItems = Array(
                repeating: ["public.utf8-plain-text": Data("项".utf8)],
                count: PasteboardSnapshotBudget.standard.maximumItemCount + 1
            )
            let pasteboard = ClipboardPasteboardFake(items: oversizedItems)
            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)

            let copied = await writer.copy("明确复制的文字")

            try expect(copied, "the user's copy request was refused for a large clipboard")
            try expect(
                pasteboard.items == [["public.utf8-plain-text": Data("明确复制的文字".utf8)]]
            )
        }

        await runAsync(
            "clipboard snapshots are read away from the main thread",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)

            let prepared = await PasteboardDeliveryTransaction.prepare(
                text: "Speaker 文本",
                pasteboard: pasteboard.access
            )
            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)
            _ = await writer.copy("明确复制的文字")

            try expect(preparationFailure(prepared) == nil)
            try expect(
                pasteboard.representationReadsOnMainThread == 0,
                "a clipboard snapshot blocked the main thread"
            )
        }

        await runAsync(
            "clipboard restore returns the snapshot while ownership holds",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let transaction = try replacement(
                of: try capturedSnapshot(pasteboard),
                in: pasteboard
            )

            try expect(transaction.verifies("Speaker 文本"))
            try expect(transaction.stillOwnsPasteboard())
            try expect(
                pasteboard.items == transcriptItems,
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
            let transaction = try replacement(
                of: try capturedSnapshot(pasteboard),
                in: pasteboard
            )

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
            "clipboard replacement refuses a snapshot another App has outdated",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let snapshot = try capturedSnapshot(pasteboard)
            let externalItems = [["public.utf8-plain-text": Data("用户新复制".utf8)]]
            pasteboard.replaceExternally(with: externalItems)

            let transaction = PasteboardReplacementTransaction.begin(
                replacing: snapshot,
                with: .text("Speaker 文本"),
                purpose: .pasteTransaction,
                pasteboard: pasteboard.access
            )

            try expect(transaction == nil, "Speaker replaced a clipboard it had not set aside")
            try expect(pasteboard.items == externalItems)
        }

        await runAsync(
            "automatic delivery offers its text only when another App asks",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let transaction = try await preparedTransaction(pasteboard, clock: clock)

            try expect(pasteboard.items == transcriptItems)
            try expect(
                pasteboard.readPromisedTextAsAnotherApplication() == "Speaker 文本",
                "the promised clipboard text did not render the transcript"
            )
            await transaction.restoreIfOwned()
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "clipboard restore waits for a slow reader instead of a fixed delay",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let completion = PasteboardRestoreCompletion()
            let transaction = try await preparedTransaction(
                pasteboard, clock: clock, completion: completion)

            let restore = Task { await transaction.restoreWhenReleased(by: .unconfirmed) }
            try await clock.waitUntilSleepRequestCount(1)

            clock.advance(by: .milliseconds(500))
            await settle()
            try expect(
                pasteboard.items == transcriptItems,
                "the clipboard was restored before the target read it"
            )
            clock.advance(by: .milliseconds(1_500))
            await settle()
            try expect(
                pasteboard.items == transcriptItems,
                "a reader slower than two seconds lost the transcript"
            )

            try expect(pasteboard.readPromisedTextAsAnotherApplication() == "Speaker 文本")
            try await clock.waitUntilSleepRequestCount(2)
            try expect(clock.sleepRequests.last == .milliseconds(100))
            await settle()
            let restoredAtRead = await completion.isCompleted
            try expect(!restoredAtRead, "the clipboard was restored while the reader was reading")

            clock.advance(by: .milliseconds(100))
            try await completion.waitUntilCompleted()
            await restore.value
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "clipboard restore holds an early read until the minimum delay",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let completion = PasteboardRestoreCompletion()
            let transaction = try await preparedTransaction(
                pasteboard, clock: clock, completion: completion)

            let restore = Task { await transaction.restoreWhenReleased(by: .unconfirmed) }
            try await clock.waitUntilSleepRequestCount(1)
            pasteboard.readPromisedTextAsAnotherApplication()
            try await clock.waitUntilSleepRequestCount(2)
            try expect(clock.sleepRequests.last == .milliseconds(500))

            clock.advance(by: .milliseconds(100))
            await settle()
            let restoredEarly = await completion.isCompleted
            try expect(!restoredEarly, "an early read restored before the minimum delay")

            clock.advance(by: .milliseconds(400))
            try await completion.waitUntilCompleted()
            await restore.value
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "clipboard restore stops waiting for a target that never reads",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let completion = PasteboardRestoreCompletion()
            let transaction = try await preparedTransaction(
                pasteboard, clock: clock, completion: completion)

            let restore = Task { await transaction.restoreWhenReleased(by: .unconfirmed) }
            try await clock.waitUntilSleepRequestCount(1)
            try expect(clock.sleepRequests == [PasteboardRestoreTiming.standard.maximumDelay])

            clock.advance(by: .milliseconds(2_999))
            await settle()
            let restoredEarly = await completion.isCompleted
            try expect(!restoredEarly)

            clock.advance(by: .milliseconds(1))
            try await completion.waitUntilCompleted()
            await restore.value
            try expect(
                pasteboard.items == originalItems,
                "the cap did not give the clipboard back"
            )
        }

        await runAsync(
            "clipboard restore waits for a readable target's receipt before trusting a read",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let completion = PasteboardRestoreCompletion()
            let transaction = try await preparedTransaction(
                pasteboard, clock: clock, completion: completion)
            let receipt = PasteReceipt()

            let restore = Task { await transaction.restoreWhenReleased(by: receipt) }
            try await clock.waitUntilSleepRequestCount(1)
            pasteboard.readPromisedTextAsAnotherApplication()
            clock.advance(by: .milliseconds(800))
            await settle()
            let restoredBeforeReceipt = await completion.isCompleted
            try expect(
                !restoredBeforeReceipt,
                "a read restored the clipboard before the receipt concluded"
            )

            receipt.conclude(.unconfirmed)
            try await completion.waitUntilCompleted()
            await restore.value
            try expect(pasteboard.items == originalItems)
        }

        await runAsync(
            "clipboard restore follows a confirmed receipt at once",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let completion = PasteboardRestoreCompletion()
            let transaction = try await preparedTransaction(
                pasteboard, clock: clock, completion: completion)
            let receipt = PasteReceipt()

            let restore = Task { await transaction.restoreWhenReleased(by: receipt) }
            try await clock.waitUntilSleepRequestCount(1)
            clock.advance(by: .milliseconds(200))

            receipt.conclude(.confirmed)
            try await completion.waitUntilCompleted()
            await restore.value
            try expect(pasteboard.items == originalItems)
            try expect(clock.sleepRequestCount == 1)
        }

        await runAsync(
            "clipboard restore coordinator finishes a reserved restore before shutdown returns",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let clock = ManualVoiceInputClock()
            let transaction = try await preparedTransaction(pasteboard, clock: clock)

            let coordinator = PasteboardRestoreCoordinator()
            guard let reservation = await coordinator.reserve() else {
                throw SpecFailure(
                    message: "a fresh coordinator refused a reservation"
                )
            }
            await coordinator.schedule(
                transaction, reservation: reservation, receipt: .unconfirmed)
            try await clock.waitUntilSleepRequestCount(1)

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

            clock.advance(by: PasteboardRestoreTiming.standard.maximumDelay)
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

        run(
            "clipboard write purposes carry the nspasteboard.org privacy types",
            failures: &failures
        ) {
            try expect(
                PasteboardWritePurpose.pasteTransaction.privacyTypes.map(\.rawValue) == [
                    "org.nspasteboard.TransientType",
                    "org.nspasteboard.AutoGeneratedType",
                ])
            try expect(PasteboardWritePurpose.pasteTransaction.isCurrentHostOnly)
            try expect(PasteboardWritePurpose.explicitCopy.privacyTypes.isEmpty)
            try expect(!PasteboardWritePurpose.explicitCopy.isCurrentHostOnly)
            try expect(
                PasteboardWritePurpose.concealedCopy.privacyTypes.map(\.rawValue)
                    == ["org.nspasteboard.ConcealedType"])
            try expect(PasteboardWritePurpose.concealedCopy.isCurrentHostOnly)
            try expect(
                PasteboardWritePurpose.pasteTransaction.markerType
                    != PasteboardWritePurpose.explicitCopy.markerType,
                "an explicit copy would look like an abandoned paste at launch"
            )
        }

        await runAsync(
            "automatic delivery keeps its clipboard value out of clipboard history and other devices",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            let transaction = try await preparedTransaction(
                pasteboard, clock: ManualVoiceInputClock())
            try expect(pasteboard.writePurposes == [.pasteTransaction])
            try expect(pasteboard.clearsKeptOnCurrentHost == [true])

            await transaction.restoreIfOwned()
            try expect(pasteboard.items == originalItems)
            try expect(
                pasteboard.clearsKeptOnCurrentHost == [true, false],
                "the restored clipboard was kept off other devices"
            )
        }

        await runAsync(
            "explicit copies stay ordinary and secure-target copies are concealed",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: [])
            let writer = SystemClipboardWriter(pasteboard: pasteboard.access)

            let copied = await writer.copy("明确复制的文字")
            let concealed = await writer.copy("密码框的文字", privacy: .concealed)

            try expect(copied && concealed)
            try expect(pasteboard.writePurposes == [.explicitCopy, .concealedCopy])
            try expect(pasteboard.clearsKeptOnCurrentHost == [false, true])
        }

        run(
            "launch clears a paste value that an ended process never restored",
            failures: &failures
        ) {
            let pasteboard = ClipboardPasteboardFake(items: originalItems)
            pasteboard.leaveSpeakerValue("崩溃前的转写", purpose: .pasteTransaction)

            try expect(AbandonedPasteTransaction.clear(from: pasteboard.access))
            try expect(pasteboard.items.isEmpty)
        }

        run(
            "launch leaves explicit copies and other clipboard values alone",
            failures: &failures
        ) {
            let copied = ClipboardPasteboardFake(items: [])
            copied.leaveSpeakerValue("用户复制的转写", purpose: .explicitCopy)
            let copiedItems = copied.items
            try expect(!AbandonedPasteTransaction.clear(from: copied.access))
            try expect(copied.items == copiedItems)

            let foreign = ClipboardPasteboardFake(items: originalItems)
            try expect(!AbandonedPasteTransaction.clear(from: foreign.access))
            try expect(foreign.items == originalItems)
            try expect(foreign.clearCount == 0)
        }
    }

    private static func capturedSnapshot(
        _ pasteboard: ClipboardPasteboardFake
    ) throws -> PasteboardSnapshot {
        switch PasteboardSnapshot.capture(from: pasteboard.access, budget: .standard) {
        case .success(let snapshot):
            return snapshot
        case .failure(let failure):
            throw SpecFailure(message: "a readable clipboard produced no snapshot: \(failure)")
        }
    }

    @MainActor
    private static func replacement(
        of snapshot: PasteboardSnapshot,
        in pasteboard: ClipboardPasteboardFake
    ) throws -> PasteboardReplacementTransaction {
        guard
            let transaction = PasteboardReplacementTransaction.begin(
                replacing: snapshot,
                with: .text("Speaker 文本"),
                purpose: .pasteTransaction,
                pasteboard: pasteboard.access
            )
        else {
            throw SpecFailure(message: "the replacement transaction refused a safe clipboard")
        }
        return transaction
    }

    private static func preparationFailure(
        _ prepared: Result<PasteboardDeliveryTransaction, PasteboardPreparationFailure>
    ) -> PasteboardPreparationFailure? {
        if case .failure(let failure) = prepared { failure } else { nil }
    }

    private static func preparedTransaction(
        _ pasteboard: ClipboardPasteboardFake,
        clock: ManualVoiceInputClock,
        completion: PasteboardRestoreCompletion? = nil
    ) async throws -> PasteboardDeliveryTransaction {
        let prepared = await PasteboardDeliveryTransaction.prepare(
            text: "Speaker 文本",
            pasteboard: pasteboard.access,
            clock: clock,
            conditionalRestoreDidFinish: { await completion?.markCompleted() }
        )
        switch prepared {
        case .success(let transaction):
            return transaction
        case .failure(let failure):
            throw SpecFailure(
                message: "the delivery transaction refused a safe clipboard: \(failure)")
        }
    }
}
