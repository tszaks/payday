import EventKit
import Foundation
import UserNotifications

/// "How was your shift?" — the one smart nudge PRODUCT.md asks for. Learned
/// from history, never configured beyond an off-switch: if today (or the
/// next usual work night) hasn't been logged by ~45 minutes past the
/// typical log time, one local notification deep-links to the log sheet.
/// Never more than one pending at a time — every reschedule call clears
/// and replaces whatever was already scheduled under the same identifier.
@MainActor
enum SmartNudgeScheduler {
    static let notificationIdentifier = "com.szakacsmedia.payday.smartNudge"
    private static let minutesPastTypicalHour = 45

    /// Called whenever there's a natural moment to re-check: the app
    /// coming to the foreground, and right after every tip log (sheet or
    /// Siri) — logging tonight is exactly what should cancel tonight's
    /// nudge and queue up the next usual night's instead. Deliberately
    /// never prompts for permission itself — only schedules if
    /// authorization is ALREADY granted. Asking is a separate, explicit
    /// call (requestAuthorizationIfNeeded below) made only at a moment of
    /// actual relevant value, never on launch.
    static func reschedule(preferencesStore: UserPreferencesStore, allEntries: [TipEntry]) {
        Task {
            await performReschedule(preferencesStore: preferencesStore, allEntries: allEntries)
        }
    }

    private static func performReschedule(preferencesStore: UserPreferencesStore, allEntries: [TipEntry]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        guard preferencesStore.isSmartNudgeEnabled else { return }

        let alreadyLoggedToday = allEntries.contains { Calendar.current.isDateInToday($0.date) }
        guard let fireDate = workScheduleFireDate(preferencesStore: preferencesStore, alreadyLoggedToday: alreadyLoggedToday)
            ?? rhythmFireDate(allEntries: allEntries)
        else { return }

        guard await isCurrentlyAuthorized(center: center) else { return }
        schedule(at: fireDate, center: center)
    }

    /// The designated-work-calendar fire date, upgrading this same nudge's
    /// timing to the end of the posted shift instead of the learned
    /// typical-hour heuristic — still ONE notification identifier, ONE
    /// piece of content, same permission gating below. Nil whenever the
    /// feature is off, calendar access isn't authorized, the calendar's
    /// gone, or it simply has nothing usable in the next 7 days — any of
    /// those silently hand back to rhythmFireDate below, since a broken
    /// calendar must never break the nudge.
    private static func workScheduleFireDate(preferencesStore: UserPreferencesStore, alreadyLoggedToday: Bool, now: Date = .now) -> Date? {
        guard let calendarIdentifier = preferencesStore.workCalendarIdentifier else { return nil }
        let calendarStore = WorkCalendarStore()
        guard calendarStore.authorizationStatus == .fullAccess else { return nil }
        guard let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now) else { return nil }
        guard let shifts = calendarStore.scheduledShifts(calendarIdentifier: calendarIdentifier, keyword: preferencesStore.workCalendarKeyword, from: now, to: horizon) else { return nil }
        return WorkScheduleNudge.fireDate(shifts: shifts, now: now, alreadyLoggedToday: alreadyLoggedToday)
    }

    /// The learned typical-hour heuristic — exactly today's behavior,
    /// unchanged, now just factored out so the designated-calendar path
    /// above can take priority when it has something usable.
    private static func rhythmFireDate(allEntries: [TipEntry]) -> Date? {
        let engine = StatsEngine(records: allEntries.map(TipRecord.init))
        let rhythm = engine.workRhythm()
        guard !rhythm.usualWeekdays.isEmpty, let typicalLogHour = rhythm.typicalLogHour else { return nil }
        return nextFireDate(usualWeekdays: rhythm.usualWeekdays, typicalLogHour: typicalLogHour, allEntries: allEntries)
    }

    /// The next moment worth nudging: today if it's a usual night, the
    /// time hasn't passed, and nothing's logged yet — otherwise the next
    /// usual weekday after today, no "already logged" check needed since
    /// that day hasn't happened yet.
    private static func nextFireDate(usualWeekdays: Set<Int>, typicalLogHour: Int, allEntries: [TipEntry], from now: Date = .now) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        for dayOffset in 0..<8 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            guard usualWeekdays.contains(calendar.component(.weekday, from: candidateDay)) else { continue }
            guard let fireTime = calendar.date(bySettingHour: typicalLogHour, minute: minutesPastTypicalHour, second: 0, of: candidateDay),
                  fireTime > now
            else { continue }
            if dayOffset == 0, allEntries.contains(where: { calendar.isDate($0.date, inSameDayAs: candidateDay) }) {
                continue
            }
            return fireTime
        }
        return nil
    }

    /// Read-only status check — never prompts. See requestAuthorizationIfNeeded
    /// for the one deliberate place that's allowed to.
    private static func isCurrentlyAuthorized(center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    /// The only place this app ever asks iOS for notification permission —
    /// called at a moment of actual relevant value (the first shift ever
    /// logged, in LogTipSheet; or turning "Remind me to log" on in
    /// Settings), never on launch. Apple's own system dialog only ever
    /// appears once, while the status is still .notDetermined — once a
    /// person has answered (either way), this is a silent no-op, so
    /// callers can invoke it freely without tracking whether they've
    /// already asked.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private static func schedule(at date: Date, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "How was your shift?"
        content.body = "Log your tips in Payday."
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        center.add(request)
    }
}
