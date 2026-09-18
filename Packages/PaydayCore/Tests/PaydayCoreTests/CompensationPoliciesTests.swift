import Foundation
import Testing
@testable import PaydayCore

/// The policy payload shared by the App Group blob, the
/// `user_settings.compensation_policies` column and the widget, and the two
/// one-time migrations out of the pre-policy world.
@Suite("CompensationPolicies")
struct CompensationPoliciesTests {
    static let monday = CivilDay(year: 2026, month: 9, day: 28)

    static func rate(_ cents: Int, from day: CivilDay, provenance: RateProvenance = .confirmed) -> PayRatePolicy {
        PayRatePolicy(id: UUID(), effectiveFrom: day, hourlyRateCents: cents, provenance: provenance)
    }

    static func calendarPolicy(_ weekday: Int, from day: CivilDay, zone: String = "America/New_York") -> PayrollCalendarPolicy {
        PayrollCalendarPolicy(
            id: UUID(),
            effectiveFrom: day,
            workweekStartWeekday: weekday,
            payrollTimeZone: TimeZone(identifier: zone)!
        )
    }

    @Test("Policies normalize to effect order however they are handed in")
    func normalizesToEffectOrder() {
        let later = Self.rate(500, from: Self.monday)
        let earlier = Self.rate(283, from: Self.monday.adding(days: -70))
        let policies = CompensationPolicies(rates: [later, earlier], calendars: [])
        #expect(policies.rates.map(\.hourlyRateCents) == [283, 500])
        #expect(policies.latestRate?.hourlyRateCents == 500)
    }

    @Test("The rate and calendar in effect on a day are the last ones that started on or before it")
    func lookupsFindTheEffectivePolicy() {
        let policies = CompensationPolicies(
            rates: [Self.rate(283, from: Self.monday.adding(days: -70)), Self.rate(500, from: Self.monday)],
            calendars: [Self.calendarPolicy(2, from: .distantPast)]
        )
        #expect(policies.rate(on: Self.monday.adding(days: -1))?.hourlyRateCents == 283)
        #expect(policies.rate(on: Self.monday)?.hourlyRateCents == 500)
        #expect(policies.rate(on: Self.monday.adding(days: -100)) == nil)
        #expect(policies.calendar(on: Self.monday)?.workweekStartWeekday == 2)
    }

    @Test("A calendar policy off a workweek boundary is not in effect, and the previous one still is")
    func lookupHonoursTheBoundaryRule() {
        let first = Self.calendarPolicy(2, from: .distantPast)
        // Wednesday is not a Monday, so this policy is unrepresentable.
        let offBoundary = Self.calendarPolicy(1, from: CivilDay(year: 2026, month: 9, day: 30))
        let policies = CompensationPolicies(rates: [], calendars: [first, offBoundary])
        #expect(policies.calendar(on: CivilDay(year: 2026, month: 10, day: 5))?.id == first.id)
        // `latestCalendar` is the stored one either way: Settings has to show
        // the user what is on disk, boundary rule or not.
        #expect(policies.latestCalendar?.id == offBoundary.id)
    }

    @Test("The payroll time zone is the latest calendar policy's, and nil when there is none")
    func payrollTimeZoneComesFromThePolicy() {
        #expect(CompensationPolicies.empty.payrollTimeZone == nil)
        let policies = CompensationPolicies(
            rates: [],
            calendars: [
                Self.calendarPolicy(2, from: .distantPast, zone: "America/New_York"),
                Self.calendarPolicy(2, from: Self.monday, zone: "Asia/Tokyo")
            ]
        )
        #expect(policies.payrollTimeZone?.identifier == "Asia/Tokyo")
    }

