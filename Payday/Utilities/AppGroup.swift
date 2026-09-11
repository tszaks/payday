import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

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

    /// Shared with the widget and Siri intent, which read the wage straight
    /// out of `defaults` rather than going through UserPreferencesStore.
    static let baseHourlyWageCentsKey = "com.szakacsmedia.payday.baseHourlyWageCents"
    static let appearanceKey = "com.szakacsmedia.payday.appearance"

    /// nil means the wage feature is off — never treated as a $0/hr rate.
    static var baseHourlyWageCents: Int? {
        defaults.object(forKey: baseHourlyWageCentsKey) == nil ? nil : defaults.integer(forKey: baseHourlyWageCentsKey)
    }

    static var appearance: AppAppearance {
        defaults.string(forKey: appearanceKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}

/// One portable-settings clock shared by the app and widget target. It keeps
/// settings conflict ordering out of the business-value stores themselves.
enum PaydaySettingsSyncClock {
    private static let key = "com.szakacsmedia.payday.settingsModifiedAt"

    static let didChange = Notification.Name("com.szakacsmedia.payday.settingsDidChange")

    static var modifiedAt: Date {
        modifiedAt(in: AppGroup.defaults)
    }

    static func modifiedAt(in defaults: UserDefaults) -> Date {
        // A read must not manufacture a brand-new local edit. On a fresh
        // install that would make untouched defaults look newer than real
        // settings already stored by another device.
        (defaults.object(forKey: key) as? Date)
            ?? Date(timeIntervalSince1970: 0)
    }

    static func touch(_ date: Date = .now, defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(date, forKey: key)
        if Thread.isMainThread {
            NotificationCenter.default.post(name: didChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didChange, object: nil)
            }
        }
    }

    static func acceptRemoteTimestamp(_ date: Date, defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(date, forKey: key)
    }
}
