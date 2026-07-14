import Foundation

/// Shared storage identifier for the main app and the widget extension —
/// two separate processes, one on-disk store. The widget can't reach the
/// app's own container, so config (PaySchedule, preferences) and the
/// SwiftData store both live here instead of the default locations.
enum AppGroup {
    static let identifier = "group.com.szakacsmedia.payday"

    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
