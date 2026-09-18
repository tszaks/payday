import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// Criterion 5 on the RECORDS arm, which was gated by one test while the
/// legacy arm was gated by five suites.
///
/// ## The measurement that produced this file
///
/// Criterion 5 says parity holds on real screen adapters. Counting suites
/// does not establish that — a suite can exist and gate nothing — so the
/// question was asked with a mutation instead: make `DashboardEarnings`
/// clamp its DATASET to today while `HistoryEarnings` does not, which is
/// exactly the cross-surface divergence criterion 5 forbids.
///
/// Run twice, once against each arm of the builder:
///
/// | Mutation | Suites catching | Failing tests |
/// |---|---|---|
/// | **legacy** arm clamps | 5 | 32 |
/// | **records** arm clamps | 1 | 3 |
///
/// The legacy arm is deeply gated: `DashboardPeriodParityTests`
/// ("Dashboard period income equals the History row and period detail" —
/// criterion 5's first clause verbatim), the payday card, final-day
/// membership, and the cutoff suite all fail. The records arm was caught
/// only by `FlipGates5And7Tests.gate5FourConsumersAgree`, written the same
/// day.
///
/// **That asymmetry is backwards relative to risk.** The legacy arm is what
/// every account uses today and is scheduled for deletion in PR 8. The
/// records arm is what every account uses after conversion — and since S15
/// the flip is reachable, so the thinly gated arm is the one whose defects
/// would reach a person.
///
/// ## Why this is a new file rather than a parameterisation
///
/// The obvious move is to run the existing 22 Dashboard parity tests through
/// both arms. It is not available: those fixtures are hand-built `[TipEntry]`
/// values, and turning a legacy pair into a `ShiftRecord` is the SERVER's
/// deriver (`private.derive_shifts`), which has no Swift equivalent on
/// device. Projecting records INTO entries exists, but building the fixtures
/// that way would make every case mirror-derived — and a test built by
/// mirroring cannot catch a defect in the mirror.
///
/// So these construct records directly and assert the same CLAIMS, not the
/// same code. What is covered here is the gap the mutation exposed, not a
/// duplicate of the legacy suite.
@Suite("Dashboard parity on the records arm", .serialized)
@MainActor
struct DashboardRecordsArmParityTests {

    private static let zone = PaydayTestZone.payroll

    private static func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func policies(rateCents: Int) -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("recordsarm/rate"),
                effectiveFrom: .distantPast, hourlyRateCents: rateCents, provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("recordsarm/calendar"),
                effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone
            )]
        )
    }

    /// Two shifts in one biweekly period, one before "now" and one after, so
    /// a to-date cutoff is observably different from the period total. That
    /// gap is what makes the cutoff claim testable at all.
    private static func records() -> [ShiftRecord] {
        [
            ShiftRecord(workDate: at(2026, 10, 5), shiftPeriod: .dinner,
                        cashTipsCents: 0, creditTipsCents: 30_000, tipOutCents: 4_000,
                        hoursWorked: 8, recordedAt: at(2026, 10, 5)),
            ShiftRecord(workDate: at(2026, 10, 9), shiftPeriod: .dinner,
                        cashTipsCents: 0, creditTipsCents: 25_000,
                        hoursWorked: 8, recordedAt: at(2026, 10, 9)),
        ]
    }

    private static func currentRange() -> DayRange {
        DayRange(
            start: CivilDay(at(2026, 9, 28, hour: 0), in: zone),
            end: CivilDay(at(2026, 10, 11, hour: 0), in: zone)
        )
    }

    /// **The cutoff is a QUERY argument, not a second dataset.**
    ///
    /// This is the claim the mutation broke and that only one test caught on
    /// this arm. If the dataset itself were clamped, the two questions below
    /// could not disagree — and their disagreement is the whole point of a
    /// to-date hero sitting on a whole-period screen.
    @Test("one records dataset answers both the to-date and the whole-period question")
    func oneRecordsDatasetTwoScopes() throws {
        let comp = Self.policies(rateCents: 1_800)
        let snapshot = try #require(DashboardEarnings.build(
            records: Self.records(), policies: comp, payrollTimeZone: Self.zone
        ).snapshot)

        let range = Self.currentRange()
        let whole = snapshot.range(range)
        let toDate = snapshot.range(range, asOf: CivilDay(Self.at(2026, 10, 7, hour: 12), in: Self.zone))

        // The dataset is UNCLAMPED: the whole-period answer includes the
        // October 9 shift, which is after the cutoff.
        #expect(whole.knownComponents.earnedIncomeCents
                > toDate.knownComponents.earnedIncomeCents,
                "if these are equal the dataset was clamped, not the query")
        #expect(toDate.knownComponents.earnedIncomeCents > 0,
                "and the to-date answer is not simply empty")
    }

    /// **Criterion 5's first clause on this arm:** Dashboard == the History
    /// row == period detail, all three from records.
    ///
    /// Asserted through the builders the screens actually call, so a
    /// divergence in either builder's dataset shows up here rather than in
    /// a restatement of their arithmetic.
    @Test("Dashboard, the History row and period detail agree on one records period")
    func threeSurfacesAgreeOnRecords() throws {
        let comp = Self.policies(rateCents: 1_800)
        let records = Self.records()
        let range = Self.currentRange()

        let dashboard = try #require(DashboardEarnings.build(
            records: records, policies: comp, payrollTimeZone: Self.zone
        ).snapshot)
        let history = try #require(HistoryEarnings.build(
            entries: [], records: records, policies: comp,
            payrollTimeZone: Self.zone, representation: .records
        ).snapshot)

        let fromDashboard = dashboard.range(range).knownComponents.earnedIncomeCents
        let fromHistory = history.range(range).knownComponents.earnedIncomeCents

        #expect(fromDashboard == fromHistory)
        // Non-zero, so this is not two empty snapshots agreeing — the way a
        // parity assertion passes for the wrong reason.
        #expect(fromDashboard > 0)
        // One dataset, provably: the stamps match, so the two surfaces are
        // not merely arriving at the same total from different inputs.
        #expect(dashboard.stamp.digest == history.stamp.digest)
    }

    /// A shift on the FINAL day of the period is inside the engine's range.
    ///
    /// The legacy arm has `DashboardFinalDayMembershipTests` for this, and it
    /// failed under the mutation. The records arm had nothing. It is the
    /// original audit's own measured defect — "a 5pm shift on the period's
    /// last day was in the row's total and absent from the detail's" — so it
    /// is worth pinning on the arm that will carry it.
    @Test("a shift at 5pm on the period's final day is inside the records range")
    func finalDayShiftIsInRange() throws {
        let comp = Self.policies(rateCents: 1_800)
        // 17:00 on the period's last day. `PayPeriod.end` is that day's
        // midnight, which is what used to exclude it.
        let finalDay = Self.at(2026, 10, 11, hour: 17)
        let records = [ShiftRecord(
            workDate: finalDay, shiftPeriod: .dinner,
            cashTipsCents: 0, creditTipsCents: 12_000, hoursWorked: 6,
            recordedAt: finalDay
        )]

        let snapshot = try #require(DashboardEarnings.build(
            records: records, policies: comp, payrollTimeZone: Self.zone
        ).snapshot)
        let result = snapshot.range(Self.currentRange())

        #expect(result.knownComponents.earnedIncomeCents > 0,
                "the final day's shift must be inside the period, not after it")
        #expect(result.shiftIDs.contains(records[0].id),
                "and it must be THIS shift, not a total that happens to be non-zero")
    }
}
