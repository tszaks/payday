import Foundation
import UserNotifications

/// The app's namesake moment, off the lock screen: one local notification on
/// payday morning carrying **the same number the Dashboard's payday card
/// shows**, tapping straight into the current period's detail where the stub
/// gets verified. Same restraint discipline as SmartNudgeScheduler: exactly
/// one pending request per identifier, always fully replaced on reschedule,
/// never more. There are two identifiers: the payday moment itself, and one
/// numberless stub nudge two days later if that period's paycheck is still
/// not recorded. Both carry the period in `userInfo` (`periodStart`,
/// `periodEnd`, seconds since 1970) so a tap lands in that period's stub
/// sheet with the scanner started.
///
/// ## PR 5 group 2.12: the one figure spoken with no screen behind it
///
/// This is the only place Payday says a dollar amount where there is no view
/// to carry a label, a caption or a drawer. So it is the one place where two
/// surfaces disagreeing is invisible until it is on somebody's lock screen.
///
/// **It disagreed.** Until this migration the body was
/// `PredictedPaycheck.tipsLineCents(from: TipBreakdown.total(of:))` — the
/// stub's TIPS line, deliberately wage-EXCLUSIVE, with mandatory gratuity
/// split off into a second clause ("about $X in tips and $Y in gratuity").
/// Wave 1 moved the Dashboard's payday card onto
/// `MetricID.expectedPaycheckGross` (`PredictedPaycheck.figure(from:)`),
/// which is tips line **plus gratuity plus wages**, under the sentence "Your
/// check should show". MEASURED on the fixture in
/// `PaydayPushSchedulerTests.notificationFigureEqualsTheDashboardCard`
/// (one 8h shift at $20/hr with $150 credit tips and $40.50 gratuity, one
/// closed weekly period): the lock screen said **$150.00** and the card the
/// tap landed on said **$350.50**, both answering "what will my check show".
/// This file's own header claimed the opposite — "carrying the same predicted
/// tips-line number the app itself shows" — which had quietly become false.
///
/// The reconciliation is the first option of the two: **the notification
/// speaks the Dashboard's figure, not a second metric.** It builds the
/// Dashboard's dataset with the Dashboard's builder
/// (`DashboardEarnings.build`) and formats the Dashboard's figure with the
/// Dashboard's formatter (`PredictedPaycheck.figure(from:)`), so parity is
/// structural: one snapshot, one stamp, one `EarningsResult`, one
/// `EarningsFigure`. There is no second formula here that has to be kept in
/// step, which is why the old "in tips and in gratuity" split is DELETED
/// rather than relabelled — splitting the check back into its lines is the
/// thing `PredictedPaycheck`'s header and the payday card both refuse to do
/// ("One number, so no surface leaves the person adding it up").
///
/// ## When it speaks, and when it stays silent instead
///
/// A notification body cannot carry a caption under a figure, so rule 4 of
/// the adapter contract is enforced by SILENCE rather than by a placeholder:
/// where a screen would render "$X" plus "wages missing for 1 shift", this
/// says nothing about the amount and falls back to the numberless body. One
/// answer and one silence is not two answers; two numbers under one question
/// is. The three gates, in order:
///
/// 1. **No dataset** (`snapshot` nil, or the period is not answerable) —
///    numberless. Never `$0.00` for "Payday could not read your shifts".
/// 2. **`.partial`** — numberless. The figure would omit an unpriced shift's
///    wages and there is nowhere to say so.
/// 3. **No credit tips logged** — numberless, which is the gate this file has
///    always had, now restated on the engine's own components
///    (`voluntaryCreditCents > 0`) rather than on `TipBreakdown`. It matters
///    more than it used to: `PredictedPaycheck.tipsLineCents` falls back to
///    ALL voluntary tips when no credit was logged, so an all-cash period
///    produces a check expectation containing cash, and cash never runs
///    through payroll. The Dashboard card renders that fallback today (group
///    2.1's call, [DB-22]); this refuses to put it on a lock screen.
///
/// `.estimated` DOES speak, because it has a caption that reads as a
/// sentence, and it carries it.
///
/// ## A policy edit is a reschedule trigger, because the figure is policy-dependent
///
/// The old body was `PredictedPaycheck.tipsLineCents`, wage-EXCLUSIVE, so no
/// rate or workweek edit could ever move it and the six reschedule triggers
/// were all shift-shaped (foreground, any log, a paycheck save). The new body
/// includes wages, and `performReschedule` reads
/// `PolicyStore.storedPolicies()`. So a rate edit moves the number — and
/// until this was added, nothing told the pending request.
///
/// MEASURED (`policyEditMovesTheDecision`, one 8h shift on 2026-07-15 with
/// $150.00 of credit tips, weekly period closing 2026-07-19, paid 07-24): the
/// body reads **$150.00** with the wage feature off, **$310.00** once $20/hr
/// is set, and **$350.00** once that is corrected to $25/hr. None of those
/// three edits touched a shift, so on the pre-fix tree the lock screen kept
/// saying $150.00 while the Dashboard card the tap lands on recomputed from
/// `policyStore.policies` on every render. Two totals under one question, on
/// a lock screen, which is the exact defect class this group exists to close.
/// It self-healed on the next `.active` scenePhase, which is why it was a P1
/// and not a P0.
///
/// The trigger lives in `RootView` next to the scenePhase one, observing
/// `PolicyStore.didChange` — the same signal `EarningsStore.triggerNames`
/// carries — so it fires for every policy write there is (`applyRateEdit`,
/// `applyRateChange`, `applyCalendarChange`, `confirmRateHistory`, the
/// launch migration, and a policy arriving from a sync download), rather than
/// for the three the next editor of `PayrollSettingsSection` remembers.
@MainActor
enum PaydayPushScheduler {
    nonisolated static let notificationIdentifier = "payday-moment"
    nonisolated static let stubNudgeIdentifier = "payday-stub-nudge"
    nonisolated static let stubNudgeBody = "Snap your stub and Payday checks it."
    /// Days after payday the stub nudge fires, at the same 9 AM.
    private nonisolated static let stubNudgeOffsetDays = 2
    /// Bound on the walk back from the period containing `now`. A payroll
    /// lag longer than a few periods does not exist; this only stops a
    /// degenerate schedule from walking forever.
    private nonisolated static let maxPeriodsBack = 6
    nonisolated static let periodStartKey = "periodStart"
    nonisolated static let periodEndKey = "periodEnd"
    private nonisolated static let fireHour = 9

