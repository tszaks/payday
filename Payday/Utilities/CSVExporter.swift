import Foundation

/// Turns logged shifts into a plain CSV, one row per shift (one closeout;
/// cash and credit merged, same "a shift, not a row" rule as ShiftDayRow) —
/// a pure, fully-tested function, no SwiftUI, no file I/O of its own. A
/// double day produces two rows, one per closeout, distinguished by the
/// Shift column and both flagged Double.
///
/// Gratuity/Hours/Start/End/Tip-Out/Sales/Servers are shift-level facts, not
/// per-entry ones: each column reflects ShiftDetails.resolve's single
/// canonical value (credit entry preferred, else cash), never a sum across
/// the shift's entries — a shift with a stray value on both entries (legacy
/// data) still reports one number here, matching every other reader in the
/// app, rather than double-counting it.
enum CSVExporter {
    /// New columns are APPENDED, never inserted, and that is a deliberate
    /// cost. `Hours-Clock` reads better next to `Hours`, but inserting it
    /// would shift every later column and break a formula in whatever
    /// spreadsheet someone already built on an earlier export. Readability
    /// loses to not breaking a file that is already on someone's computer.
    /// Fixture E1 requires cells to be located by HEADER NAME and never by
    /// index, which is the same rule from the reader's side.
    static let header = "Date,Shift,Cash,Credit,Gratuity-Fees,Tip-Out,Net,Hours,Start,End,Sales,Servers,Double,Note,Period,Paycheck,Hours-Clock,Non-Wage-Earnings,Regular-Wages,Overtime-Wages,Earned-Income,Completeness"

    /// `valuations` carries the engine's answer for each shift, keyed by shift
    /// id. When a shift has none the five engine columns are EMPTY rather than
    /// zero: a blank says "not computed", a zero says "the engine says you
    /// earned nothing", and in a file someone may take to a payroll dispute
    /// those are not interchangeable.
    /// The one entry point. Takes BOTH representations and resolves which
    /// to read itself — see `ShiftRepresentation` for why callers no longer
    /// get to choose, and `export(records:)` below for what this file in
    /// particular gets wrong when a caller chooses legacy by accident.
    @MainActor
    static func export(
        entries: [TipEntry],
        records: [ShiftRecord],
        paycheckRecords: [PaycheckRecord],
        calculator: PayPeriodCalculator,
        calendar: Calendar = .current,
        valuations: [UUID: ShiftValuation] = [:],
        representation: ShiftRepresentation = .automatic
    ) -> String {
        representation.usesRecords
            ? export(records: records, paycheckRecords: paycheckRecords, calculator: calculator, calendar: calendar, valuations: valuations)
            : export(entries: entries, paycheckRecords: paycheckRecords, calculator: calculator, calendar: calendar, valuations: valuations)
    }

    static func export(
        entries: [TipEntry],
        paycheckRecords: [PaycheckRecord],
        calculator: PayPeriodCalculator,
        calendar: Calendar = .current,
        valuations: [UUID: ShiftValuation] = [:]
    ) -> String {
        let shifts = ShiftDays.groupedByShift(entries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod, calendar: calendar)
            .map(RowShift.init(legacyGroup:))
        return export(shifts: shifts, paycheckRecords: paycheckRecords, calculator: calculator, calendar: calendar, valuations: valuations)
    }

    /// The same export from the new representation.
    ///
    /// This exists because of what the export IS on a converted account.
    /// `LogTipSheet.saveNew` writes a `ShiftRecord` and no `TipEntry` once
    /// the account is authoritative, so a shift logged after conversion has
    /// no legacy row at all — and an exporter reading `entries` would omit
    /// it silently. `DeleteAccountSheet` offers this file directly above the
    /// delete button, calling it the honest alternative to losing the
    /// record, so a short export there is the safety net failing quietly at
    /// the one moment it is the only thing standing between someone and
    /// permanently losing their own history.
    ///
    /// Both entry points funnel into `export(shifts:)`. One row builder, so
    /// the two representations cannot drift into two different files.
    @MainActor
    static func export(
        records: [ShiftRecord],
        paycheckRecords: [PaycheckRecord],
        calculator: PayPeriodCalculator,
        calendar: Calendar = .current,
        valuations: [UUID: ShiftValuation] = [:]
    ) -> String {
        export(shifts: records.map(RowShift.init(record:)), paycheckRecords: paycheckRecords, calculator: calculator, calendar: calendar, valuations: valuations)
    }

    private static func export(
        shifts unsorted: [RowShift],
        paycheckRecords: [PaycheckRecord],
        calculator: PayPeriodCalculator,
        calendar: Calendar,
        valuations: [UUID: ShiftValuation]
    ) -> String {
        let shifts = unsorted.sorted { $0.day < $1.day }
        var dayShiftCounts: [Date: Int] = [:]
        for shift in shifts { dayShiftCounts[shift.day, default: 0] += 1 }
        let rows = shifts.map { shift -> String in
            row(for: shift, dayHasMultipleShifts: (dayShiftCounts[shift.day] ?? 0) >= 2, paycheckRecords: paycheckRecords, calculator: calculator, calendar: calendar, valuation: valuations[shift.shiftID])
        }
        return ([header] + rows).joined(separator: "\n")
    }

