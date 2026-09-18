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
    /// Posted whenever the stored policies actually change, by any of the
    /// three write kinds. `EarningsStore` rebuilds on it.
    ///
    /// `@Observable` is not enough on its own: it tells a SwiftUI view that
    /// read `policies` to re-render, but the earnings snapshot has to be
    /// recomputed by a store that is not reading this object's properties,
    /// and a download or a migration must move it too. `apply` also touches
    /// `PaydaySettingsSyncClock`, which posts its own notification; the
    /// 50 ms debounce in `EarningsStore` coalesces the pair into one
    /// rebuild.
    static let didChange = Notification.Name("com.szakacsmedia.payday.policiesDidChange")

    private static let key = "com.szakacsmedia.payday.compensationPolicies"
    /// Set once the frozen calendar policy has been created, for reporting.
    /// The migration itself is gated on there being no calendar policy at
    /// all, so a payload that arrives from another device satisfies it.
    private static let calendarMigrationKey = "com.szakacsmedia.payday.policyMigration.calendarFrozen.v1"
    /// Set once the assumed rate policy has been considered, for reporting.
    /// It does NOT gate the work: see `runMigrationsIfNeeded`.
    private static let rateMigrationKey = "com.szakacsmedia.payday.policyMigration.assumedRate.v1"
    /// Set when an adoption created a policy that has never been uploaded.
    /// See `adoptedPoliciesAwaitingUpload`.
    private static let awaitingUploadKey = "com.szakacsmedia.payday.policyMigration.awaitingUpload.v1"

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

    /// The calendar policy a new one has to start on a boundary of, and the
    /// one whose frozen zone is "the payroll time zone".
    ///
    /// **Never feed this to a valuation.** It is `calendars.last`, so once
    /// the user queues a workweek change it is a policy that is not in effect
    /// yet — reading its weekday re-buckets all of history TODAY. Wave 0's
    /// first cut did exactly that on two screens. The valuation lookups are
    /// `calendarPolicyInEffect(today:)` and `policies.calendar(on:)`, and the
    /// engine does its own effective dating when handed the whole
    /// `CompensationPolicies` value, which is what every money path should
    /// pass.
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
        Self.postDidChange()
        // Touched in THIS store's suite, not implicitly in the App Group.
        // In the app they are the same suite, but a store pointed at another
        // one would otherwise keep its policies in one place and its
        // conflict clock in another, and the clock is what decides whether
        // this device's rate history beats the server's.
        PaydaySettingsSyncClock.touch(defaults: defaults)
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

    /// The plain "Hourly wage" row in Settings: the user is saying what their
    /// rate IS, not that it changed on a date. It rewrites the LATEST rate
    /// policy in place and marks it `.confirmed`, so correcting a typo never
    /// invents a raise.
    ///
    /// With no rate policy on file it creates one effective from the distant
    /// past, which is exactly what `baseHourlyWageCents` already did (it
    /// priced every shift ever logged), so turning the wage on moves no
    /// number relative to the shipped build.
    ///
    /// A nil or zero rate REMOVES every rate policy: nil has always meant
    /// "the wage feature is off", never "$0/hr", and the ledger reports
    /// `.rateNotSet` rather than a fabricated zero.
    func applyRateEdit(hourlyRateCents: Int?) {
        guard let cents = hourlyRateCents, cents > 0 else {
            apply(CompensationPolicies(version: policies.version, rates: [], calendars: policies.calendars))
            return
        }
        if var latest = policies.latestRate {
            latest.hourlyRateCents = cents
            latest.provenance = .confirmed
            applyRate(latest)
        } else {
            applyRate(PayRatePolicy(
                id: UUID(),
                effectiveFrom: .distantPast,
                hourlyRateCents: cents,
                provenance: .confirmed
            ))
        }
    }

    /// "Rate changed on…": a dated raise or cut. Adds a new `.confirmed`
    /// policy, which reprices only the shifts on or after that day — the
    /// weekly overtime threshold stays continuous across it.
    ///
    /// Zero is not a rate, here as in `applyRateEdit`: "zero means the wage
    /// feature is off" is ONE rule and both entry points obey it. Without
    /// this guard a `0` typed into the sheet stored a `.confirmed` $0.00/hr
    /// policy, and MEASURED through the real ledger an 8-hour shift then read
    /// back as `wage.isValued == true`, `regularWagesCents == 0`,
    /// `shiftsWageValued == 1` and no diagnostics: $0.00 of wages on real
    /// worked hours, presented as a confirmed complete fact instead of
    /// `.rateNotSet`. A dated change to zero is also not expressible as a
    /// removal (removal is not dated), so it is refused outright rather than
    /// routed into `applyRateEdit`, which would wipe the real rate history a
    /// typo was never asking to delete.
    func applyRateChange(hourlyRateCents: Int, effectiveFrom day: CivilDay) {
        guard hourlyRateCents > 0 else { return }
        applyRate(PayRatePolicy(
            id: UUID(),
            effectiveFrom: day,
            hourlyRateCents: hourlyRateCents,
            provenance: .confirmed
        ))
    }

    /// "Yes, since I started": the legacy rate really has always been the
    /// rate, so the assumption becomes a confirmation. Not a cent changes;
    /// the "estimated" caption disappears.
    func confirmRateHistory() {
        guard policies.hasOnlyAssumedRates else { return }
        var updated = policies
        for policy in policies.rates where policy.provenance == .assumedFromLegacySetting {
            var confirmed = policy
            confirmed.provenance = .confirmed
            updated = updated.adding(rate: confirmed)
        }
        apply(updated)
    }

    /// Applies a workweek-start or payroll-zone change as ONE not-yet-effective
    /// calendar policy.
    ///
    /// Three rules, each there for a reason:
    ///
    /// 1. **It takes effect at the next workweek boundary STRICTLY AFTER
    ///    today.** A policy that started this week would re-bucket days the
    ///    user has already worked and silently move the overtime on them.
    /// 2. **A second change before the first takes effect REPLACES it.**
    ///    Settings drives this from a picker; stacking would mint a policy
    ///    per scroll tick, and every one of them is a permanent row in the
    ///    user's payroll history.
    /// 3. **Reverting to what is already in effect removes the pending
    ///    policy entirely** rather than writing a no-op one, so the history
    ///    only ever records real changes.
    ///
    /// Returns the pending policy, or nil when the change was a revert.
    @discardableResult
    func applyCalendarChange(
        workweekStartWeekday: Int,
        payrollTimeZone: TimeZone,
        today: CivilDay
    ) -> PayrollCalendarPolicy? {
        let settled = policies.calendars.filter { $0.effectiveFrom <= today }
        let pending = policies.calendars.filter { $0.effectiveFrom > today }
        let inEffect = settled.last

        var kept = settled
        if let inEffect,
           inEffect.workweekStartWeekday == workweekStartWeekday,
           inEffect.payrollTimeZone == payrollTimeZone {
            apply(CompensationPolicies(version: policies.version, rates: policies.rates, calendars: kept))
            return nil
        }

        let policy = PolicyMigration.calendarPolicy(
            effectiveFrom: today.adding(days: 1),
            workweekStartWeekday: workweekStartWeekday,
            payrollTimeZone: payrollTimeZone,
            previous: inEffect,
            // Reuse the pending policy's id so this replaces it instead of
            // adding a second future policy.
            id: pending.first?.id ?? UUID()
        )
        kept.append(policy)
        apply(CompensationPolicies(version: policies.version, rates: policies.rates, calendars: kept))
        return policy
    }

    /// The calendar policy that is not in effect yet, if the user has queued
    /// a change. Settings shows its date ("Takes effect Mon, Oct 5").
    func pendingCalendarPolicy(today: CivilDay) -> PayrollCalendarPolicy? {
        policies.calendars.last { $0.effectiveFrom > today }
    }

    /// The calendar policy in effect today, which is what actually values a
    /// shift worked today.
    func calendarPolicyInEffect(today: CivilDay) -> PayrollCalendarPolicy? {
        policies.calendar(on: today)
    }

    /// A payload the sync decided is newer. Persists without touching the
    /// settings clock; the caller records the remote timestamp instead.
    func replaceFromSupabase(_ updated: CompensationPolicies) {
        // The server evidently holds policies, so whatever this device
        // adopted has nothing left to push: drop the pending-upload flag
        // before the early return, so an identical payload settles it too.
        acknowledgePolicyUpload()
        guard updated != policies else { return }
        policies = updated
        persist()
        Self.postDidChange()
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
        defer { Self.postDidChange() }
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.calendarMigrationKey)
        defaults.removeObject(forKey: Self.rateMigrationKey)
        defaults.removeObject(forKey: Self.awaitingUploadKey)
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

        // CONTENT-gated, not flag-gated, and this is load-bearing.
        //
        // The first draft gated the rate on a "has this run" flag. Measured on
        // the simulator: launch once with no wage set, the flag is written and
        // no policy is made; set a wage afterwards and NO rate policy is ever
        // created, so every wage in the app reads `.rateNotSet` and the
        // totals silently lose the wage line. Several real paths write the
        // legacy mirror without coming through Settings > Payroll: the
        // shipped 1.0 build writing through `upsert_user_settings`, the
        // first-run setup, the debug seeder.
        //
        // Gating on "there is a wage and no rate policy" instead makes this an
        // ADOPTION rather than a one-shot migration, so every one of those
        // paths converges. It cannot resurrect a deliberately cleared rate:
        // clearing the rate in Payroll clears the legacy mirror with it, so
        // there is nothing left to adopt.
        if let cents = baseHourlyWageCents, cents > 0, updated.rates.isEmpty {
            let policy = PolicyMigration.assumedRatePolicy(
                hourlyRateCents: cents,
                earliestShiftDay: earliestShiftDate.map { CivilDay($0, in: payrollZone) }
            )
            updated = updated.adding(rate: policy)
            outcome.createdRatePolicy = policy
        }
        defaults.set(true, forKey: Self.rateMigrationKey)

        guard outcome.changedAnything else { return outcome }
        policies = updated
        persist()
        Self.postDidChange()
        // An adoption is not a user edit, so it must not advance the settings
        // clock — but it still has to REACH the server once, or the column
        // the migration exists for stays NULL forever on exactly the
        // population it was written for. The clock is what
        // `PaydaySyncService.synchronize` compares to decide whether to
        // upload settings at all, and on an already-synced device it is
        // unchanged here, so this flag is the separate, explicit "there is an
        // adopted policy the server has never seen" signal. See
        // `PaydaySyncService.settingsNeedUpload`.
        defaults.set(true, forKey: Self.awaitingUploadKey)
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

    /// True when `runMigrationsIfNeeded` created a policy that has never been
    /// uploaded, so the next sync owes the server one settings write.
    ///
    /// This closes the hole the PaydayCloudGate comment claimed was already
    /// closed ("BEFORE restore, so a first sync uploads the policies it just
    /// created"). It was not: `synchronize` gates the settings upload on
    /// `checkpoint.settingsClientUpdatedAt != localSettings.clientUpdatedAt`,
    /// `clientUpdatedAt` is derived solely from `PaydaySettingsSyncClock`, and
    /// the adoption deliberately never touches that clock. On an already-
    /// synced Payday 1.0 device — the exact population the migration exists
    /// for — nothing differed, `upsertSettings` was never called, and
    /// `user_settings.compensation_policies` stayed NULL until some unrelated
    /// settings edit happened to fire.
    var adoptedPoliciesAwaitingUpload: Bool {
        defaults.bool(forKey: Self.awaitingUploadKey)
    }

    /// The server now holds these policies. Called after a successful
    /// `upsertSettings`, and after a download hands this device policies (the
    /// server clearly already has them, so there is nothing left to push).
    func acknowledgePolicyUpload() {
        defaults.removeObject(forKey: Self.awaitingUploadKey)
    }

    // MARK: Persistence

    /// Posts `didChange` on the main thread. Mirrors
    /// `PaydaySettingsSyncClock.touch`: a policy write can arrive from a
    /// background sync leg, and the observers are main-actor stores.
    private static func postDidChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: didChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didChange, object: nil)
            }
        }
    }

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