    @Test("Adding a policy replaces by id rather than duplicating")
    func addingReplacesByID() {
        var policy = Self.rate(283, from: Self.monday)
        var policies = CompensationPolicies(rates: [policy], calendars: [])
        policy.hourlyRateCents = 400
        policies = policies.adding(rate: policy)
        #expect(policies.rates.count == 1)
        #expect(policies.rates[0].hourlyRateCents == 400)
        #expect(policies.removingRate(id: policy.id).rates.isEmpty)
    }

    @Test("The payload round-trips as JSON with its time zone as an identifier")
    func roundTripsAsJSON() throws {
        let policies = CompensationPolicies(
            rates: [Self.rate(283, from: Self.monday, provenance: .assumedFromLegacySetting)],
            calendars: [Self.calendarPolicy(2, from: .distantPast)]
        )
        let data = try JSONEncoder().encode(policies)
        let decoded = try JSONDecoder().decode(CompensationPolicies.self, from: data)
        #expect(decoded == policies)

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let calendars = try #require(object["calendars"] as? [[String: Any]])
        #expect(calendars[0]["payrollTimeZone"] as? String == "America/New_York")
        #expect(calendars[0]["effectiveFrom"] as? String == "0001-01-01")
        let rates = try #require(object["rates"] as? [[String: Any]])
        #expect(rates[0]["provenance"] as? String == "assumedFromLegacySetting")
    }

    @Test("A payload with no version and no arrays decodes as empty rather than failing")
    func decodesPartialPayload() throws {
        let decoded = try JSONDecoder().decode(CompensationPolicies.self, from: Data("{}".utf8))
        #expect(decoded == CompensationPolicies.empty)
        #expect(decoded.version == CompensationPolicies.currentVersion)
        #expect(decoded.isEmpty)
    }

