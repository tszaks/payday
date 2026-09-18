import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

/// The user's real compensation history, as `PolicyStore` would hold it.
///
/// Never a scalar rate handed to a bridge: that re-stamps as a
/// `.distantPast` `.confirmed` policy and reprices every pre-raise shift at
/// today's rate (MEASURED $520 against the correct $440, wave 0). A nil rate
/// is the wage feature OFF, which is what every legacy expectation in this
/// suite was written under.
private func policies(
    rateCents: Int?,
    workweekStartWeekday: Int = 1,
    provenance: RateProvenance = .confirmed
) -> CompensationPolicies {
    let calendar = PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("push/calendar/\(workweekStartWeekday)"),
        effectiveFrom: .distantPast,
        workweekStartWeekday: workweekStartWeekday,
        payrollTimeZone: PaydayTestZone.payroll
    )
    guard let rateCents else { return CompensationPolicies(rates: [], calendars: [calendar]) }
    return CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("push/rate/\(rateCents)/\(provenance)"),
            effectiveFrom: .distantPast,
            hourlyRateCents: rateCents,
            provenance: provenance
        )],
        calendars: [calendar]
    )
}

@Suite("Payday push scheduling")
struct PaydayPushSchedulerTests {
    // Weekly close on Sunday Jul 19, paid the following Friday (5-day lag) —
    // same shape as PaydayMoment's own weekly-lag fixture.
    private func weeklyPaidFriday() -> PayPeriodCalculator {
        PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.payroll,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 5, firstWeekday: nil)
        )
    }

    private func creditEntry(cents: Int, on day: Date) -> TipEntry {
        TipEntry(date: day, amountCents: cents, kind: .credit)
    }

    private func cashEntry(cents: Int, on day: Date) -> TipEntry {
        TipEntry(date: day, amountCents: cents, kind: .cash)
    }

    /// Every case's call, with the wage feature off unless the case says
    /// otherwise: the policies argument is the ONE policy source and there is
    /// no overload that takes a scalar.
    private func makeDecision(
        now: Date,
        calculator: PayPeriodCalculator? = nil,
        entries: [TipEntry] = [],
        paycheckRecords: [PaycheckRecord] = [],
        isReminderEnabled: Bool = true,
        policies compensation: CompensationPolicies? = nil
    ) -> PaydayPushScheduler.Decision? {
        PaydayPushScheduler.decision(
            now: now,
            calculator: calculator ?? weeklyPaidFriday(),
            allEntries: entries,
            paycheckRecords: paycheckRecords,
            isReminderEnabled: isReminderEnabled,
            policies: compensation ?? policies(rateCents: nil),
            payrollTimeZone: PaydayTestZone.payroll
        )
    }

    @Test("fires at 9AM on the period's payday")
    func firesOnPayday() {
        let decision = makeDecision(
            now: date(2026, 7, 19, hour: 20),
            entries: [creditEntry(cents: 15000, on: date(2026, 7, 15))]
        )
        #expect(decision?.fireDate == date(2026, 7, 24, hour: 9))
    }

    @Test("nothing once the fire moment has already passed")
    func nothingAfterPayday() {
        // No payroll lag: payday is the last day of the period itself, at
        // 9AM — by 2PM that same day the moment is behind, not ahead.
        let sameDay = PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.payroll,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 0, firstWeekday: nil)
        )
        #expect(makeDecision(now: date(2026, 7, 19, hour: 14), calculator: sameDay) == nil)
    }

    @Test("nothing once the period's paycheck is already recorded")
    func nothingWhenAlreadyVerified() {
        let record = PaycheckRecord(periodStart: date(2026, 7, 13), periodEnd: date(2026, 7, 19), paidTipsCents: 15000)
        let decision = makeDecision(
            now: date(2026, 7, 19, hour: 20),
            entries: [creditEntry(cents: 15000, on: date(2026, 7, 15))],
            paycheckRecords: [record]
        )
        #expect(decision == nil)
    }

    @Test("the body speaks the whole pre-tax check, not the tips line alone")
    func bodySpeaksTheWholeCheck() throws {
        // $150 credit + $40 cash, wage feature off. The check carries the
        // credit net of tip-out and never the cash: cash does not run
        // through payroll.
        let entries = [
            creditEntry(cents: 15000, on: date(2026, 7, 15)),
            cashEntry(cents: 4000, on: date(2026, 7, 16))
        ]
        let decision = try #require(makeDecision(now: date(2026, 7, 19, hour: 20), entries: entries))
        #expect(decision.body == "Your check should show about $150.00 before tax. Card tips, gratuity and wages, less tip-out.")
        let figure = try #require(decision.figure)
        #expect(figure.cents == 15_000)
        #expect(figure.metric == .expectedPaycheckGross)
        #expect(figure.label == "Expected")
    }

    /// The old body split the check into "about $X in tips and $Y in
    /// gratuity" — two numbers under one question, and neither of them the
    /// one the Dashboard's payday card shows. MEASURED before this change:
    /// $150.00 and $40.50 spoken separately against the card's $190.50.
    @Test("Toast gratuity is inside the one check figure, not a second clause")
    func gratuityIsInsideTheOneFigure() throws {
        let entry = TipEntry(
            date: date(2026, 7, 15),
            amountCents: 15_000,
            kind: .credit,
            receiptMetrics: ShiftReceiptMetrics(
                earningsSchemaVersion: 2,
                gratuityFeesCents: 4_050
            )
        )
        let decision = try #require(makeDecision(now: date(2026, 7, 19, hour: 20), entries: [entry]))
        #expect(decision.figure?.cents == 19_050)
        #expect(decision.body == "Your check should show about $190.50 before tax. Card tips, gratuity and wages, less tip-out.")
        #expect(!decision.body.contains("in gratuity"))
    }

    @Test("wages are inside the figure once a rate policy exists")
    func wagesAreInsideTheFigure() throws {
        // One 8h shift at $20/hr: $150 credit tips + $160 of wages.
        let entry = TipEntry(
            date: date(2026, 7, 15, hour: 17),
            amountCents: 15_000,
            kind: .credit,
            hoursWorked: 8
        )
        let decision = try #require(makeDecision(
            now: date(2026, 7, 19, hour: 20),
            entries: [entry],
            policies: policies(rateCents: 2_000)
        ))
        #expect(decision.figure?.cents == 15_000 + 16_000)
        #expect(decision.body == "Your check should show about $310.00 before tax. Card tips, gratuity and wages, less tip-out.")
    }

    @Test("an estimated rate carries its caption instead of the basis line")
    func estimatedCarriesItsCaption() throws {
        let entry = TipEntry(
            date: date(2026, 7, 15, hour: 17),
            amountCents: 15_000,
            kind: .credit,
            hoursWorked: 8
        )
        let decision = try #require(makeDecision(
            now: date(2026, 7, 19, hour: 20),
            entries: [entry],
            policies: policies(rateCents: 2_000, provenance: .assumedFromLegacySetting)
        ))
        #expect(decision.figure?.completeness.state == .estimated)
        #expect(decision.body == "Your check should show about $310.00 before tax. Wages estimated from your current rate")
    }

    /// Rule 4, enforced by silence rather than by a placeholder: a
    /// `.partial` figure omits an unpriced shift's wages and a notification
    /// body has nowhere to say so, so it says no number at all. One shift
    /// with hours, one without, both with credit tips.
    @Test("a partial period speaks no figure at all")
    func partialSpeaksNoFigure() throws {
        let withHours = TipEntry(
            date: date(2026, 7, 15, hour: 17),
            amountCents: 15_000,
            kind: .credit,
            hoursWorked: 8
        )
        let withoutHours = creditEntry(cents: 9_000, on: date(2026, 7, 16, hour: 17))
        let decision = try #require(makeDecision(
            now: date(2026, 7, 19, hour: 20),
            entries: [withHours, withoutHours],
            policies: policies(rateCents: 2_000)
        ))
        #expect(decision.figure == nil)
        #expect(decision.body == "Your check lands today. Open Payday to check the period.")
        #expect(!decision.body.contains("$"))
    }

    /// `PredictedPaycheck.tipsLineCents` falls back to ALL voluntary tips
    /// when no credit was logged, so an all-cash period yields a check
    /// expectation made of cash — and cash never runs through payroll. The
    /// gate this file has always had, restated on the engine's own
    /// components.
    @Test("falls back to the plain body when no credit tips were logged")
    func fallbackBodyWithNoCreditTips() throws {
        let decision = try #require(makeDecision(
            now: date(2026, 7, 19, hour: 20),
            entries: [cashEntry(cents: 4000, on: date(2026, 7, 16))]
        ))
        #expect(decision.figure == nil)
        #expect(decision.body == "Your check lands today. Open Payday to check the period.")
    }

    @Test("disabled preference means nothing, regardless of everything else")
    func disabledPreferenceSchedulesNothing() {
        let decision = makeDecision(
            now: date(2026, 7, 19, hour: 20),
            entries: [creditEntry(cents: 15000, on: date(2026, 7, 15))],
            isReminderEnabled: false
        )
        #expect(decision == nil)
    }

    /// A nil snapshot is a refusal, not a zero. Rule 4 on the one surface
    /// with no view to put a placeholder in: no currency text anywhere.
    @Test("no dataset means no currency in the body")
    func noDatasetSpeaksNoCurrency() throws {
        // No calendar policy at all, so the ledger has no workweek to
        // allocate into and every wage reads `.unavailable(.noCalendarPolicy)`
        // — the honest engine answer, and `.partial` for the selection.
        let decision = try #require(makeDecision(
            now: date(2026, 7, 19, hour: 20),
            entries: [TipEntry(
                date: date(2026, 7, 15, hour: 17),
                amountCents: 15_000,
                kind: .credit,
                hoursWorked: 8
            )],
            policies: CompensationPolicies(rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("push/rate/orphan"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 2_000,
                provenance: .confirmed
            )], calendars: [])
        ))
        #expect(decision.figure == nil)
        #expect(!decision.body.contains("$"))
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PR 5 group 2.12 parity: the lock screen and the card it taps into.
// ═══════════════════════════════════════════════════════════════════════════

