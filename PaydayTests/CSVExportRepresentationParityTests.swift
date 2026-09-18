import Foundation
import SwiftData
import Testing
@testable import Payday
@testable import PaydayCore

/// The CSV's two representation arms must produce the identical row.
///
/// ## Why this suite exists
///
/// `git grep -c "export(records:" -- PaydayTests/` returned **0**. The fix for
/// the most severe defect of the flip review -- an export that permanently
/// omitted every post-conversion shift, offered directly above the delete
/// button -- shipped with its new path completely unexercised.
///
/// And the argument that was protecting it does not reach this far. Funnelling
/// both arms into one `RowShift` builder makes divergent FORMATTING
/// unwritable, which is real: there is one row renderer, so the two files
/// cannot differ in column order, escaping or number formatting. It does NOT
/// make divergent VALUES unwritable, because `RowShift.init(legacyGroup:)` and
/// `RowShift.init(record:)` read different sources and resolve shift-level
/// facts by different rules -- `TipBreakdown`/`ShiftDetails` on one side,
/// direct fields on the other. One row builder guarantees the same shape, not
/// the same numbers.
///
/// So the gate has to be a parity assertion over real data, not an appeal to
/// the architecture.
///
/// ## The shapes chosen, and why each one
///
/// - **A plain cash+credit shift with a tip-out.** The common case, and the
///   one where `ShiftDetails.resolve`'s single-canonical-value rule could
///   disagree with a record's direct field.
/// - **A gratuity-bearing shift.** The one the review flagged: the record arm
///   reads `employeeGratuityFeesCents` raw, so if the two arms ever disagreed
///   about gratuity this is where it would show.
/// - **A wage-only shift with hours and no tips.** Under the legacy two-row
///   model this shape wrote zero rows at all (`ShiftWriter:41-51`, an audit
///   finding), so it is the shape most likely to be absent from one arm.
@Suite("CSV export representation parity", .serialized)
@MainActor
struct CSVExportRepresentationParityTests {

    private static let zone = TimeZone(identifier: "America/New_York")!

    private static func day(_ offset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let base = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        return cal.date(byAdding: .day, value: offset, to: base)!
    }

    private static func calculator() -> PayPeriodCalculator {
        PayPeriodCalculator(payrollTimeZone: zone, schedule: .fallback)
    }

    /// A record and the legacy rows that describe the SAME shift.
    ///
    /// `ShiftProjection.rows(for:)` is what produces the legacy view of a
    /// record, so the two sides are one shift expressed twice rather than two
    /// hand-written fixtures that could drift apart -- the "a test that
    /// rebuilds this by hand is a test that can share the view's mistake"
    /// rule, applied to the input rather than the wiring.
    private func bothRepresentations(_ record: ShiftRecord) -> ([ShiftRecord], [TipEntry]) {
        let entries = ShiftProjection.rows(for: record).map { row in
            TipEntry(
                id: row.id, date: row.date, amountCents: row.amountCents, kind: row.kind,
                note: row.note, recordedAt: row.recordedAt, hoursWorked: row.hoursWorked,
                tipOutCents: row.tipOutCents, salesCents: row.salesCents,
                shiftPeriod: row.shiftPeriod, shiftID: row.shiftID, clockIn: row.clockIn,
                clockOut: row.clockOut, serverCount: row.serverCount,
                receiptMetrics: row.receiptMetrics
            )
        }
        return ([record], entries)
    }

    /// Both arms, over one shift, compared cell by cell.
    ///
    /// `representation:` is named explicitly rather than left to `.automatic`,
    /// because `.automatic` reads global account state and the point here is to
    /// compare the ARMS, not to test the switch. That is exactly what the
    /// `.legacy`/`.records` cases were added for.
    private func rows(for record: ShiftRecord) -> (legacy: [String], records: [String]) {
        let (recordList, entryList) = bothRepresentations(record)
        let legacy = CSVExporter.export(
            entries: entryList, records: [], paycheckRecords: [],
            calculator: Self.calculator(), representation: .legacy
        )
        let records = CSVExporter.export(
            entries: [], records: recordList, paycheckRecords: [],
            calculator: Self.calculator(), representation: .records
        )
        return (legacy.split(separator: "\n").map(String.init),
                records.split(separator: "\n").map(String.init))
    }

