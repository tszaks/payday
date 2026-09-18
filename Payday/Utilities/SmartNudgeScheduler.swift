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
    static func reschedule(
        preferencesStore: UserPreferencesStore,
        allEntries: [TipEntry],
        shiftRecords: [ShiftRecord]
    ) {
        Task {
            await performReschedule(
                preferencesStore: preferencesStore,
                allEntries: allEntries,
                shiftRecords: shiftRecords
            )
        }
    }

    private static func performReschedule(
        preferencesStore: UserPreferencesStore,
        allEntries: [TipEntry],
        shiftRecords: [ShiftRecord]
    ) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        guard preferencesStore.isSmartNudgeEnabled else { return }

        guard let fireDate = rhythmFireDate(allEntries: allEntries, shiftRecords: shiftRecords) else { return }

        guard await isCurrentlyAuthorized(center: center) else { return }
        schedule(at: fireDate, center: center)
    }

    /// The per-account switch, in ONE place for this reader.
    ///
    /// Both representations exist at once during the conversion window -- a
    /// converted shift is a `ShiftRecord` AND its original `TipEntry` rows,
    /// which are never rewritten -- so reading the union would count that
    /// shift twice. `shiftsAreAuthoritative` is therefore a switch, not a
    /// merge: `ShiftRecord` when true, `TipEntry` when false.
    ///
    /// It lives here rather than at the call sites because this reader has
    /// FOUR of them -- `RootView`, `LogTipsIntent`, `BackfillSheet` and
    /// `LogTipSheet` -- and a switch duplicated four ways is a switch that
    /// can disagree with itself.
    ///
    /// No shipped account is authoritative yet, so today this always takes
    /// the `TipEntry` branch and the behaviour is byte-identical to before.
    /// `switchIsANoOpForAnAccountThatHasNotConverted` asserts exactly that.
    static func rhythmFireDate(
        allEntries: [TipEntry],
        shiftRecords: [ShiftRecord],
        from now: Date = .now
    ) -> Date? {
        if PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount {
            return rhythmFireDate(rows: ShiftProjection.rows(for: shiftRecords), from: now)
        }
        return rhythmFireDate(rows: allEntries, from: now)
    }

    /// The learned typical-hour heuristic keeps reminders useful without
    /// reading or connecting to the user's calendar.
    /// Generic over the row rather than existential, so Release still
    /// specializes it: the measured witness-table cost of a protocol here is
    /// a `-Onone` effect only (see docs/design/FOLLOWUP-release-perf-budget.md).
    static func rhythmFireDate<Row: LegacyShiftRow>(rows: [Row], from now: Date = .now) -> Date? {
        let engine = StatsEngine(payrollTimeZone: PolicyStore.storedPayrollTimeZone(), records: rows.map(TipRecord.init))
        // `referenceDate: now`, not the default `.now`. The rhythm window and
        // the fire-date search must share ONE clock: with the default, the
        // rhythm was computed against wall-clock time while the search below
        // used the caller's `now`, so one decision rested on two different
        // "now"s. That also made this untestable.
        let rhythm = engine.workRhythm(referenceDate: now)
        guard !rhythm.usualWeekdays.isEmpty, let typicalLogHour = rhythm.typicalLogHour else { return nil }
        return nextFireDate(usualWeekdays: rhythm.usualWeekdays, typicalLogHour: typicalLogHour, rows: rows, from: now)
    }

    /// The next moment worth nudging: today if it's a usual night, the
    /// time hasn't passed, and nothing's logged yet — otherwise the next
    /// usual weekday after today, no "already logged" check needed since
    /// that day hasn't happened yet.
    static func nextFireDate<Row: LegacyShiftRow>(usualWeekdays: Set<Int>, typicalLogHour: Int, rows: [Row], from now: Date = .now) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        for dayOffset in 0..<8 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            guard usualWeekdays.contains(calendar.component(.weekday, from: candidateDay)) else { continue }
            guard let fireTime = calendar.date(bySettingHour: typicalLogHour, minute: minutesPastTypicalHour, second: 0, of: candidateDay),
                  fireTime > now
            else { continue }
            // "Already logged tonight, so do not nudge." This is the check
            // that goes blind the moment the writer flips to ShiftCommands
            // (which writes ShiftRecord and never TipEntry) unless this reader
            // has already been switched -- the user would be told "you haven't
            // logged today" straight after logging.
            if dayOffset == 0, rows.contains(where: { calendar.isDate($0.date, inSameDayAs: candidateDay) }) {
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
