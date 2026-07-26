import Foundation
import SwiftData

/// The one place a new shift's rows get inserted — lifted out of
/// LogTipSheet.saveNew so BackfillSheet's batch flow can create the exact
/// same cash/credit/ShiftDetails rows without duplicating that logic.
/// Callers own everything that isn't the insert itself: the first-shift
/// check, the pre-insert stats/reveal computation, nudge rescheduling, and
/// widget refresh all stay with the caller.
enum ShiftWriter {
    /// Mints one shiftID shared by the cash and credit rows (a "shift" is
    /// every row sharing that id), inserts a row per kind that actually has
    /// an amount, and writes the shift-level details onto the one canonical
    /// entry via ShiftDetails. Returns the inserted rows (zero, one, or two).
    @discardableResult
    static func insertShift(
        into context: ModelContext,
        date: Date,
        cashCents: Int,
        creditCents: Int,
        note: String? = nil,
        recordedAt: Date = .now,
        hoursWorked: Double? = nil,
        tipOutCents: Int? = nil,
        salesCents: Int? = nil,
        shiftPeriod: ShiftPeriod? = nil,
        clockIn: Date? = nil,
        clockOut: Date? = nil,
        serverCount: Int? = nil
    ) -> [TipEntry] {
        // Clamp to today: callers may pass an unclamped date, but a shift
        // can never be logged for the future.
        let normalizedDate = Calendar.current.startOfDay(for: min(date, .now))
        // One id ties this closeout's cash and credit rows into one shift.
        // Calling this again for the same day mints a fresh id — that's how
        // a double (two closeouts) emerges, with no toggle.
        let shiftID = UUID()

        var newEntries: [TipEntry] = []
        if cashCents > 0 {
            let entry = TipEntry(date: normalizedDate, amountCents: cashCents, kind: .cash, note: note, recordedAt: recordedAt, shiftID: shiftID)
            context.insert(entry)
            newEntries.append(entry)
        }
        if creditCents > 0 {
            let entry = TipEntry(date: normalizedDate, amountCents: creditCents, kind: .credit, note: note, recordedAt: recordedAt, shiftID: shiftID)
            context.insert(entry)
            newEntries.append(entry)
        }
        // Shift-level details land on one canonical entry (credit
        // preferred), never split across both — see ShiftDetails.
        ShiftDetails.write(hoursWorked: hoursWorked, tipOutCents: tipOutCents, salesCents: salesCents, shiftPeriod: shiftPeriod, clockIn: clockIn, clockOut: clockOut, serverCount: serverCount, into: newEntries)

        return newEntries
    }
}