    /// What should be posted, computed purely from a schedule, this app's
    /// history, the compensation policies and the reminder preference — no
    /// UNUserNotificationCenter, no Date.now baked in, so the decision is
    /// unit-testable on its own.
    struct Decision: Equatable {
        let fireDate: Date
        let body: String
        /// The figure the body speaks, or nil when it speaks none.
        ///
        /// Carried so the parity gate can compare it to
        /// `DashboardFacts.predictedPaycheck` as a figure — same metric, same
        /// label, same cents — rather than by scraping the sentence. When it
        /// is non-nil, `body` contains `figure.text` and nothing else
        /// currency-shaped.
        let figure: EarningsFigure?
        /// The period announced, carried into `userInfo` for the tap.
        let periodStart: Date
        let periodEnd: Date
    }

    /// The second, numberless nudge for a period whose stub is still not in.
    struct StubNudge: Equatable {
        let fireDate: Date
        let periodStart: Date
        let periodEnd: Date
    }

    /// The pending coalesced reschedule. A burst of triggers costs ONE
    /// ledger pass, and the LAST trigger is the one that wins.
    private static var coalescedReschedule: Task<Void, Never>?

    /// Called from the same lifecycle moments SmartNudgeScheduler is: the
    /// app coming to the foreground, after every tip log (sheet, backfill,
    /// or Siri) — and, uniquely to this reminder, right after a paycheck
    /// gets recorded, since a verified period has nothing left to announce.
    /// Plus, since this figure became policy-dependent, every
    /// `PolicyStore.didChange` (`RootView`, and see the note there).
    ///
    /// **Coalesced on `EarningsStore.debounceNanoseconds`, the same 50 ms and
    /// the same constant `EarningsStore` debounces this app's other
    /// `PolicyStore.didChange` consumer on**, because the policy trigger
    /// arrives PER KEYSTROKE: Settings' "Hourly wage" row calls
    /// `applyRateEdit` on every digit, so typing `2500` is four real policy
    /// edits. Without this, four full `DashboardEarnings.build` passes run on
    /// the MainActor per rate typed — MEASURED at 0.447s each over a
    /// 10,000-row history ([LN-01]'s cost note), so ~1.8s of hitching while
    /// the field is being typed into — and four in-flight tasks each snapshot
    /// the policies BEFORE their `await`, so whichever resumes last enqueues
    /// its own figure. The one that resumed last could be the one holding
    /// `$0.02`. Cancel-and-replace makes the last trigger the last word.
    static func reschedule(preferencesStore: UserPreferencesStore, schedule: PaySchedule?, shiftRecords: [ShiftRecord], paycheckRecords: [PaycheckRecord]) {
        coalescedReschedule?.cancel()
        coalescedReschedule = Task {
            try? await Task.sleep(nanoseconds: EarningsStore.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await performReschedule(preferencesStore: preferencesStore, schedule: schedule, shiftRecords: shiftRecords, paycheckRecords: paycheckRecords)
        }
    }

    private static func performReschedule(preferencesStore: UserPreferencesStore, schedule: PaySchedule?, shiftRecords: [ShiftRecord], paycheckRecords: [PaycheckRecord]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier, stubNudgeIdentifier])

