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
        Task { @MainActor in
            if identifier == SmartNudgeScheduler.notificationIdentifier {
                DeepLinkCoordinator.shared.pendingLogTarget = .new(defaultDate: .now)
            } else if identifier == PaydayPushScheduler.notificationIdentifier {
                DeepLinkCoordinator.shared.pendingCurrentPeriodDetail = true
            }
        }
        completionHandler()
    }
}