    /// One shift's facts as a row needs them, from EITHER representation.
    ///
    /// The row builder below takes this and nothing else, which is what makes
    /// "the legacy export and the record export produce different files" a
    /// thing that cannot be written rather than a thing to be tested for.
    /// Every money value arrives already resolved — no arithmetic happens in
    /// the row.
    private struct RowShift {
        let day: Date
        let shiftID: UUID
        let cashCents: Int
        let creditCents: Int
        let gratuityFeesCents: Int
        /// Named for the engine's own metric rather than the legacy
        /// `.netCents` spelling: this is `nonWageEarnings` (cash + credit +
        /// gratuity - tip-out), the CSV's `Net` column is just its label, and
        /// design-lint rule 4 correctly refuses the old name outside the
        /// engine because PR 8 deletes it.
        let nonWageEarningsCents: Int
        let tipOutCents: Int?
        let hoursWorked: Double?
        let clockIn: Date?
        let clockOut: Date?
        let salesCents: Int?
        let serverCount: Int?
        let shiftPeriod: ShiftPeriod?
        let note: String

        /// The legacy pair-of-rows shape, resolved by the same two helpers
        /// every other legacy reader uses: `TipBreakdown.total` for the money
        /// and `ShiftDetails.resolve` for the shift-level facts. Unchanged
        /// behaviour — this is the code that was inline in `row`.
        init(legacyGroup group: (day: Date, shiftID: UUID, items: [TipEntry])) {
            let breakdown = TipBreakdown.total(of: group.items)
            let details = ShiftDetails.resolve(from: group.items)
            day = group.day
            shiftID = group.shiftID
            cashCents = breakdown.cashCents
            creditCents = breakdown.creditCents
            gratuityFeesCents = breakdown.gratuityFeesCents
            nonWageEarningsCents = breakdown.netTotalCents
            tipOutCents = details.tipOutCents
            hoursWorked = details.hoursWorked
            clockIn = details.clockIn
            clockOut = details.clockOut
            salesCents = details.salesCents
            serverCount = details.serverCount
            shiftPeriod = details.shiftPeriod
            note = group.items.compactMap(\.note).joined(separator: "; ")
        }

        /// One record, one shift, no resolution step: the fields ARE the
        /// shift's facts. `nonWageEarningsCents` is the model's own helper
        /// rather than the sum spelled out here, so this file adds no money
        /// arithmetic outside the engine (design-lint rule 4) and the Net
        /// column cannot disagree with every other reader of the same shift.
        ///
        /// `employeeGratuityFeesCents` is read RAW, with no v2 fold, and that
        /// is the same choice `StatsRecordAdapter` makes for the same reason:
        /// `ShiftRecord.nonWageEarningsCents` -- the model's own definition of
        /// what a shift earned -- reads the field unguarded, so a reader that
        /// folded first would be a second definition of a record's money.
        ///
        /// It is safe because a v1 payload cannot reach a `ShiftRecord`,
        /// enforced at both write points: the server deriver's sanitizer
        /// stamps `earningsSchemaVersion` to 2 with `create_missing = true`,
        /// and on device the `receiptMetrics` setter asserts `>= 2` while
        /// `design-lint` makes `applyEarnings` the only writer. Both halves
        /// are needed; neither alone would do it.
        @MainActor
        init(record: ShiftRecord) {
            day = record.workDate
            shiftID = record.id
            cashCents = record.cashTipsCents
            creditCents = record.creditTipsCents
            gratuityFeesCents = record.receiptMetrics?.employeeGratuityFeesCents ?? 0
            nonWageEarningsCents = record.nonWageEarningsCents
            tipOutCents = record.tipOutCents
            hoursWorked = record.hoursWorked
            clockIn = record.clockIn
            clockOut = record.clockOut
            salesCents = record.salesCents
            serverCount = record.serverCount
            shiftPeriod = record.shiftPeriod
            note = record.note ?? ""
        }
    }

