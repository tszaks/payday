import Foundation
import ActivityKit

/// The one path a shift session starts or ends through. StartShiftIntent/
/// EndShiftIntent (Siri, Shortcuts, Control Center, the Live Activity's own
/// End button, the Home Screen quick action), Dashboard's Start/End Shift
/// row, and the QA launch hook all call these two functions rather than
/// touching ShiftSessionStore and ActivityKit separately — one "how a shift
/// starts/ends" behavior regardless of entry point.
/// The live mirror of ShiftSessionStore for SwiftUI. The store itself is
/// plain UserDefaults (it has to be — the widget process reads it), so a
/// view can't observe it directly; every in-app start/end goes through
/// ShiftSessionManager, which keeps this in step. Same shared-singleton
/// shape as DeepLinkCoordinator. `sync()` covers the one case the manager
/// can't see: a session ended in another process while the app was
/// suspended.
@Observable
@MainActor
final class ShiftSessionState {
    static let shared = ShiftSessionState()
    private init() { activeStart = ShiftSessionStore.activeStart }

    var activeStart: Date?

    func sync() { activeStart = ShiftSessionStore.activeStart }
}

@MainActor
enum ShiftSessionManager {
    /// No-op if a session is already active (ShiftSessionStore.start's own
    /// guard). A denied/failed Live Activity request never fails the punch
    /// itself — the session is already recorded before the request is made.
    static func start(at date: Date = .now) {
        ShiftSessionStore.start(at: date)
        ShiftSessionState.shared.sync()
        guard let startedAt = ShiftSessionStore.activeStart else { return }
        do {
            _ = try Activity<ShiftSessionAttributes>.request(
                attributes: ShiftSessionAttributes(),
                content: .init(state: .init(startedAt: startedAt), staleDate: nil),
                pushType: nil
            )
        } catch {
            // See doc comment above: intentionally swallowed.
        }
    }

    /// nil if no session was running — nothing ended, nothing stashed.
    /// `stashPendingEnd: false` is for a caller (LogTipSheet, ending the live
    /// shift it's mid-save on) that already has the exact punches in hand —
    /// see ShiftSessionStore.endActive's own doc comment.
    @discardableResult
    static func end(at date: Date = .now, stashPendingEnd: Bool = true) async -> (start: Date, end: Date)? {
        guard ShiftSessionStore.activeStart != nil else { return nil }
        for activity in Activity<ShiftSessionAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        defer { ShiftSessionState.shared.sync() }
        return ShiftSessionStore.endActive(at: date, stash: stashPendingEnd)
    }
}
