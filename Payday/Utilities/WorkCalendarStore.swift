import EventKit
import Foundation

/// Thin EventKit wrapper — the only place this app talks to calendars.
/// Owns the EKEventStore, never caches results (each reschedule fetches
/// fresh so an edited shift is picked up on the next pass), and never
/// scans event titles: every event in the designated calendar counts as a
/// shift, no event anywhere else does. App target only — the widget has
/// no need to touch EventKit.
@MainActor
final class WorkCalendarStore {
    private let eventStore = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// The one place this app ever asks iOS for calendar access — only
    /// ever called from an explicit tap on "Connect Work Calendar" in
    /// Settings, never on launch or in the background.
    func requestAccess() async -> Bool {
        (try? await eventStore.requestFullAccessToEvents()) ?? false
    }

    /// Every calendar available to pick from, grouped by source (iCloud,
    /// Google, etc.) in the picker sheet — plain identifying info only, no
    /// event data.
    func availableCalendars() -> [(id: String, title: String, sourceTitle: String)] {
        eventStore.calendars(for: .event).map { calendar in
            (id: calendar.calendarIdentifier, title: calendar.title, sourceTitle: calendar.source?.title ?? "")
        }
    }

    /// Shifts from ONLY the designated calendar, in the given window — no
    /// title scanning, no inference: every event here counts, all-day
    /// events don't (an all-day event has no closeout moment). Returns nil
    /// if the identifier no longer resolves to a real calendar (e.g. it
    /// was deleted since being picked), so callers can fall back to the
    /// rhythm heuristic silently instead of treating "gone" the same as
    /// "nothing scheduled."
    func scheduledShifts(calendarIdentifier: String, keyword: String? = nil, from start: Date, to end: Date) -> [WorkScheduleNudge.ScheduledShift]? {
        guard let calendar = eventStore.calendar(withIdentifier: calendarIdentifier) else { return nil }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { WorkScheduleNudge.matches(title: $0.title, keyword: keyword) }
            .map { WorkScheduleNudge.ScheduledShift(start: $0.startDate, end: $0.endDate) }
    }
}