/// **The notification's figure equals the Dashboard's predicted-paycheck
/// figure for the same period.**
///
/// This is the invariant group 2.12 owes, and it is the whole reason the
/// group exists: the notification is the only place Payday speaks a dollar
/// amount with no screen behind it, so a disagreement between it and the app
/// is invisible until it is on somebody's lock screen.
///
/// **MEASURED on the pre-migration tree, with this fixture:** the body said
/// "Your stub should show about $150.00 in tips and $40.50 in gratuity."
/// while `DashboardFacts.predictedPaycheck.text` for the same period and the
/// same shifts read **$350.50** — the tips line, the gratuity line and the
/// wages, which is what a stub totals to. Two numbers, one question.
///
/// It is asserted against the real adapters on both sides:
/// `DashboardFacts.init` as `DashboardView.body` calls it, and
/// `PaydayPushScheduler.decision` as `performReschedule` calls it. Neither
/// side is restated here, which is the plan's completion rule 2.
@Suite("Payday notification equals the Dashboard payday card")
struct PaydayNotificationParityTests {
    private static let payrollTimeZone = PaydayTestZone.payroll

    /// A weekly period closing Sunday 2026-07-19, paid the following Friday.
    private static func calculator() -> PayPeriodCalculator {
        PayPeriodCalculator(
            payrollTimeZone: payrollTimeZone,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 5, firstWeekday: nil)
        )
    }

    /// One 8h shift at $20/hr with $150 of credit tips and $40.50 of Toast
    /// gratuity: $150.00 tips line + $40.50 gratuity + $160.00 wages.
    private static func entries() -> [TipEntry] {
        [TipEntry(
            date: date(2026, 7, 15, hour: 17),
            amountCents: 15_000,
            kind: .credit,
            hoursWorked: 8,
            receiptMetrics: ShiftReceiptMetrics(
                earningsSchemaVersion: 2,
                gratuityFeesCents: 4_050
            )
        )]
    }

    @Test("the spoken figure is the card's figure, metric, label and cents")
    func notificationFigureEqualsTheDashboardCard() throws {
        let compensation = policies(rateCents: 2_000)
        let entries = Self.entries()
        // 2026-07-19 20:00 is inside the period closing that day, so the
        // scheduler announces it and fires on its payday, 2026-07-24.
        let scheduledAt = date(2026, 7, 19, hour: 20)
        let decision = try #require(PaydayPushScheduler.decision(
            now: scheduledAt,
            calculator: Self.calculator(),
            allEntries: entries,
            paycheckRecords: [],
            isReminderEnabled: true,
            policies: compensation,
            payrollTimeZone: Self.payrollTimeZone
        ))

        // The Dashboard, on the morning the notification fires, with the
        // payday card pinned to that same period.
        let dataset = DashboardEarnings.build(
            entries: entries,
            policies: compensation,
            payrollTimeZone: Self.payrollTimeZone,
            calendar: PayrollCalendar.gridCalendar(in: Self.payrollTimeZone)
        )
        let facts = DashboardFacts(
            snapshot: dataset.snapshot,
            allShifts: dataset.shiftDays,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 5, firstWeekday: nil),
            now: scheduledAt,
            forcedPaydayPhase: .checkDay,
            dismissedClosedEnd: nil,
            dismissedCheckEnd: nil,
            payrollTimeZone: Self.payrollTimeZone
        )

        let spoken = try #require(decision.figure)
        #expect(spoken.cents == 35_050)
        #expect(facts.predictedPaycheck.cents == 35_050)
        #expect(spoken.cents == facts.predictedPaycheck.cents)
        #expect(spoken.metric == facts.predictedPaycheck.metric)
        #expect(spoken.label == facts.predictedPaycheck.label)
        #expect(spoken == facts.predictedPaycheck)

        // And the sentence carries exactly that figure's text, so the
        // parity is one the person can see rather than one the types agree
        // about privately.
        let amount = try #require(facts.predictedPaycheck.text)
        #expect(amount == "$350.50")
        #expect(decision.body.contains(amount))
        #expect(!decision.body.contains("in tips and"))

        // The SUPERSEDED answer, measured with the helper the old body
        // called, and asserted against so a revert is visible here rather
        // than on somebody's lock screen: the tips LINE alone, $150.00,
        // against the $350.50 the card shows for the same period.
        let legacyTipsLine = PredictedPaycheck.tipsLineCents(from: TipBreakdown.total(of: entries))
        #expect(legacyTipsLine == 15_000)
        #expect(Money.string(fromCents: legacyTipsLine) == "$150.00")
        #expect(spoken.cents != legacyTipsLine)
    }

    /// The figure the notification refuses to speak is never a DIFFERENT
    /// figure: it is no figure. A partial period is the case that separates
    /// "one answer and one silence" from "two answers".
    @Test("when the notification stays silent the card still speaks, and nothing contradicts")
    func silenceIsNotADisagreement() throws {
        let compensation = policies(rateCents: 2_000)
        // The same shift, plus one with credit tips and no hours logged.
        let entries = Self.entries() + [TipEntry(
            date: date(2026, 7, 16, hour: 17),
            amountCents: 9_000,
            kind: .credit
        )]
        let scheduledAt = date(2026, 7, 19, hour: 20)
        let decision = try #require(PaydayPushScheduler.decision(
            now: scheduledAt,
            calculator: Self.calculator(),
            allEntries: entries,
            paycheckRecords: [],
            isReminderEnabled: true,
            policies: compensation,
            payrollTimeZone: Self.payrollTimeZone
        ))
        let dataset = DashboardEarnings.build(
            entries: entries,
            policies: compensation,
            payrollTimeZone: Self.payrollTimeZone,
            calendar: PayrollCalendar.gridCalendar(in: Self.payrollTimeZone)
        )
        let facts = DashboardFacts(
            snapshot: dataset.snapshot,
            allShifts: dataset.shiftDays,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 5, firstWeekday: nil),
            now: scheduledAt,
            forcedPaydayPhase: .checkDay,
            dismissedClosedEnd: nil,
            dismissedCheckEnd: nil,
            payrollTimeZone: Self.payrollTimeZone
        )

        #expect(decision.figure == nil)
        #expect(!decision.body.contains("$"))
        // The card does speak, with its caption, because it has room for one.
        // $150 + $90 of credit tips, net of no tip-out, plus $40.50 of
        // gratuity, plus the one priced shift's $160 of wages. The unpriced
        // shift's wages are excluded, which is what `.partial` MEANS.
        #expect(facts.predictedPaycheck.cents == 24_000 + 4_050 + 16_000)
        #expect(facts.predictedPaycheck.caption == "wages missing for 1 shift")
    }
}