    @Test("An unknown time zone identifier in a stored payload is a DecodingError, not a crash")
    func rejectsUnknownTimeZone() {
        let json = """
        {"version":1,"rates":[],"calendars":[{"id":"\(UUID().uuidString)","effectiveFrom":"2026-09-28",\
        "workweekStartWeekday":2,"overtimeThresholdMinutes":2400,"overtimeMultiplierHundredths":150,\
        "payrollTimeZone":"Mars/Olympus_Mons"}]}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CompensationPolicies.self, from: Data(json.utf8))
        }
    }

    // MARK: The migrations

    @Test("The frozen calendar policy restates what the app was already using, so nobody's overtime moves")
    func frozenCalendarPolicyFreezesTheEffectiveValue() {
        let zone = TimeZone(identifier: "America/New_York")!
        let policy = PolicyMigration.frozenCalendarPolicy(workweekStartWeekday: 2, payrollTimeZone: zone)
        #expect(policy.effectiveFrom == .distantPast)
        #expect(policy.workweekStartWeekday == 2)
        #expect(policy.overtimeThresholdMinutes == 2400)
        #expect(policy.overtimeMultiplierHundredths == 150)
        #expect(policy.payrollTimeZone == zone)

        // Every existing shift is inside the first policy, whatever its date.
        let policies = CompensationPolicies(rates: [], calendars: [policy])
        #expect(policies.calendar(on: CivilDay(year: 2019, month: 1, day: 1))?.id == policy.id)
    }

    @Test("Two devices migrating the same legacy settings mint the same policy ids")
    func migrationIDsAreDeterministic() {
        let zone = TimeZone(identifier: "America/New_York")!
        let a = PolicyMigration.frozenCalendarPolicy(workweekStartWeekday: 2, payrollTimeZone: zone)
        let b = PolicyMigration.frozenCalendarPolicy(workweekStartWeekday: 2, payrollTimeZone: zone)
        #expect(a.id == b.id)
        #expect(a == b)

        let rateA = PolicyMigration.assumedRatePolicy(hourlyRateCents: 283, earliestShiftDay: Self.monday)
        let rateB = PolicyMigration.assumedRatePolicy(hourlyRateCents: 283, earliestShiftDay: Self.monday)
        #expect(rateA.id == rateB.id)

        // A different legacy fact is a different policy.
        #expect(PolicyMigration.frozenCalendarPolicy(workweekStartWeekday: 1, payrollTimeZone: zone).id != a.id)
        #expect(PolicyMigration.assumedRatePolicy(hourlyRateCents: 400, earliestShiftDay: Self.monday).id != rateA.id)
        #expect(PolicyMigration.assumedRatePolicy(hourlyRateCents: 283, earliestShiftDay: nil).id != rateA.id)
    }

    @Test("The migration creates ONE rate policy, from the earliest shift, marked assumed")
    func assumedRatePolicyFabricatesNoHistory() {
        let policy = PolicyMigration.assumedRatePolicy(hourlyRateCents: 283, earliestShiftDay: Self.monday)
        #expect(policy.effectiveFrom == Self.monday)
        #expect(policy.hourlyRateCents == 283)
        #expect(policy.provenance == .assumedFromLegacySetting)

        let policies = CompensationPolicies(rates: [policy], calendars: [])
        #expect(policies.rates.count == 1, "no history is invented")
        #expect(policies.hasOnlyAssumedRates)
        // Nothing before the first shift is priced at all.
        #expect(policies.rate(on: Self.monday.adding(days: -1)) == nil)

        // Confirming it turns the estimate off without changing a cent.
        var confirmed = policy
        confirmed.provenance = .confirmed
        let after = policies.adding(rate: confirmed)
        #expect(after.rates.count == 1)
        #expect(after.hasOnlyAssumedRates == false)
        #expect(after.rates[0].hourlyRateCents == 283)
    }

    @Test("With no shifts the assumed rate starts at the distant past, so future shifts are valued")
    func assumedRateWithNoShifts() {
        let policy = PolicyMigration.assumedRatePolicy(hourlyRateCents: 283, earliestShiftDay: nil)
        #expect(policy.effectiveFrom == .distantPast)
        #expect(CompensationPolicies(rates: [policy], calendars: []).rate(on: Self.monday)?.hourlyRateCents == 283)
    }

    @Test("A migrated user's totals are unchanged in cents and only the label moves")
    func migrationChangesNoCents() {
        let zone = TimeZone(identifier: "America/New_York")!
        let calendar = PolicyMigration.frozenCalendarPolicy(workweekStartWeekday: 2, payrollTimeZone: zone)
        let shifts = [
            ShiftInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                       workDay: Self.monday, period: .dinner, minutesWorked: 255),
            ShiftInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                       workDay: Self.monday.adding(days: 1), period: .dinner, minutesWorked: 330)
        ]
        let assumed = PolicyMigration.assumedRatePolicy(hourlyRateCents: 283, earliestShiftDay: Self.monday)
        let assumedRun = CompensationLedger.evaluate(shifts, rates: [assumed], calendars: [calendar])

        var confirmed = assumed
        confirmed.provenance = .confirmed
        let confirmedRun = CompensationLedger.evaluate(shifts, rates: [confirmed], calendars: [calendar])

        #expect(assumedRun.totalComponents == confirmedRun.totalComponents)
        #expect(assumedRun.totalComponents.wagesCents == 2759, "W1's number, through the migrated policies")
        #expect(assumedRun.completeness.state == .estimated)
        #expect(confirmedRun.completeness.state == .complete)
    }

    // MARK: Boundary snapping

    @Test("A chosen date snaps forward to the next workweek start under the previous policy")
    func snappingMovesForwardToABoundary() {
        let previous = Self.calendarPolicy(2, from: .distantPast)
        // Wed 2026-09-30 -> Mon 2026-10-05.
        let snapped = PolicyMigration.snappedEffectiveFrom(
            onOrAfter: CivilDay(year: 2026, month: 9, day: 30), previous: previous
        )
        #expect(snapped == CivilDay(year: 2026, month: 10, day: 5))
        #expect(snapped.weekday == 2)

        // A date already on the boundary does not move.
        #expect(PolicyMigration.snappedEffectiveFrom(onOrAfter: Self.monday, previous: previous) == Self.monday)
        // With no previous policy there is no boundary to respect.
        #expect(PolicyMigration.snappedEffectiveFrom(
            onOrAfter: CivilDay(year: 2026, month: 9, day: 30), previous: nil
        ) == CivilDay(year: 2026, month: 9, day: 30))
    }

    @Test("A snapped calendar policy is always accepted by the engine and raises no diagnostic")
    func snappedPolicyIsAlwaysAccepted() {
        let previous = Self.calendarPolicy(2, from: .distantPast)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        for offset in 0..<21 {
            let chosen = Self.monday.adding(days: offset)
            let policy = PolicyMigration.calendarPolicy(
                effectiveFrom: chosen,
                workweekStartWeekday: 1,
                payrollTimeZone: tokyo,
                previous: previous
            )
            let accepted = CompensationLedger.acceptCalendarPolicies([previous, policy])
            #expect(accepted.diagnostics.isEmpty, "chosen \(chosen.iso) snapped to \(policy.effectiveFrom.iso)")
            #expect(accepted.accepted.count == 2)
            #expect(policy.effectiveFrom >= chosen)
            #expect(policy.effectiveFrom.weekday == previous.workweekStartWeekday)
            // The threshold and multiplier carry over; only the week start
            // and the frozen zone change.
            #expect(policy.overtimeThresholdMinutes == previous.overtimeThresholdMinutes)
            #expect(policy.overtimeMultiplierHundredths == previous.overtimeMultiplierHundredths)
            #expect(policy.payrollTimeZone == tokyo)
        }
    }

    @Test("Changing the payroll zone reprices nothing before the new policy")
    func newZoneRepricesNothingEarlier() {
        let previous = Self.calendarPolicy(2, from: .distantPast)
        let shifts = [
            ShiftInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                       workDay: Self.monday, period: .dinner, minutesWorked: 255),
            ShiftInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                       workDay: Self.monday.adding(days: 8), period: .dinner, minutesWorked: 330)
        ]
        let rates = [Self.rate(283, from: .distantPast)]
        let before = CompensationLedger.value(shifts, rates: rates, calendars: [previous])
        let moved = PolicyMigration.calendarPolicy(
            effectiveFrom: Self.monday.adding(days: 7),
            workweekStartWeekday: 2,
            payrollTimeZone: TimeZone(identifier: "Asia/Tokyo")!,
            previous: previous
        )
        let after = CompensationLedger.value(shifts, rates: rates, calendars: [previous, moved])
        #expect(before[0] == after[0], "the earlier shift kept its policy and its cents")
        #expect(after[1].calendarPolicyID == moved.id)
        #expect(before[1].components == after[1].components, "a zone change is not a raise")
    }
}

@Suite("CivilDay workweek snapping")
struct CivilDayWorkweekSnappingTests {
    @Test("nextStartOfWorkweek returns this day when it is already the start")
    func alreadyOnBoundary() {
        let monday = CivilDay(year: 2026, month: 9, day: 28)
        #expect(monday.weekday == 2)
        #expect(monday.nextStartOfWorkweek(startingOn: 2) == monday)
    }

    @Test("nextStartOfWorkweek never moves backwards and always lands on the asked weekday")
    func alwaysForwardAndOnTheWeekday() {
        let start = CivilDay(year: 2026, month: 1, day: 1)
        for offset in 0..<400 {
            let day = start.adding(days: offset)
            for weekday in 1...7 {
                let snapped = day.nextStartOfWorkweek(startingOn: weekday)
                #expect(snapped >= day)
                #expect(snapped.weekday == weekday)
                #expect(CivilDay.daysBetween(day, snapped) < 7)
                // And it is the same week the previous helper reports.
                #expect(snapped.startOfWorkweek(startingOn: weekday) == snapped)
            }
        }
    }
}