    private static func row(for shift: RowShift, dayHasMultipleShifts: Bool, paycheckRecords: [PaycheckRecord], calculator: PayPeriodCalculator, calendar: Calendar, valuation: ShiftValuation?) -> String {
        let day = shift.day
        let shiftDetails = shift
        let cashCents = shift.cashCents
        let creditCents = shift.creditCents
        let gratuityFeesCents = shift.gratuityFeesCents
        let nonWageEarningsCents = shift.nonWageEarningsCents
        let shiftField = shift.shiftPeriod?.displayName ?? ""
        let note = shift.note

        let period = calculator.period(containing: day)
        let paycheck = paycheckRecords.first { $0.periodEnd >= period.start && $0.periodEnd <= period.end }

        // Bound individually rather than inline in the array literal below —
        // that many chained `.map(...) ?? ""` expressions in one array
        // literal was slow enough to trip the type checker's time budget.
        let tipOutField: String = shiftDetails.tipOutCents.map(dollars) ?? ""
        // THE ENGINE'S FORMATTER, not a local one. The previous line here was
        // `shiftDetails.hoursWorked.map(trimmedHours)`, and `trimmedHours`
        // rounded to the quarter hour: a 6h23m shift exported as "6.5". That
        // contradicted PRODUCT.md's punches-are-literal ruling and is what
        // fixture E1 exists to prevent, since a payroll dispute is argued from
        // this file. Minutes come from the engine's conversion so the export
        // and the wage math cannot disagree about what the shift was.
        let minutesWorked: Int? = shiftDetails.hoursWorked.map(HoursFormatting.minutes(fromHours:))
        let hoursField: String = minutesWorked.map(HoursFormatting.decimalHours(minutes:)) ?? ""
        let clockHoursField: String = minutesWorked.map(HoursFormatting.clockHours(minutes:)) ?? ""
        let startField: String = shiftDetails.clockIn.map { time24($0, calendar: calendar) } ?? ""
        let endField: String = shiftDetails.clockOut.map { time24($0, calendar: calendar) } ?? ""
        let salesField: String = shiftDetails.salesCents.map(dollars) ?? ""
        let serversField: String = shiftDetails.serverCount.map(String.init) ?? ""
        let paycheckField: String = paycheck.map { dollars($0.paidTipsCents) } ?? ""
        let periodField = "\(isoDate(period.start)) to \(isoDate(period.end))"

        let fields = [
            isoDate(day),
            shiftField,
            dollars(cashCents),
            dollars(creditCents),
            gratuityFeesCents > 0 ? dollars(gratuityFeesCents) : "",
            tipOutField,
            dollars(nonWageEarningsCents),
            hoursField,
            startField,
            endField,
            salesField,
            serversField,
            dayHasMultipleShifts ? "Y" : "N",
            escape(note),
            periodField,
            paycheckField,
            clockHoursField,
            // Empty, not zero, when the engine has no answer for this shift.
            valuation.map { dollars($0.components.nonWageEarningsCents) } ?? "",
            valuation.map { dollars($0.components.regularWagesCents) } ?? "",
            valuation.map { dollars($0.components.overtimeWagesCents) } ?? "",
            valuation.map { dollars($0.components.earnedIncomeCents) } ?? "",
            valuation.map(completeness) ?? ""
        ]
        return fields.joined(separator: ",")
    }

    private static func isoDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    private static func dollars(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100)
    }

    /// Why this row's wage is what it is, in one word per state.
    ///
    /// A blank `Earned-Income` with no explanation is a support ticket. This
    /// column is what turns "the engine had no answer" into a reason, and the
    /// distinction between `estimated` and `complete` is the one that matters
    /// for a dispute: an estimated wage came from a rate the user has not yet
    /// confirmed.
    private static func completeness(_ valuation: ShiftValuation) -> String {
        switch valuation.wage {
        case .valued(_, let assumed): return assumed ? "estimated" : "complete"
        case .unavailable(.rateNotSet): return "no rate set"
        case .unavailable(.hoursMissing): return "hours missing"
        case .unavailable(.noCalendarPolicy): return "no payroll calendar"
        }
    }

    /// Fixed 24-hour "HH:mm" — deliberately locale-independent, unlike the
    /// am/pm rendering Moves and Insights narration use for prose. A CSV
    /// column needs one unambiguous format regardless of who opens it, same
    /// reasoning as isoDate below.
    private static func time24(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// Characters that make a spreadsheet treat a cell as a formula rather
    /// than text. Tab and carriage return are included because Excel strips
    /// leading whitespace before deciding.
    private static let formulaTriggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Quotes and escapes a field only when it actually needs it — a plain
    /// note with no comma, quote, or newline stays unquoted — and makes sure
    /// the cell cannot be read as a formula.
    ///
    /// CSV quoting alone is not enough. Quoting protects the file's STRUCTURE;
    /// it does nothing about a cell whose text begins with `=`, `+`, `-` or
    /// `@`, which Excel, Numbers and Sheets evaluate on open. Notes are the
    /// one free-text column here and the agent API accepts them from any
    /// write-scoped key, so an exported CSV could carry a live formula into
    /// whatever the person opens it with (CWE-1236, found by the 2026-09-14
    /// security review).
    private static func escape(_ field: String) -> String {
        let neutralized = neutralizingFormula(field)
        guard neutralized.contains(",") || neutralized.contains("\"") || neutralized.contains("\n") else {
            return neutralized
        }
        return "\"\(neutralized.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Prefixes a leading apostrophe, which every major spreadsheet reads as
    /// "the rest of this cell is literal text". Applied after trimming the
    /// leading whitespace those applications ignore, so " =1+1" is caught too.
    private static func neutralizingFormula(_ field: String) -> String {
        guard let first = field.drop(while: { $0 == " " }).first,
              formulaTriggers.contains(first)
        else { return field }
        return "'" + field
    }
}
