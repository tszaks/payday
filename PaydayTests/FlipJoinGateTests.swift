import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// A required gate for the writer-flip PR, written ahead of it so the
/// property is known rather than discovered.
///
/// `DayDetailSheet` renders its rows as
/// `dayResult.shiftIDs.compactMap { groupsByID[$0] }`. That is a JOIN: the
/// snapshot supplies ids, the grouping supplies rows, and `compactMap`
/// SILENTLY DROPS any id with no matching group. So a day can legitimately
/// show a total while rendering fewer rows than the total is made of, and
/// nothing would say so — the screen would simply look like a quiet day with
/// a suspiciously large number on it.
///
/// After the flip the snapshot is built from `ShiftRecord` while the rows come
/// from the projection, so the join key has to hold across that boundary. This
/// asserts it does, on the shape most likely to break it: several shifts on
/// one day, including one with no tips at all.
@Suite("Flip join gate")
@MainActor
struct FlipJoinGateTests {

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
                id: PolicyMigration.deterministicID("flipjoin/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 283,
                provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("flipjoin/calendar"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: zone
            )]
        )
    }

    /// The join must be total: every id the snapshot reports for a day has a
    /// row group, and the groups for that day are exactly those ids.
    @Test("a day with a total renders every one of its shifts, none dropped")
    func aDayWithATotalDropsNoRows() throws {
        let policies = Self.policies()
        let today = Self.day(0)

        // Three shifts on one day. The third is WAGE-ONLY: hours, no tips.
        // That is the case the shipped writer used to drop entirely, so it is
        // the one most likely to vanish from a join.
        let lunch = ShiftRecord(
            workDate: today, shiftPeriod: .lunch,
            cashTipsCents: 2_200, creditTipsCents: 3_100,
            tipOutCents: 400, hoursWorked: 4.25, recordedAt: today
        )
        let dinner = ShiftRecord(
            workDate: today, shiftPeriod: .dinner,
            cashTipsCents: 5_600, creditTipsCents: 9_900,
            hoursWorked: 5.5, recordedAt: today.addingTimeInterval(3_600)
        )
        let wageOnly = ShiftRecord(
            workDate: today,
            hoursWorked: 3, recordedAt: today.addingTimeInterval(7_200)
        )
        let records = [lunch, dinner, wageOnly]

        // The flip's shape: snapshot from ShiftRecord, rows from the
        // projection grouped by the app's one grouping rule.
        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        let snapshot = try EarningsSnapshot.build(EarningsInputs(
            shifts: adapted.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            asOf: CivilDay(Self.day(1), in: Self.zone)
        ))

        let projected = records.flatMap { ShiftProjection.rows(for: $0) }
        let groups = ShiftDays.groupedByShift(
            projected,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: CalendarEarnings.groupingCalendar(payrollTimeZone: Self.zone)
        )
        let groupsByID = Dictionary(
            groups.map { ($0.shiftID, $0) }, uniquingKeysWith: { a, _ in a }
        )

        let civil = CivilDay(today, in: Self.zone)
        let dayResult = snapshot.day(civil)

        // The total is real, so this is not a join over an empty day.
        #expect(dayResult.knownComponents.earnedIncomeCents > 0)
        #expect(dayResult.shiftIDs.count == 3, "the snapshot must see all three shifts")

        // THE GATE: the compactMap drops nothing.
        let rendered = dayResult.shiftIDs.compactMap { groupsByID[$0] }
        #expect(rendered.count == dayResult.shiftIDs.count,
                "compactMap dropped \(dayResult.shiftIDs.count - rendered.count) of \(dayResult.shiftIDs.count) rows")

        // And the ids really are the record ids, both directions, so the join
        // is total rather than coincidentally equal in count.
        #expect(Set(dayResult.shiftIDs) == Set(records.map(\.id)))
        #expect(Set(groupsByID.keys).isSuperset(of: Set(dayResult.shiftIDs)))

        // The wage-only shift is present, which is the one a join or a writer
        // is most likely to lose.
        #expect(dayResult.shiftIDs.contains(wageOnly.id))
        #expect(groupsByID[wageOnly.id] != nil)
    }
}
