import Testing
import Foundation
@testable import Payday

/// PR B in the app: the log sheet's Role row, the Insights role filter, the
/// CSV Role column, the sync wire, and the role rates in Settings. Synthetic
/// round numbers throughout.
private func rolesCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    return calendar
}

private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    rolesCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func entry(_ role: String?, _ date: Date, _ period: ShiftPeriod? = nil, recordedAt: Date? = nil) -> ShiftRoleList.Entry {
    ShiftRoleList.Entry(roleName: role, workDate: date, recordedAt: recordedAt, shiftPeriod: period)
}

/// Sunday-start workweek, All roles $8, Bar $10, Floor $5.
private func rolePolicies() -> CompensationPolicies {
    CompensationPolicies(
        rates: [
            PayRatePolicy(id: PolicyMigration.deterministicID("roles/all"), effectiveFrom: .distantPast,
                          hourlyRateCents: 800, provenance: .confirmed),
            PayRatePolicy(id: PolicyMigration.deterministicID("roles/bar"), effectiveFrom: .distantPast,
                          hourlyRateCents: 1_000, provenance: .confirmed, roleName: "Bar"),
            PayRatePolicy(id: PolicyMigration.deterministicID("roles/floor"), effectiveFrom: .distantPast,
                          hourlyRateCents: 500, provenance: .confirmed, roleName: "Floor"),
        ],
        calendars: [PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("roles/calendar"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 1,
            payrollTimeZone: PaydayTestZone.payroll
        )]
    )
}

@Suite("Roles: the log sheet's Role row")
struct LogShiftRoleFactsTests {
    @Test("with no roles on the account the row is hidden until Add role is tapped")
    func hiddenWithZeroRoles() {
        let shifts = [entry(nil, day(2026, 10, 5)), entry(nil, day(2026, 10, 6))]
        let untouched = LogShiftRoleFacts(shifts: shifts, tappedAddRole: false)
        #expect(!untouched.isRowVisible)
        #expect(untouched.showsAddRole)
        #expect(untouched.chips.isEmpty)
        #expect(LogShiftRoleFacts(shifts: shifts, tappedAddRole: true).isRowVisible)
        #expect(LogShiftRoleFacts(shifts: [], tappedAddRole: false).isRowVisible == false)
    }

    @Test("once any shift has a role the row shows, with no Add role button")
    func visibleWithARole() {
        let facts = LogShiftRoleFacts(shifts: [entry("Bar", day(2026, 10, 5))], tappedAddRole: false)
        #expect(facts.isRowVisible)
        #expect(!facts.showsAddRole)
    }

    @Test("chips are distinct roles, most recent first, case and spaces collapsed")
    func chipOrder() {
        let shifts = [
            entry("Floor", day(2026, 10, 1)),
            entry("bar ", day(2026, 10, 2)),
            entry("Host", day(2026, 10, 3)),
            entry("Bar", day(2026, 10, 4)),
            entry(nil, day(2026, 10, 5)),
        ]
        #expect(LogShiftRoleFacts(shifts: shifts, tappedAddRole: false).chips == ["Bar", "Host", "Floor"])
    }

    @Test("a new shift never starts with a role: nothing is seeded from history")
    func nothingSeeded() {
        // Tyler's no-assumptions law (2026-07-27). The facts carry no
        // "starts with" at all; the only role a draft has is the one chosen.
        let shifts = [entry("Bar", day(2026, 10, 3), .lunch), entry("Floor", day(2026, 10, 8), .dinner)]
        let facts = LogShiftRoleFacts(shifts: shifts, tappedAddRole: false, draftRole: nil)
        #expect(facts.chips == ["Floor", "Bar"])
        #expect(facts.isRowVisible)
    }

    @Test("tapping a chip selects it; tapping the selected chip clears it")
    func toggling() {
        #expect(LogShiftRoleFacts.toggled(nil, tapping: "Bar") == "Bar")
        #expect(LogShiftRoleFacts.toggled("bar", tapping: "Bar") == nil)
        #expect(LogShiftRoleFacts.toggled("Floor", tapping: "Bar") == "Bar")
    }
}

