import CryptoKit
import Foundation
@testable import PaydayCore

/// Codable mirror of one `Fixtures/<ID>.json` (shape documented in
/// `Fixtures/README.md`). Every collection is optional in the file and
/// non-optional here so a fixture only states what it uses.
struct Fixture: Decodable, Sendable {
    struct Policies: Decodable, Equatable, Sendable {
        var rate: [RatePolicy]
        var calendar: [CalendarPolicy]

        init(rate: [RatePolicy] = [], calendar: [CalendarPolicy] = []) {
            self.rate = rate
            self.calendar = calendar
        }

        private enum CodingKeys: String, CodingKey { case rate, calendar }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rate = try c.decodeIfPresent([RatePolicy].self, forKey: .rate) ?? []
            calendar = try c.decodeIfPresent([CalendarPolicy].self, forKey: .calendar) ?? []
        }
    }

    struct RatePolicy: Decodable, Equatable, Sendable {
        var effectiveFrom: CivilDay
        var hourlyRateCents: Int
        var provenance: RateProvenance
    }

    struct CalendarPolicy: Decodable, Equatable, Sendable {
        var effectiveFrom: CivilDay
        var workweekStartWeekday: Int
        var overtimeThresholdMinutes: Int?
        var overtimeMultiplierHundredths: Int?
        var payrollTimeZone: String
    }

    struct Schedule: Decodable, Equatable, Sendable {
        var frequency: String
        var anchorPeriodEnd: CivilDay
        var payDelayDays: Int?
        var firstWeekday: Int?
    }

    struct Shift: Decodable, Equatable, Sendable {
        var id: UUID
        var workDay: CivilDay
        var period: ShiftPeriodTag?
        var minutesWorked: Int?
        var voluntaryCashCents: Int?
        var voluntaryCreditCents: Int?
        var gratuityFeesCents: Int?
        var tipOutCents: Int?
    }

    /// A legacy `TipEntry` row as stored today. `date` is kept as the raw
    /// string because legacy rows carry a `Date`: N1 and N3 write a full
    /// ISO-8601 timestamp with offset (`2026-09-29T17:30:00-04:00`, which the
    /// migration must reduce to a civil day in the payroll zone; N3's
    /// 23:40 -04:00 row is the whole point of that fixture), N2 writes a bare
    /// `YYYY-MM-DD`. `civilDay(in:)` accepts both.
    struct LegacyEntry: Decodable, Equatable, Sendable {
        var id: UUID
        var shiftID: UUID?
        var date: String
        var amountCents: Int
        var kind: String
        var tipOutCents: Int?
        var hoursWorked: Double?
        var receiptMetricsJSON: String?

        /// The civil day of `date` in `zone`: a bare `YYYY-MM-DD` is returned
        /// as written; an ISO-8601 timestamp is converted through `zone`.
        /// Nil when the string is neither.
        func civilDay(in zone: TimeZone) -> CivilDay? {
            if let day = CivilDay(iso: date) { return day }
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime]
            guard let instant = parser.date(from: date) else { return nil }
            return CivilDay(instant, in: zone)
        }
    }

    /// Paycheck lines are all optional in the file; `toPaycheckInputs()`
    /// insists on the ones `PaycheckInput` requires.
    struct Paycheck: Decodable, Equatable, Sendable {
        var id: UUID?
        var periodStart: CivilDay?
        var periodEnd: CivilDay?
        var paidTipsCents: Int?
        var grossPayCents: Int?
        var netPayCents: Int?
        var regularWagesCents: Int?
        var overtimeWagesCents: Int?
        var gratuityCents: Int?
        var taxesCents: Int?
    }

    var id: String
    var description: String
    var kind: String
    var policies: Policies
    var schedule: Schedule?
    var shifts: [Shift]
    var legacyEntries: [LegacyEntry]
    var paychecks: [Paycheck]
    var asOf: CivilDay?
    var deviceTimeZone: String?
    var expected: [String: JSONValue]
    var notes: String?

    private enum CodingKeys: String, CodingKey {
        case id, description, kind, policies, schedule, shifts, legacyEntries, paychecks,
             asOf, deviceTimeZone, expected, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        policies = try c.decodeIfPresent(Policies.self, forKey: .policies) ?? Policies()
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule)
        shifts = try c.decodeIfPresent([Shift].self, forKey: .shifts) ?? []
        legacyEntries = try c.decodeIfPresent([LegacyEntry].self, forKey: .legacyEntries) ?? []
        paychecks = try c.decodeIfPresent([Paycheck].self, forKey: .paychecks) ?? []
        asOf = try c.decodeIfPresent(CivilDay.self, forKey: .asOf)
        deviceTimeZone = try c.decodeIfPresent(String.self, forKey: .deviceTimeZone)
        expected = try c.decodeIfPresent([String: JSONValue].self, forKey: .expected) ?? [:]
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    // MARK: Conversion to engine inputs

    func toShiftInputs() -> [ShiftInput] {
        shifts.map { s in
            ShiftInput(
                id: s.id,
                workDay: s.workDay,
                period: s.period,
                recordedAt: nil,
                voluntaryCashCents: s.voluntaryCashCents ?? 0,
                voluntaryCreditCents: s.voluntaryCreditCents ?? 0,
                gratuityFeesCents: s.gratuityFeesCents ?? 0,
                tipOutCents: s.tipOutCents,
                minutesWorked: s.minutesWorked
            )
        }
    }

    /// Fixture policies carry no ids; each gets a deterministic UUID derived
    /// from its own CONTENT, not from the fixture id or index. Two fixtures
    /// that declare byte-identical policies therefore get identical policy
    /// ids, which is what lets W3 assert `policiesDigestEqualsW2` and lets its
    /// `ratePolicyID`/`calendarPolicyID` match W2's (the canonical policy line
    /// includes the id, so a fixture-id-derived UUID would make the digests
    /// differ for a reason unrelated to the one input W3 changes). The same
    /// premise holds for T1, M1, C1 and S2, which also share W2's policies.
    func toRatePolicies() -> [PayRatePolicy] {
        policies.rate.map { r in
            PayRatePolicy(
                id: FixtureLoader.deterministicUUID(
                    "policy/rate/\(r.effectiveFrom.iso)/\(r.hourlyRateCents)/\(r.provenance.rawValue)"),
                effectiveFrom: r.effectiveFrom,
                hourlyRateCents: r.hourlyRateCents,
                provenance: r.provenance
            )
        }
    }

    /// Content-derived ids, for the same reason as `toRatePolicies()`. The
    /// defaulted fields are resolved BEFORE hashing so a fixture that spells
    /// out `2400`/`150` and one that omits them get the same id.
    func toCalendarPolicies() throws -> [PayrollCalendarPolicy] {
        try policies.calendar.map { c in
            guard let zone = TimeZone(identifier: c.payrollTimeZone) else {
                throw FixtureLoader.Error.unknownTimeZone(c.payrollTimeZone, fixture: id)
            }
            // `PayrollCalendarPolicy`'s memberwise init takes this as a
            // precondition, so a bad fixture value would trap and abort the
            // whole test run. Reject it here, exactly like the zone above, so
            // one named test fails instead.
            guard PayrollCalendarPolicy.weekdayRange.contains(c.workweekStartWeekday) else {
                throw FixtureLoader.Error.invalidWeekday(c.workweekStartWeekday, fixture: id)
            }
            let threshold = c.overtimeThresholdMinutes ?? 2400
            let multiplier = c.overtimeMultiplierHundredths ?? 150
            return PayrollCalendarPolicy(
                id: FixtureLoader.deterministicUUID(
                    "policy/calendar/\(c.effectiveFrom.iso)/\(c.workweekStartWeekday)/\(threshold)/\(multiplier)/\(zone.identifier)"),
                effectiveFrom: c.effectiveFrom,
                workweekStartWeekday: c.workweekStartWeekday,
                overtimeThresholdMinutes: threshold,
                overtimeMultiplierHundredths: multiplier,
                payrollTimeZone: zone
            )
        }
    }

    func toScheduleInput() -> PayScheduleInput? {
        schedule.map {
            PayScheduleInput(
                frequency: $0.frequency,
                anchorPeriodEnd: $0.anchorPeriodEnd,
                payDelayDays: $0.payDelayDays ?? 0,
                firstWeekday: $0.firstWeekday
            )
        }
    }

    func toPaycheckInputs() throws -> [PaycheckInput] {
        try paychecks.enumerated().map { index, p in
            guard let start = p.periodStart, let end = p.periodEnd, let paid = p.paidTipsCents else {
                throw FixtureLoader.Error.incompletePaycheck(index: index, fixture: id)
            }
            return PaycheckInput(
                id: p.id ?? FixtureLoader.deterministicUUID("\(id)/paycheck/\(index)"),
                periodStart: start,
                periodEnd: end,
                paidTipsCents: paid,
                grossPayCents: p.grossPayCents,
                netPayCents: p.netPayCents,
                regularWagesCents: p.regularWagesCents,
                overtimeWagesCents: p.overtimeWagesCents,
                gratuityCents: p.gratuityCents,
                taxesCents: p.taxesCents
            )
        }
    }

    /// `expected["wrongAnswers"]`, the numbers today's app produces that the
    /// fixture asserts are wrong.
    var wrongAnswers: [String: JSONValue] {
        expected["wrongAnswers"]?.objectValue ?? [:]
    }
}

