import Foundation
import Testing
@testable import Payday

/// **One fact, five definitions.** `nonWageEarnings` -- what a shift earned
/// before wages -- is written out independently in `EarningsComponents`
/// (PaydayCore), `ShiftRecord`, `TipBreakdown`, `LegacyShiftRow` and
/// `StatsEngine`. They agree on ordinary data, which is exactly what makes
/// them dangerous: a divergence would surface only on data nobody tested.
///
/// The suspicion this suite was written to settle is concrete. A receipt
/// payload with `earningsSchemaVersion` ABSENT is live in production, and
/// the absent key does not read the same everywhere:
///
///   ShiftRecord.swift:213          `(earningsSchemaVersion ?? 2) >= 2`
///   ShiftReceiptMetrics.swift:121  `(earningsSchemaVersion ?? 1) < 2`
///
/// One says v2, the other says v1. `StatsEngine` sums NORMALIZED
/// `voluntaryTipCents` (`:278`) while `ShiftRecord` sums RAW fields
/// (`:295`), so if the version is read differently the two disagree by
/// exactly the gratuity.
@Suite("nonWageEarnings agreement")
@MainActor
struct NonWageEarningsAgreementTests {

    private func record(
        version: Int?,
        cash: Int,
        credit: Int,
        gratuity: Int,
        tipOut: Int?
    ) -> ShiftRecord {
        var metrics = ShiftReceiptMetrics()
        metrics.earningsSchemaVersion = version
        metrics.gratuityFeesCents = gratuity
        return ShiftRecord(
            workDate: Date(timeIntervalSince1970: 1_758_000_000),
            cashTipsCents: cash,
            creditTipsCents: credit,
            tipOutCents: tipOut,
            hoursWorked: 5,
            receiptMetrics: metrics
        )
    }

    /// The StatsEngine-path answer for one shift, reached the way the app
    /// reaches it: through the real adapter, not by re-deriving the formula.
    private func statsPathCents(_ r: ShiftRecord) -> Int {
        let rows = StatsRecordAdapter.tipRecords(from: [r])
        return rows.reduce(0) { $0 + $1.voluntaryTipCents }
            + (r.receiptMetrics?.employeeGratuityFeesCents ?? 0)
            - (r.tipOutCents ?? 0)
    }

    @Test("every generation of receipt agrees across both definitions", arguments: [
        (Int?.some(2), 1_000, 2_000, 300, Int?.some(150)),
        (Int?.some(2), 1_000, 2_000, 0,   Int?.none),
        (Int?.none,    1_000, 2_000, 300, Int?.some(150)),   // the live shape
        (Int?.none,    1_000, 2_000, 0,   Int?.none),
        (Int?.some(1), 1_000, 2_000, 300, Int?.none),
        (Int?.none,      100,     0, 900, Int?.none),        // gratuity > tips
    ])
    func definitionsAgree(
        version: Int?, cash: Int, credit: Int, gratuity: Int, tipOut: Int?
    ) {
        let r = record(version: version, cash: cash, credit: credit,
                       gratuity: gratuity, tipOut: tipOut)
        let model = r.nonWageEarningsCents
        let stats = statsPathCents(r)
        #expect(model == stats, """
            nonWageEarnings disagrees for version=\(String(describing: version)) \
            cash=\(cash) credit=\(credit) gratuity=\(gratuity) \
            tipOut=\(String(describing: tipOut)):
              ShiftRecord.nonWageEarningsCents = \(model)
              StatsEngine path                 = \(stats)
              difference                       = \(model - stats)
            """)
    }
}