        // Read from the store's own suite, the same way the payroll zone
        // already is, so no caller's signature changes and every call site
        // hands over one policy source rather than seven. `PolicyStore.apply`
        // persists before it posts, and every reschedule trigger runs after
        // the edit that caused it, so this is the same value the screens hold.
        let policies = PolicyStore.storedPolicies()
        let payrollTimeZone = policies.payrollTimeZone ?? .current
        let calculator = PayPeriodCalculator(payrollTimeZone: payrollTimeZone, schedule: schedule ?? .fallback)
        // `ShiftRecord` is a `@Model` and `ShiftInputAdapter` is therefore
        // `@MainActor`, while `decision` and `spokenFigure` are deliberately
        // `nonisolated` so the suite can exercise the rule without a main
        // actor. Adapting here crosses that boundary once, in the one place
        // that is already on the main actor, and everything below it stays
        // value types.
        let shiftInputs = ShiftInputAdapter.adapt(shiftRecords, calendars: policies.calendars)
        let nudge = stubNudge(
            now: .now,
            calculator: calculator,
            paycheckRecords: paycheckRecords,
            isReminderEnabled: preferencesStore.isPaydayReminderEnabled
        )
        let decision = decision(
            now: .now,
            calculator: calculator,
            shiftInputs: shiftInputs,
            paycheckRecords: paycheckRecords,
            isReminderEnabled: preferencesStore.isPaydayReminderEnabled,
            policies: policies,
            payrollTimeZone: payrollTimeZone
        )
        guard decision != nil || nudge != nil else { return }

