import Testing
import Foundation
@testable import Payday

/// The Swift half of fixture P7.
///
/// `supabase/tests/shift_deriver_test.sql` pins the SAME four rows and the
/// SAME five numbers as literals on the server side. Neither file re-derives
/// anything and neither imports the other's answer: if the ranking in
/// `ShiftDetails` and the ranking in `private.derive_shifts` ever stop
/// agreeing, BOTH suites fail. That is the point of pinning it twice.
///
/// Why this shape and not one cash row plus one credit row: for a group of
/// exactly one row per kind, "credit ?? cash" and "first non-nil in rank
/// order" are the same answer, so every fixture that existed before P7
/// (N1, N3, N4, N5, L1, L2, P6) passed under BOTH rules and none of them
/// could see the defect. A group holding two rows of one kind is reachable
/// with no data corruption at all — see the header of `ShiftDetails` for the
/// two live paths that produce one — and on such a group the old rule
/// returned a different split for each array order, with the server agreeing
/// with neither.
@Suite("Shift group ranking parity (fixture P7)")
struct ShiftGroupRankingParityTests {
    // The same UUID literals as fixture P7 in the SQL suite, because the
    // ranking's last tie-break IS the id and a test that minted random ids
    // would only be testing the ranking sometimes.
    private static let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
    private static let cashAID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
    private static let creditBID = UUID(uuidString: "00000000-0000-0000-0000-000000000903")!
    private static let cashCID = UUID(uuidString: "00000000-0000-0000-0000-000000000904")!
    private static let creditDID = UUID(uuidString: "00000000-0000-0000-0000-000000000905")!