@Suite("Roles: Insights shows one role alone")
@MainActor
struct InsightsRoleFilterTests {
    /// Sun 2026-10-04 start. Bar 10h Mon, Floor 10h Tue, Bar 10h Wed, Floor
    /// 10h Thu (40h), Bar 5h Fri (overtime), Floor 5h Sat (overtime).
    static func week() -> [ShiftRecord] {
        let plan: [(Int, String, Double)] = [(5, "Bar", 10), (6, "Floor", 10), (7, "Bar", 10),
                                             (8, "Floor", 10), (9, "Bar", 5), (10, "Floor", 5)]
        return plan.map { d, role, hours in
            ShiftRecord(workDate: day(2026, 10, d), cashTipsCents: 10_000, hoursWorked: hours, roleName: role)
        }
    }

    @Test("the filter appears only with two or more roles, most used first")
    func optionsNeedTwoRoles() {
        let none = [ShiftRecord(workDate: day(2026, 10, 5), cashTipsCents: 1_000)]
        let one = [ShiftRecord(workDate: day(2026, 10, 5), cashTipsCents: 1_000, roleName: "Bar")]
        #expect(InsightsEarnings.roleOptions(records: none).isEmpty)
        #expect(InsightsEarnings.roleOptions(records: one).isEmpty)
        let two = one + [
            ShiftRecord(workDate: day(2026, 10, 6), cashTipsCents: 1_000, roleName: "Floor"),
            ShiftRecord(workDate: day(2026, 10, 7), cashTipsCents: 1_000, roleName: "Floor"),
        ]
        #expect(InsightsEarnings.roleOptions(records: two) == ["Floor", "Bar"])
    }

    @Test("bar view + floor view = All, to the cent, in a week over the threshold")
    func roleViewsSumToAll() throws {
        let records = Self.week()
        let zone = PaydayTestZone.payroll
        let all = InsightsEarnings.build(records: records, policies: rolePolicies(), payrollTimeZone: zone)
        let bar = InsightsEarnings.build(records: records, policies: rolePolicies(), payrollTimeZone: zone, role: "bar")
        let floor = InsightsEarnings.build(records: records, policies: rolePolicies(), payrollTimeZone: zone, role: "Floor")
        let range = DayRange(start: CivilDay(year: 2026, month: 10, day: 4), end: CivilDay(year: 2026, month: 10, day: 10))
        let allResult = try #require(all.snapshot).range(range)
        let barResult = try #require(bar.snapshot).range(range)
        let floorResult = try #require(floor.snapshot).range(range)

        // Bar: 20h x $10 + 5h overtime x $15. Floor: 20h x $5 + 5h x $7.50.
        #expect(barResult.knownComponents.wagesCents == 20_000 + 7_500)
        #expect(barResult.knownComponents.overtimeWagesCents == 7_500)
        #expect(floorResult.knownComponents.wagesCents == 10_000 + 3_750)
        #expect(barResult.knownComponents + floorResult.knownComponents == allResult.knownComponents)
        #expect(barResult.knownComponents.earnedIncomeCents + floorResult.knownComponents.earnedIncomeCents
                == allResult.knownComponents.earnedIncomeCents)

        // The rows StatsEngine reads are the role's only.
        #expect(bar.shiftIDs.count == 3)
        #expect(floor.shiftIDs.count == 3)
        #expect(all.shiftIDs.count == 6)
        #expect(bar.snapshot?.stamp.digest != all.snapshot?.stamp.digest)
    }
}

