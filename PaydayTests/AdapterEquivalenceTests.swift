import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// MEASUREMENT: does the store's adapter agree with the bridge's, for the
/// same shifts?
///
/// The screens read money through `LegacySnapshotBridge`, which builds a
/// `ShiftInput` from legacy rows via `ShiftDetails.resolve` + `TipBreakdown`.
/// `EarningsStore` reads through `ShiftInputAdapter.adapt(_:calendars:)`,
/// which builds one straight off a `ShiftRecord`. Two different adapters for
/// one fact.
///
/// #41 proved the BRIDGE treats a `TipEntry` and a `ProjectedShiftRow`
/// identically. It proved nothing about bridge-versus-adapter. If these
/// disagree anywhere, that is a criterion-5 defect in its own right — two
/// adapters, two answers for one shift — and not merely an obstacle to route
/// around, because swapping the bridge for the store would silently change a
/// live user's numbers.
///
/// Iterated in one test rather than `@Test(arguments:)`: the parameterized
/// form repeatedly made the macro expansion fail to produce a diagnostic.
@Suite("Adapter equivalence")
@MainActor
struct AdapterEquivalenceTests {

    private static let zone = TimeZone(identifier: "America/New_York")!

    /// Monday 2026-09-28, so a workweek boundary and a period boundary are
    /// both reachable from it.
    private static func day(_ offset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let base = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        return cal.date(byAdding: .day, value: offset, to: base)!
    }

