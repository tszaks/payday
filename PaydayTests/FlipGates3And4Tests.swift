import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// Gates 3 and 4, re-examined against the nine call sites the sweep switched.
///
/// ## Why these two, and why now rather than after the sync leg
///
/// Both gates landed in earlier pieces, before the sweep found nine unswitched
/// readers, and I had not looked at either since. The sequencing is deliberate:
/// S14 merges as a genuine no-op because `applyShiftAuthority` has no caller,
/// so a stale gate here is a LATENT gap. The sync leg is the slice that adds
/// the caller, and the moment it lands an account can actually flip, which
/// converts every stale gate into live exposure. Verify while the flip is
/// still unreachable and cheap to be wrong about, then make it reachable.
///
/// ## Gate 3: a day with a total drops no rows
///
/// `FlipJoinGateTests` already pins this for the `ShiftRecord` snapshot joined
/// against `ShiftProjection` rows. What it did NOT cover is the two surfaces
/// the sweep switched that produce a day total AND a row list of their own:
/// `CalendarEarnings` (gap 7, the month grid) and `HistoryEarnings` as
/// `PeriodsView` now reads it (gap 1). A total sitting over a row list that
/// is missing one of its shifts is the same defect on a different screen.
///
/// ## Gate 4: digest identity ACROSS the flip
///
/// The design says "the same dataset fingerprints identically before and
/// after, which is only assertable because the canonicalization landed first
/// (#45)". MEASURED 2026-09-18: the property HOLDS -- a mirrored shift built
/// through `LegacySnapshotBridge` and through `ShiftInputAdapter` produces the
/// identical digest `f44d8243ff77764621415a87df30ff5f0298fa3457502965f7e532ee882a9c7d`
/// and the identical cents.
///
/// But it was asserted NOWHERE. All three existing digest assertions compare
/// two builders **within the same arm** (History vs Dashboard on records,
/// History vs Calendar on records, History vs Dashboard on legacy). None
/// compares across the flip, which is the only comparison gate 4 is about.
///
/// A true property with no gate is one refactor away from being a false one,
/// and this particular property is load-bearing: the stamp is the cache key
/// for every screen, and two arms with different digests would mean a flip
/// silently invalidating every cache AND two surfaces reading different arms
/// holding different stamps for one dataset.
@Suite("Flip gates 3 and 4", .serialized)
@MainActor
struct FlipGates3And4Tests {

    private static let zone = TimeZone(identifier: "America/New_York")!

    private static func day(_ offset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let base = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        return cal.date(byAdding: .day, value: offset, to: base)!
    }

