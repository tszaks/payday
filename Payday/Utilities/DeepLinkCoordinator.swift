import Foundation

/// Bridges App Intents (run via Siri, Shortcuts, the widget, Control Center,
/// the Action Button — none of which have access to the SwiftUI
/// environment) into the log sheet. MainTabView observes this singleton and
/// presents the sheet whenever an intent sets a pending target.
@MainActor
@Observable
final class DeepLinkCoordinator {
    static let shared = DeepLinkCoordinator()
    var pendingLogTarget: TipEntrySheetTarget?
    /// Set by payday://shift (the Live Activity/lock screen tap) — a plain
    /// Bool rather than an AppTab, so this file (shared into the widget
    /// target for OpenLogSheetIntent) never depends on a type that only
    /// exists in the app target. MainTabView observes this and switches
    /// tabs; a shift-in-progress tap always lands on Dashboard, never a
    /// sheet.
    var pendingDashboardSelection = false
    /// Set by a tapped payday-moment push notification — routes into the
    /// CURRENT period's detail, the same landing spot as Dashboard's "See
    /// all" and the -OpenCurrentPeriodDetail QA hook. MainTabView observes
    /// this and forwards it into TabRouter, since a notification tap lands
    /// here (an app-wide singleton) before any view's own state exists.
    var pendingCurrentPeriodDetail = false
    private init() {}
}
