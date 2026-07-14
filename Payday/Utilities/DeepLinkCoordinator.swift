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
    private init() {}
}