    private static let workDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
    }()

    /// Fixture P7, in id order: one shift_id, four live rows, the tip-out on
    /// the FIRST credit row and a v1 receipt (no `earningsSchemaVersion`,
    /// which is live production data) on the SECOND one.
    private func fixtureP7() -> [TipEntry] {
        [
            TipEntry(id: Self.cashAID, date: Self.workDate, amountCents: 5000, kind: .cash,
                     shiftID: Self.groupID),
            TipEntry(id: Self.creditBID, date: Self.workDate, amountCents: 2000, kind: .credit,
                     tipOutCents: 1000, shiftID: Self.groupID),
            TipEntry(id: Self.cashCID, date: Self.workDate, amountCents: 1000, kind: .cash,
                     shiftID: Self.groupID),
            TipEntry(id: Self.creditDID, date: Self.workDate, amountCents: 3000, kind: .credit,
                     shiftID: Self.groupID,
                     receiptMetrics: ShiftReceiptMetrics(gratuityFeesCents: 4200))
        ]
    }


    /// The fold `private.derive_shifts` performs server-side, restated over
    /// the live Swift primitives: `ShiftDetails` for the ranking and
    /// `ShiftReceiptMetrics.voluntaryTipsCents` for the owner's normalization.
    /// `TipBreakdown.total(of:)` was the production spelling until the legacy
    /// read arm was deleted; the contract it pinned is still the server's,
    /// and the SQL suite still fails if the ranking or the normalization here
    /// drifts from `derive_shifts`.
    private func fold(_ rows: [TipEntry]) -> (cash: Int, credit: Int, gratuity: Int, tipOut: Int, net: Int) {
        var cash = 0, credit = 0, gratuity = 0, tipOut = 0
        for shift in ShiftDays.groupedByShift(
            rows, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod
        ) {
            let details = ShiftDetails.resolve(from: shift.items)
            let owner = ShiftDetails.metricsOwner(of: shift.items)
            for row in shift.items {
                // Only the canonical owner's payload normalizes; a payload on
                // any other row must not subtract gratuity twice.
                let metrics = row.id == owner?.id ? details.receiptMetrics : nil
                let voluntary = metrics?.voluntaryTipsCents(fromStoredAmount: row.amountCents)
                    ?? row.amountCents
                switch row.kind {
                case .cash: cash += voluntary
                case .credit: credit += voluntary
                }
            }
            tipOut += details.tipOutCents ?? 0
            gratuity += details.receiptMetrics?.employeeGratuityFeesCents ?? 0
        }
        let net = EarningsComponents(
            voluntaryCashCents: cash,
            voluntaryCreditCents: credit,
            gratuityFeesCents: gratuity,
            tipOutCents: tipOut
        ).nonWageEarningsCents
        return (cash, credit, gratuity, tipOut, net)
    }

    /// Every ordering of a fixed array, so "order-independent" is measured
    /// over all of them rather than asserted about two.
    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var result: [[T]] = []
        for (index, item) in items.enumerated() {
            var rest = items
            rest.remove(at: index)
            for tail in permutations(rest) { result.append([item] + tail) }
        }
        return result
    }

    @Test("P7: the fold's split is 6000 / 2000 / 4200 / 1000 / 11200")
    func p7MatchesTheDeriver() {
        let fold = fold(fixtureP7())
        // MEASURED on Postgres 17.11, all 17 migrations applied from clean,
        // private.derive_shifts called directly on these four rows:
        //   cash 6000  credit 2000  gratuity 4200  tip_out 1000  non_wage 11200
        #expect(fold.cash == 6000)
        #expect(fold.credit == 2000)
        #expect(fold.gratuity == 4200)
        #expect(fold.tipOut == 1000)
        #expect(fold.net == 11200)
    }

    @Test("P7: the two array-order answers the old rule produced are both excluded")
    func p7ExcludesBothOldAnswers() {
        let fold = fold(fixtureP7())
        // id order used to give 6000 / 5000 / 0 / 1000 / 10000 — $12.00 short
        // of the fold and $30.00 off on the credit split, because the receipt
        // on the second credit row was invisible.
        #expect(!(fold.credit == 5000 && fold.gratuity == 0))
        #expect(fold.net != 10000)
        // Receipt-row-first used to give 6000 / 2000 / 4200 / 0 / 12200 —
        // $10.00 over, because the tip-out on the non-first credit row was
        // then the invisible one.
        #expect(fold.tipOut != 0)
        #expect(fold.net != 12200)
    }

    @Test("P7: all 24 orderings of the same four rows give one answer")
    func p7IsOrderIndependent() {
        for ordering in permutations(fixtureP7()) {
            let fold = fold(ordering)
            let ids = ordering.map { String($0.id.uuidString.suffix(3)) }.joined(separator: ",")
            #expect(fold.cash == 6000, "order \(ids)")
            #expect(fold.credit == 2000, "order \(ids)")
            #expect(fold.gratuity == 4200, "order \(ids)")
            #expect(fold.tipOut == 1000, "order \(ids)")
            #expect(fold.net == 11200, "order \(ids)")
        }
    }

    @Test("P7: resolve reads the tip-out off the first credit row by rank, in any order")
    func p7ResolveIsOrderIndependent() {
        for ordering in permutations(fixtureP7()) {
            let resolved = ShiftDetails.resolve(from: ordering)
            #expect(resolved.tipOutCents == 1000)
            #expect(resolved.receiptMetrics?.gratuityFeesCents == 4200)
            #expect(ShiftDetails.metricsOwner(of: ordering)?.id == Self.creditDID)
        }
    }

    @Test("a value on a group's SECOND credit row is not invisible")
    func secondCreditRowIsVisible() {
        // The first credit row by id holds nothing; the rule is "first
        // NON-NIL in rank order", not "the rank-1 row's value", so hours and
        // sales resolve off the second credit row rather than falling through
        // to cash — which is what `credit ?? cash` did.
        let entries = [
            TipEntry(id: Self.cashAID, date: Self.workDate, amountCents: 5000, kind: .cash,
                     hoursWorked: 9.5, salesCents: 10000, shiftID: Self.groupID),
            TipEntry(id: Self.creditBID, date: Self.workDate, amountCents: 2000, kind: .credit,
                     shiftID: Self.groupID),
            TipEntry(id: Self.creditDID, date: Self.workDate, amountCents: 3000, kind: .credit,
                     hoursWorked: 5.0, salesCents: 120_000, shiftPeriod: .dinner,
                     shiftID: Self.groupID)
        ]
        let resolved = ShiftDetails.resolve(from: entries)
        #expect(resolved.hoursWorked == 5.0)
        #expect(resolved.salesCents == 120_000)
        #expect(resolved.shiftPeriod == .dinner)
        // Never summed: 14.5 hours and $130,000 of sales are both wrong.
        #expect(resolved.hoursWorked != 14.5)
        #expect(resolved.salesCents != 130_000)
    }

    @Test("a receipt on a cash row outranks a credit row with none")
    func objectFirstBeatsCreditFirst() {
        // Fixture N5's shape, stated on this side of the wall: the server
        // ranks a row carrying a payload above a credit row carrying none,
        // so the gratuity is subtracted from the CASH row it belongs to.
        // 800 / 2000 / 4200 / 7000 is what the SQL suite pins for N5.
        let entries = [
            TipEntry(id: Self.cashAID, date: Self.workDate, amountCents: 5000, kind: .cash,
                     shiftID: Self.groupID,
                     receiptMetrics: ShiftReceiptMetrics(gratuityFeesCents: 4200)),
            TipEntry(id: Self.creditBID, date: Self.workDate, amountCents: 2000, kind: .credit,
                     shiftID: Self.groupID)
        ]
        #expect(ShiftDetails.metricsOwner(of: entries)?.id == Self.cashAID)
        let fold = fold(entries)
        #expect(fold.cash == 800)
        #expect(fold.credit == 2000)
        #expect(fold.gratuity == 4200)
        #expect(fold.net == 7000)
    }

    @Test("two payloads in one group tie on object-ness and credit wins, subtracting once")
    func duplicatedPayloadSubtractsOnce() {
        // Fixture L2: both rows carry a payload, so object-ness ties and the
        // credit row owns it. 5000 / 0 / 4200 / 9200 is the SQL suite's L2.
        let entries = [
            TipEntry(id: Self.cashAID, date: Self.workDate, amountCents: 5000, kind: .cash,
                     shiftID: Self.groupID,
                     receiptMetrics: ShiftReceiptMetrics(guestCount: 7, gratuityFeesCents: 1000)),
            TipEntry(id: Self.creditBID, date: Self.workDate, amountCents: 3000, kind: .credit,
                     shiftID: Self.groupID,
                     receiptMetrics: ShiftReceiptMetrics(guestCount: 42, gratuityFeesCents: 4200))
        ]
        #expect(ShiftDetails.metricsOwner(of: entries)?.id == Self.creditBID)
        let fold = fold(entries)
        #expect(fold.cash == 5000)
        #expect(fold.credit == 0)
        #expect(fold.gratuity == 4200)
        #expect(fold.net == 9200)
    }

    @Test("write puts the shift's values on detail rank 1, whatever the array order")
    func writeTargetsDetailRankOne() {
        // Fresh entries per ordering: `write` mutates, and reusing one set of
        // reference-type rows across 24 orderings would only test the first.
        for ordering in permutations([0, 1, 2, 3]) {
            let fixture = fixtureP7()
            let rows = ordering.map { fixture[$0] }
            ShiftDetails.write(hoursWorked: 6, tipOutCents: 2500, salesCents: 90_000,
                               shiftPeriod: .dinner, into: rows)
            let primary = rows.first { $0.id == Self.creditBID }
            #expect(primary?.hoursWorked == 6)
            #expect(primary?.tipOutCents == 2500)
            for row in rows where row.id != Self.creditBID {
                #expect(row.hoursWorked == nil)
                #expect(row.tipOutCents == nil)
            }
            // And the write is readable through resolve, in any order.
            #expect(ShiftDetails.resolve(from: rows).tipOutCents == 2500)
        }
    }
}
