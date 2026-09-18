import Foundation
import Testing
@testable import Payday

@Suite("Render facts performance")
struct RenderFactsPerformanceTests {
    /// These are wall-clock budgets, so they measure the machine as much as the
    /// code. A developer Mac runs them comfortably; GitHub's shared macOS runners
    /// are 20-40% slower and vary run to run, which failed the History budget at
    /// 0.596s against 0.5s on 2026-09-17 while every other gate was green and no
    /// app code had changed (PR 1 touches only Packages/ and docs/).
    ///
    /// Scaling the budget on CI keeps the guard that matters — a real algorithmic
    /// regression is an order of magnitude, not 20% — without turning every pull
    /// request into a coin flip. Deleting or globally loosening the budgets would
    /// have given up the regression signal on a developer machine too, where the
    /// numbers are actually meaningful.
    ///
    /// THE ENVIRONMENT VARIABLE HAS TO BE FORWARDED, AND IT IS NOT AUTOMATIC.
    /// GitHub Actions sets CI=true in the RUNNER's shell, but these tests run in
    /// the host app process on the simulator, which does not inherit the
    /// runner's environment. So from 2026-09-17 until this comment was written
    /// the scaling was dead code: every CI run measured against the unscaled
    /// budget, which is why PR #13 -- a SQL-only slice touching no Swift at all
    /// -- failed here at 0.5406s against 0.5s while its own message printed
    /// "scaled x1.0".
    ///
    /// MEASURED on this simulator, forcing a failure so the message prints the
    /// scale, three ways:
    ///
    ///   xcodebuild ...                          -> scaled x1.0
    ///   CI=true xcodebuild ...                  -> scaled x1.0   (what CI did)
    ///   xcodebuild ... TEST_RUNNER_CI=true      -> scaled x1.0   (a build
    ///                                              setting, not an env var)
    ///   TEST_RUNNER_CI=true xcodebuild ...      -> scaled x4.0
    ///
    /// xcodebuild forwards a SHELL environment variable named TEST_RUNNER_<VAR>
    /// into the test process as <VAR>, with the prefix stripped. The CI workflow
    /// therefore sets TEST_RUNNER_CI on the `xcodebuild test` step. Setting plain
    /// CI, or passing TEST_RUNNER_CI as an xcodebuild argument, silently does
    /// nothing -- and "silently" is the whole problem: the guard still runs, it
    /// just runs at the wrong limit and reports a scale of 1 in a message nobody
    /// reads until it fails.
    static let budgetScale: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 4

