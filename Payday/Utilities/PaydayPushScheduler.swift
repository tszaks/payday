import Foundation
import UserNotifications

/// The app's namesake moment, off the lock screen: one local notification on
/// payday morning carrying **the same number the Dashboard's payday card
/// shows**, tapping straight into the current period's detail where the stub
/// gets verified. Same restraint discipline as SmartNudgeScheduler: exactly
/// one pending request at a time, always fully replaced on reschedule, never
/// more.
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
@MainActor
enum PaydayPushScheduler {
    nonisolated static let notificationIdentifier = "payday-moment"
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
    }

    /// Called from the same lifecycle moments SmartNudgeScheduler is: the
    /// app coming to the foreground, after every tip log (sheet, backfill,
    /// or Siri) — and, uniquely to this reminder, right after a paycheck
    /// gets recorded, since a verified period has nothing left to announce.
    static func reschedule(preferencesStore: UserPreferencesStore, schedule: PaySchedule?, allEntries: [TipEntry], paycheckRecords: [PaycheckRecord]) {
        Task {
            await performReschedule(preferencesStore: preferencesStore, schedule: schedule, allEntries: allEntries, paycheckRecords: paycheckRecords)
        }
    }

    private static func performReschedule(preferencesStore: UserPreferencesStore, schedule: PaySchedule?, allEntries: [TipEntry], paycheckRecords: [PaycheckRecord]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])

        // Read from the store's own suite, the same way the payroll zone
        // already is, so no caller's signature changes and every call site
        // hands over one policy source rather than seven. `PolicyStore.apply`
        // persists before it posts, and every reschedule trigger runs after
        // the edit that caused it, so this is the same value the screens hold.
        let policies = PolicyStore.storedPolicies()
        let payrollTimeZone = policies.payrollTimeZone ?? .current
        let calculator = PayPeriodCalculator(payrollTimeZone: payrollTimeZone, schedule: schedule ?? .fallback)
        guard let decision = decision(
            now: .now,
            calculator: calculator,
            allEntries: allEntries,
            paycheckRecords: paycheckRecords,
            isReminderEnabled: preferencesStore.isPaydayReminderEnabled,
            policies: policies,
            payrollTimeZone: payrollTimeZone
        ) else { return }

        guard await isCurrentlyAuthorized(center: center) else { return }
        enqueue(decision, center: center)
    }

    /// The rule: fire at 9AM on the payday for whichever period is
    /// currently open — its check hasn't landed yet, so it's always the
    /// right one to announce. Nothing if that moment has already passed,
    /// nothing once that period's paycheck is already on record (verification
    /// is done, there's nothing left to say), and nothing if the reminder is
    /// turned off.
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
        allEntries: [TipEntry],
        paycheckRecords: [PaycheckRecord],
        isReminderEnabled: Bool,
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        calendar: Calendar = .current
    ) -> Decision? {
        guard isReminderEnabled else { return nil }

        var cal = calendar
        cal.timeZone = .current
        let period = calculator.period(containing: now)
        let payDate = calculator.payDate(for: period)
        guard let fireDate = cal.date(bySettingHour: fireHour, minute: 0, second: 0, of: payDate), fireDate > now else { return nil }

        let alreadyRecorded = paycheckRecords.contains {
            cal.isDate($0.periodStart, inSameDayAs: period.start) && cal.isDate($0.periodEnd, inSameDayAs: period.end)
        }
        guard !alreadyRecorded else { return nil }

        // ONE dataset and ONE figure behind the decision. Building it twice —
        // once for the words, once for the value the gate compares — is how a
        // surface comes to hold two snapshots of the same shifts, which is
        // the defect `DashboardEarnings`' header measured at $180.00 over an
        // unavailable row.
        let figure = spokenFigure(
            for: period,
            allEntries: allEntries,
            policies: policies,
            payrollTimeZone: payrollTimeZone
        )
        return Decision(fireDate: fireDate, body: body(for: figure), figure: figure)
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
        allEntries: [TipEntry],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone
    ) -> EarningsFigure? {
        let dataset = DashboardEarnings.build(
            entries: allEntries,
            policies: policies,
            payrollTimeZone: payrollTimeZone,
            calendar: PayrollCalendar.gridCalendar(in: payrollTimeZone)
        )
        guard let snapshot = dataset.snapshot else { return nil }
        let result = snapshot.range(DayRange(
            start: CivilDay(period.start, in: payrollTimeZone),
            end: CivilDay(period.end, in: payrollTimeZone)
        ))
        // Gate 3: no credit tips logged at all. See the type header.
        guard result.knownComponents.voluntaryCreditCents > 0 else { return nil }
        // Gate 2: `.partial` has no room for its caption here.
        if case .partial = result.completeness.state { return nil }
        return PredictedPaycheck.figure(from: result)
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

    private static func enqueue(_ decision: Decision, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Payday."
        content.body = decision.body
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: decision.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        center.add(request)
    }
}
