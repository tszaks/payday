import Foundation
import Testing
@testable import PaydayCore

/// PR B: a role per shift, a rate per role, and a snapshot that reports one
/// role while the ledger still values the whole workweek. Synthetic round
/// numbers throughout.
@Suite("Roles: a rate per role")
struct RolesTests {
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func day(_ iso: String) -> CivilDay { CivilDay(iso: iso)! }

    /// Workweeks start Sunday; 2026-10-04 is a Sunday.
    static let calendar = PayrollCalendarPolicy(
        id: uuid(900),
        effectiveFrom: day("2026-01-04"),
        workweekStartWeekday: 1,
        payrollTimeZone: TimeZone(identifier: "America/New_York")!
    )

    static let allRoles = PayRatePolicy(
        id: uuid(901), effectiveFrom: day("2026-01-01"), hourlyRateCents: 800, provenance: .confirmed)
    static let bar = PayRatePolicy(
        id: uuid(902), effectiveFrom: day("2026-01-01"), hourlyRateCents: 1000, provenance: .confirmed,
        roleName: "Bar")
    static let floor = PayRatePolicy(
        id: uuid(903), effectiveFrom: day("2026-01-01"), hourlyRateCents: 500, provenance: .confirmed,
        roleName: "Floor")
    static let rates = [allRoles, bar, floor]

    static func shift(_ n: Int, _ iso: String, hours: Int, role: String?) -> ShiftInput {
        ShiftInput(id: uuid(n), workDay: day(iso), voluntaryCashCents: 1000, minutesWorked: hours * 60,
                   roleName: role)
    }

    /// The two-role week: 25 bar hours, 20 floor hours, and 5 hours as a
    /// "host" role with no rate of its own. 50 hours, so the last 10 are
    /// overtime, and they fall on a bar shift (5) and the host shift (5).
    static let week: [ShiftInput] = [
        shift(1, "2026-10-05", hours: 10, role: "Bar"),
        shift(2, "2026-10-06", hours: 10, role: "Floor"),
        shift(3, "2026-10-07", hours: 10, role: "bar "),   // case and space do not matter
        shift(4, "2026-10-08", hours: 10, role: "Floor"),  // 40 hours here
        shift(5, "2026-10-09", hours: 5, role: "Bar"),     // 5 overtime hours at the bar rate
        shift(6, "2026-10-10", hours: 5, role: "Host"),    // no Host rate: the all-roles rate
    ]

    static func valuation(_ n: Int, in valuations: [ShiftValuation]) -> ShiftValuation {
        valuations.first { $0.id == uuid(n) }!
    }

    @Test("each shift is paid at its role's rate; overtime runs across roles")
    func twoRoleWeek() {
        let v = CompensationLedger.value(Self.week, rates: Self.rates, calendars: [Self.calendar])
        #expect(Self.valuation(1, in: v).components.regularWagesCents == 10_000)
        #expect(Self.valuation(2, in: v).components.regularWagesCents == 5_000)
        #expect(Self.valuation(3, in: v).components.regularWagesCents == 10_000)
        #expect(Self.valuation(4, in: v).components.regularWagesCents == 5_000)
        #expect(Self.valuation(5, in: v).components.overtimeWagesCents == 7_500)
        #expect(Self.valuation(5, in: v).components.regularWagesCents == 0)
        #expect(Self.valuation(6, in: v).components.overtimeWagesCents == 6_000)
        #expect(Self.valuation(6, in: v).ratePolicyID == Self.allRoles.id)
        #expect(Self.valuation(3, in: v).ratePolicyID == Self.bar.id)
        #expect(v.reduce(0) { $0 + $1.components.wagesCents } == 43_500)
    }

    @Test("a shift with no role ignores role rates")
    func noRoleUsesAllRoles() {
        let plain = Self.shift(10, "2026-10-05", hours: 4, role: nil)
        #expect(CompensationLedger.ratePolicy(in: Self.rates, for: plain)?.id == Self.allRoles.id)
        // Only role rates: a role-less shift has no rate at all.
        #expect(CompensationLedger.ratePolicy(in: [Self.bar], for: plain) == nil)
    }

    @Test("a role rate wins over the all-roles rate only once it takes effect")
    func roleRateEffectiveDates() {
        let lateBar = PayRatePolicy(
            id: Self.uuid(904), effectiveFrom: Self.day("2026-10-07"), hourlyRateCents: 1200,
            provenance: .confirmed, roleName: "BAR")
        let rates = [Self.allRoles, lateBar].sorted(by: CompensationLedger.ratePolicyOrder)
        let before = Self.shift(11, "2026-10-06", hours: 1, role: "bar")
        let after = Self.shift(12, "2026-10-08", hours: 1, role: "bar")
        #expect(CompensationLedger.ratePolicy(in: rates, for: before)?.id == Self.allRoles.id)
        #expect(CompensationLedger.ratePolicy(in: rates, for: after)?.id == lateBar.id)
    }

    @Test("an account with no roles prices exactly as before")
    func noRolesUnchanged() {
        let plain = Self.week.map { s -> ShiftInput in var c = s; c.roleName = nil; return c }
        let v = CompensationLedger.value(plain, rates: [Self.allRoles], calendars: [Self.calendar])
        // 40h x $8 + 10h x $12.
        #expect(v.reduce(0) { $0 + $1.components.wagesCents } == 32_000 + 12_000)
    }

