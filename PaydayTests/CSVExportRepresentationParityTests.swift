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
