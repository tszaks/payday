import Testing
import Foundation
@testable import Payday

/// Fresh, isolated UserDefaults suites per test — never `.standard` or the
/// real app-group suite, so these can't bleed into each other or into a
/// real device's stored preferences.
private func freshDefaults() -> UserDefaults {
    let suiteName = "com.szakacsmedia.payday.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Suite("UserPreferencesStore wage migration")
struct UserPreferencesStoreWageMigrationTests {
    private static let wageKey = "com.szakacsmedia.payday.baseHourlyWageCents"

    @Test("a legacy wage in standard defaults migrates into the app-group suite")
    func migratesLegacyWage() {
        let standard = freshDefaults()
        let suite = freshDefaults()
        standard.set(2500, forKey: Self.wageKey)

        let store = UserPreferencesStore(defaults: standard, wageDefaults: suite)

        #expect(store.baseHourlyWageCents == 2500)
        #expect(suite.integer(forKey: Self.wageKey) == 2500)
        #expect(standard.object(forKey: Self.wageKey) == nil)
    }

    @Test("no legacy wage and no suite wage stays nil")
    func staysNilWhenNeverSet() {
        let standard = freshDefaults()
        let suite = freshDefaults()

        let store = UserPreferencesStore(defaults: standard, wageDefaults: suite)

        #expect(store.baseHourlyWageCents == nil)
    }

    @Test("a wage cleared after migration is NOT resurrected by a stale standard key on the next launch")
    func clearedWageIsNotResurrected() {
        let standard = freshDefaults()
        let suite = freshDefaults()
        standard.set(2500, forKey: Self.wageKey)

        // First launch: migrates 2500 into the suite.
        let firstLaunch = UserPreferencesStore(defaults: standard, wageDefaults: suite)
        #expect(firstLaunch.baseHourlyWageCents == 2500)

        // User turns the feature off.
        firstLaunch.baseHourlyWageCents = nil
        #expect(suite.object(forKey: Self.wageKey) == nil)

        // A stale copy of the old value reappears in standard defaults
        // (e.g. an old build wrote it back, or a restore resurrected it) —
        // this must never resurrect the wage the user just cleared.
        standard.set(2500, forKey: Self.wageKey)

        let secondLaunch = UserPreferencesStore(defaults: standard, wageDefaults: suite)
        #expect(secondLaunch.baseHourlyWageCents == nil)
    }

    @Test("migration only ever runs once, even across repeated launches with no wage")
    func migrationIsIdempotent() {
        let standard = freshDefaults()
        let suite = freshDefaults()
        standard.set(1800, forKey: Self.wageKey)

        _ = UserPreferencesStore(defaults: standard, wageDefaults: suite)
        _ = UserPreferencesStore(defaults: standard, wageDefaults: suite)
        let third = UserPreferencesStore(defaults: standard, wageDefaults: suite)

        #expect(third.baseHourlyWageCents == 1800)
    }
}

@Suite("Appearance preference")
struct UserPreferencesStoreAppearanceTests {
    private static let appearanceKey = "com.szakacsmedia.payday.appearance"

    @Test("defaults to Automatic when no choice exists")
    func defaultsToAutomatic() {
        let store = UserPreferencesStore(defaults: freshDefaults(), wageDefaults: freshDefaults())

        #expect(store.appearance == .system)
    }

    @Test("legacy appearance migrates to shared defaults and persists there")
    func migratesAndPersistsSharedAppearance() {
        let standard = freshDefaults()
        let shared = freshDefaults()
        standard.set(AppAppearance.dark.rawValue, forKey: Self.appearanceKey)

        let store = UserPreferencesStore(defaults: standard, wageDefaults: shared)
        #expect(store.appearance == .dark)
        #expect(standard.object(forKey: Self.appearanceKey) == nil)
        #expect(shared.string(forKey: Self.appearanceKey) == AppAppearance.dark.rawValue)

        store.appearance = .light
        let relaunched = UserPreferencesStore(defaults: standard, wageDefaults: shared)
        #expect(relaunched.appearance == .light)
    }

    @Test("reading an untouched settings clock stays at the epoch")
    func untouchedClockDoesNotBecomeANewEdit() {
        let defaults = freshDefaults()

        #expect(PaydaySettingsSyncClock.modifiedAt(in: defaults) == Date(timeIntervalSince1970: 0))
        #expect(PaydaySettingsSyncClock.modifiedAt(in: defaults) == Date(timeIntervalSince1970: 0))
    }

    @Test("a real settings edit advances the settings clock")
    func editAdvancesClock() {
        let defaults = freshDefaults()
        let editDate = Date(timeIntervalSince1970: 1_234)

        PaydaySettingsSyncClock.touch(editDate, defaults: defaults)

        #expect(PaydaySettingsSyncClock.modifiedAt(in: defaults) == editDate)
    }
}
