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

/// Small app-config preferences that aren't tied to the pay schedule.
/// Same UserDefaults-backed pattern as PayScheduleStore: config, not a record.
@Observable
final class UserPreferencesStore {
    private static let nameKey = "com.szakacsmedia.payday.firstName"
    private static let appearanceKey = "com.szakacsmedia.payday.appearance"
    private static let faceIDLockKey = "com.szakacsmedia.payday.faceIDLock"
    private static let smartNudgeKey = "com.szakacsmedia.payday.smartNudge"
    private let defaults: UserDefaults

    var firstName: String? {
        didSet { persistName() }
    }

    var appearance: AppAppearance {
        didSet { persistAppearance() }
    }

    /// Off by default, like Notes — a lock nobody asked for is a lockout
    /// waiting to happen, not a feature.
    var isFaceIDLockEnabled: Bool {
        didSet { defaults.set(isFaceIDLockEnabled, forKey: Self.faceIDLockKey) }
    }

    /// On by default (unlike the lock) — this is a built-in behavior with
    /// an easy off-switch, not an opt-in. UserDefaults has no way to
    /// distinguish "never set" from "explicitly false," so a missing key
    /// reads as true rather than the usual Bool absence default of false.
    var isSmartNudgeEnabled: Bool {
        didSet { defaults.set(isSmartNudgeEnabled, forKey: Self.smartNudgeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.firstName = defaults.string(forKey: Self.nameKey)
        self.appearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.isFaceIDLockEnabled = defaults.bool(forKey: Self.faceIDLockKey)
        self.isSmartNudgeEnabled = defaults.object(forKey: Self.smartNudgeKey) == nil ? true : defaults.bool(forKey: Self.smartNudgeKey)
    }

    private func persistName() {
        if let firstName, !firstName.isEmpty {
            defaults.set(firstName, forKey: Self.nameKey)
        } else {
            defaults.removeObject(forKey: Self.nameKey)
        }
    }

    private func persistAppearance() {
        defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
    }
}
