import Foundation
import Testing
@testable import PaydayCore

@Suite("FixtureLoader")
struct FixtureLoaderTests {
    @Test("The Fixtures resource directory is in the bundle")
    func fixturesDirectoryPresent() {
        #expect(Bundle.module.url(forResource: "README", withExtension: "md", subdirectory: FixtureLoader.directory) != nil)
        #expect(Bundle.module.url(forResource: KnownIssues.fileName, withExtension: "json", subdirectory: FixtureLoader.directory) != nil)
    }

    @Test("A missing fixture throws a named error instead of crashing")
    func missingFixture() {
        #expect(throws: FixtureLoader.Error.self) {
            _ = try FixtureLoader.load("DOES-NOT-EXIST")
        }
    }

    @Test("Decodes the documented fixture shape and converts to engine inputs")
    func decodesShape() throws {
        let json = """
        {
          "id": "X1", "description": "shape check", "kind": "ledger",
          "policies": {
            "rate": [{"effectiveFrom": "2026-01-01", "hourlyRateCents": 283, "provenance": "confirmed"}],
            "calendar": [{"effectiveFrom": "2026-01-05", "workweekStartWeekday": 2, "overtimeThresholdMinutes": 2400,
                          "overtimeMultiplierHundredths": 150, "payrollTimeZone": "America/New_York"}]
          },
          "schedule": {"frequency": "weekly", "anchorPeriodEnd": "2026-09-27", "firstWeekday": 2},
          "shifts": [
            {"id": "11111111-1111-4111-8111-111111111111", "workDay": "2026-09-28", "period": "dinner", "minutesWorked": 255,
             "voluntaryCashCents": 6000, "voluntaryCreditCents": 4000, "gratuityFeesCents": 0, "tipOutCents": 1000},
            {"id": "22222222-2222-4222-8222-222222222222", "workDay": "2026-09-29", "period": null, "minutesWorked": null,
             "voluntaryCashCents": 0, "voluntaryCreditCents": 500, "gratuityFeesCents": 0, "tipOutCents": null}
          ],
          "legacyEntries": [
            {"id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "shiftID": null, "date": "2026-09-28", "amountCents": 3000, "kind": "cash",
             "tipOutCents": null, "hoursWorked": 4.25, "receiptMetricsJSON": null}
          ],
          "paychecks": [
            {"id": "33333333-3333-4333-8333-333333333333", "periodStart": "2026-09-21", "periodEnd": "2026-09-27",
             "paidTipsCents": 10000, "grossPayCents": 15050, "regularWagesCents": 5000, "overtimeWagesCents": 0, "gratuityCents": 0}
          ],
          "asOf": "2026-10-02",
          "deviceTimeZone": "Pacific/Honolulu",
          "expected": {"week": 2759, "label": "Known so far", "ratio": 6.3833, "wrongAnswers": {"perShiftRounding": 2760}},
          "notes": "n"
        }
        """
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(json.utf8))
        #expect(fixture.id == "X1")
        #expect(fixture.kind == "ledger")
        #expect(fixture.asOf == CivilDay(year: 2026, month: 10, day: 2))
        #expect(fixture.deviceTimeZone == "Pacific/Honolulu")
        #expect(fixture.expected["week"]?.intValue == 2759)
        #expect(fixture.expected["label"]?.stringValue == "Known so far")
        #expect(fixture.expected["ratio"]?.doubleValue == 6.3833)
        #expect(fixture.wrongAnswers["perShiftRounding"]?.intValue == 2760)

        let shifts = fixture.toShiftInputs()
        #expect(shifts.count == 2)
        #expect(shifts[0].period == .dinner)
        #expect(shifts[0].tipOutCents == 1000)
        #expect(shifts[0].minutesWorked == 255)
        #expect(shifts[1].period == nil)
        #expect(shifts[1].tipOutCents == nil)
        #expect(shifts[1].minutesWorked == nil)

        let rates = fixture.toRatePolicies()
        #expect(rates.count == 1)
        #expect(rates[0].hourlyRateCents == 283)
        #expect(rates[0].provenance == .confirmed)
        // Policy ids are derived from policy CONTENT, not from the fixture id,
        // so two fixtures declaring the same policy agree on the id (and so on
        // InputManifest.policiesDigest). See FixtureLoader.toRatePolicies().
        #expect(rates[0].id == FixtureLoader.deterministicUUID("policy/rate/2026-01-01/283/confirmed"))
        #expect(rates[0].id != FixtureLoader.deterministicUUID("X1/rate/0"))

        let calendars = try fixture.toCalendarPolicies()
        #expect(calendars.count == 1)
        #expect(calendars[0].workweekStartWeekday == 2)
        #expect(calendars[0].payrollTimeZone.identifier == "America/New_York")
        #expect(calendars[0].id == FixtureLoader.deterministicUUID(
            "policy/calendar/2026-01-05/2/2400/150/America/New_York"))

        let schedule = try #require(fixture.toScheduleInput())
        #expect(schedule.frequency == "weekly")
        #expect(schedule.firstWeekday == 2)

        let paychecks = try fixture.toPaycheckInputs()
        #expect(paychecks.count == 1)
        #expect(paychecks[0].paidTipsCents == 10000)
        #expect(paychecks[0].grossPayCents == 15050)
        #expect(paychecks[0].netPayCents == nil)

        #expect(fixture.legacyEntries.count == 1)
        #expect(fixture.legacyEntries[0].hoursWorked == 4.25)
        #expect(fixture.legacyEntries[0].shiftID == nil)
    }

    @Test("Minimal fixture: omitted collections decode as empty")
    func minimalFixture() throws {
        let json = #"{"id": "MIN", "expected": {}}"#
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(json.utf8))
        #expect(fixture.shifts.isEmpty)
        #expect(fixture.legacyEntries.isEmpty)
        #expect(fixture.paychecks.isEmpty)
        #expect(fixture.policies.rate.isEmpty)
        #expect(fixture.schedule == nil)
        #expect(fixture.asOf == nil)
    }

    @Test("Deterministic UUIDs are stable and distinct")
    func deterministicUUID() {
        #expect(FixtureLoader.deterministicUUID("W1/rate/0") == FixtureLoader.deterministicUUID("W1/rate/0"))
        #expect(FixtureLoader.deterministicUUID("W1/rate/0") != FixtureLoader.deterministicUUID("W1/rate/1"))
    }

    @Test("Every fixture present in the bundle decodes and has a matching id")
    func allPresentFixturesDecode() throws {
        for id in FixtureLoader.availableIDs() {
            let fixture = try FixtureLoader.load(id)
            #expect(fixture.id == id, "Fixture file \(id).json declares id \(fixture.id)")
        }
    }

    @Test("expectingKnownIssues runs the body when the id is not listed")
    func knownIssueWrapperRunsBody() throws {
        var ran = false
        try expectingKnownIssues(for: "NOT-LISTED") { ran = true }
        #expect(ran)
        #expect(!KnownIssues.isKnownIssue("NOT-LISTED"))
    }
}
