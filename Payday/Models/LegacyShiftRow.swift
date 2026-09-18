import Foundation

/// The 16 members of a legacy tip row, as a protocol.
///
/// PR 2 slice S9. Every reader that used to take `[TipEntry]` becomes generic
/// over this instead, which is what lets a `ShiftRecord` be projected into the
/// same shape and read by the same code. `TipEntry` already satisfies all of
/// it as written, so the conformance below is empty and `TipEntry` itself does
/// not change.
///
/// **Why a protocol rather than overloads.** An earlier design replaced this
/// with seven `[ShiftRow]` overloads plus a one-to-two expansion, purely
/// because it had redefined a row as one per SHIFT carrying both cash and
/// credit. One row per KIND dissolves that: the bridge into `TipRecord` is a
/// faithful 1:1 again, `StatsEngine.shiftFacts`' kind filter and its
/// credit-first resolution keep working untouched, and "every existing test
/// compiles unchanged" is satisfied by construction rather than by maintaining
/// a second parallel surface.
protocol LegacyShiftRow {
    var id: UUID { get }
    var date: Date { get }
    var amountCents: Int { get }
    var kind: TipKind { get }
    var note: String? { get }
    var recordedAt: Date? { get }
    var shiftID: UUID? { get }
    var hoursWorked: Double? { get }
    var tipOutCents: Int? { get }
    var salesCents: Int? { get }
    var shiftPeriod: ShiftPeriod? { get }
    var clockIn: Date? { get }
    var clockOut: Date? { get }
    var serverCount: Int? { get }
    var receiptMetrics: ShiftReceiptMetrics? { get }
    var isDouble: Bool { get }

    /// Declared rather than left to the extension because `CalendarView` sums
    /// it row by row, so a conforming type is allowed to have its own.
    var netCents: Int { get }
}

extension LegacyShiftRow {
    /// This row's voluntary tips plus any canonical employee gratuity or fees,
    /// minus any canonical tip-out.
    ///
    /// The same body as `TipEntry.netCents`, deliberately, because the whole
    /// point of the projection is that the before and after sides agree to the
    /// cent. Shift-level receipt data lives on exactly one projected row, so
    /// summing this across a shift counts the gratuity and the tip-out once
    /// each — which is also the fix for the calendar double-subtracting a
    /// duplicated tip-out.
    var netCents: Int {
        (receiptMetrics?.employeeEarningsCents(fromStoredAmount: amountCents) ?? amountCents)
            - (tipOutCents ?? 0)
    }
}

extension TipEntry: LegacyShiftRow {}
