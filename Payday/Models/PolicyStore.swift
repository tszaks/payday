import Foundation

/// Owns the compensation policies — rate history and payroll calendar
/// history — in the App Group's UserDefaults as one JSON blob.
///
/// Same pattern as `PayScheduleStore`: configuration, not records, so never
/// SwiftData. It lives in the App Group rather than `.standard` because the
/// widget and the Siri intent value shifts too and must read the same
/// policies the app does.
///
/// The store deliberately has no settable `policies` property. A wage is a
/// number someone is owed: every write goes through a named method that says
/// what kind of write it is, because the three kinds differ in exactly one
/// consequential way — whether they advance `PaydaySettingsSyncClock`:
///
/// - `apply(_:)` is a user edit. It touches the clock, so it wins over the
///   server's copy and uploads on the next sync.
/// - `replaceFromSupabase(_:)` is a download. The caller has already decided
///   the remote payload is newer; touching the clock here would make the
///   device look like it had edited the value it just received.
/// - `runMigrationsIfNeeded(...)` restates facts the app already had. It must
///   NOT touch the clock: a read-time bump would make untouched local
///   defaults look newer than real settings stored by another device and
///   clobber them (the same trap `PaydaySettingsSyncClock.modifiedAt`
///   documents for fresh installs). Design 1: "The migration does not touch
///   PaydaySettingsSyncClock."
@Observable
final class PolicyStore {
    private static let key = "com.szakacsmedia.payday.compensationPolicies"
    /// Set once the frozen calendar policy has been created, for reporting.
    /// The migration itself is gated on there being no calendar policy at
    /// all, so a payload that arrives from another device satisfies it.
    private static let calendarMigrationKey = "com.szakacsmedia.payday.policyMigration.calendarFrozen.v1"
    /// Gates the assumed rate policy. Flag-gated rather than content-gated
    /// because a user who clears their wage has chosen to have no rate
    /// policy, and a content gate would resurrect it on the next launch.
    private static let rateMigrationKey = "com.szakacsmedia.payday.policyMigration.assumedRate.v1"

    private let defaults: UserDefaults