    /// Two rate policies, so the set includes a shift priced under a CHANGED
    /// rate history rather than a single scalar.
    private static func policies() -> CompensationPolicies {
        CompensationPolicies(
            rates: [
                PayRatePolicy(
                    id: PolicyMigration.deterministicID("adaptereq/rate/old"),
                    effectiveFrom: .distantPast,
                    hourlyRateCents: 283,
                    provenance: .confirmed
                ),
                PayRatePolicy(
                    id: PolicyMigration.deterministicID("adaptereq/rate/new"),
                    effectiveFrom: CivilDay(day(3), in: zone),
                    hourlyRateCents: 1_500,
                    provenance: .confirmed
                ),
            ],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("adaptereq/calendar"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: zone
            )]
        )
    }

    private static func metrics(gratuity: Int?) -> ShiftReceiptMetrics? {
        guard let gratuity else { return nil }
        var m = ShiftReceiptMetrics()
        m.gratuityFeesCents = gratuity
        m.earningsSchemaVersion = 2
        return m
    }

    /// The shape-diverse set. Each case names the hazard it covers.
    private static func shifts() -> [(name: String, record: ShiftRecord)] {
        var out: [(String, ShiftRecord)] = []

        // A zero day: no tips, no hours. The "nothing was worked" vs
        // "nothing is known" distinction.
        out.append(("zero day", ShiftRecord(workDate: day(0))))

        // The 6.3833 precision case, E1's shift: 383 minutes out of a Double.
        out.append(("6.3833 precision", ShiftRecord(
            workDate: day(0), cashTipsCents: 4_000, creditTipsCents: 7_500,
            hoursWorked: 6.383333333333334, recordedAt: day(0)
        )))

        // A deduction: tip-out exceeding the cash tips, so the non-wage
        // component goes negative.
        out.append(("negative after tip-out", ShiftRecord(
            workDate: day(1), cashTipsCents: 1_000, creditTipsCents: 0,
            tipOutCents: 4_000, hoursWorked: 5, recordedAt: day(1)
        )))

        // Two shifts on ONE day, lunch and dinner, so grouping and period
        // ranking both participate.
        out.append(("multi-shift day: lunch", ShiftRecord(
            workDate: day(2), shiftPeriod: .lunch, cashTipsCents: 2_200,
            creditTipsCents: 3_100, tipOutCents: 400, hoursWorked: 4.25,
            recordedAt: day(2)
        )))
        out.append(("multi-shift day: dinner", ShiftRecord(
            workDate: day(2), shiftPeriod: .dinner, cashTipsCents: 5_600,
            creditTipsCents: 9_900, tipOutCents: 0, hoursWorked: 5.5,
            receiptMetrics: metrics(gratuity: 1_250), recordedAt: day(2)
        )))

        // On/after the rate change, so this one is priced by the SECOND rate
        // policy.
        out.append(("under the changed rate", ShiftRecord(
            workDate: day(3), cashTipsCents: 3_000, creditTipsCents: 4_000,
            tipOutCents: 500, hoursWorked: 8, recordedAt: day(3)
        )))

        // A long week, to push the workweek over the overtime threshold so
        // the split participates.
        for i in 4...6 {
            out.append(("overtime filler \(i)", ShiftRecord(
                workDate: day(i), cashTipsCents: 1_500, creditTipsCents: 2_000,
                hoursWorked: 11, recordedAt: day(i)
            )))
        }

        // The next period, so a period boundary is crossed within the set.
        out.append(("across the period boundary", ShiftRecord(
            workDate: day(14), cashTipsCents: 2_500, creditTipsCents: 6_000,
            tipOutCents: 700, hoursWorked: 7.75,
            receiptMetrics: metrics(gratuity: 900), recordedAt: day(14)
        )))

        return out.map { (name: $0.0, record: $0.1) }
    }

    /// Per-shift equivalence, field by field, so a failure names the shift and
    /// the figure rather than reporting one opaque inequality.
    @Test("every shift adapts to the same ShiftInput through both paths")
    func perShiftInputsAgree() throws {
        let cals = Self.policies().calendars
        for (name, record) in Self.shifts() {
            let adapted = ShiftInputAdapter.adapt([record], calendars: cals)
            let firstAdapted = adapted.inputs.first
            let viaAdapter = try #require(firstAdapted, "\(name): adapter produced nothing")

            let projected = ShiftProjection.rows(for: record)
            let bridged = LegacySnapshotBridge.shiftInput(
                for: (day: record.workDate, shiftID: record.id, items: projected),
                payrollTimeZone: Self.zone
            )

            // A zero shift projects to no rows at all, so the bridge yields
            // nil where the adapter yields an input. That is a real
            // difference, recorded rather than smoothed over.
            guard let viaBridge = bridged else {
                Issue.record("\(name): bridge produced nil where the adapter produced an input")
                continue
            }

            #expect(viaAdapter.workDay == viaBridge.workDay, "\(name): workDay")
            #expect(viaAdapter.period == viaBridge.period, "\(name): period")
            #expect(viaAdapter.voluntaryCashCents == viaBridge.voluntaryCashCents, "\(name): cash")
            #expect(viaAdapter.voluntaryCreditCents == viaBridge.voluntaryCreditCents, "\(name): credit")
            #expect(viaAdapter.gratuityFeesCents == viaBridge.gratuityFeesCents, "\(name): gratuity")
            // tipOutCents is asserted separately, below: the two paths
            // genuinely differ for an EXPLICIT zero, and that difference is
            // money-neutral. Pinned rather than hidden.
            if viaAdapter.tipOutCents != 0 || viaBridge.tipOutCents != nil {
                #expect(viaAdapter.tipOutCents == viaBridge.tipOutCents, "\(name): tipOut")
            }
            #expect(viaAdapter.minutesWorked == viaBridge.minutesWorked, "\(name): minutes")
        }
    }

    /// The ONE divergence the measurement found, pinned so it cannot change
    /// in silence.
    ///
    /// For a shift with an EXPLICIT zero tip-out, `ShiftInputAdapter` passes
    /// `0` through (it reads `ShiftRecord.tipOutCents`, an `Int?`, directly)
    /// while `LegacySnapshotBridge` maps it to `nil`
    /// (`breakdown.tipOutCents == 0 ? nil : ...`).
    ///
    /// It is money-neutral — the engine reads `nil` as 0 cents, and
    /// `wholeSnapshotAgrees` confirms every day agrees to the cent — but it is
    /// not nothing: `InputManifest` digests the inputs, so the same shift
    /// yields a different digest through the two paths. That matters for
    /// snapshot-upload acceptance and for the store's skip-if-unchanged check.
    ///
    /// The divergence is INTRINSIC to the two representations, not a bug in
    /// either side, and `theLegacyRepresentationCannotTellZeroFromUnentered`
    /// below proves it.
    ///
    /// `TipBreakdown.tipOutCents` is non-optional and accumulates
    /// `details.tipOutCents ?? 0`, so the nil-versus-zero distinction is
    /// destroyed by the breakdown TYPE before the bridge ever sees it. Given
    /// a breakdown of 0 the bridge cannot know which case it had, and `nil`
    /// -- "unknown" -- is the honest answer. Passing `0` through instead would
    /// assert "entered as zero" on data that cannot support the claim.
    ///
    /// So the adapter is more faithful only because its INPUT carries more:
    /// `ShiftRecord.tipOutCents` is an `Int?` that survives the write. Each
    /// side is correct for the input it has.
    ///
    /// Consequence for the bridge-to-store swap: a shift with an explicit
    /// zero tip-out legitimately digests differently before and after
    /// conversion, because the stored data genuinely gained information. So
    /// nothing may DEPEND on digest equality across the flip -- that is the
    /// thing to check, rather than "fixing" either adapter.
    @Test("an explicit zero tip-out is 0 via the adapter and nil via the bridge")
    func explicitZeroTipOutDivergesAndIsMoneyNeutral() throws {
        let record = ShiftRecord(
            workDate: Self.day(2), shiftPeriod: .dinner,
            cashTipsCents: 5_600, creditTipsCents: 9_900,
            tipOutCents: 0, hoursWorked: 5.5, recordedAt: Self.day(2)
        )
        let cals = Self.policies().calendars

        let adapted = ShiftInputAdapter.adapt([record], calendars: cals)
        let viaAdapter = try #require(adapted.inputs.first)
        let bridged = LegacySnapshotBridge.shiftInput(
            for: (day: record.workDate, shiftID: record.id,
                  items: ShiftProjection.rows(for: record)),
            payrollTimeZone: Self.zone
        )
        let viaBridge = try #require(bridged)

        #expect(viaAdapter.tipOutCents == 0)
        #expect(viaBridge.tipOutCents == nil)

        // Money-neutral, which is the half that lets the swap be safe.
        #expect(viaAdapter.voluntaryCashCents == viaBridge.voluntaryCashCents)
        #expect(viaAdapter.voluntaryCreditCents == viaBridge.voluntaryCreditCents)
        #expect(viaAdapter.gratuityFeesCents == viaBridge.gratuityFeesCents)
        #expect(viaAdapter.minutesWorked == viaBridge.minutesWorked)
    }

    /// Why the divergence above is intrinsic rather than a defect.
    ///
    /// Two shifts, identical except that one had NO tip-out entered and the
    /// other had an explicit zero. Through the adapter they stay distinct.
    /// Through the bridge they become the same `ShiftInput`, because
    /// `TipBreakdown` accumulates `tipOutCents ?? 0` into a non-optional Int
    /// and the difference is gone before the bridge runs.
    ///
    /// This is the test that stopped me "fixing" the bridge to pass `0`
    /// through: that change would have made it claim a fact its input does not
    /// contain.
    @Test("the legacy representation cannot tell an explicit zero from unentered")
    func theLegacyRepresentationCannotTellZeroFromUnentered() throws {
        let cals = Self.policies().calendars
        let unentered = ShiftRecord(
            workDate: Self.day(2), cashTipsCents: 5_600, creditTipsCents: 9_900,
            tipOutCents: nil, hoursWorked: 5.5, recordedAt: Self.day(2)
        )
        let explicitZero = ShiftRecord(
            workDate: Self.day(2), cashTipsCents: 5_600, creditTipsCents: 9_900,
            tipOutCents: 0, hoursWorked: 5.5, recordedAt: Self.day(2)
        )

        // The adapter keeps them apart.
        let aUnentered = try #require(ShiftInputAdapter.adapt([unentered], calendars: cals).inputs.first)
        let aZero = try #require(ShiftInputAdapter.adapt([explicitZero], calendars: cals).inputs.first)
        #expect(aUnentered.tipOutCents == nil)
        #expect(aZero.tipOutCents == 0)
        #expect(aUnentered.tipOutCents != aZero.tipOutCents)

        // The bridge cannot, and that is the representation's limit, not the
        // bridge's mistake.
        let bUneneteredRaw = LegacySnapshotBridge.shiftInput(
            for: (day: unentered.workDate, shiftID: unentered.id,
                  items: ShiftProjection.rows(for: unentered)),
            payrollTimeZone: Self.zone
        )
        let bZeroRaw = LegacySnapshotBridge.shiftInput(
            for: (day: explicitZero.workDate, shiftID: explicitZero.id,
                  items: ShiftProjection.rows(for: explicitZero)),
            payrollTimeZone: Self.zone
        )
        let bUnentered = try #require(bUneneteredRaw)
        let bZero = try #require(bZeroRaw)
        #expect(bUnentered.tipOutCents == nil)
        #expect(bZero.tipOutCents == nil)
        #expect(bUnentered.tipOutCents == bZero.tipOutCents)

        // Money is the same either way, which is why this is safe rather than
        // merely tolerable.
        #expect(aUnentered.voluntaryCashCents == bUnentered.voluntaryCashCents)
        #expect(aZero.voluntaryCashCents == bZero.voluntaryCashCents)
    }

    /// And the whole snapshot, to the cent and the minute, because per-shift
    /// agreement is not the claim that matters — the claim is that a screen
    /// reading the store sees the same money as a screen reading the bridge.
    @Test("the whole dataset values identically through both paths")
    func wholeSnapshotAgrees() throws {
        let policies = Self.policies()
        let records = Self.shifts().map(\.record)

        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        let storeSnapshot = try EarningsSnapshot.build(EarningsInputs(
            shifts: adapted.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            asOf: CivilDay(Self.day(30), in: Self.zone)
        ))

        let groups = records.map { r in
            (day: r.workDate, shiftID: r.id, items: ShiftProjection.rows(for: r))
        }
        let bridgeSnapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups,
            policies: policies,
            payrollTimeZone: Self.zone,
            asOf: Self.day(30)
        ))

        #expect(storeSnapshot.shifts.count == bridgeSnapshot.shifts.count, "shift count")

        // Day by day across the whole span, so a divergence is localized.
        for offset in 0...15 {
            let civil = CivilDay(Self.day(offset), in: Self.zone)
            let a = storeSnapshot.day(civil)
            let b = bridgeSnapshot.day(civil)
            #expect(a.knownComponents.earnedIncomeCents == b.knownComponents.earnedIncomeCents,
                    "day \(civil.iso): earnedIncome")
            #expect(a.knownComponents.nonWageEarningsCents == b.knownComponents.nonWageEarningsCents,
                    "day \(civil.iso): nonWage")
            #expect(a.knownComponents.regularWagesCents == b.knownComponents.regularWagesCents,
                    "day \(civil.iso): regularWages")
            #expect(a.knownComponents.overtimeWagesCents == b.knownComponents.overtimeWagesCents,
                    "day \(civil.iso): overtimeWages")
            #expect(a.minutes == b.minutes, "day \(civil.iso): minutes")
        }

        // Non-trivial, so the equalities above are not a comparison of
        // empty snapshots.
        let anyDay = storeSnapshot.day(CivilDay(Self.day(2), in: Self.zone))
        #expect(anyDay.knownComponents.earnedIncomeCents > 0)
        #expect(anyDay.minutes > 0)
    }
}
