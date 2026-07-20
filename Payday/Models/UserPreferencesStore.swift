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
    private static let baseHourlyWageCentsKey = AppGroup.baseHourlyWageCentsKey
    /// Set once migration to the app-group suite has run, so a wage the user
    /// later clears (removeObject on the suite key) is never mistaken for
    /// "never migrated" and copied back from a stale standard-defaults value.
    private static let baseHourlyWageMigratedKey = "com.szakacsmedia.payday.baseHourlyWageMigratedToAppGroup"
    private let defaults: UserDefaults
    /// The widget can't reach `.standard` (a different process's container),
    /// so the wage — the one preference it needs — lives in the app-group
    /// suite instead. Everything else here stays on `.standard`.
    private let wageDefaults: UserDefaults

    var firstName: String? {
        didSet { persistName() }
    }

    /// The tipped base wage, in cents — money is stored in cents everywhere
    /// in this app, never Double dollars. Used ONLY to estimate the wages
    /// line on a paycheck expectation; nil means the feature is off, and
    /// this value is never counted as tip income anywhere.
    var baseHourlyWageCents: Int? {
        didSet { persistBaseHourlyWageCents() }
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

    init(defaults: UserDefaults = .standard, wageDefaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        self.wageDefaults = wageDefaults
        self.firstName = defaults.string(forKey: Self.nameKey)
        self.appearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.isFaceIDLockEnabled = defaults.bool(forKey: Self.faceIDLockKey)
        self.isSmartNudgeEnabled = defaults.object(forKey: Self.smartNudgeKey) == nil ? true : defaults.bool(forKey: Self.smartNudgeKey)

        Self.migrateBaseHourlyWageCentsIfNeeded(from: defaults, to: wageDefaults)
        self.baseHourlyWageCents = wageDefaults.object(forKey: Self.baseHourlyWageCentsKey) == nil ? nil : wageDefaults.integer(forKey: Self.baseHourlyWageCentsKey)
    }

    /// One-time copy of the wage from `.standard` (where it used to live)
    /// into the app-group suite. Runs at most once per install — gated on
    /// `baseHourlyWageMigratedKey` in the suite, not on whether the suite's
    /// wage key is currently set, since clearing the wage after migration
    /// also removes that key and must not look like "never migrated."
    private static func migrateBaseHourlyWageCentsIfNeeded(from standard: UserDefaults, to suite: UserDefaults) {
        guard !suite.bool(forKey: baseHourlyWageMigratedKey) else { return }
        // When the app-group container is unavailable, AppGroup.defaults
        // falls back to `.standard` itself — the same store passed in as
        // `standard` here. Copying then removing in that case would erase
        // the value it just "migrated" into itself.
        guard standard !== suite else {
            suite.set(true, forKey: baseHourlyWageMigratedKey)
            return
        }
        if let legacyValue = standard.object(forKey: baseHourlyWageCentsKey) as? Int {
            suite.set(legacyValue, forKey: baseHourlyWageCentsKey)
        }
        standard.removeObject(forKey: baseHourlyWageCentsKey)
        suite.set(true, forKey: baseHourlyWageMigratedKey)
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

    private func persistBaseHourlyWageCents() {
        if let baseHourlyWageCents {
            wageDefaults.set(baseHourlyWageCents, forKey: Self.baseHourlyWageCentsKey)
        } else {
            wageDefaults.removeObject(forKey: Self.baseHourlyWageCentsKey)
        }
    }
}