    @Test("bar view + floor view + host view = All, to the cent, across an overtime week")
    func subsetsSumToAll() throws {
        func snapshot(_ reported: Set<UUID>?) throws -> EarningsSnapshot {
            try EarningsSnapshot.build(EarningsInputs(
                shifts: Self.week, rates: Self.rates, calendars: [Self.calendar],
                asOf: Self.day("2026-12-31"), reportedShiftIDs: reported))
        }
        let range = DayRange(start: Self.day("2026-10-04"), end: Self.day("2026-10-10"))
        let all = try snapshot(nil).range(range)
        let barIDs: Set = [Self.uuid(1), Self.uuid(3), Self.uuid(5)]
        let floorIDs: Set = [Self.uuid(2), Self.uuid(4)]
        let bar = try snapshot(barIDs).range(range)
        let floor = try snapshot(floorIDs).range(range)
        let host = try snapshot([Self.uuid(6)]).range(range)

        // The bar view carries the overtime that fell on its own shift.
        #expect(bar.knownComponents.overtimeWagesCents == 7_500)
        #expect(bar.knownComponents.wagesCents == 27_500)
        #expect(floor.knownComponents.wagesCents == 10_000)
        #expect(floor.knownComponents.overtimeWagesCents == 0)
        #expect(bar.knownComponents + floor.knownComponents + host.knownComponents == all.knownComponents)
        #expect(bar.minutes + floor.minutes + host.minutes == all.minutes)
        #expect(bar.overtimeMinutes == 300)
        #expect(bar.shiftIDs.count == 3)
        #expect(Set(bar.shiftIDs) == barIDs)
    }

    @Test("a subset snapshot has its own digest; the whole one is unchanged")
    func subsetDigest() throws {
        let inputs = EarningsInputs(shifts: Self.week, rates: Self.rates, calendars: [Self.calendar],
                                    asOf: Self.day("2026-12-31"))
        var subset = inputs
        subset.reportedShiftIDs = [Self.uuid(1)]
        let whole = try inputs.manifest()
        #expect(try subset.manifest().digest != whole.digest)
        #expect(!(try InputManifest.canonicalText(
            shifts: Self.week, rates: Self.rates, calendars: [Self.calendar],
            asOf: Self.day("2026-12-31"))).contains("reported|"))
        #expect(whole.reportedShiftCount == nil)
        #expect(try subset.manifest().reportedShiftCount == 1)
    }

    @Test("the digest moves with a role and is unchanged without one")
    func manifestDigest() {
        let id = Self.uuid(20)
        let day = Self.day("2026-10-05")
        let plain = ShiftInput(id: id, workDay: day, voluntaryCashCents: 1000)
        let blank = ShiftInput(id: id, workDay: day, voluntaryCashCents: 1000, roleName: "   ")
        let bar = ShiftInput(id: id, workDay: day, voluntaryCashCents: 1000, roleName: "Bar")
        let pipe = ShiftInput(id: id, workDay: day, voluntaryCashCents: 1000, roleName: "Bar|1\n")
        let lines = InputManifest.Canonical.shiftLines
        #expect(lines([plain]) == lines([blank]))
        #expect(lines([plain])[0] == "S|\(id.uuidString)|2026-10-05|-|-|1000|0|0|0|-")
        #expect(lines([bar])[0] == lines([plain])[0] + "|role=Bar")
        #expect(!lines([pipe])[0].dropFirst().contains("\n"))
        #expect(lines([pipe])[0].components(separatedBy: "|").count == 11)

        let rate = InputManifest.Canonical.rateLines
        #expect(!rate([Self.allRoles])[0].contains("role="))
        #expect(rate([Self.bar])[0].hasSuffix("|role=Bar"))
    }

    @Test("PayRatePolicy round-trips with and without a role; old JSON decodes")
    func codable() throws {
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000901","effectiveFrom":"2026-01-01","hourlyRateCents":800,"provenance":"confirmed"}"#
        let decoded = try JSONDecoder().decode(PayRatePolicy.self, from: Data(legacy.utf8))
        #expect(decoded.roleName == nil)
        #expect(decoded.hourlyRateCents == 800)

        let plainJSON = String(decoding: try JSONEncoder().encode(Self.allRoles), as: UTF8.self)
        #expect(!plainJSON.contains("roleName"))
        #expect(try JSONDecoder().decode(PayRatePolicy.self, from: Data(plainJSON.utf8)) == Self.allRoles)

        let barData = try JSONEncoder().encode(Self.bar)
        #expect(String(decoding: barData, as: UTF8.self).contains(#""roleName":"Bar""#))
        #expect(try JSONDecoder().decode(PayRatePolicy.self, from: barData) == Self.bar)
    }

    @Test("the cap counts Unicode scalars, the server's unit, on character boundaries")
    func capCountsScalars() {
        // One chef emoji is three scalars (woman, joiner, cook): 14 of them
        // are 14 Swift characters but 42 code points, which Postgres would
        // cut to 40 and break the match with the role's rate policy.
        let chef = "\u{1F469}\u{200D}\u{1F373}"
        #expect(chef.unicodeScalars.count == 3)
        let fourteen = String(repeating: chef, count: 14)
        let capped = ShiftRole.normalized(fourteen)
        #expect(capped == String(repeating: chef, count: 13))
        #expect(capped!.unicodeScalars.count == 39)
        // Plain text is capped at 40 as before.
        #expect(ShiftRole.normalized(String(repeating: "a", count: 41)) == String(repeating: "a", count: 40))
        #expect(ShiftRole.capped("abc") == "abc")
    }

    @Test("role names are trimmed, capped at 40, nil when empty; keys ignore case")
    func normalization() {
        #expect(ShiftRole.normalized("  Bar  ") == "Bar")
        #expect(ShiftRole.normalized("   ") == nil)
        #expect(ShiftRole.normalized(nil) == nil)
        #expect(ShiftRole.normalized(String(repeating: "x", count: 50))?.count == 40)
        #expect(ShiftRole.key(" BAR") == ShiftRole.key("bar"))
    }
}
