import Foundation
import SwiftData
import Testing
@testable import Payday

/// PR 2, the reader-switch cut: `SmartNudgeScheduler` learns to read either
/// representation, and reads neither differently than before.
///
/// Why a switch and not a union: during the conversion window a converted
/// shift exists as a `ShiftRecord` AND as its original `TipEntry` rows, which
/// are never rewritten. A reader that consulted both would count that shift
/// twice, so `shiftsAreAuthoritative` selects one.
///
/// Why this reader first: it carries no money at all, so the pattern can be
/// established without also being a money-path change, and it is the surface
/// where a wrong answer is most obviously wrong — the nudge exists to say
/// "you haven't logged tonight", and after the writer flips to
/// `ShiftCommands` (which writes `ShiftRecord` and never `TipEntry`) an
/// unswitched reader would say that to someone who just logged.
///
/// Both tests below pin the two halves the cut depends on: nothing changes
/// for any account that has not converted (which is every shipped account
/// today, so this PR ships no behaviour change), and the `ShiftRecord` path
/// is genuinely read when it is selected.
@Suite("Smart nudge representation switch", .serialized)
@MainActor
struct SmartNudgeSwitchTests {

    private func account(authoritative: Bool) -> UUID {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        _ = PaydaySyncState.registerCurrentUser(id)
        if authoritative {
            PaydaySyncState.mutate(userID: id) {
                $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
            }
        }
        #expect(PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount == authoritative)
        return id
    }

    private static let calendar = Calendar.current

    /// A fixed Friday-ish anchor at 20:00, so "tonight" has not yet reached
    /// the 22:45 fire time.
    private static let now = calendar.date(
        bySettingHour: 20, minute: 0, second: 0,
        of: Date(timeIntervalSince1970: 1_790_000_000)
    )!

    /// Five prior weeks on the same weekday, each logged at 22:00, which is
    /// what `workRhythm` needs to call this a usual night with a typical hour.
    private static func historyDays() -> [Date] {
        (1...5).compactMap {
            calendar.date(byAdding: .day, value: -7 * $0, to: calendar.startOfDay(for: now))
        }
    }

    private static func loggedAt22(_ day: Date) -> Date {
        calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
    }

    private static func legacyHistory() -> [TipEntry] {
        historyDays().map { day in
            TipEntry(date: day, amountCents: 9_000, kind: .cash,
                     recordedAt: loggedAt22(day), hoursWorked: 6, shiftID: UUID())
        }
    }

    private static func shiftHistory() -> [ShiftRecord] {
        historyDays().map { day in
            ShiftRecord(workDate: day, cashTipsCents: 9_000, hoursWorked: 6,
                        recordedAt: loggedAt22(day))
        }
    }

    /// Half one: for an account that has not converted — every shipped
    /// account today — the switch is a no-op. Asserted against a
    /// `shiftRecords` array that is deliberately NON-EMPTY and would produce a
    /// different answer if it were consulted, because passing an empty array
    /// would make this pass whether the branch worked or not.
    @Test("the switch is a no-op for an account that has not converted")
    func switchIsANoOpForAnAccountThatHasNotConverted() {
        _ = account(authoritative: false)
        let legacy = Self.legacyHistory()

        // Shift rows for TONIGHT as well as the history. If this array were
        // read, tonight would count as already logged and the fire date would
        // move a week.
        var shifts = Self.shiftHistory()
        shifts.append(ShiftRecord(workDate: Self.calendar.startOfDay(for: Self.now),
                                  cashTipsCents: 9_000, hoursWorked: 6,
                                  recordedAt: Self.now))

        let viaSwitch = SmartNudgeScheduler.rhythmFireDate(
            allEntries: legacy, shiftRecords: shifts, from: Self.now
        )
        let legacyOnly = SmartNudgeScheduler.rhythmFireDate(rows: legacy, from: Self.now)

        #expect(viaSwitch == legacyOnly)
        // And it really is tonight, so the comparison above is not two nils.
        let tonight = try? #require(viaSwitch)
        #expect(tonight != nil)
        if let tonight {
            #expect(Self.calendar.isDate(tonight, inSameDayAs: Self.now))
        }
    }

    /// Half two: when the account IS authoritative the `ShiftRecord` path is
    /// read, and the legacy array is ignored rather than merged. Proved by
    /// passing legacy rows for tonight and shift rows that have none: if
    /// either were merged, tonight would look logged.
    @Test("an authoritative account reads ShiftRecord and ignores the legacy rows")
    func authoritativeAccountReadsShiftRecords() {
        _ = account(authoritative: true)

        var legacy = Self.legacyHistory()
        legacy.append(TipEntry(date: Self.calendar.startOfDay(for: Self.now),
                               amountCents: 9_000, kind: .cash,
                               recordedAt: Self.now, hoursWorked: 6, shiftID: UUID()))

        let fire = SmartNudgeScheduler.rhythmFireDate(
            allEntries: legacy, shiftRecords: Self.shiftHistory(), from: Self.now
        )

        // Tonight is unlogged in the SHIFT representation, so the nudge is
        // tonight. Were the legacy array consulted or merged, tonight would
        // count as logged and this would be a week out.
        let tonight = try? #require(fire)
        #expect(tonight != nil)
        if let tonight {
            #expect(Self.calendar.isDate(tonight, inSameDayAs: Self.now))
        }
    }

    /// The user-visible behaviour, now through the shift path: a shift logged
    /// tonight must suppress tonight's nudge. This is the assertion that would
    /// have failed after the writer flip if this reader had not been switched.
    @Test("a shift logged tonight suppresses tonight's nudge through the shift path")
    func aShiftLoggedTonightSuppressesTonightsNudge() {
        _ = account(authoritative: true)

        var shifts = Self.shiftHistory()
        let unsuppressed = SmartNudgeScheduler.rhythmFireDate(
            allEntries: [], shiftRecords: shifts, from: Self.now
        )
        shifts.append(ShiftRecord(workDate: Self.calendar.startOfDay(for: Self.now),
                                  cashTipsCents: 9_000, hoursWorked: 6,
                                  recordedAt: Self.now))
        let suppressed = SmartNudgeScheduler.rhythmFireDate(
            allEntries: [], shiftRecords: shifts, from: Self.now
        )

        // Guard against the comparison being two nils or two equal values,
        // which is how an earlier parity test in this project passed for the
        // wrong reason.
        #expect(unsuppressed != nil)
        #expect(suppressed != unsuppressed)
        if let unsuppressed { #expect(Self.calendar.isDate(unsuppressed, inSameDayAs: Self.now)) }
        if let suppressed { #expect(!Self.calendar.isDate(suppressed, inSameDayAs: Self.now)) }
    }
}
