import Foundation
import UserNotifications

/// The app's namesake moment, off the lock screen: one local notification on
/// payday morning carrying the same predicted tips-line number the app
/// itself shows, tapping straight into the current period's detail where
/// the stub gets verified. Same restraint discipline as SmartNudgeScheduler:
/// exactly one pending request at a time, always fully replaced on
/// reschedule, never more.
@MainActor
enum PaydayPushScheduler {
    nonisolated static let notificationIdentifier = "payday-moment"
    private nonisolated static let fireHour = 9

    /// What should be posted, computed purely from a schedule, this app's
    /// history, and the reminder preference — no UNUserNotificationCenter,
    /// no Date.now baked in, so the decision is unit-testable on its own.
    struct Decision: Equatable {
        let fireDate: Date
        let body: String
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

        let calculator = PayPeriodCalculator(schedule: schedule ?? .fallback)
        guard let decision = decision(
            now: .now,
            calculator: calculator,
            allEntries: allEntries,
            paycheckRecords: paycheckRecords,
            isReminderEnabled: preferencesStore.isPaydayReminderEnabled
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
    nonisolated static func decision(
        now: Date,
        calculator: PayPeriodCalculator,
        allEntries: [TipEntry],
        paycheckRecords: [PaycheckRecord],
        isReminderEnabled: Bool,
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

        let periodEntries = allEntries.filter { $0.date >= period.start && $0.date <= period.end }
        let breakdown = TipBreakdown.total(of: periodEntries)
        // The tips LINE, not the whole check: this is the figure the person is
        // about to compare against a stub, and a stub prints tips and wages on
        // separate lines. Net of tip-out, same as every other surface.
        let body: String
        if PredictedPaycheck.hasCreditTips(breakdown) {
            let tips = Money.string(fromCents: PredictedPaycheck.tipsLineCents(from: breakdown))
            if breakdown.gratuityFeesCents > 0 {
                body = "Your stub should show about \(tips) in tips and \(Money.string(fromCents: breakdown.gratuityFeesCents)) in gratuity."
            } else {
                body = "Your check's tips line should read about \(tips)."
            }
        } else {
            body = "Your check lands today. Open Payday to check the period."
        }
        return Decision(fireDate: fireDate, body: body)
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
