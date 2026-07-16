import Foundation

/// The single place the "hours/tip-out/sales belong to the shift (one
/// closeout), never to one entry or tip type" rule is enforced — on read
/// (resolve) and on write (write). A shift with a cash entry and a credit
/// entry only ever has these three fields live on ONE of them, credit
/// preferred, matching the convention used everywhere a shift gets logged.
/// Callers pass a SINGLE shift's entries (the rows sharing one shiftID),
/// not a whole day — a double day has two independent shifts, each with its
/// own canonical entry. This is a product ruling, not a UI convenience:
/// StatsEngine and CSVExporter both resolve through here too, so a corrupted
/// shift (a value stray on the "wrong" entry, or set on both at once) reads
/// as one number everywhere in the app, never a double-counted one.
enum ShiftDetails {
    /// The canonical hours/tip-out/sales/shift-period for a set of entries
    /// covering one shift, resolved from whichever entry actually holds
    /// it — credit first, falling back to cash — and NEVER summed across
    /// entries.
    static func resolve(from entries: [TipEntry]) -> (hoursWorked: Double?, tipOutCents: Int?, salesCents: Int?, shiftPeriod: ShiftPeriod?, clockIn: Date?, clockOut: Date?) {
        let credit = entries.first { $0.kind == .credit }
        let cash = entries.first { $0.kind == .cash }
        return (
            hoursWorked: credit?.hoursWorked ?? cash?.hoursWorked,
            tipOutCents: credit?.tipOutCents ?? cash?.tipOutCents,
            salesCents: credit?.salesCents ?? cash?.salesCents,
            shiftPeriod: credit?.shiftPeriod ?? cash?.shiftPeriod,
            clockIn: credit?.clockIn ?? cash?.clockIn,
            clockOut: credit?.clockOut ?? cash?.clockOut
        )
    }

    /// Writes hours/tip-out/sales/shift-period/clockIn/clockOut onto the
    /// one canonical entry for a shift (credit when one exists, else the
    /// first entry) and clears them from every other entry in that shift —
    /// self-healing any data where a value ended up set on more than one
    /// entry. clockIn/clockOut default to nil so existing call sites (and
    /// tests) that only care about the original four fields keep compiling.
    static func write(hoursWorked: Double?, tipOutCents: Int?, salesCents: Int?, shiftPeriod: ShiftPeriod?, clockIn: Date? = nil, clockOut: Date? = nil, into entries: [TipEntry]) {
        guard let primary = entries.first(where: { $0.kind == .credit }) ?? entries.first else { return }
        for entry in entries where entry.id != primary.id {
            entry.hoursWorked = nil
            entry.tipOutCents = nil
            entry.salesCents = nil
            entry.shiftPeriod = nil
            entry.clockIn = nil
            entry.clockOut = nil
        }
        primary.hoursWorked = hoursWorked
        primary.tipOutCents = tipOutCents
        primary.salesCents = salesCents
        primary.shiftPeriod = shiftPeriod
        primary.clockIn = clockIn
        primary.clockOut = clockOut
    }
}
