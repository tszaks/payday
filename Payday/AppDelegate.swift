import UIKit

/// Home Screen long-press quick actions (Log Shift, Start Shift — see
/// project.yml's UIApplicationShortcutItems) need windowScene(_:performActionFor:),
/// which only a UIKit scene delegate receives; there's no SwiftUI-only hook
/// for a quick action tapped while the app is already running. This is the
/// one piece of UIKit app/scene lifecycle the app carries, for that reason
/// alone.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ShiftSceneDelegate.self
        // Cold launch via a long-press quick action: ShiftSceneDelegate
        // doesn't exist yet to receive performActionFor directly, so the
        // item rides in here and gets consumed on the scene's first
        // becoming-active instead.
        if let shortcutItem = options.shortcutItem {
            ShiftSceneDelegate.pendingShortcutItem = shortcutItem
        }
        return configuration
    }
}

/// Handles a quick action tapped while the app is already running or
/// backgrounded; AppDelegate above handles the cold-launch case.
final class ShiftSceneDelegate: NSObject, UIWindowSceneDelegate {
    static var pendingShortcutItem: UIApplicationShortcutItem?

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        ShiftQuickActions.handle(shortcutItem)
        completionHandler(true)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let shortcutItem = Self.pendingShortcutItem else { return }
        Self.pendingShortcutItem = nil
        ShiftQuickActions.handle(shortcutItem)
    }
}

/// The two Home Screen quick action identifiers routed to the same
/// deep-link/session paths every other entry point already uses.
enum ShiftQuickActions {
    @MainActor
    static func handle(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case "com.szakacsmedia.payday.quickaction.log":
            DeepLinkCoordinator.shared.pendingLogTarget = .new(defaultDate: .now)
        case "com.szakacsmedia.payday.quickaction.startshift":
            ShiftSessionManager.start()
        default:
            break
        }
    }
}