    private(set) var policies: CompensationPolicies

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        self.policies = Self.load(from: defaults)
    }

    // MARK: Reads the rest of the app uses

    /// The frozen payroll time zone: the latest calendar policy's zone.
    ///
    /// Falls back to the device zone ONLY when no calendar policy exists yet,
    /// which is the single moment the app is allowed to consult the device —
    /// a first launch before the migration has run. Every date-bucketing
    /// surface reads this instead of `TimeZone.current`, so a phone that
    /// travels cannot move a shift into another week.
    var payrollTimeZone: TimeZone {
        policies.payrollTimeZone ?? .current
    }

    /// The rate Settings shows and `baseHourlyWageCents` is a view of: the
    /// latest rate policy's, or nil when the wage feature is off.
    var currentHourlyRateCents: Int? {
        policies.latestRate?.hourlyRateCents
    }

    /// The calendar policy a new one has to start on a boundary of.
    var latestCalendarPolicy: PayrollCalendarPolicy? {
        policies.latestCalendar
    }

    /// Whether the one-time rate-history prompt is still owed: the only rate
    /// policies on file are legacy assumptions AND there is at least one
    /// shift whose wages therefore read as estimated. A brand-new user with
    /// no shifts is asked nothing.
    func owesRateHistoryPrompt(shiftCount: Int) -> Bool {
        shiftCount > 0 && policies.hasOnlyAssumedRates
    }

    // MARK: Writes

    /// A user edit: persists, advances the settings clock so it wins over the
    /// server's copy, and refreshes the widget because its numbers just moved.
    func apply(_ updated: CompensationPolicies) {
        guard updated != policies else { return }
        policies = updated
        persist()
        PaydaySettingsSyncClock.touch()
        #if !WIDGET_EXTENSION
        PaydayWidgetRefresh.request()
        #endif
    }

    /// Adds or replaces one rate policy (by id) as a user edit.
    func applyRate(_ policy: PayRatePolicy) {
        apply(policies.adding(rate: policy))
    }

    /// Adds or replaces one calendar policy (by id) as a user edit.
    func applyCalendar(_ policy: PayrollCalendarPolicy) {
        apply(policies.adding(calendar: policy))
    }

    /// A payload the sync decided is newer. Persists without touching the
    /// settings clock; the caller records the remote timestamp instead.
    func replaceFromSupabase(_ updated: CompensationPolicies) {
        guard updated != policies else { return }
        policies = updated
        persist()
        #if !WIDGET_EXTENSION
        PaydayWidgetRefresh.request()
        #endif
    }

    /// Clears every policy. Debug/test convenience and account deletion,
    /// mirroring the reset hooks on the app's other stores. Also clears the
    /// migration flags, so a fresh account migrates again rather than
    /// starting with no rate at all.
    func reset() {
        policies = .empty
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.calendarMigrationKey)
        defaults.removeObject(forKey: Self.rateMigrationKey)
    }

    // MARK: The two one-time migrations (Design 1)

    struct MigrationOutcome: Equatable {
        var createdCalendarPolicy: PayrollCalendarPolicy?
        var createdRatePolicy: PayRatePolicy?

        var changedAnything: Bool { createdCalendarPolicy != nil || createdRatePolicy != nil }
    }

    /// Creates the first calendar policy and, if a legacy wage is set, the
    /// one assumed rate policy. Idempotent, and silent about it: neither
    /// write advances the settings clock.
    ///
    /// - Parameters:
    ///   - resolvedFirstWeekday: `PaySchedule.resolvedFirstWeekday` as it
    ///     reads right now. Freezing the *resolved* value is the point: the
    ///     app has been bucketing overtime by it, so restating it moves
    ///     nobody's overtime even though `firstWeekday` becomes grid-only.
    ///   - earliestShiftDate: the instant of the user's first shift. It is
    ///     converted to a civil day HERE, with the payroll zone this call
    ///     freezes, so the caller cannot get the ordering wrong by reading a
    ///     zone that does not exist yet. The assumed rate starts on that day,
    ///     so nothing before their first shift is priced.
    ///   - baseHourlyWageCents: the legacy wage, or nil when the feature was
    ///     never turned on (in which case no rate policy is created and every
    ///     wage reads `.rateNotSet`).
    ///   - deviceTimeZone: captured once, here, and frozen onto the policy.
    @discardableResult
    func runMigrationsIfNeeded(
        resolvedFirstWeekday: Int,
        earliestShiftDate: Date?,
        baseHourlyWageCents: Int?,
        deviceTimeZone: TimeZone = .current
    ) -> MigrationOutcome {
        var outcome = MigrationOutcome()
        var updated = policies
        // An existing policy's frozen zone wins; the device is consulted only
        // when there is no policy yet, which is the one moment it is allowed.
        let payrollZone = updated.payrollTimeZone ?? deviceTimeZone

        if updated.calendars.isEmpty {
            let weekday = PayrollCalendarPolicy.weekdayRange.contains(resolvedFirstWeekday)
                ? resolvedFirstWeekday
                : 1
            let policy = PolicyMigration.frozenCalendarPolicy(
                workweekStartWeekday: weekday,
                payrollTimeZone: deviceTimeZone
            )
            updated = updated.adding(calendar: policy)
            outcome.createdCalendarPolicy = policy
            defaults.set(true, forKey: Self.calendarMigrationKey)
        }

        if !defaults.bool(forKey: Self.rateMigrationKey) {
            if let cents = baseHourlyWageCents, cents > 0, updated.rates.isEmpty {
                let policy = PolicyMigration.assumedRatePolicy(
                    hourlyRateCents: cents,
                    earliestShiftDay: earliestShiftDate.map { CivilDay($0, in: payrollZone) }
                )
                updated = updated.adding(rate: policy)
                outcome.createdRatePolicy = policy
            }
            // Marked run either way: a user with no wage set has no rate
            // policy BY CHOICE, and the migration must not keep looking for
            // one every launch and mint it the moment they type a number in
            // (that is a user edit, and it is `.confirmed`).
            defaults.set(true, forKey: Self.rateMigrationKey)
        }

        guard outcome.changedAnything else { return outcome }
        policies = updated
        persist()
        // Deliberately no PaydaySettingsSyncClock.touch(): see the type note.
        #if !WIDGET_EXTENSION
        PaydayWidgetRefresh.request()
        #endif
        return outcome
    }

    /// Whether each migration has run, for the debug sheet and the tests.
    var migrationFlags: (calendar: Bool, rate: Bool) {
        (defaults.bool(forKey: Self.calendarMigrationKey), defaults.bool(forKey: Self.rateMigrationKey))
    }

    // MARK: Persistence

    private static func load(from defaults: UserDefaults) -> CompensationPolicies {
        guard let data = defaults.data(forKey: key) else { return .empty }
        return (try? JSONDecoder().decode(CompensationPolicies.self, from: data)) ?? .empty
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(policies) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The policies as the widget and the Siri intent read them: straight out
    /// of the shared defaults, with no store instance and no observation.
    static func storedPolicies(defaults: UserDefaults = AppGroup.defaults) -> CompensationPolicies {
        load(from: defaults)
    }

    /// The payroll time zone for a process that has no `PolicyStore`.
    static func storedPayrollTimeZone(defaults: UserDefaults = AppGroup.defaults) -> TimeZone {
        storedPolicies(defaults: defaults).payrollTimeZone ?? .current
    }
}
