import Foundation
import ActivityKit

/// The Live Activity's own content — just the start time. Elapsed duration
/// is never recomputed or stored here: Text(timerInterval:) renders it live
/// off startedAt alone, on the system's own clock.
struct ShiftSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
    }
}

/// The one active-or-not shift session — device-local by design (no
/// CloudKit sync for a transient in-progress punch, only the shift it
/// becomes once logged). Backed by AppGroup.defaults so the widget
/// extension process (Control Widget, Live Activity End button) reads the
/// exact same truth as the app, whichever process happens to run an intent.
enum ShiftSessionStore {
    private static let activeStartKey = "activeShiftStartedAt"
    private static let pendingEndKey = "pendingEndedShift"

    private struct PendingEnd: Codable {
        let start: Date
        let end: Date
    }

    static var activeStart: Date? {
        AppGroup.defaults.object(forKey: activeStartKey) as? Date
    }

    /// No-op if a session is already active — one shift at a time, the
    /// first punch wins rather than the most recent.
    static func start(at date: Date = .now) {
        guard activeStart == nil else { return }
        AppGroup.defaults.set(date, forKey: activeStartKey)
    }

    /// Clears the active session and stashes the exact start/end pair as
    /// pendingEnd for the app to turn into a prefilled log sheet next
    /// foreground. Returns nil (and touches nothing) if no session was
    /// running.
    @discardableResult
    static func endActive(at date: Date = .now) -> (start: Date, end: Date)? {
        guard let start = activeStart else { return nil }
        AppGroup.defaults.removeObject(forKey: activeStartKey)
        let pair = (start: start, end: date)
        let encoded = try? JSONEncoder().encode(PendingEnd(start: pair.start, end: pair.end))
        AppGroup.defaults.set(encoded, forKey: pendingEndKey)
        return pair
    }

    static var pendingEnd: (start: Date, end: Date)? {
        guard let data = AppGroup.defaults.data(forKey: pendingEndKey),
              let decoded = try? JSONDecoder().decode(PendingEnd.self, from: data)
        else { return nil }
        return (start: decoded.start, end: decoded.end)
    }

    /// Read + clear atomically — the log sheet this feeds should only ever
    /// see a given ended shift once.
    @discardableResult
    static func popPendingEnd() -> (start: Date, end: Date)? {
        guard let pair = pendingEnd else { return nil }
        AppGroup.defaults.removeObject(forKey: pendingEndKey)
        return pair
    }
}
