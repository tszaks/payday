import Foundation
import Testing
@testable import Payday

/// PR 2 slice S9: a shift rendered as the legacy rows every existing reader
/// expects, and the proof that both sides agree to the cent.
///
/// The projection rule is small and was stated incompatibly twice in an
/// earlier draft, in a way that cost real money either way it was resolved.
/// Almost every test here pins one half of that.
@Suite("Shift projection")
struct ShiftProjectionTests {

    private static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PaydayTestZone.payroll
        return calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: 17))!
    }

    // MARK: - Rule 1: one row per non-zero kind

    @Test("a two-kind shift projects credit first, then cash")
    func twoKindsProjectCreditFirst() {
        let shift = ShiftRecord(
            workDate: Self.day(2026, 9, 1),
            cashTipsCents: 5_000,
            creditTipsCents: 2_000
        )

        let rows = ShiftProjection.rows(for: shift)

        #expect(rows.count == 2)
        // Credit first, matching the detail rank and the order the legacy
        // writer produced, so any reader taking `first` sees the same row.
        #expect(rows[0].kind == .credit)
        #expect(rows[0].amountCents == 2_000)
        #expect(rows[1].kind == .cash)
        #expect(rows[1].amountCents == 5_000)
    }

    /// The commonest shape there is: a server who tips the bar out in cash.
    ///
    /// This is the case naive zero-suppression got wrong. Suppress the credit
    /// row and put the shift-level fields on it anyway, and the cash row
    /// carries nothing: the tip-out resolves to 0 and a shift worth 4,000
    /// reports 5,000, with the gratuity and the hours vanishing the same way.
    @Test("a cash-only shift carries every shift-level field on its cash row")
    func cashOnlyShiftCarriesTheDetails() throws {
        let shift = ShiftRecord(
            workDate: Self.day(2026, 9, 2),
            shiftPeriod: .dinner,
            cashTipsCents: 5_000,
            creditTipsCents: 0,
            tipOutCents: 1_000,
            salesCents: 42_000,
            hoursWorked: 6.5,
            serverCount: 4,
            receiptMetrics: ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 1_200),
            note: "busy"
        )

        let rows = ShiftProjection.rows(for: shift)

        #expect(rows.count == 1, "no phantom $0 credit row")
        let row = try #require(rows.first)
        #expect(row.kind == .cash)
        #expect(row.amountCents == 5_000)
        #expect(row.tipOutCents == 1_000)
        #expect(row.salesCents == 42_000)
        #expect(row.hoursWorked == 6.5)
        #expect(row.serverCount == 4)
        #expect(row.shiftPeriod == .dinner)
        #expect(row.receiptMetrics?.gratuityFeesCents == 1_200)
        // 5000 voluntary + 1200 gratuity - 1000 tip-out.
        #expect(row.netCents == 5_200)
    }

    /// A wage-only or gratuity-only shift is real, and the whole reason rule 1
    /// has a tail: the hours must still reach every reader.
    @Test("a shift with no tips at all still projects one row with its hours")
    func wageOnlyShiftStillProjects() throws {
        let shift = ShiftRecord(
            workDate: Self.day(2026, 9, 3),
            cashTipsCents: 0,
            creditTipsCents: 0,
            hoursWorked: 5
        )

        let rows = ShiftProjection.rows(for: shift)

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.kind == .credit)
        #expect(row.amountCents == 0)
        #expect(row.hoursWorked == 5, "the hours are the only thing this shift has")
    }

    // MARK: - Rule 2: the detail rank

    @Test("the credit row owns the shift-level fields when both kinds exist")
    func creditOwnsTheDetails() throws {
        let shift = ShiftRecord(
            workDate: Self.day(2026, 9, 4),
            cashTipsCents: 5_000,
            creditTipsCents: 2_000,
            tipOutCents: 1_000,
            hoursWorked: 6
        )

        let rows = ShiftProjection.rows(for: shift)
        let credit = try #require(rows.first { $0.kind == .credit })
        let cash = try #require(rows.first { $0.kind == .cash })

        #expect(credit.tipOutCents == 1_000)
        #expect(credit.hoursWorked == 6)
        // Nil on the other row, or summing across the shift double-counts.
        #expect(cash.tipOutCents == nil)
        #expect(cash.hoursWorked == nil)
    }

    // MARK: - Rule 3: the note goes on every row

    /// Keeps the exported CSV note field byte-identical with the legacy side:
    /// a two-kind shift gives "N; N" because the legacy writer passed the note
    /// to both initializers. Put it on one row and the string diverges.
    @Test("the note and recordedAt appear on every emitted row")
    func noteIsOnEveryRow() {
        let recorded = Self.day(2026, 9, 5)
        let shift = ShiftRecord(
            workDate: Self.day(2026, 9, 5),
            cashTipsCents: 5_000,
            creditTipsCents: 2_000,
            note: "N",
            recordedAt: recorded
        )

        let rows = ShiftProjection.rows(for: shift)

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.note == "N" })
        #expect(rows.allSatisfy { $0.recordedAt == recorded })
        #expect(rows.compactMap(\.note).joined(separator: "; ") == "N; N")
    }

    // MARK: - Identity

    /// Identity-keyed SwiftUI views diff on these, so a fresh UUID per rebuild
    /// would make every list look wholesale replaced and thrash the screen.
    @Test("projected ids are stable across rebuilds and distinct per kind")
    func idsAreStableAndDistinct() {
        let shift = ShiftRecord(
            workDate: Self.day(2026, 9, 6),
            cashTipsCents: 5_000,
            creditTipsCents: 2_000
        )

        let first = ShiftProjection.rows(for: shift).map(\.id)
        let second = ShiftProjection.rows(for: shift).map(\.id)

        #expect(first == second)
        #expect(Set(first).count == 2, "cash and credit must not collide")
    }

    /// A projected id must never be mistaken for a real record's id, or a
    /// reader keyed on ids could match a projection against a stored row.
    @Test("a projected id is never the shift's own id")
    func projectedIDIsNamespaced() {
        let shift = ShiftRecord(workDate: Self.day(2026, 9, 7), cashTipsCents: 100)
        let rows = ShiftProjection.rows(for: shift)
        #expect(!rows.map(\.id).contains(shift.id))
        // Every projected row still points BACK at its shift, which is how a
        // reader groups them.
        #expect(rows.allSatisfy { $0.shiftID == shift.id })
    }

    @Test("two different shifts never project the same row id")
    func differentShiftsDoNotCollide() {
        let a = ShiftRecord(workDate: Self.day(2026, 9, 8), cashTipsCents: 100)
        let b = ShiftRecord(workDate: Self.day(2026, 9, 8), cashTipsCents: 100)
        let ids = Set(ShiftProjection.rows(for: a).map(\.id))
            .union(ShiftProjection.rows(for: b).map(\.id))
        #expect(ids.count == 2)
    }

    // MARK: - Zero delta against the legacy path

    /// The arithmetic proof, which is also the calendar fix.
    ///
    /// For cash C, credit R, v2 gratuity G and tip-out T, `TipBreakdown.total`
    /// gives `C + R + G - T`, and the row-by-row `netCents` path the calendar
    /// uses gives `(R + G - T) + C`. Equal, and no longer double-subtracting
    /// the tip-out, which is what the old two-row storage did when a receipt
    /// payload was duplicated onto both rows.
    @Test("the projection and the legacy rows agree to the cent")
    func projectionIsZeroDeltaAgainstLegacyRows() {
        let workDay = Self.day(2026, 9, 9)
        let cash = 5_000, credit = 2_000, gratuity = 1_200, tipOut = 1_000
        let metrics = ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: gratuity)

        let shift = ShiftRecord(
            workDate: workDay,
            shiftPeriod: .dinner,
            cashTipsCents: cash,
            creditTipsCents: credit,
            tipOutCents: tipOut,
            hoursWorked: 6.5,
            receiptMetrics: metrics,
            note: "N"
        )
        let projected = ShiftProjection.rows(for: shift)

        // The same shift as the legacy two-row pair the writer would have
        // produced: shift-level facts on the credit row only.
        let shiftID = UUID()
        let legacy: [TipEntry] = [
            TipEntry(date: workDay, amountCents: credit, kind: .credit, note: "N",
                     hoursWorked: 6.5, tipOutCents: tipOut, shiftPeriod: .dinner,
                     shiftID: shiftID, receiptMetrics: metrics),
            TipEntry(date: workDay, amountCents: cash, kind: .cash, note: "N",
                     shiftID: shiftID)
        ]

        // 1. The breakdown, through the real generic function.
        let projectedTotal = TipBreakdown.total(of: projected)
        let legacyTotal = TipBreakdown.total(of: legacy)
        #expect(projectedTotal == legacyTotal)

        // 2. The row-by-row path the calendar uses, which must agree with it.
        let projectedNet = projected.reduce(0) { $0 + $1.netCents }
        let legacyNet = legacy.reduce(0) { $0 + $1.netCents }
        #expect(projectedNet == legacyNet)
        #expect(projectedNet == cash + credit + gratuity - tipOut)

        // 3. And the resolver sees the same shift-level facts either way.
        let projectedDetails = ShiftDetails.resolve(from: projected)
        let legacyDetails = ShiftDetails.resolve(from: legacy)
        #expect(projectedDetails.tipOutCents == legacyDetails.tipOutCents)
        #expect(projectedDetails.hoursWorked == legacyDetails.hoursWorked)
        #expect(projectedDetails.shiftPeriod == legacyDetails.shiftPeriod)
        #expect(projectedDetails.receiptMetrics?.gratuityFeesCents
            == legacyDetails.receiptMetrics?.gratuityFeesCents)
    }

    /// The cash-only variant of the same proof, which is the shape the naive
    /// suppression rule broke.
    @Test("a cash-only shift is zero delta against its single legacy row")
    func cashOnlyIsZeroDelta() {
        let workDay = Self.day(2026, 9, 10)
        let metrics = ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 1_200)

        let shift = ShiftRecord(
            workDate: workDay,
            cashTipsCents: 5_000,
            creditTipsCents: 0,
            tipOutCents: 1_000,
            receiptMetrics: metrics,
            note: "N"
        )
        let legacy: [TipEntry] = [
            TipEntry(date: workDay, amountCents: 5_000, kind: .cash, note: "N",
                     tipOutCents: 1_000, shiftID: UUID(), receiptMetrics: metrics)
        ]

        let projected = ShiftProjection.rows(for: shift)
        #expect(TipBreakdown.total(of: projected) == TipBreakdown.total(of: legacy))
        // Split out rather than inlined: the compiler cannot type-check the
        // combined reduce-and-compare expression in reasonable time.
        let projectedNet = projected.reduce(0) { $0 + $1.netCents }
        let legacyNet = legacy.reduce(0) { $0 + $1.netCents }
        #expect(projectedNet == legacyNet)
        let projectedNotes: [String] = projected.compactMap(\.note)
        let legacyNotes: [String] = legacy.compactMap(\.note)
        #expect(projectedNotes.joined(separator: "; ") == legacyNotes.joined(separator: "; "))
    }

    @Test("projecting several shifts preserves each one's rows")
    func manyShiftsProject() {
        let shifts = [
            ShiftRecord(workDate: Self.day(2026, 9, 11), cashTipsCents: 100, creditTipsCents: 200),
            ShiftRecord(workDate: Self.day(2026, 9, 12), cashTipsCents: 300),
            ShiftRecord(workDate: Self.day(2026, 9, 13), hoursWorked: 4)
        ]

        let rows = ShiftProjection.rows(for: shifts)

        #expect(rows.count == 4)
        #expect(Set(rows.map(\.id)).count == 4)
        #expect(Set(rows.compactMap(\.shiftID)).count == 3)
    }
}