    /// Budget in seconds, scaled for the host, with the raw limit kept for the
    /// failure message so a CI failure still reports what it was measured against.
    static func budget(_ seconds: Double) -> Double { seconds * budgetScale }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The policies a Facts struct values with, as `PolicyStore` would hold
    /// them. A calendar policy is not optional furniture here: with none on
    /// file the ledger has no workweek to bucket into and every shift takes
    /// the cheap unbucketed path, which would quietly make this budget
    /// measure the wrong code.
    private func policies(rateCents: Int?, zone: TimeZone) -> CompensationPolicies {
        let calendar = PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("perf/calendar"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 2,
            payrollTimeZone: zone
        )
        guard let rateCents else { return CompensationPolicies(rates: [], calendars: [calendar]) }
        return CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("perf/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: rateCents,
                provenance: .confirmed
            )],
            calendars: [calendar]
        )
    }

    /// PR 5 wave 1 (group 2.2): the calendar no longer reduces the rows, it
    /// values the WHOLE dataset once through the engine and then asks it twice
    /// — `range(month)` for the headline, `days(in: month)` for the tiles.
    /// That is what makes a tile carry the week's overtime, and it is strictly
    /// more work than the old per-day slice, so the budget now covers the
    /// snapshot BUILD (manifest digest over 10,000 rows plus the ledger's
    /// workweek allocation) as well as the month's queries.
    ///
    /// There is no facts cache behind this number. A cache key has to exist
    /// before the value it guards, and the only honest key is the snapshot's
    /// own `stamp` (contract rule 3, which deletes the hand-maintained
    /// `Key`/`dataRevision` pair), which does not exist until the snapshot is
    /// built. So the measurement below is what a month swipe actually costs.
    @Test("calendar values a 10,000-row history and queries one month within an interactive budget")
    func calendarFactsStayFastForLargeHistory() {
        var calendar = Calendar(identifier: .gregorian)
        // One zone for the grid and for the engine: the facts read
        // `calendar.timeZone` to name a tile's civil day, and the snapshot has
        // to be valued in the same zone or a tile and its shift disagree about
        // which day it was.
        let zone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = zone
        let historyStart = date(2000, 1, 1, calendar: calendar)
        let displayedMonth = date(2026, 7, 1, calendar: calendar)
        let entries = (0..<10_000).map { index in
            TipEntry(
                date: calendar.date(byAdding: .day, value: index, to: historyStart)!,
                amountCents: 100,
                recordedAt: historyStart
            )
        }

        let startedAt = Date.timeIntervalSinceReferenceDate
        let facts = CalendarMonthFacts(
            snapshot: CalendarEarnings.snapshot(
                shifts: CalendarEarnings.shiftGroups(entries: entries, payrollTimeZone: zone),
                policies: policies(rateCents: nil, zone: zone),
                payrollTimeZone: zone
            ),
            displayedMonth: displayedMonth,
            calendar: calendar
        )
        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt

        #expect(facts.daysWorkedCount == 31)
        #expect(facts.monthFigure.cents == 3_100)
        #expect(facts.monthFigure.cents == facts.tiles.compactMap(\.figure.cents).reduce(0, +))
        #expect(facts.gridDays.count == 35)
        #expect(elapsed < Self.budget(0.5), "Calendar render facts took \(elapsed) seconds against a 0.5s budget scaled x\(Self.budgetScale)")
    }

    /// The day sheet reads the same whole-dataset snapshot, so it pays the
    /// same build. Measured because it happens on a tap, not on a swipe.
    @Test("the day sheet values a 10,000-row history and queries one day within an interactive budget")
    func dayDetailFactsStayFastForLargeHistory() {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = zone
        let historyStart = date(2000, 1, 1, calendar: calendar)
        let entries = (0..<10_000).map { index in
            TipEntry(
                date: calendar.date(byAdding: .day, value: index, to: historyStart)!,
                amountCents: 100,
                recordedAt: historyStart,
                hoursWorked: 5
            )
        }
        let openedDay = calendar.date(byAdding: .day, value: 9_000, to: historyStart)!

        let startedAt = Date.timeIntervalSinceReferenceDate
        let facts = DayDetailFacts(
            allEntries: entries,
            date: openedDay,
            policies: policies(rateCents: 1_500, zone: zone),
            payrollTimeZone: zone
        )
        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt

        #expect(facts.shifts.count == 1)
        // One 5-hour shift in its own workweek: 7500c of wages plus 100c tips.
        #expect(facts.total.cents == 7_600)
        #expect(elapsed < Self.budget(0.5), "Day detail render facts took \(elapsed) seconds against a 0.5s budget scaled x\(Self.budgetScale)")
    }

    @Test("chart queries 20,000 shifts into 14 bars within an interactive budget")
    func chartFactsStayFastForLargeHistory() throws {
        // PR 5 wave 0: the chart no longer aggregates a caller's tuples, it
        // asks `EarningsSnapshot` once per bar. The budget therefore covers
        // 14 engine queries over a 20,000-shift index rather than one
        // dictionary grouping, and it is the number that matters, because
        // this runs inside a drag.
        let zone = TimeZone(secondsFromGMT: 0)!
        let start = CivilDay(year: 2026, month: 7, day: 1)
        let range = DayRange(start: start, end: CivilDay(year: 2026, month: 7, day: 14))
        let snapshot = try EarningsSnapshot.build(EarningsInputs(
            shifts: (0..<20_000).map { index in
                ShiftInput(
                    id: UUID(),
                    workDay: start.adding(days: index % 14),
                    voluntaryCashCents: 100
                )
            },
            asOf: CivilDay(year: 2026, month: 7, day: 14)
        ))

        let startedAt = Date.timeIntervalSinceReferenceDate
        let facts = EarningsChartFacts(snapshot: snapshot, range: range, timeZone: zone)
        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt

        #expect(facts.points.count == 14)
        #expect(facts.points.reduce(0) { $0 + $1.cents } == 2_000_000)
        // Every bar came out of a query, so the bars and the whole-range
        // answer are the same engine at two scopes rather than two additions.
        #expect(facts.whole?.knownComponents.earnedIncomeCents == 2_000_000)
        #expect(elapsed < Self.budget(0.5), "Chart render facts took \(elapsed) seconds against a 0.5s budget scaled x\(Self.budgetScale)")
    }

    @Test("History partitions a 10,000-row data set within an interactive budget")
    func historyFactsStayFastForLargeHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let historyStart = date(2000, 1, 1, calendar: calendar)
        let now = date(2026, 7, 14, calendar: calendar)
        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: date(2026, 7, 19, calendar: calendar)
        )
        let entries = (0..<10_000).map { index in
            TipEntry(
                date: calendar.date(byAdding: .day, value: index, to: historyStart)!,
                amountCents: 100,
                recordedAt: historyStart
            )
        }
        let period = PayPeriod(
            start: date(2026, 7, 6, calendar: calendar),
            end: date(2026, 7, 19, calendar: calendar)
        )

        let listStartedAt = Date.timeIntervalSinceReferenceDate
        let listFacts = PeriodsPageFacts(
            allEntries: entries,
            paycheckRecords: [],
            schedule: schedule,
            wageCentsPerHour: nil,
            payrollTimeZone: PaydayTestZone.payroll,
            now: now,
            calendar: calendar
        )
        let listElapsed = Date.timeIntervalSinceReferenceDate - listStartedAt

        let detailStartedAt = Date.timeIntervalSinceReferenceDate
        let detailFacts = PeriodDetailFacts(
            allEntries: entries,
            paycheckRecords: [],
            period: period,
            schedule: schedule,
            wageCentsPerHour: nil,
            policies: policies(rateCents: nil, zone: PaydayTestZone.payroll),
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: calendar
        )
        let detailElapsed = Date.timeIntervalSinceReferenceDate - detailStartedAt

        #expect(listFacts.rows.count == 24)
        #expect(listFacts.rows.first?.breakdown.netTotalCents == 1_400)
        #expect(detailFacts.shiftDays.count == 14)
        #expect(detailFacts.heroTotalCents == 1_400)
        #expect(listElapsed < Self.budget(0.5), "History list facts took \(listElapsed) seconds against a 0.5s budget scaled x\(Self.budgetScale)")
        #expect(detailElapsed < Self.budget(0.5), "Period detail facts took \(detailElapsed) seconds against a 0.5s budget scaled x\(Self.budgetScale)")
    }

    @Test("Insights facts, including twelve retrospective forecast engines, stay inside an interactive budget")
    func insightsFactsStayFastForLargeHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let historyStart = date(2020, 1, 1, calendar: calendar)
        // Three shifts a week for five years — a heavy but real career.
        var records: [TipRecord] = []
        for week in 0..<260 {
            for offset in [0, 2, 4] {
                let day = calendar.date(byAdding: .day, value: week * 7 + offset, to: historyStart)!
                records.append(TipRecord(
                    date: day,
                    amountCents: 15_000 + (week % 7) * 300,
                    kind: .credit,
                    isDouble: false,
                    hoursWorked: 6,
                    shiftID: UUID()
                ))
            }
        }
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records, calendar: calendar)
        let now = calendar.date(byAdding: .day, value: 260 * 7, to: historyStart)!

        let startedAt = Date.timeIntervalSinceReferenceDate
        // forecastAccuracy is the expensive one: twelve sub-engines, each
        // rebuilding shiftFacts and walking workRhythm day by day.
        _ = engine.forecastAccuracy(referenceDate: now)
        _ = engine.typicalRanges(referenceDate: now)
        _ = engine.earningTrend(referenceDate: now)
        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt

        #expect(elapsed < Self.budget(1.0), "Insights facts took \(elapsed) seconds over \(records.count) shifts against a 1.0s budget scaled x\(Self.budgetScale)")
    }
}
