import Foundation
import Testing
@testable import PaydayCore

/// Cross-fixture invariants. W2 is the base dataset; W3, M1, S2, T1 and C1
/// are W2 with exactly one declared input changed, so a drift in any of
/// them (a policy date, a shift minute) would silently turn "the schedule
/// flip alone moved nothing" into "two things changed". This suite pins
/// that each one differs from W2 in its declared variable and nowhere else.
@Suite("Fixture consistency")
struct FixtureConsistencyTests {
    /// The `kind` vocabulary from `Fixtures/README.md`.
    static let allowedKinds: Set<String> = ["ledger", "migration", "query", "export", "paycheck", "presentation"]

    /// The 14 plan fixtures (plan "PR 1", `.pr1-spec.md`).
    static let planIDs: Set<String> = ["W1", "W2", "W3", "N1", "N2", "N3", "M1", "H1", "P1", "E1", "S2", "Z1", "T1", "C1"]

    /// W2's five base shifts, by id suffix.
    static let baseShiftIDs: [UUID] = (1...5).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
    static let thursday = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let futureShift = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    static func shiftsByID(_ fixture: Fixture) -> [UUID: Fixture.Shift] {
        Dictionary(uniqueKeysWithValues: fixture.shifts.map { ($0.id, $0) })
    }

    @Test("Exactly the 14 plan fixtures are present and every id matches its filename")
    func idsMatchFilenames() throws {
        let ids = FixtureLoader.availableIDs()
        #expect(Set(ids) == Self.planIDs, "present: \(ids)")
        for id in ids {
            let fixture = try FixtureLoader.load(id)
            #expect(fixture.id == id, "\(id).json declares id \(fixture.id)")
        }
    }

    @Test("Every fixture kind is one of the documented kinds")
    func kindsAreAllowed() throws {
        for id in FixtureLoader.availableIDs() {
            let fixture = try FixtureLoader.load(id)
            #expect(Self.allowedKinds.contains(fixture.kind), "\(id).json kind \(fixture.kind.debugDescription)")
        }
    }