        guard await isCurrentlyAuthorized(center: center) else { return }
        if let decision {
            enqueue(identifier: notificationIdentifier, body: decision.body, fireDate: decision.fireDate,
                    periodStart: decision.periodStart, periodEnd: decision.periodEnd, center: center)
        }
        if let nudge {
            enqueue(identifier: stubNudgeIdentifier, body: stubNudgeBody, fireDate: nudge.fireDate,
                    periodStart: nudge.periodStart, periodEnd: nudge.periodEnd, center: center)
        }
    }

    /// The rule: fire at 9AM on the payday of the EARLIEST period whose
    /// payday moment is still ahead of `now` and whose paycheck is not yet
    /// recorded. Not simply the period containing `now`: once that period's
    /// end is behind, its check has not landed yet (payday is the end plus
    /// the payroll lag), and announcing the open period instead would drop
    /// the very payday that is coming next. Nothing once every candidate is
    /// recorded (verification is done) and nothing if the reminder is off.
    ///
    /// - Parameters:
    ///   - policies: `PolicyStore.policies`, whole. Never a scalar rate and
    ///     never a scalar weekday: wave 0 measured $520.00/`.complete`
    ///     against the correct $440.00/`.estimated` when a scalar rate became
    ///     a `.distantPast` confirmed policy. The engine does the effective
    ///     dating, and this figure has to be the Dashboard's, which means the
    ///     dataset behind it has to be the Dashboard's too.
    ///   - payrollTimeZone: the FROZEN payroll zone
    ///     (`policies.payrollTimeZone`), which is the zone the shifts are
    ///     grouped in and the zone the period boundaries were laid out in.
    nonisolated static func decision(
        now: Date,
        calculator: PayPeriodCalculator,
        /// The shifts, already adapted to value types by the caller. See
        /// `performReschedule` for why the adaptation happens there.
        shiftInputs: ShiftInputAdapter.Output,
        paycheckRecords: [PaycheckRecord],
        isReminderEnabled: Bool,
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        calendar: Calendar = .current
    ) -> Decision? {
        guard isReminderEnabled,
              let found = nextUnrecordedPeriod(
                  now: now, calculator: calculator, paycheckRecords: paycheckRecords,
                  offsetDays: 0, calendar: calendar
              ) else { return nil }
        let (period, fireDate) = found

        // ONE dataset and ONE figure behind the decision. Building it twice —
        // once for the words, once for the value the gate compares — is how a
        // surface comes to hold two snapshots of the same shifts, which is
        // the defect `DashboardEarnings`' header measured at $180.00 over an
        // unavailable row.
        let figure = spokenFigure(
            for: period,
            shiftInputs: shiftInputs,
            policies: policies,
            payrollTimeZone: payrollTimeZone
        )
        return Decision(fireDate: fireDate, body: body(for: figure), figure: figure,
                        periodStart: period.start, periodEnd: period.end)
    }

    /// The stub nudge: 9 AM two days after the payday of the earliest period
    /// whose nudge moment is still ahead and whose paycheck is not recorded.
    /// Numberless by design, so it needs no dataset.
    nonisolated static func stubNudge(
        now: Date,
        calculator: PayPeriodCalculator,
        paycheckRecords: [PaycheckRecord],
        isReminderEnabled: Bool,
        calendar: Calendar = .current
    ) -> StubNudge? {
        guard isReminderEnabled,
              let found = nextUnrecordedPeriod(
                  now: now, calculator: calculator, paycheckRecords: paycheckRecords,
                  offsetDays: stubNudgeOffsetDays, calendar: calendar
              ) else { return nil }
        let (period, fireDate) = found
        return StubNudge(fireDate: fireDate, periodStart: period.start, periodEnd: period.end)
    }

    /// The shared walk. Candidates are the period containing `now` and the
    /// periods before it, oldest first, whose 9 AM moment (payday plus
    /// `offsetDays`) is still ahead of `now`. The walk back stops at the
    /// first period whose moment is behind, since every earlier one is
    /// behind too. The first unrecorded candidate wins.
    private nonisolated static func nextUnrecordedPeriod(
        now: Date,
        calculator: PayPeriodCalculator,
        paycheckRecords: [PaycheckRecord],
        offsetDays: Int,
        calendar: Calendar
    ) -> (PayPeriod, Date)? {
        var cal = calendar
        cal.timeZone = .current
        func moment(_ period: PayPeriod) -> Date? {
            guard let day = cal.date(byAdding: .day, value: offsetDays, to: calculator.payDate(for: period)) else { return nil }
            return cal.date(bySettingHour: fireHour, minute: 0, second: 0, of: day)
        }

        let current = calculator.period(containing: now)
        var newestFirst: [(PayPeriod, Date)] = []
        for period in [current] + calculator.priorPeriods(before: current, count: maxPeriodsBack) {
            guard let fireDate = moment(period), fireDate > now else { break }
            newestFirst.append((period, fireDate))
        }

        return newestFirst.reversed().first { period, _ in
            !paycheckRecords.contains {
                cal.isDate($0.periodStart, inSameDayAs: period.start) && cal.isDate($0.periodEnd, inSameDayAs: period.end)
            }
        }
    }

    // MARK: - The figure, and the words around it

    /// The body, numberless when `spokenFigure` refused.
    private nonisolated static func body(for figure: EarningsFigure?) -> String {
        guard let figure, let amount = figure.text else {
            return "Your check lands today. Open Payday to check the period."
        }
        // The caption WINS over the basis when there is one: a completeness
        // disclosure outranks restating a formula the person can read in the
        // app, and a lock-screen body that runs to three sentences is a body
        // nobody finishes. Only `.estimated` reaches here with a caption —
        // `.partial` was refused above — and its caption already reads as a
        // sentence. Verbatim, with no terminal period bolted on: the caption
        // is `CompletenessCopy`'s copy and this is not the file that owns
        // it. A screen renders the same string as a caption line, so the
        // wording a person reads on the lock screen and the wording under
        // the figure in the app are the same characters.
        let second = figure.caption ?? "Card tips, gratuity and wages, less tip-out."
        return "Your check should show about \(amount) before tax. \(second)"
    }

    /// `MetricID.expectedPaycheckGross` for `period`, off the Dashboard's own
    /// dataset, or nil when this surface must not speak a number.
    ///
    /// Nothing here adds, subtracts, scales or rounds a cents value. The
    /// snapshot is `DashboardEarnings.build`'s (unclamped, `asOf:
    /// .distantFuture`, whole history so a workweek straddling the period
    /// boundary keeps its overtime), the query is one `range(_:)` over the
    /// period's civil days, and the figure is `PredictedPaycheck.figure`.
    ///
    /// No `asOf` argument at the query site, and that is not an omission: the
    /// period being announced is the one whose CHECK lands, so by the time
    /// this fires `now` is past its end and a to-date clamp would be a no-op
    /// that only looks like a scope. It is the same reason Dashboard's payday
    /// card takes no cutoff while its hero does.
    private nonisolated static func spokenFigure(
        for period: PayPeriod,
        shiftInputs: ShiftInputAdapter.Output,
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone
    ) -> EarningsFigure? {
        // The figure a person HEARS has to be the figure the app SHOWS. A
        // push that speaks a number from a different source than Dashboard
        // reads is the same disagreement as two screens disagreeing, except
        // the person cannot open the number to check it.
        // The same inputs, rates, calendars and unclamped `asOf`
        // `DashboardEarnings.build(records:)` uses, so the notification
        // and the card cannot price the period differently.
        let snapshotOrNil = try? EarningsSnapshot.build(EarningsInputs(
            shifts: shiftInputs.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            asOf: CivilDay(.distantFuture, in: payrollTimeZone),
            unreadableReceiptShiftIDs: shiftInputs.unreadableReceiptShiftIDs
        ))
        guard let snapshot = snapshotOrNil else { return nil }
        let result = snapshot.range(DayRange(
            start: CivilDay(period.start, in: payrollTimeZone),
            end: CivilDay(period.end, in: payrollTimeZone)
        ))
        // Gate 3: no credit tips logged at all. See the type header.
        guard result.knownComponents.voluntaryCreditCents > 0 else { return nil }
        // Gate 2: `.partial` has no room for its caption here.
        if case .partial = result.completeness.state { return nil }
        // The same payout setting every on-screen check uses.
        return PaycheckReconciler.Expectation(
            result: result, stamp: nil,
            cardTipsOnCheck: !UserPreferencesStore.storedCardTipsPaidAtClose()
        ).grossFigure
    }

    /// Read-only status check — never prompts. Notification permission is
    /// SmartNudgeScheduler's job alone; this never asks.
    private static func isCurrentlyAuthorized(center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    private static func enqueue(identifier: String, body: String, fireDate: Date, periodStart: Date, periodEnd: Date, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Payday."
        content.body = body
        content.sound = .default
        content.userInfo = [
            periodStartKey: periodStart.timeIntervalSince1970,
            periodEndKey: periodEnd.timeIntervalSince1970
        ]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request)
    }
}