    /// Compares by HEADER NAME, never by index. Fixture E1's own rule, from
    /// the reader's side: a column appended later must not break this test in
    /// a way that looks like a value drift.
    private func cells(_ lines: [String]) throws -> [String: String] {
        let header = try #require(lines.first).split(separator: ",", omittingEmptySubsequences: false)
        let row = try #require(lines.dropFirst().first)
            .split(separator: ",", omittingEmptySubsequences: false)
        #expect(header.count == row.count, "header and row must have the same cell count")
        return Dictionary(
            zip(header.map(String.init), row.map(String.init)),
            uniquingKeysWith: { a, _ in a }
        )
    }

    private func expectIdenticalRow(_ record: ShiftRecord, _ label: String) throws {
        let (legacyLines, recordLines) = rows(for: record)

        // Both arms produced a row at all. Without this the test passes when
        // BOTH are empty, which is the failure mode the gap-6 defect actually
        // had: a silently short file.
        #expect(legacyLines.count == 2, "\(label): the legacy arm must export exactly one row")
        #expect(recordLines.count == 2, "\(label): the record arm must export exactly one row")

        let legacy = try cells(legacyLines)
        let records = try cells(recordLines)

        // Named cell by cell so a failure says WHICH column drifted.
        for column in [
            "Date", "Shift", "Cash", "Credit", "Gratuity-Fees", "Tip-Out", "Net",
            "Hours", "Start", "End", "Sales", "Servers", "Double", "Note", "Period",
            "Hours-Clock",
        ] {
            #expect(legacy[column] == records[column],
                    "\(label): column \(column) differs between representations")
        }
    }

    // MARK: - Constructed legacy, not mirrored

    /// **The case the mirror cannot generate.**
    ///
    /// Every parity assertion above derives its legacy side from
    /// `ShiftProjection.rows(for:)`, and a test built by MIRRORING cannot
    /// catch a defect in the mirror: it proves the record arm agrees with the
    /// projection's legacy VIEW of that record, not that a shift which
    /// genuinely exists as a legacy pair exports correctly.
    ///
    /// The projection puts every shift-level value on exactly ONE row. Real
    /// legacy data does not: `CSVExporter`'s own header names the shape --
    /// "a shift with a stray value on both entries (legacy data) still
    /// reports one number here, matching every other reader in the app,
    /// rather than double-counting it." The mirror can never produce that
    /// pair, so no mirrored test can check the claim.
    ///
    /// So this constructs the legacy rows by hand, with `tipOutCents` on BOTH
    /// of them, and asserts the export subtracts it ONCE. A double-subtraction
    /// here is real money: $12.00 of tip-out taken twice is $12.00 missing
    /// from a file someone may take to a payroll dispute.
    ///
    /// **Honest scope.** This shape turned out to be ALREADY gated, by
    /// `CSVExporterTests`' "hours/tip-out/sales set on BOTH entries
    /// (corruption) resolve to one canonical value, never a sum" -- measured:
    /// summing instead of resolving fails both that test and this one. So this
    /// duplicates existing coverage rather than adding it, and it is kept for
    /// one narrow reason: it sits in the PARITY suite, where a reader
    /// evaluating whether the arms agree will look, and it documents the
    /// mirror limitation at the place the mirror is used.
    ///
    /// The generalizable finding is more useful than the test: the mirror
    /// blind spot in parity suites is **partly compensated by single-arm
    /// suites that construct their inputs**. A parity suite cannot see a
    /// defect in its own mirror, but `CSVExporterTests` can, because it builds
    /// legacy rows by hand and never projects. So the audit question is not
    /// "does this parity suite mirror?" but "is there a constructed
    /// counterpart ANYWHERE for the shapes the mirror cannot emit?" -- and
    /// that is what was actually checked before adding this.
    @Test("a legacy pair with a stray tip-out on BOTH rows subtracts it once")
    func strayValueOnBothLegacyRowsIsCountedOnce() throws {
        let day = Self.day(0)
        let shiftID = UUID()
        // Constructed, NOT projected: both rows carry hours and tip-out, which
        // `ShiftProjection` would never emit.
        let cash = TipEntry(
            date: day, amountCents: 4_000, kind: .cash, recordedAt: day,
            hoursWorked: 6, tipOutCents: 1_200, shiftPeriod: .dinner, shiftID: shiftID
        )
        let credit = TipEntry(
            date: day, amountCents: 6_000, kind: .credit, recordedAt: day,
            hoursWorked: 6, tipOutCents: 1_200, shiftPeriod: .dinner, shiftID: shiftID
        )

        let csv = CSVExporter.export(
            entries: [cash, credit], records: [], paycheckRecords: [],
            calculator: Self.calculator(), representation: .legacy
        )
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, "one shift, one row, however many entries back it")
        let cells = try cells(lines)

        // Tip-out reported ONCE, not summed across the two rows.
        #expect(cells["Tip-Out"] == "12.00", "the stray duplicate must not double the tip-out")
        // And Net subtracts it once: 4000 + 6000 - 1200.
        #expect(cells["Net"] == "88.00", "Net must subtract the tip-out exactly once")
        // Hours likewise resolved to the one canonical value, not 12.
        #expect(cells["Hours"] == "6.0000", "hours must not be summed across the pair")
    }

    /// The same discipline for the other direction: a legacy pair where only
    /// ONE row carries the shift-level values, which is what the projection
    /// emits and what most real data looks like. Constructed here anyway, so
    /// the suite has a hand-built baseline to compare the stray case against
    /// rather than trusting that the mirror and the hand-built agree.
    /// **The shape with no constructed counterpart anywhere**, found by asking
    /// the better audit question: not "does this suite mirror?" but "is there
    /// a constructed test for the shapes the mirror cannot emit?"
    ///
    /// `ShiftProjection` emits at most one row per KIND. Real legacy data can
    /// hold two cash rows under one `shiftID` -- two cash amounts logged for
    /// one closeout -- and `TipBreakdown` accumulates them
    /// (`result.cashCents += voluntaryCents`). So the sum is the intended
    /// behaviour, and the record side has a single `cashTipsCents` field to
    /// hold it.
    ///
    /// Asserted because nothing asserted it: the mirror cannot generate the
    /// shape, and unlike the stray-value case there was no single-arm suite
    /// covering it either.
    @Test("a legacy shift with TWO cash rows sums them into one row's Cash cell")
    func twoSameKindLegacyRowsAreSummed() throws {
        let day = Self.day(0)
        let shiftID = UUID()
        let first = TipEntry(
            date: day, amountCents: 3_000, kind: .cash, recordedAt: day,
            hoursWorked: 6, tipOutCents: 500, shiftPeriod: .dinner, shiftID: shiftID
        )
        let second = TipEntry(
            date: day, amountCents: 2_500, kind: .cash,
            recordedAt: day.addingTimeInterval(60), shiftID: shiftID
        )

        let csv = CSVExporter.export(
            entries: [first, second], records: [], paycheckRecords: [],
            calculator: Self.calculator(), representation: .legacy
        )
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, "two rows of one shift are still ONE exported shift")
        let cells = try cells(lines)

        // Summed, because both rows are real cash the person took home.
        #expect(cells["Cash"] == "55.00", "two cash rows of one shift sum")
        // The shift-level tip-out is still resolved once, not multiplied by
        // the number of rows.
        #expect(cells["Tip-Out"] == "5.00")
        #expect(cells["Net"] == "50.00", "5500 - 500")
        #expect(cells["Hours"] == "6.0000")
    }

    @Test("a constructed legacy pair with values on one row matches the mirrored expectation")
    func constructedLegacyPairMatchesMirror() throws {
        let day = Self.day(0)
        let shiftID = UUID()
        let cash = TipEntry(
            date: day, amountCents: 4_000, kind: .cash, recordedAt: day,
            hoursWorked: 6, tipOutCents: 1_200, shiftPeriod: .dinner, shiftID: shiftID
        )
        let credit = TipEntry(
            date: day, amountCents: 6_000, kind: .credit, recordedAt: day,
            shiftPeriod: .dinner, shiftID: shiftID
        )
        let csv = CSVExporter.export(
            entries: [cash, credit], records: [], paycheckRecords: [],
            calculator: Self.calculator(), representation: .legacy
        )
        let cells = try cells(csv.split(separator: "\n").map(String.init))
        #expect(cells["Tip-Out"] == "12.00")
        #expect(cells["Net"] == "88.00")
        #expect(cells["Hours"] == "6.0000")
        #expect(cells["Cash"] == "40.00")
        #expect(cells["Credit"] == "60.00")
    }

    @Test("a cash+credit shift with a tip-out exports identically from both representations")
    func plainShiftIsIdentical() throws {
        let record = ShiftRecord(
            workDate: Self.day(0), shiftPeriod: .dinner,
            cashTipsCents: 5_600, creditTipsCents: 9_900, tipOutCents: 1_200,
            salesCents: 84_000, hoursWorked: 6.5, serverCount: 4,
            recordedAt: Self.day(0)
        )
        try expectIdenticalRow(record, "plain")
    }

    /// The shape the review flagged. The record arm reads
    /// `employeeGratuityFeesCents` raw rather than folding it, so this is
    /// where a disagreement about gratuity would appear.
    @Test("a gratuity-bearing shift exports identically from both representations")
    func gratuityShiftIsIdentical() throws {
        let record = ShiftRecord(
            workDate: Self.day(1), shiftPeriod: .dinner,
            cashTipsCents: 2_000, creditTipsCents: 8_000, tipOutCents: 500,
            hoursWorked: 5.0,
            receiptMetrics: ShiftReceiptMetrics(
                earningsSchemaVersion: 2,
                gratuityFeesCents: 3_400
            ),
            recordedAt: Self.day(1)
        )
        try expectIdenticalRow(record, "gratuity")

        // And the gratuity actually reached the file, so this is not two
        // blank cells agreeing.
        let (_, recordLines) = rows(for: record)
        let cells = try cells(recordLines)
        #expect(cells["Gratuity-Fees"] == "34.00", "the gratuity must be exported, not dropped")
        // Net is cash + credit + gratuity - tipOut = 2000 + 8000 + 3400 - 500.
        #expect(cells["Net"] == "129.00", "Net must include gratuity and subtract tip-out once")
    }

    /// A wage-only shift: hours, no tips. Under the legacy two-row model this
    /// shape wrote no rows at all, so it is the one most likely to be missing
    /// from an arm rather than merely different.
    @Test("a wage-only shift with hours appears in the record arm's export")
    func wageOnlyShiftIsExported() throws {
        let record = ShiftRecord(
            workDate: Self.day(2), shiftPeriod: .lunch,
            cashTipsCents: 0, creditTipsCents: 0, hoursWorked: 5.0,
            recordedAt: Self.day(2)
        )
        let csv = CSVExporter.export(
            entries: [], records: [record], paycheckRecords: [],
            calculator: Self.calculator(), representation: .records
        )
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, "a wage-only shift must still export a row; its hours are real")
        let cells = try cells(lines)
        #expect(cells["Hours"] == "5.0000")
        #expect(cells["Net"] == "0.00")
    }

    /// The gap-6 regression guard, stated as the defect rather than as the
    /// fix: on an authoritative account a shift exists ONLY as a record, and
    /// an export that reads `entries` omits it permanently, because the
    /// deriver runs legacy-to-records only and nothing ever writes a
    /// `TipEntry` back.
    @Test("a records-only dataset exports its shifts instead of an empty file")
    func recordsOnlyDatasetIsNotEmpty() throws {
        let records = [
            ShiftRecord(workDate: Self.day(0), cashTipsCents: 1_000,
                        creditTipsCents: 2_000, hoursWorked: 4.0, recordedAt: Self.day(0)),
            ShiftRecord(workDate: Self.day(1), cashTipsCents: 3_000,
                        creditTipsCents: 4_000, hoursWorked: 5.0, recordedAt: Self.day(1)),
        ]
        let csv = CSVExporter.export(
            entries: [], records: records, paycheckRecords: [],
            calculator: Self.calculator(), representation: .records
        )
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 3, "two shifts must produce two rows under the header")

        // The legacy arm over the same dataset is the DEFECT: nothing to read.
        let legacyOverRecordsOnly = CSVExporter.export(
            entries: [], records: records, paycheckRecords: [],
            calculator: Self.calculator(), representation: .legacy
        )
        #expect(legacyOverRecordsOnly.split(separator: "\n").count == 1,
                "the legacy arm sees nothing here, which is precisely why the switch had to exist")
    }
}