@Suite("Roles: CSV, wire and policies")
@MainActor
struct ShiftRolesDataTests {
    private static let calculator = PayPeriodCalculator(
        payrollTimeZone: PaydayTestZone.payroll,
        schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: day(2026, 7, 19), firstWeekday: 2)
    )

    @Test("with no roles the CSV header is exactly today's")
    func csvUnchangedWithoutRoles() {
        let csv = CSVExporter.export(
            records: [ShiftRecord(workDate: day(2026, 7, 8), cashTipsCents: 5_000)],
            paycheckRecords: [], calculator: Self.calculator)
        let header = csv.split(separator: "\n").first.map(String.init)
        #expect(header == CSVExporter.header)
        #expect(!(header ?? "").contains("Role"))
    }

    @Test("with a role the CSV appends Role as the last column")
    func csvAppendsRoleLast() {
        let csv = CSVExporter.export(
            records: [
                ShiftRecord(workDate: day(2026, 7, 8), cashTipsCents: 5_000, roleName: "Bar"),
                ShiftRecord(workDate: day(2026, 7, 9), cashTipsCents: 5_000),
            ],
            paycheckRecords: [], calculator: Self.calculator)
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == CSVExporter.header + ",Role")
        let headers = lines[0].split(separator: ",").map(String.init)
        #expect(headers.last == "Role")
        #expect(Array(headers.dropLast()) == CSVExporter.header.split(separator: ",").map(String.init))
        let first = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let second = lines[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(first.count == headers.count)
        #expect(first.last == "Bar")
        #expect(second.last == "")
    }

    private static func remote(role: String?) -> RemoteShift {
        let record = ShiftRecord(workDate: day(2026, 9, 1), cashTipsCents: 1_000, roleName: role)
        return RemoteShift(record: record, userID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    }

    @Test("the role is always sent, null when none, and survives the round trip")
    func wireRoundTrip() throws {
        let none = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.remote(role: nil))) as? [String: Any])
        #expect(none.keys.contains("role_name"))
        #expect(none["role_name"] is NSNull)

        var row = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.remote(role: "Bar"))) as? [String: Any])
        #expect(row["role_name"] as? String == "Bar")
        row["user_id"] = "11111111-1111-4111-8111-111111111111"
        let decoded = try JSONDecoder().decode(RemoteShift.self, from: JSONSerialization.data(withJSONObject: row))
        #expect(decoded.roleName == "Bar")
    }

    @Test("a row from an older build, with no role key, decodes as no role")
    func missingKeyDecodesNil() throws {
        var row = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.remote(role: "Bar"))) as? [String: Any])
        row.removeValue(forKey: "role_name")
        row["user_id"] = "11111111-1111-4111-8111-111111111111"
        let decoded = try JSONDecoder().decode(RemoteShift.self, from: JSONSerialization.data(withJSONObject: row))
        #expect(decoded.roleName == nil)
    }

    @Test("a shift with no role fingerprints as before; a role changes it")
    func fingerprint() throws {
        let value = Self.remote(role: nil).businessValue
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(!object.keys.contains("roleName"))
        #expect(try Self.remote(role: "Bar").contentFingerprint != Self.remote(role: nil).contentFingerprint)
    }

    @Test("a record's role is trimmed, capped and reaches the engine input")
    func recordToInput() {
        let record = ShiftRecord(workDate: day(2026, 10, 5), cashTipsCents: 1_000, hoursWorked: 1, roleName: "  Bar  ")
        #expect(record.roleName == "Bar")
        #expect(ShiftRecord(workDate: .now, roleName: "   ").roleName == nil)
        let input = ShiftInputAdapter.inputs(from: [record], calendars: rolePolicies().calendars)
        #expect(input.first?.roleName == "Bar")
    }

    @Test("Your rate is the All roles rate; removing a role's rate falls back to it")
    func policiesAllRoles() {
        let policies = rolePolicies()
        #expect(policies.latestRate?.hourlyRateCents == 800)
        #expect(policies.rate(on: CivilDay(year: 2026, month: 10, day: 5))?.hourlyRateCents == 800)
        #expect(policies.roleNames == ["Bar", "Floor"])
        let removed = policies.removingRates(forRole: "bar")
        #expect(removed.roleNames == ["Floor"])
        #expect(removed.latestRate?.hourlyRateCents == 800)
        // A bar shift is now paid at All roles.
        let shift = ShiftInput(id: UUID(), workDay: CivilDay(year: 2026, month: 10, day: 5), minutesWorked: 60, roleName: "Bar")
        let valued = CompensationLedger.value([shift], rates: removed.rates, calendars: removed.calendars)
        #expect(valued.first?.components.regularWagesCents == 800)
    }
}