enum FixtureLoader {
    enum Error: Swift.Error, CustomStringConvertible {
        case missing(id: String)
        case unknownTimeZone(String, fixture: String)
        case invalidWeekday(Int, fixture: String)
        case incompletePaycheck(index: Int, fixture: String)

        var description: String {
            switch self {
            case .missing(let id):
                return "Fixture \(id).json is not in Tests/PaydayCoreTests/Fixtures"
            case .unknownTimeZone(let zone, let fixture):
                return "Fixture \(fixture): unknown payrollTimeZone \(zone)"
            case .invalidWeekday(let weekday, let fixture):
                return "Fixture \(fixture): workweekStartWeekday must be "
                    + "\(PayrollCalendarPolicy.weekdayRange.lowerBound) (Sunday) ... "
                    + "\(PayrollCalendarPolicy.weekdayRange.upperBound) (Saturday), got \(weekday)"
            case .incompletePaycheck(let index, let fixture):
                return "Fixture \(fixture): paycheck #\(index) lacks periodStart/periodEnd/paidTipsCents"
            }
        }
    }

    static let directory = "Fixtures"

    /// Loads `Fixtures/<id>.json` from the test bundle.
    static func load(_ id: String) throws -> Fixture {
        guard let url = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: directory) else {
            throw Error.missing(id: id)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    /// Whether `Fixtures/<id>.json` exists, for tests that should skip
    /// rather than fail while a parallel workflow is still writing fixtures.
    static func exists(_ id: String) -> Bool {
        Bundle.module.url(forResource: id, withExtension: "json", subdirectory: directory) != nil
    }

    /// Every fixture ID present in the bundle, sorted.
    static func availableIDs() -> [String] {
        (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: directory) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != KnownIssues.fileName }
            .sorted()
    }

    /// A UUID derived from `name` via SHA-256 (first 16 bytes), stable across
    /// runs and platforms.
    static func deterministicUUID(_ name: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data(name.utf8)))
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
        ))
    }
}
