import Foundation

/// Per-shift wage math for the surfaces that have not moved to
/// `EarningsSnapshot` yet. As of PR 3 every function here is a thin wrapper
/// over `CompensationLedger`: no `Double` arithmetic, no second rounding
/// rule, one engine. PR 5 migrates the callers and PR 8 deletes this type.
///
/// It remains wage-only by contract. Callers add the tip side themselves
/// (`TipBreakdown`), and nothing here is ever classified as voluntary tips or
/// employee gratuity.
enum WageEstimate {
    /// Pre-tax wages for ONE shift of `hours` at `wageCentsPerHour`.
    ///
    /// Routed through the ledger's integer arithmetic in units of 1/6000
    /// cent, so 4.25h at 283c is 1203 by rule and not by coincidence.
    /// Returns nil when the rate isn't set or no hours were logged — an
    /// estimate is never fabricated from a fallback.
    ///
    /// NOT for a row inside a list. This rounds ONE shift in isolation, and
    /// a shift in isolation is not a shift inside a workweek: it carries no
    /// overtime, and its half cents round on their own (5.5h at 283c is 1557
    /// here, 1556 as the second shift of W1's day). A figure that has to add
    /// up to a total alongside its siblings must come from
    /// `centsPerShift`/`centsByShiftID`, which allocate all of them at once.
    /// What is left for this function is the genuinely solitary shift: the
    /// live in-progress edit in `LogTipSheet`, whose shift is not saved yet,
    /// and `StatsEngine`'s per-shift rate facts. PR 5 moves both onto
    /// `EarningsSnapshot`.
    static func cents(wageCentsPerHour: Int?, hours: Double) -> Int? {
        guard let wageCentsPerHour, wageCentsPerHour > 0, hours > 0 else { return nil }
        return CompensationLedger.roundCents(
            CompensationLedger.wageUnits(
                rateCents: wageCentsPerHour,
                minutes: WorkedMinutes.minutes(fromHours: hours),
                multiplierHundredths: 100
            )
        )
    }

    /// Total logged hours for grouped shifts (sum of each shift's canonical
    /// hoursWorked via ShiftDetails' one-value-per-shift rule) — a shift's
    /// hours count once no matter how many `TipEntry` rows made up its
    /// closeout.
    static func loggedHours(shiftGroups: [[TipEntry]]) -> Double {
        shiftGroups.reduce(0) { $0 + (ShiftDetails.resolve(from: $1).hoursWorked ?? 0) }
    }

    /// The LogTipSheet header total: cash + credit, net of tip-out, plus this
    /// shift's base-rate wages. The one place that math lives, so it is
    /// testable independent of the view.
    static func shiftTotalCents(cashCents: Int, creditCents: Int, tipOutCents: Int, wageCentsPerHour: Int?, hoursWorked: Double?) -> Int {
        let wage = hoursWorked.flatMap { cents(wageCentsPerHour: wageCentsPerHour, hours: $0) } ?? 0
        return cashCents + creditCents - tipOutCents + wage
    }

    /// Wages for a set of shift groups, valued ONCE by the ledger and summed.
    ///
    /// Before PR 3 this rounded each shift on its own and added the results,
    /// which made a 4.25h and a 5.5h shift at $2.83 come to 2760c while the
    /// same two shifts' week came to 2759c — the app disagreed with itself by
    /// a cent depending on which screen you were looking at. The ledger
    /// allocates each shift its slice of the week's running total instead
    /// (Design 1, step 5), so these per-shift figures telescope exactly to
    /// the week total, each is still within 1c of its own naive rounding, and
    /// the W1 golden fixture's 1203 + 1556 = 2759 is what both surfaces say.
    /// `roundsPerShiftNotPerTotal` is superseded, by the plan, on purpose.
    ///
    /// CAVEAT, and it is the reason PR 5 exists: the threshold is split over
    /// the workweeks of the shifts PASSED IN. Handing this a single day or a
    /// single month therefore under-reports overtime for a week that extends
    /// past that range, exactly as W2 asserts. It is still strictly better
    /// than the old behaviour, which reported no overtime here at all; the
    /// fix is for the caller to read `EarningsSnapshot` over every shift.
    static func centsSummedPerShift(
        payrollTimeZone: TimeZone,
        workweekStartWeekday: Int,
        shiftGroups: [[TipEntry]],
        wageCentsPerHour: Int?
    ) -> Int {
        centsPerShift(
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: workweekStartWeekday,
            shiftGroups: shiftGroups,
            wageCentsPerHour: wageCentsPerHour
        ).reduce(0, +)
    }

    /// The per-shift figures `centsSummedPerShift` is the sum of, in the
    /// order the groups arrived — so a screen's rows and the total above them
    /// are two views of ONE array and cannot be a cent apart.
    ///
    /// This is the fix for PR 3's review P0: `centsSummedPerShift` moved the
    /// day/period total onto the ledger's cumulative allocation, but every
    /// per-shift DISPLAY was still calling `cents(wageCentsPerHour:hours:)`,
    /// which rounds each shift independently. One civil day with a 4.25h and
    /// a 5.5h shift at 283c/hr read 2759 in the DayDetailSheet hero and
    /// 1203 + 1557 = 2760 in the two rows listed directly beneath it.
    ///
    /// `cents(wageCentsPerHour:hours:)` remains for the surfaces that hold a
    /// single shift with no sibling set to allocate against (LogTipSheet's
    /// live in-progress edit, `StatsEngine`'s per-shift rate facts). Those
    /// are still independently rounded and can still be 1c from this array;
    /// PR 5 moves them onto `EarningsSnapshot`. See docs/PRODUCT.md Pillar 8.
    static func centsPerShift(
        payrollTimeZone: TimeZone,
        workweekStartWeekday: Int,
        shiftGroups: [[TipEntry]],
        wageCentsPerHour: Int?
    ) -> [Int] {
        guard wageCentsPerHour != nil else { return Array(repeating: 0, count: shiftGroups.count) }
        return LegacyLedgerBridge.wagesCentsPerShift(
            shiftGroups: shiftGroups,
            rateCents: wageCentsPerHour,
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: workweekStartWeekday
        )
    }

    /// `centsPerShift` keyed by the caller's OWN shift ids, for a list that
    /// renders rows out of `ShiftDays.groupedByShift` output. Pass the same
    /// grouping the rows are built from; the key is that grouping's
    /// `shiftID`, so a row can never look up another shift's slice.
    static func centsByShiftID(
        payrollTimeZone: TimeZone,
        workweekStartWeekday: Int,
        shifts: [(day: Date, shiftID: UUID, items: [TipEntry])],
        wageCentsPerHour: Int?
    ) -> [UUID: Int] {
        let wages = centsPerShift(
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: workweekStartWeekday,
            shiftGroups: shifts.map(\.items),
            wageCentsPerHour: wageCentsPerHour
        )
        return Dictionary(zip(shifts.map(\.shiftID), wages), uniquingKeysWith: +)
    }

    /// Exact hour label ("6h 23m") for every user-facing hours display — now
    /// `WorkedMinutes.hoursLabel`, so the app and the engine cannot describe
    /// the same shift two different ways. Minutes are omitted only when they
    /// are exactly zero ("6h"), never rounded away otherwise: a punch is
    /// literal (Tyler's law).
    static func hoursLabel(_ hours: Double) -> String {
        WorkedMinutes.hoursLabel(minutes: WorkedMinutes.minutes(fromHours: hours))
    }
}
