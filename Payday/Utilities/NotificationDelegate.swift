import Foundation
import UserNotifications

/// Routes a tapped smart-nudge notification into the same log sheet
/// everything else deep-links to. The delegate protocol isn't actor
/// isolated, so this hops to the main actor itself before touching
/// DeepLinkCoordinator rather than isolating the whole class.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Stateless singleton — every access just dispatches into a @MainActor
    // Task, so there's no shared mutable state for concurrency checking to
    // actually protect here.
    nonisolated(unsafe) static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let landing = Self.periodLanding(identifier: identifier, userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if identifier == SmartNudgeScheduler.notificationIdentifier {
                DeepLinkCoordinator.shared.pendingLogTarget = .new(defaultDate: .now)
            } else if let landing {
                DeepLinkCoordinator.shared.pendingPeriodLanding = landing
            }
        }
        completionHandler()
    }

    /// Where a tapped payday push lands, or nil for any other notification.
    /// Pure, so the routing is testable without a notification response.
    /// Requests queued by older builds carry no period, so they land in the
    /// current period's detail as they always did.
    static func periodLanding(identifier: String, userInfo: [AnyHashable: Any]) -> PeriodLanding? {
        guard identifier == PaydayPushScheduler.notificationIdentifier
            || identifier == PaydayPushScheduler.stubNudgeIdentifier else { return nil }
        guard let start = userInfo[PaydayPushScheduler.periodStartKey] as? TimeInterval,
              let end = userInfo[PaydayPushScheduler.periodEndKey] as? TimeInterval else {
            return .currentDetail
        }
        return .paycheckScan(
            periodStart: Date(timeIntervalSince1970: start),
            periodEnd: Date(timeIntervalSince1970: end)
        )
    }
}
