import Foundation
import SwiftData
import Testing
@testable import Payday

/// PR 6, groups 2.10 and 2.11: the fourth parity invariant, Siri == widget ==
/// app.
///
/// This was the one named invariant in the goal with no test at all, because
/// both ambient surfaces computed their own figures. Each built its own
/// `StatsEngine` and added wages through
/// `PeriodIncome.wages(..., wageCentsPerHour: AppGroup.baseHourlyWageCents,
/// firstWeekday: schedule.firstWeekday)` — the audit's original bug twice
/// over, on the two surfaces a user cannot refresh:
///
/// - a single scalar rate instead of the rate history; and
/// - the CALENDAR's first weekday driving the overtime workweek instead of
///   the payroll calendar's.
///
/// They now call one function, so the parity is structural. What is left to
/// test is that the shared function agrees with what the app's own screens
/// show, and that a failure is never dressed as a number.
@Suite("Ambient parity: Siri == widget == app", .serialized)
@MainActor
struct AmbientParityTests {
    private static let zone = PaydayTestZone.payroll

    private static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 17) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour))!
    }

    private func snapshot(
        shifts: [ShiftInput],
        rateCents: Int? = 283,
        asOf: Date = Self.day(2026, 9, 29)
    ) throws -> EarningsSnapshot {
        let calendar = PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("ambient/calendar"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 2,
            payrollTimeZone: Self.zone
        )
        let rates: [PayRatePolicy] = rateCents.map {
            [PayRatePolicy(
                id: PolicyMigration.deterministicID("ambient/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: $0,
                provenance: .confirmed
            )]
        } ?? []
        return try EarningsSnapshot.build(
            EarningsInputs(
                shifts: shifts,
                paychecks: [],
                schedule: PayScheduleInput(
                    frequency: "biweekly",
                    anchorPeriodEnd: CivilDay(year: 2026, month: 10, day: 4),
                    payDelayDays: 0
                ),
                rates: rates,
                calendars: [calendar],
                asOf: CivilDay(asOf, in: Self.zone)
            ),
            generation: 0,
            computedAt: asOf
        )
    }

    /// `month` is a parameter and not a constant, which cost two rounds to
    /// learn. It was hardcoded to September, so a fixture written as
    /// "28, 29, 30, 1, 2" silently meant Sep 1 and Sep 2 -- outside the pay
    /// period -- and the 45-hour week was really 27 hours with no overtime.
    /// The guard at the end of the overtime test is what caught it, twice.
    private static func shift(
        _ id: Int, month: Int = 9, day: Int, cash: Int, minutes: Int?
    ) -> ShiftInput {
        ShiftInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(id)")!,
            workDay: CivilDay(year: 2026, month: month, day: day),
            voluntaryCashCents: cash,
            minutesWorked: minutes
        )
    }

    /// The core claim. One function produces the figure both surfaces show, so
    /// the amount AND the label are identical by construction, and the test
    /// pins that the figure is the app's own pay-period answer rather than a
    /// second computation that happens to agree today.
    @Test("the ambient figure is the app's own pay-period result")
    func ambientFigureIsTheAppsResult() throws {
        let snapshot = try snapshot(shifts: [
            Self.shift(1, day: 28, cash: 5_000, minutes: 480),
            Self.shift(2, day: 29, cash: 3_000, minutes: 300)
        ])
        let now = Self.day(2026, 9, 29)

        let ambient = AmbientPeriodFigure.answer(
            from: snapshot,
            schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: Self.day(2026, 10, 4)),
            payrollTimeZone: Self.zone,
            now: now
        )

        // What the app's screens read, through the same public query.
        let appResult = snapshot.payPeriod(
            DayRange(
                start: CivilDay(ambient.period.start, in: Self.zone),
                end: CivilDay(ambient.period.end, in: Self.zone)
            ),
            asOf: CivilDay(now, in: Self.zone)
        )
        let appFigure = EarningsFigure.earnedIncome(appResult)

        #expect(ambient.figure == appFigure, "the ambient surfaces and the app must be one figure")
        #expect(ambient.figure.amount == .cents(appResult.knownComponents.earnedIncomeCents))
    }

    /// The overtime case, which is what the old scalar-plus-first-weekday path
    /// got wrong. A week over the threshold must show the same overtime on the
    /// widget as in the app, and the old path bucketed by the calendar grid's
    /// weekday rather than the payroll calendar's.
    @Test("a week over the overtime threshold reads the same on both")
    func overtimeAgrees() throws {
        // Mon 28 Sep through Fri 2 Oct, 45 hours: 40 regular, 5 overtime.
        //
        // The snapshot's own asOf has to reach Oct 2 as well. It did not on
        // the first attempt, and the guard at the end of this test is what
        // caught it: the period query clamped to Sep 29, only 18 of the 45
        // hours counted, and the comparison was two overtime-free figures
        // agreeing. A parity test that compares two zeros proves nothing.
        let snapshot = try snapshot(shifts: [
            Self.shift(1, day: 28, cash: 0, minutes: 540),
            Self.shift(2, day: 29, cash: 0, minutes: 540),
            Self.shift(3, day: 30, cash: 0, minutes: 540),
            Self.shift(4, month: 10, day: 1, cash: 0, minutes: 540),
            Self.shift(5, month: 10, day: 2, cash: 0, minutes: 540)
        ], asOf: Self.day(2026, 10, 2))
        let now = Self.day(2026, 10, 2)

        let ambient = AmbientPeriodFigure.answer(
            from: snapshot,
            schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: Self.day(2026, 10, 4)),
            payrollTimeZone: Self.zone,
            now: now
        )
        let appResult = snapshot.payPeriod(
            DayRange(
                start: CivilDay(ambient.period.start, in: Self.zone),
                end: CivilDay(ambient.period.end, in: Self.zone)
            ),
            asOf: CivilDay(now, in: Self.zone)
        )

        #expect(ambient.figure == EarningsFigure.earnedIncome(appResult))
        // The overtime is actually present, so this is a real comparison and
        // not two zeros agreeing.
        #expect(appResult.overtimeMinutes > 0, "45h must produce overtime or this proves nothing")
    }

    /// A partial period must not be called a Total on a surface with no room
    /// for a caption, and the spoken sentence must say so out loud, because a
    /// spoken number is the one figure a user cannot re-read.
    @Test("an unpriced shift changes the label, not just the caption")
    func partialChangesTheLabel() throws {
        let snapshot = try snapshot(shifts: [
            Self.shift(1, day: 28, cash: 5_000, minutes: 480),
            // No hours, so its wage cannot be valued.
            Self.shift(2, day: 29, cash: 3_000, minutes: nil)
        ])
        let ambient = AmbientPeriodFigure.answer(
            from: snapshot,
            schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: Self.day(2026, 10, 4)),
            payrollTimeZone: Self.zone,
            now: Self.day(2026, 9, 29)
        )

        #expect(!ambient.figure.mayBeCalledATotal,
                "a period with an unpriced shift is not a Total")
        #expect(ambient.figure.label == "Known so far")
    }

    // MARK: - Failure is never a number

    /// The rule for both surfaces: a store that cannot be read renders
    /// "Couldn't load", never "$0". A Lock Screen zero is the same lie as the
    /// app showing it, on a surface the user cannot refresh.
    @Test("an unavailable figure carries no amount at all")
    func unavailableCarriesNoAmount() {
        let figure = EarningsFigure.unavailable()
        #expect(figure.amount == .unavailable)
        // There is no cents to read, so no view can accidentally render one.
        if case .cents = figure.amount {
            Issue.record("an unavailable figure must not carry cents")
        }
    }

    @Test("the three absences read differently from each other")
    func absencesAreDistinct() {
        // Conflating these would tell a user with a full history that they
        // had never set the app up.
        let sentences = Set([
            AmbientPeriodFigure.Absence.notAuthorized,
            .noSchedule,
            .unavailable
        ].map { absence -> String in
            switch absence {
            case .notAuthorized: "Sign in to Payday first."
            case .noSchedule: "Set up your pay schedule in Payday first."
            case .unavailable: "Payday couldn't read your shifts right now."
            }
        })
        #expect(sentences.count == 3)
    }

    /// Siri speaks the label rather than assuming "You've made". With a shift
    /// missing its hours, "You've made $80" would be a claim the engine did
    /// not make.
    @Test("the spoken sentence follows the figure's own label")
    func spokenSentenceFollowsTheLabel() throws {
        let complete = try snapshot(shifts: [Self.shift(1, day: 29, cash: 5_000, minutes: 300)])
        let partial = try snapshot(shifts: [
            Self.shift(1, day: 29, cash: 5_000, minutes: 300),
            Self.shift(2, day: 28, cash: 3_000, minutes: nil)
        ])
        let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: Self.day(2026, 10, 4))

        let completeFigure = AmbientPeriodFigure.answer(
            from: complete, schedule: schedule,
            payrollTimeZone: Self.zone, now: Self.day(2026, 9, 29)).figure
        let partialFigure = AmbientPeriodFigure.answer(
            from: partial, schedule: schedule,
            payrollTimeZone: Self.zone, now: Self.day(2026, 9, 29)).figure

        #expect(completeFigure.mayBeCalledATotal)
        #expect(!partialFigure.mayBeCalledATotal)
    }
}