    private static func policies() -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("gates34/rate"),
                effectiveFrom: .distantPast, hourlyRateCents: 283, provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("gates34/calendar"),
                effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone
            )]
        )
    }

    private static func mirroredEntries(_ records: [ShiftRecord]) -> [TipEntry] {
        records.flatMap { ShiftProjection.rows(for: $0) }.map { row in
            TipEntry(
                id: row.id, date: row.date, amountCents: row.amountCents, kind: row.kind,
                note: row.note, recordedAt: row.recordedAt, hoursWorked: row.hoursWorked,
                tipOutCents: row.tipOutCents, salesCents: row.salesCents,
                shiftPeriod: row.shiftPeriod, shiftID: row.shiftID, clockIn: row.clockIn,
                clockOut: row.clockOut, serverCount: row.serverCount,
                receiptMetrics: row.receiptMetrics
            )
        }
    }

    /// One day, three shifts, the third WAGE-ONLY.
    ///
    /// The wage-only shape is deliberate and the same choice
    /// `FlipJoinGateTests` made: the shipped writer used to drop a shift with
    /// hours and no tips entirely, so it is the one most likely to vanish from
    /// a join rather than merely be wrong in it.
    private static func records() -> [ShiftRecord] {
        let today = day(0)
        return [
            ShiftRecord(workDate: today, shiftPeriod: .lunch, cashTipsCents: 2_200,
                        creditTipsCents: 3_100, tipOutCents: 400, hoursWorked: 4.25,
                        recordedAt: today),
            ShiftRecord(workDate: today, shiftPeriod: .dinner, cashTipsCents: 5_600,
                        creditTipsCents: 9_900, hoursWorked: 5.5,
                        recordedAt: today.addingTimeInterval(3_600)),
            ShiftRecord(workDate: today, hoursWorked: 3,
                        recordedAt: today.addingTimeInterval(7_200)),
        ]
    }

    // MARK: - Gate 3, on the surfaces the sweep switched

    /// `CalendarEarnings` (gap 7): the tile's total and the day's shift ids
    /// must describe the same set.
    @Test("Calendar: a day with a total reports every one of its shifts")
    func gate3CalendarDropsNoShifts() throws {
        let policies = Self.policies()
        let records = Self.records()
        let snapshot = try #require(CalendarEarnings.snapshot(
            records: records, policies: policies, payrollTimeZone: Self.zone
        ))

        let civil = CivilDay(Self.day(0), in: Self.zone)
        let dayResult = snapshot.day(civil)

        // Non-zero first: a zero total with no rows is trivially consistent
        // and would pass this gate while proving nothing.
        #expect(dayResult.knownComponents.earnedIncomeCents > 0)

        // Exactly the three shifts, by id. Not a count -- a count passes when
        // one shift is swapped for another, which is a different bug with the
        // same arithmetic.
        let reported = Set(dayResult.shiftIDs)
        let expected = Set(records.map(\.id))
        #expect(reported == expected, "the day's total must be over exactly these shifts")
        #expect(reported.count == 3)
    }

    /// `HistoryEarnings` as `PeriodsView` reads it (gap 1): the period row's
    /// total and the shift ids behind it must agree, because the row pushes
    /// into a detail that lists them.
    @Test("History: a period with a total reports every one of its shifts")
    func gate3HistoryDropsNoShifts() throws {
        let policies = Self.policies()
        let records = Self.records()
        let build = HistoryEarnings.build(
            entries: [], records: records, policies: policies,
            payrollTimeZone: Self.zone, representation: .records
        )
        let snapshot = try #require(build.snapshot)

        let civil = CivilDay(Self.day(0), in: Self.zone)
        let dayResult = snapshot.day(civil)
        #expect(dayResult.knownComponents.earnedIncomeCents > 0)
        #expect(Set(dayResult.shiftIDs) == Set(records.map(\.id)))

        // And the row list the screen renders is the same set, so a figure
        // cannot sit over a different collection than it was computed from.
        #expect(Set(build.shiftRecordDays.map(\.id)) == Set(records.map(\.id)))
        #expect(build.shiftDays.isEmpty, "the record arm must not also populate the legacy list")
    }

    // MARK: - Gate 4, across the flip

    /// The gate that was missing: the SAME shifts, expressed both ways,
    /// fingerprint identically.
    ///
    /// **CORRECTION.** An earlier draft of this comment claimed the tip-out
    /// shapes below cover `#45`'s canonicalization -- the fix replacing
    /// `field(s.tipOutCents)` with `String(s.tipOutCents ?? 0)` because nil
    /// and 0 encoded differently while meaning the same thing to the ledger.
    /// **They do not.** MEASURED by reverting that fix: the mutation was
    /// caught by `ManifestPathAgreementTests`
    /// ("an explicit-zero tip-out fingerprints identically through both
    /// adapters"), and these tests stayed green.
    ///
    /// The reason is structural and worth knowing: `mirroredEntries` derives
    /// the legacy side from `ShiftProjection.rows(for:)`, which carries a
    /// record's nil-ness through unchanged. So both arms see the SAME
    /// nil-or-zero on every shape here, and the nil-versus-explicit-zero
    /// divergence never arises. `ManifestPathAgreementTests` owns that case
    /// because it constructs the disagreement directly instead of deriving
    /// one side from the other.
    ///
    /// What THESE add is the layer above it: identity through the two real
    /// BUILDER arms (`HistoryEarnings.build`'s legacy and record paths) end
    /// to end, rather than through the adapters in isolation. The shapes are
    /// chosen to exercise the builder paths, not the manifest's encoding:
    ///
    /// - **tip-out present** and **absent**, the ordinary paths.
    /// - **gratuity-bearing**, the one input reaching the manifest through a
    ///   receipt decode rather than a stored field.
    /// - **wage-only**, no tips at all.
    @Test(
        "the same dataset fingerprints identically through both representations",
        arguments: ["tipOut", "noTipOut", "gratuity", "wageOnly"]
    )
    func gate4DigestSurvivesTheFlip(_ shape: String) throws {
        let policies = Self.policies()
        let today = Self.day(0)
        let record: ShiftRecord
        switch shape {
        case "tipOut":
            record = ShiftRecord(workDate: today, shiftPeriod: .dinner, cashTipsCents: 2_200,
                                 creditTipsCents: 3_100, tipOutCents: 400, hoursWorked: 4.25,
                                 recordedAt: today)
        case "noTipOut":
            record = ShiftRecord(workDate: today, shiftPeriod: .dinner, cashTipsCents: 2_200,
                                 creditTipsCents: 3_100, hoursWorked: 4.25, recordedAt: today)
        case "gratuity":
            record = ShiftRecord(workDate: today, shiftPeriod: .dinner, cashTipsCents: 2_000,
                                 creditTipsCents: 8_000, tipOutCents: 500, hoursWorked: 5,
                                 receiptMetrics: ShiftReceiptMetrics(
                                    earningsSchemaVersion: 2, gratuityFeesCents: 3_400),
                                 recordedAt: today)
        default:
            record = ShiftRecord(workDate: today, hoursWorked: 5, recordedAt: today)
        }

        let records = [record]
        let entries = Self.mirroredEntries(records)

        let fromRecords = HistoryEarnings.build(
            entries: [], records: records, policies: policies,
            payrollTimeZone: Self.zone, representation: .records
        )
        let fromLegacy = HistoryEarnings.build(
            entries: entries, records: [], policies: policies,
            payrollTimeZone: Self.zone, representation: .legacy
        )

        let recordSnapshot = try #require(fromRecords.snapshot, "\(shape): no record snapshot")
        let legacySnapshot = try #require(fromLegacy.snapshot, "\(shape): no legacy snapshot")

        // The whole-manifest digest, which is what every screen's cache keys
        // on. If this differs, a flip silently invalidates every cache and
        // two surfaces on different arms hold different stamps for one
        // dataset.
        #expect(recordSnapshot.stamp.digest == legacySnapshot.stamp.digest,
                "\(shape): the same shifts must fingerprint identically across the flip")

        // The sub-digest that actually carries the shifts, named separately so
        // a failure says whether the shifts moved or something else did.
        #expect(recordSnapshot.stamp.manifest.shiftsDigest
                == legacySnapshot.stamp.manifest.shiftsDigest,
                "\(shape): shiftsDigest")

        // And the money, so this is not two arms agreeing on a fingerprint of
        // the wrong thing.
        let civil = CivilDay(today, in: Self.zone)
        let a = recordSnapshot.day(civil)
        let b = legacySnapshot.day(civil)
        #expect(a.knownComponents.earnedIncomeCents == b.knownComponents.earnedIncomeCents,
                "\(shape): earnedIncome")
        #expect(a.minutes == b.minutes, "\(shape): minutes")
    }

    /// The negative control: a digest that SHOULD differ, does.
    ///
    /// Without this, every assertion above passes if `digest` were ever
    /// reduced to a constant -- the way a parity test passes for the wrong
    /// reason. This is the disagreeing case for gate 4.
    @Test("a genuinely different dataset fingerprints differently")
    func gate4DigestIsNotAConstant() throws {
        let policies = Self.policies()
        let today = Self.day(0)
        let base = [ShiftRecord(workDate: today, shiftPeriod: .dinner, cashTipsCents: 2_200,
                                creditTipsCents: 3_100, tipOutCents: 400, hoursWorked: 4.25,
                                recordedAt: today)]
        // One cent different, nothing else.
        let moved = [ShiftRecord(workDate: today, shiftPeriod: .dinner, cashTipsCents: 2_201,
                                 creditTipsCents: 3_100, tipOutCents: 400, hoursWorked: 4.25,
                                 recordedAt: today)]

        let a = try #require(HistoryEarnings.build(
            entries: [], records: base, policies: policies,
            payrollTimeZone: Self.zone, representation: .records
        ).snapshot)
        let b = try #require(HistoryEarnings.build(
            entries: [], records: moved, policies: policies,
            payrollTimeZone: Self.zone, representation: .records
        ).snapshot)

        #expect(a.stamp.digest != b.stamp.digest,
                "one cent must change the fingerprint, or the digest proves nothing")
    }
}