    /// `PayrollCalendarPolicy`'s memberwise init takes 1...7 as a precondition,
    /// so an out-of-range fixture value would trap and abort the whole run.
    /// `FixtureLoader.toCalendarPolicies()` rejects it as
    /// `Error.invalidWeekday` instead; this test names the rule for the
    /// fixtures themselves so a bad value fails here rather than wherever it
    /// happens to be converted first.
    @Test("Every fixture's calendar policies declare workweekStartWeekday in 1...7")
    func calendarWeekdaysAreInRange() throws {
        var checked = 0
        for id in FixtureLoader.availableIDs() {
            let fixture = try FixtureLoader.load(id)
            for (index, calendar) in fixture.policies.calendar.enumerated() {
                #expect(PayrollCalendarPolicy.weekdayRange.contains(calendar.workweekStartWeekday),
                        "\(id).json policies.calendar[\(index)].workweekStartWeekday \(calendar.workweekStartWeekday) is outside 1...7")
                checked += 1
            }
            // And the loader agrees: converting never throws for a good fixture.
            #expect(throws: Never.self) { try fixture.toCalendarPolicies() }
        }
        // Every plan fixture declares exactly one calendar policy today.
        #expect(checked == 14)
    }

    @Test("Every Monday-start calendar policy takes effect on a Monday")
    func calendarPoliciesStartOnMonday() throws {
        var checked = 0
        for id in FixtureLoader.availableIDs() {
            let fixture = try FixtureLoader.load(id)
            for (index, calendar) in fixture.policies.calendar.enumerated() where calendar.workweekStartWeekday == 2 {
                #expect(calendar.effectiveFrom.weekday == 2,
                        "\(id).json policies.calendar[\(index)].effectiveFrom \(calendar.effectiveFrom) is not a Monday")
                checked += 1
            }
        }
        // Every plan fixture is Monday-start today; the check must have bitten.
        #expect(checked == 14)
    }

    @Test("W2 base: five shifts 001..005, Monday-start policies effective 2025-12-29, biweekly schedule anchored 2026-10-04")
    func w2Base() throws {
        let w2 = try FixtureLoader.load("W2")
        #expect(w2.shifts.map(\.id) == Self.baseShiftIDs)
        #expect(w2.policies.rate.map(\.effectiveFrom) == [CivilDay(year: 2025, month: 12, day: 29)])
        #expect(w2.policies.calendar.map(\.effectiveFrom) == [CivilDay(year: 2025, month: 12, day: 29)])
        #expect(w2.policies.calendar.first?.workweekStartWeekday == 2)
        #expect(w2.schedule?.frequency == "biweekly")
        #expect(w2.schedule?.anchorPeriodEnd == CivilDay(year: 2026, month: 10, day: 4))
        #expect(w2.schedule?.firstWeekday == 2)
        #expect(w2.asOf == CivilDay(year: 2026, month: 10, day: 2))
        #expect(w2.deviceTimeZone == nil)
        #expect(Self.shiftsByID(w2)[Self.thursday]?.minutesWorked == 690)
    }

    @Test("W3, M1, S2, T1, C1 share W2's policies, schedule frequency/anchor, and asOf")
    func familySharesPolicies() throws {
        let w2 = try FixtureLoader.load("W2")
        for id in ["W3", "M1", "S2", "T1", "C1"] {
            let f = try FixtureLoader.load(id)
            #expect(f.policies == w2.policies, "\(id) policies differ from W2")
            #expect(f.schedule?.frequency == w2.schedule?.frequency, "\(id) schedule.frequency")
            #expect(f.schedule?.anchorPeriodEnd == w2.schedule?.anchorPeriodEnd, "\(id) schedule.anchorPeriodEnd")
            #expect(f.schedule?.payDelayDays == w2.schedule?.payDelayDays, "\(id) schedule.payDelayDays")
            #expect(f.asOf == w2.asOf, "\(id) asOf")
            #expect(f.legacyEntries.isEmpty && f.paychecks.isEmpty, "\(id) carries legacy entries or paychecks")
        }
    }

    @Test("W3 differs from W2 only in schedule.firstWeekday (2 -> 1)")
    func w3() throws {
        let w2 = try FixtureLoader.load("W2")
        let w3 = try FixtureLoader.load("W3")
        #expect(w3.shifts == w2.shifts)
        #expect(w3.schedule?.firstWeekday == 1)
        #expect(w2.schedule?.firstWeekday == 2)
        var patched = try #require(w3.schedule)
        patched.firstWeekday = w2.schedule?.firstWeekday
        #expect(patched == w2.schedule)
        #expect(w3.deviceTimeZone == w2.deviceTimeZone)
    }

    @Test("M1 has W2's inputs unchanged (its only addition is an inert deviceTimeZone equal to the policy zone)")
    func m1() throws {
        let w2 = try FixtureLoader.load("W2")
        let m1 = try FixtureLoader.load("M1")
        #expect(m1.shifts == w2.shifts)
        #expect(m1.schedule == w2.schedule)
        // Not a variable: it names the same zone the calendar policy freezes.
        #expect(m1.deviceTimeZone == m1.policies.calendar.first?.payrollTimeZone)
    }

    @Test("S2 is W2 plus exactly one future shift 006 on 2026-10-09")
    func s2() throws {
        let w2 = try FixtureLoader.load("W2")
        let s2 = try FixtureLoader.load("S2")
        #expect(s2.shifts.count == 6)
        #expect(Array(s2.shifts.prefix(5)) == w2.shifts)
        let extra = try #require(Self.shiftsByID(s2)[Self.futureShift])
        #expect(extra.workDay == CivilDay(year: 2026, month: 10, day: 9))
        #expect(extra.workDay > (s2.asOf ?? .distantPast))
        #expect(s2.schedule == w2.schedule)
        #expect(s2.deviceTimeZone == w2.deviceTimeZone)
    }

    @Test("T1 differs from W2 only in deviceTimeZone (Pacific/Honolulu)")
    func t1() throws {
        let w2 = try FixtureLoader.load("W2")
        let t1 = try FixtureLoader.load("T1")
        #expect(t1.shifts == w2.shifts)
        #expect(t1.schedule == w2.schedule)
        #expect(t1.deviceTimeZone == "Pacific/Honolulu")
        #expect(w2.deviceTimeZone == nil)
        #expect(t1.policies.calendar.first?.payrollTimeZone == "America/New_York")
    }

    @Test("C1 differs from W2 only in shift 004's minutesWorked (690 -> null)")
    func c1() throws {
        let w2 = try FixtureLoader.load("W2")
        let c1 = try FixtureLoader.load("C1")
        #expect(c1.shifts.map(\.id) == w2.shifts.map(\.id))
        let c1ByID = Self.shiftsByID(c1)
        let w2ByID = Self.shiftsByID(w2)
        #expect(c1ByID[Self.thursday]?.minutesWorked == nil)
        for id in Self.baseShiftIDs where id != Self.thursday {
            #expect(c1ByID[id] == w2ByID[id], "C1 shift \(id) differs from W2")
        }
        var patched = try #require(c1ByID[Self.thursday])
        patched.minutesWorked = w2ByID[Self.thursday]?.minutesWorked
        #expect(patched == w2ByID[Self.thursday])
        #expect(c1.schedule == w2.schedule)
        #expect(c1.deviceTimeZone == w2.deviceTimeZone)
    }

    @Test("Legacy entry dates in N1, N2, N3 all reduce to a civil day in the payroll zone")
    func legacyDatesParse() throws {
        for id in ["N1", "N2", "N3"] {
            let f = try FixtureLoader.load(id)
            let zoneID = try #require(f.policies.calendar.first?.payrollTimeZone)
            let zone = try #require(TimeZone(identifier: zoneID))
            #expect(!f.legacyEntries.isEmpty)
            for entry in f.legacyEntries {
                #expect(entry.civilDay(in: zone) != nil, "\(id) legacy entry \(entry.id) date \(entry.date.debugDescription)")
            }
        }
        // N3's 23:40 -04:00 row is the same New York day but the next UTC day.
        let n3 = try FixtureLoader.load("N3")
        let late = try #require(n3.legacyEntries.first { $0.date.contains("23:40") })
        #expect(late.civilDay(in: TimeZone(identifier: "America/New_York")!) == CivilDay(year: 2026, month: 9, day: 28))
        #expect(late.civilDay(in: TimeZone(identifier: "UTC")!) == CivilDay(year: 2026, month: 9, day: 29))
    }

    /// W3's `expected.manifest` block is a claim about real digests, not prose:
    /// shifts/paychecks/policies must equal W2's and only schedule and the full
    /// digest may differ. It only holds because `FixtureLoader` derives policy
    /// ids from policy CONTENT; a fixture-id-derived id would put "W2/rate/0"
    /// vs "W3/rate/0" inside the canonical policy line and break
    /// `policiesDigestEqualsW2` for a reason unrelated to the one input W3
    /// changes. PR 4 wires these sub-digests into the ledger, so pin them now.
    @Test("W3's declared manifest sub-digest relationships to W2 actually hold")
    func w3ManifestMatchesItsDeclaredRelationshipToW2() throws {
        func manifest(_ id: String) throws -> InputManifest {
            let f = try FixtureLoader.load(id)
            return try InputManifest(shifts: f.toShiftInputs(), paychecks: f.toPaycheckInputs(),
                                     schedule: f.toScheduleInput(), rates: f.toRatePolicies(),
                                     calendars: f.toCalendarPolicies(), asOf: f.asOf)
        }
        let w2 = try manifest("W2")
        let w3 = try manifest("W3")

        let declared = try #require(FixtureLoader.load("W3").expected["manifest"]?.objectValue)
        #expect(try #require(declared["shiftsDigestEqualsW2"]?.boolValue) == (w3.shiftsDigest == w2.shiftsDigest))
        #expect(try #require(declared["paychecksDigestEqualsW2"]?.boolValue) == (w3.paychecksDigest == w2.paychecksDigest))
        #expect(try #require(declared["policiesDigestEqualsW2"]?.boolValue) == (w3.policiesDigest == w2.policiesDigest))
        #expect(try #require(declared["scheduleDigestEqualsW2"]?.boolValue) == (w3.scheduleDigest == w2.scheduleDigest))
        #expect(try #require(declared["digestEqualsW2"]?.boolValue) == (w3.digest == w2.digest))

        // Spelled out, so a regression names the broken half rather than a bool mismatch.
        #expect(w3.shiftsDigest == w2.shiftsDigest)
        #expect(w3.paychecksDigest == w2.paychecksDigest)
        #expect(w3.policiesDigest == w2.policiesDigest)
        #expect(w3.scheduleDigest != w2.scheduleDigest)
        #expect(w3.digest != w2.digest)

        // The ledgerOutput identity clause also needs the policy IDS to match,
        // not just the digest they roll up into.
        let w2Fixture = try FixtureLoader.load("W2")
        let w3Fixture = try FixtureLoader.load("W3")
        #expect(w3Fixture.toRatePolicies().map(\.id) == w2Fixture.toRatePolicies().map(\.id))
        #expect(try w3Fixture.toCalendarPolicies().map(\.id) == w2Fixture.toCalendarPolicies().map(\.id))
        #expect(!w3Fixture.toRatePolicies().isEmpty)
    }

    /// W3's premise "policies are byte-identical to W2" is shared by T1, M1, C1
    /// and S2. Each of those fixtures declares W2's rate and calendar policy, so
    /// with content-derived ids each must land on W2's exact policy values, ids
    /// included, and therefore on W2's policiesDigest.
    @Test("Fixtures declaring W2's policies share W2's policy ids and policiesDigest",
          arguments: ["W3", "T1", "M1", "C1", "S2"])
    func fixturesWithW2PoliciesShareItsPolicyIDs(id: String) throws {
        let w2 = try FixtureLoader.load("W2")
        let f = try FixtureLoader.load(id)
        let w2Rates = w2.toRatePolicies()
        let w2Calendars = try w2.toCalendarPolicies()
        #expect(!w2Rates.isEmpty && !w2Calendars.isEmpty)
        // Whole values, so this fails loudly if a fixture's policy ever drifts.
        #expect(f.toRatePolicies() == w2Rates, "\(id) rate policies differ from W2's")
        #expect(try f.toCalendarPolicies() == w2Calendars, "\(id) calendar policies differ from W2's")

        let mine = try InputManifest(shifts: [], rates: f.toRatePolicies(), calendars: f.toCalendarPolicies(), asOf: nil)
        let theirs = try InputManifest(shifts: [], rates: w2Rates, calendars: w2Calendars, asOf: nil)
        #expect(mine.policiesDigest == theirs.policiesDigest)
    }

    /// One case per fixture, and the PR-1 claim every fixture makes: it loads,
    /// converts to engine inputs, and builds a manifest. Parameterized (not a
    /// loop) and wrapped in `expectingKnownIssues(for:)` so the known-issue
    /// list is load-bearing in the ordinary run: every ID in
    /// `KnownIssues.json` is claimed by this test, so listing an ID whose
    /// fixture already passes records `knownIssueNotRecorded` and fails the
    /// build, which is what forces the list to shrink (docs/CI.md).
    /// `KnownIssuesGateTests.everyKnownIssueIsClaimedByAWrappedTest` pins that
    /// no listed ID can escape this wrapper.
    @Test("Every fixture's shifts convert to ShiftInputs and policies to engine policies",
          arguments: FixtureLoader.availableIDs())
    func everyFixtureConverts(id: String) throws {
        try expectingKnownIssues(for: id) {
            let f = try FixtureLoader.load(id)
            let shifts = f.toShiftInputs()
            #expect(shifts.count == f.shifts.count)
            #expect(Set(shifts.map(\.id)).count == shifts.count, "\(id) has duplicate shift ids")
            let calendars = try f.toCalendarPolicies()
            #expect(calendars.count == f.policies.calendar.count)
            let rates = f.toRatePolicies()
            #expect(rates.count == f.policies.rate.count)
            _ = try f.toPaycheckInputs()
            // Building a manifest over the fixture exercises validate() on its free-text fields.
            let manifest = try InputManifest(shifts: shifts, paychecks: f.toPaycheckInputs(), schedule: f.toScheduleInput(),
                                         rates: rates, calendars: calendars, asOf: f.asOf)
            #expect(manifest.digest.count == 64)
        }
    }
}
