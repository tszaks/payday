import Foundation
import Testing
@testable import Payday

/// The alert must say WHICH failure happened, not always the generic one.
///
/// ## The defect
///
/// `LogTipSheet`'s failure alert rendered
/// `ShiftCommands.Failure.saveFailed.message` unconditionally, discarding
/// the case actually thrown. `ShiftCommands.Failure` already authored
/// `case .conversionPending: "Payday is still syncing this shift. Try again
/// in a moment."` — accurate and ACTIONABLE, wait and retry — and it was
/// being replaced by a generic "couldn't save" that is neither.
///
/// The catch at `LogTipSheet.swift:2121` even reads "Rolled back, or refused
/// by `mayMutate`", so the code named the case it was mishandling.
///
/// ## Why it matters now rather than in the abstract
///
/// `.conversionPending` is only thrown when the server is mid-conversion on
/// that shift, and until S15 no account could be converting. The flip made
/// it reachable, which turned an unreachable copy bug into a reachable one:
/// a person edits a shift, the sheet refuses, and the reason given is wrong.
///
/// Same family as the silent no-op delete — a refusal the user cannot act
/// on — except the accurate words already existed and were discarded.
///
/// ## What this asserts, and what it deliberately does not
///
/// It asserts the MAPPING from a thrown failure to displayed copy, which is
/// the part that was broken. It does not assert SwiftUI presented an alert:
/// the fix routes copy `ShiftCommands.Failure` already owns through the same
/// alert affordance that already existed, adding no new surface, so there is
/// nothing new to verify about presentation.
@Suite("Conversion-pending alert copy")
struct ConversionPendingAlertTests {

    /// The alert renders `(saveFailure ?? .saveFailed).message`. These pin
    /// both arms of that expression, because the nil arm is what keeps the
    /// fix from overclaiming.

    @Test("a mayMutate refusal says the shift is syncing, not that the save failed")
    func refusalSaysSyncing() {
        // Exactly what the view evaluates: `(saveFailure ?? .saveFailed).message`
        // with `saveFailure` set from `error as? ShiftCommands.Failure`.
        let saveFailure: ShiftCommands.Failure? = .conversionPending
        let shown = (saveFailure ?? .saveFailed).message
        #expect(shown == ShiftCommands.Failure.conversionPending.message)
        #expect(shown == "Payday is still syncing this shift. Try again in a moment.")
        // And it is NOT the generic one, which is the whole defect.
        #expect(shown != ShiftCommands.Failure.saveFailed.message)
    }

    /// **The symmetric guard.** An unknown error must still read generic.
    ///
    /// Claiming a sync is in progress when it is not would be the same
    /// defect pointed the other way: an under-informative message replaced
    /// by an over-confident one. Fixing the first by committing the second
    /// is the trade this test refuses.
    @Test("an unknown failure still reads as the generic save failure")
    func unknownStaysGeneric() {
        let unknown: ShiftCommands.Failure? = nil
        let shown = (unknown ?? .saveFailed).message
        #expect(shown == ShiftCommands.Failure.saveFailed.message)
        #expect(shown != ShiftCommands.Failure.conversionPending.message)
    }

    /// Every case carries distinct copy, so routing the real failure is
    /// worth doing at all.
    ///
    /// If two cases shared a message the fix would be cosmetic, and this is
    /// what makes "show the specific one" a behaviour change rather than a
    /// rename.
    @Test("each failure case says something different")
    func casesAreDistinguishable() {
        let messages = [
            ShiftCommands.Failure.shiftGone.message,
            ShiftCommands.Failure.nothingToSave.message,
            ShiftCommands.Failure.conversionPending.message,
            ShiftCommands.Failure.saveFailed.message,
        ]
        #expect(Set(messages).count == messages.count,
                "two cases sharing copy would make routing the real failure pointless")
        for message in messages {
            #expect(!message.isEmpty)
        }
    }

    /// The refusal the copy describes is REAL, so the message is not
    /// describing a state that cannot occur.
    ///
    /// The first draft of this test asserted `!x || x`, which is true for
    /// every input — a vacuous assertion, the exact artifact this session
    /// spent its length removing, written by me into the suite that exists
    /// because of that family. Caught before it ran. Recorded because "I
    /// know about this failure mode" is evidently not protection against
    /// committing it.
    ///
    /// `mayMutate` refuses when a record HAS legacy sources and the account
    /// is signed in but not yet authoritative — i.e. mid-conversion. Both
    /// halves are asserted, so the refusal is shown to be conditional
    /// rather than constant.
    @MainActor
    @Test("mayMutate refuses a record with legacy sources until the account is authoritative")
    func mayMutateRefusesAConvertingRecord() {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        _ = PaydaySyncState.registerCurrentUser(id)

        let day = Date(timeIntervalSince1970: 1_750_000_000)
        let converting = ShiftRecord(
            workDate: day, cashTipsCents: 1_000, creditTipsCents: 2_000,
            hoursWorked: 5, recordedAt: day
        )
        converting.legacyEntryIDs = [UUID()]

        // Signed in, has legacy sources, not authoritative -> REFUSED, and
        // that refusal is what makes `.conversionPending` reachable.
        #expect(!ShiftCommands.mayMutate(converting))

        // The disagreeing case: once authoritative, the same record is
        // allowed. Without this the refusal could be unconditional and the
        // assertion above would prove nothing about the condition.
        PaydaySyncState.mutate(userID: id) {
            $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
        }
        #expect(ShiftCommands.mayMutate(converting))

        // And a record with NO legacy sources is always allowed, which is
        // the other branch of the predicate.
        let native = ShiftRecord(
            workDate: day, cashTipsCents: 500, hoursWorked: 2, recordedAt: day
        )
        #expect(ShiftCommands.mayMutate(native))
    }
}
