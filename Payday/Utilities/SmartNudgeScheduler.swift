import Foundation
import UserNotifications

/// "How was tonight?" — the one smart nudge PRODUCT.md asks for. Learned
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
    /// nudge and queue up the next usual night's instead.
    static func reschedule(preferencesStore: UserPreferencesStore, allEntries: [TipEntry]) {
        Task {
            await performReschedule(preferencesStore: preferencesStore, allEntries: allEntries)
        }
    }

    private static func performReschedule(preferencesStore: UserPreferencesStore, allEntries: [TipEntry]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        guard preferencesStore.isSmartNudgeEnabled else { return }

        let engine = StatsEngine(records: allEntries.map(TipRecord.init))
        let rhythm = engine.workRhythm()
        guard !rhythm.usualWeekdays.isEmpty,
              let typicalLogHour = rhythm.typicalLogHour,
              let fireDate = nextFireDate(usualWeekdays: rhythm.usualWeekdays, typicalLogHour: typicalLogHour, allEntries: allEntries)
        else { return }

        guard await isAuthorized(center: center) else { return }
        schedule(at: fireDate, center: center)
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

    /// Contextual, not upfront: permission is only ever requested the
    /// first time there's an actual usual-work-night worth nudging about.
    private static func isAuthorized(center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    private static func schedule(at date: Date, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "How was tonight?"
        content.body = "Log tonight's tips in Payday."
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        center.add(request)
    }
}
