import Testing
import Foundation
@testable import Payday

/// Fresh, isolated UserDefaults suites per test — never `.standard` or the
/// real app-group suite, so these cannot bleed into each other or into a real
/// device's stored policies.
private func freshDefaults() -> UserDefaults {
    let suiteName = "com.szakacsmedia.payday.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private let settingsClockKey = "com.szakacsmedia.payday.settingsModifiedAt"

@Suite("PolicyStore migrations")
struct PolicyStoreMigrationTests {

    @Test("the first calendar policy freezes the resolved first weekday and the device zone")
    func freezesTheCalendar() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)
        #expect(store.policies.isEmpty)

        let outcome = store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2,
            earliestShiftDate: nil,
            baseHourlyWageCents: nil,
            deviceTimeZone: PaydayTestZone.newYork
        )

        let policy = try! #require(outcome.createdCalendarPolicy)
        #expect(policy.workweekStartWeekday == 2)
        #expect(policy.payrollTimeZone == PaydayTestZone.newYork)
        #expect(policy.effectiveFrom == .distantPast)
        #expect(store.payrollTimeZone == PaydayTestZone.newYork)
        // No wage was set, so no rate policy is invented and every wage in
        // the app reads `.rateNotSet` rather than a fabricated zero.
        #expect(outcome.createdRatePolicy == nil)
        #expect(store.currentHourlyRateCents == nil)
    }

    @Test("running the migrations twice changes nothing")
    func isIdempotent() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)
        store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: 283, deviceTimeZone: PaydayTestZone.newYork
        )
        let first = store.policies

        // A different weekday and zone on the second run must not matter:
        // the frozen policy is the one the app was already using.
        let second = store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 5, earliestShiftDate: .now,
            baseHourlyWageCents: 900, deviceTimeZone: PaydayTestZone.tokyo
        )
        #expect(second.changedAnything == false)
        #expect(store.policies == first)
        #expect(store.currentHourlyRateCents == 283)
        #expect(store.payrollTimeZone == PaydayTestZone.newYork)
    }

    @Test("the migration creates ONE assumed rate policy from the earliest shift")
    func createsOneAssumedRate() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PaydayTestZone.newYork
        let earliest = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 18))!

        let outcome = store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: earliest,
            baseHourlyWageCents: 283, deviceTimeZone: PaydayTestZone.newYork
        )

        let rate = try! #require(outcome.createdRatePolicy)
        #expect(store.policies.rates.count == 1, "no rate history is invented")
        #expect(rate.hourlyRateCents == 283)
        #expect(rate.provenance == .assumedFromLegacySetting)
        #expect(rate.effectiveFrom == CivilDay(year: 2026, month: 3, day: 14))
        #expect(store.owesRateHistoryPrompt(shiftCount: 12))
        // A user with no shifts is asked nothing.
        #expect(store.owesRateHistoryPrompt(shiftCount: 0) == false)
    }

    /// The defect a render found: gating the rate on a "has this run" flag
    /// meant a wage set AFTER the first launch never produced a rate policy,
    /// so every wage in the app read `.rateNotSet` and the wage line vanished
    /// from every total. Several live paths write the legacy mirror without
    /// coming through Settings > Payroll, the shipped 1.0 build among them.
    @Test("a wage that appears after the first run is still adopted")
    func adoptsALaterWage() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)

        store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: nil, deviceTimeZone: PaydayTestZone.newYork
        )
        #expect(store.currentHourlyRateCents == nil)
        #expect(store.migrationFlags.rate, "the flag really was written on the first pass")

        let outcome = store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: 283, deviceTimeZone: PaydayTestZone.newYork
        )
        #expect(outcome.createdRatePolicy != nil)
        #expect(store.currentHourlyRateCents == 283)
        #expect(store.policies.hasOnlyAssumedRates)
    }

    @Test("clearing the rate is not undone by the next adoption pass")
    func doesNotResurrectAClearedRate() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)
        store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: 283, deviceTimeZone: PaydayTestZone.newYork
        )
        store.applyRateEdit(hourlyRateCents: nil)
        #expect(store.currentHourlyRateCents == nil)

        // Settings clears the legacy mirror alongside the policy, so the
        // adoption pass has nothing to adopt. This is exactly the call the
        // app makes after every sync.
        let outcome = store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: nil, deviceTimeZone: PaydayTestZone.newYork
        )
        #expect(outcome.changedAnything == false)
        #expect(store.currentHourlyRateCents == nil)
    }

    /// Design 1, verbatim: "The migration does not touch
    /// PaydaySettingsSyncClock." A read-time bump would make an untouched
    /// install look newer than another device's real settings and clobber
    /// them, which is the trap `PaydaySettingsSyncClock.modifiedAt` already
    /// documents for fresh installs.
    @Test("neither migration advances the settings sync clock")
    func migrationsDoNotTouchTheSettingsClock() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)
        #expect(defaults.object(forKey: settingsClockKey) == nil)

        store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: .now,
            baseHourlyWageCents: 283, deviceTimeZone: PaydayTestZone.newYork
        )

        #expect(store.policies.rates.count == 1, "the migration really did write something")
        #expect(store.policies.calendars.count == 1)
        #expect(PaydaySettingsSyncClock.modifiedAt(in: defaults) == Date(timeIntervalSince1970: 0),
                "the migration advanced the settings clock")
    }

    @Test("a user edit DOES advance the settings clock, so it wins over the server's copy")
    func userEditsTouchTheSettingsClock() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)
        store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: nil, deviceTimeZone: PaydayTestZone.newYork
        )
        #expect(PaydaySettingsSyncClock.modifiedAt(in: defaults) == Date(timeIntervalSince1970: 0))

        store.applyRateEdit(hourlyRateCents: 500)

        #expect(PaydaySettingsSyncClock.modifiedAt(in: defaults) > Date(timeIntervalSince1970: 0))
        #expect(store.currentHourlyRateCents == 500)
    }

    @Test("a download does NOT advance the settings clock")
    func remoteReplacementDoesNotTouchTheClock() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)
        let remote = CompensationPolicies(
            rates: [PayRatePolicy(id: UUID(), effectiveFrom: .distantPast, hourlyRateCents: 400, provenance: .confirmed)],
            calendars: []
        )

        store.replaceFromSupabase(remote)

        #expect(store.currentHourlyRateCents == 400)
        #expect(PaydaySettingsSyncClock.modifiedAt(in: defaults) == Date(timeIntervalSince1970: 0))
    }

    @Test("policies survive a new store over the same defaults")
    func persistsAcrossStores() {
        let defaults = freshDefaults()
        let first = PolicyStore(defaults: defaults)
        first.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: 283, deviceTimeZone: PaydayTestZone.tokyo
        )

        // A second process (the widget) reading the same App Group.
        let second = PolicyStore(defaults: defaults)
        #expect(second.policies == first.policies)
        #expect(second.payrollTimeZone == PaydayTestZone.tokyo)
        #expect(PolicyStore.storedPayrollTimeZone(defaults: defaults) == PaydayTestZone.tokyo)
        #expect(PolicyStore.storedPolicies(defaults: defaults).latestRate?.hourlyRateCents == 283)
    }

    @Test("reset clears the policies and the flags, so a fresh account migrates again")
    func resetClearsEverything() {
        let defaults = freshDefaults()
        let store = PolicyStore(defaults: defaults)
        store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: 283, deviceTimeZone: PaydayTestZone.newYork
        )
        #expect(store.migrationFlags == (calendar: true, rate: true))

        store.reset()

        #expect(store.policies.isEmpty)
        #expect(store.migrationFlags == (calendar: false, rate: false))
        let outcome = store.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil,
            baseHourlyWageCents: 283, deviceTimeZone: PaydayTestZone.newYork
        )
        #expect(outcome.createdCalendarPolicy != nil)
        #expect(outcome.createdRatePolicy != nil)
    }
}

@Suite("PolicyStore rate and calendar edits")
struct PolicyStoreEditTests {
    private func migratedStore(rate: Int? = 283, weekday: Int = 2) -> PolicyStore {
        let store = PolicyStore(defaults: freshDefaults())
        store.runMigrationsIfNeeded(
            resolvedFirstWeekday: weekday, earliestShiftDate: nil,
            baseHourlyWageCents: rate, deviceTimeZone: PaydayTestZone.newYork
        )
        return store
    }

    @Test("editing the rate rewrites the latest policy in place, so correcting a typo is not a raise")
    func editRewritesInPlace() {
        let store = migratedStore()
        let before = try! #require(store.policies.latestRate)

        store.applyRateEdit(hourlyRateCents: 300)

        #expect(store.policies.rates.count == 1)
        #expect(store.policies.rates[0].id == before.id)
        #expect(store.policies.rates[0].effectiveFrom == before.effectiveFrom)
        #expect(store.policies.rates[0].hourlyRateCents == 300)
        #expect(store.policies.rates[0].provenance == .confirmed, "the user just typed it")
    }

    @Test("a dated rate change adds a policy and reprices only shifts on or after it")
    func datedChangeAddsAPolicy() {
        let store = migratedStore()
        let changeDay = CivilDay(year: 2026, month: 9, day: 28)

        store.applyRateChange(hourlyRateCents: 500, effectiveFrom: changeDay)

        #expect(store.policies.rates.count == 2)
        #expect(store.currentHourlyRateCents == 500)
        #expect(store.policies.rate(on: changeDay.adding(days: -1))?.hourlyRateCents == 283)
        #expect(store.policies.rate(on: changeDay)?.hourlyRateCents == 500)

        // And the ledger agrees: the earlier week is untouched.
        let shifts = [
            ShiftInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                       workDay: changeDay.adding(days: -7), period: .dinner, minutesWorked: 300),
            ShiftInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                       workDay: changeDay, period: .dinner, minutesWorked: 300)
        ]
        let valuations = CompensationLedger.value(
            shifts, rates: store.policies.rates, calendars: store.policies.calendars
        )
        #expect(valuations[0].components.regularWagesCents == 1415)
        #expect(valuations[1].components.regularWagesCents == 2500)
    }

    @Test("confirming the rate history changes no cents, only the label")
    func confirmingChangesNoCents() {
        let store = migratedStore()
        let shifts = [ShiftInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                 workDay: CivilDay(year: 2026, month: 9, day: 28),
                                 period: .dinner, minutesWorked: 300)]
        let before = CompensationLedger.evaluate(shifts, rates: store.policies.rates, calendars: store.policies.calendars)
        #expect(before.completeness.state == .estimated)

        store.confirmRateHistory()

        let after = CompensationLedger.evaluate(shifts, rates: store.policies.rates, calendars: store.policies.calendars)
        #expect(after.totalComponents == before.totalComponents)
        #expect(after.completeness.state == .complete)
        #expect(store.policies.hasOnlyAssumedRates == false)
        #expect(store.owesRateHistoryPrompt(shiftCount: 12) == false)
    }

    @Test("a workweek change takes effect at the next boundary strictly after today")
    func workweekChangeTakesEffectNextBoundary() {
        let store = migratedStore(weekday: 2)
        // Monday 2026-09-28. Today being a boundary must NOT make the change
        // retroactive to this morning.
        let today = CivilDay(year: 2026, month: 9, day: 28)

        let pending = try! #require(store.applyCalendarChange(
            workweekStartWeekday: 1, payrollTimeZone: PaydayTestZone.newYork, today: today
        ))

        #expect(pending.effectiveFrom > today)
        #expect(pending.effectiveFrom == CivilDay(year: 2026, month: 10, day: 5), "the next Monday")
        #expect(pending.effectiveFrom.weekday == 2, "a boundary under the PREVIOUS policy")
        #expect(pending.workweekStartWeekday == 1)
        #expect(store.calendarPolicyInEffect(today: today)?.workweekStartWeekday == 2)
        #expect(store.pendingCalendarPolicy(today: today)?.id == pending.id)

        // The engine accepts it without a diagnostic.
        let accepted = CompensationLedger.acceptCalendarPolicies(store.policies.calendars)
        #expect(accepted.diagnostics.isEmpty)
        #expect(accepted.accepted.count == 2)
    }

    @Test("a second workweek change before the first lands replaces it rather than stacking")
    func secondChangeReplacesThePending() {
        let store = migratedStore(weekday: 2)
        let today = CivilDay(year: 2026, month: 9, day: 30)

        store.applyCalendarChange(workweekStartWeekday: 1, payrollTimeZone: PaydayTestZone.newYork, today: today)
        store.applyCalendarChange(workweekStartWeekday: 4, payrollTimeZone: PaydayTestZone.newYork, today: today)
        store.applyCalendarChange(workweekStartWeekday: 6, payrollTimeZone: PaydayTestZone.newYork, today: today)

        #expect(store.policies.calendars.count == 2, "one settled policy and one pending, never four")
        #expect(store.pendingCalendarPolicy(today: today)?.workweekStartWeekday == 6)
    }

    @Test("reverting to what is already in effect removes the pending policy instead of recording a no-op")
    func revertingRemovesThePending() {
        let store = migratedStore(weekday: 2)
        let today = CivilDay(year: 2026, month: 9, day: 30)

        store.applyCalendarChange(workweekStartWeekday: 1, payrollTimeZone: PaydayTestZone.newYork, today: today)
        #expect(store.policies.calendars.count == 2)

        let reverted = store.applyCalendarChange(
            workweekStartWeekday: 2, payrollTimeZone: PaydayTestZone.newYork, today: today
        )
        #expect(reverted == nil)
        #expect(store.policies.calendars.count == 1)
        #expect(store.pendingCalendarPolicy(today: today) == nil)
    }

    @Test("a zone change freezes the new zone forward and leaves earlier shifts on the old one")
    func zoneChangeIsForwardOnly() {
        let store = migratedStore(weekday: 2)
        let today = CivilDay(year: 2026, month: 9, day: 30)

        let pending = try! #require(store.applyCalendarChange(
            workweekStartWeekday: 2, payrollTimeZone: PaydayTestZone.tokyo, today: today
        ))

        #expect(pending.payrollTimeZone == PaydayTestZone.tokyo)
        #expect(store.policies.calendar(on: today)?.payrollTimeZone == PaydayTestZone.newYork)
        #expect(store.policies.calendar(on: pending.effectiveFrom)?.payrollTimeZone == PaydayTestZone.tokyo)
        // `payrollTimeZone` reports the LATEST policy, which is what a new
        // shift logged from now on will be dated in.
        #expect(store.payrollTimeZone == PaydayTestZone.tokyo)
    }
}

/// The frozen payroll zone, measured on the two app types that bucket by
/// civil day. Both used to force `TimeZone.current` onto whatever calendar
/// they were handed, so a flight redrew history nobody had touched.
@Suite("Payroll time zone is frozen, not the device's")
struct FrozenPayrollTimeZoneTests {
    private let schedule = PaySchedule(
        frequency: .biweekly,
        anchorPeriodEnd: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = PaydayTestZone.newYork
            return calendar.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        }(),
        payDelayDays: 5,
        firstWeekday: 2
    )

    @Test("PayPeriodCalculator uses the zone it is given, not the process zone")
    func calculatorHonoursTheGivenZone() {
        // 2026-10-05 02:30 UTC is still Oct 4 in New York and already Oct 5
        // in Tokyo, so the two zones disagree about which period this
        // instant falls in — which is the whole point of freezing one.
        let instant = ISO8601DateFormatter().date(from: "2026-10-05T02:30:00Z")!

        let newYork = PayPeriodCalculator(payrollTimeZone: PaydayTestZone.newYork, schedule: schedule)
        let tokyo = PayPeriodCalculator(payrollTimeZone: PaydayTestZone.tokyo, schedule: schedule)

        #expect(newYork.payrollTimeZone == PaydayTestZone.newYork)
        #expect(tokyo.payrollTimeZone == PaydayTestZone.tokyo)
        #expect(newYork.period(containing: instant).end != tokyo.period(containing: instant).end,
                "the two zones really do disagree about this instant")

        // And the zone is honoured whatever calendar it arrives with: a
        // calendar carrying Honolulu does not override it.
        var honoluluCalendar = Calendar(identifier: .gregorian)
        honoluluCalendar.timeZone = PaydayTestZone.honolulu
        let stillNewYork = PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.newYork, schedule: schedule, calendar: honoluluCalendar
        )
        #expect(stillNewYork.period(containing: instant) == newYork.period(containing: instant))
    }

    @Test("StatsEngine uses the zone it is given, not the process zone")
    func engineHonoursTheGivenZone() {
        let instant = ISO8601DateFormatter().date(from: "2026-10-05T02:30:00Z")!
        let records = [TipRecord(date: instant, amountCents: 5000, kind: .credit, isDouble: false, hoursWorked: 5)]

        let newYork = StatsEngine(payrollTimeZone: PaydayTestZone.newYork, records: records)
        let tokyo = StatsEngine(payrollTimeZone: PaydayTestZone.tokyo, records: records)

        #expect(newYork.payrollTimeZone == PaydayTestZone.newYork)
        let newYorkNight = try! #require(newYork.nightlyTotals().first)
        let tokyoNight = try! #require(tokyo.nightlyTotals().first)
        #expect(newYorkNight.cents == tokyoNight.cents, "the money is the same money")
        #expect(newYorkNight.date != tokyoNight.date, "but the civil day it lands on is not")
    }

    @Test("the same shift is worth the same cents whatever zone the device is in")
    func wagesDoNotMoveWithTheDevice() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PaydayTestZone.newYork
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 17))!
        let entries = [TipEntry(
            date: day, amountCents: 5000, kind: .credit, isDouble: false,
            hoursWorked: 9.75, shiftID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )]

        let fromNewYork = PeriodIncome.wages(
            payrollTimeZone: PaydayTestZone.newYork, entries: entries, wageCentsPerHour: 283, firstWeekday: 2
        )
        // The payroll zone is frozen at New York; the DEVICE being in Tokyo
        // must not reach this call at all, which is what "required
        // parameter" buys. Passing New York from a Tokyo device is the real
        // behaviour, and it is identical.
        let fromTokyoDevice = PeriodIncome.wages(
            payrollTimeZone: PaydayTestZone.newYork, entries: entries, wageCentsPerHour: 283, firstWeekday: 2,
            calendar: {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = PaydayTestZone.tokyo
                return c
            }()
        )

        #expect(fromNewYork?.totalCents == 2759, "W1's number")
        #expect(fromNewYork?.totalCents == fromTokyoDevice?.totalCents)
        #expect(fromNewYork?.regularCents == fromTokyoDevice?.regularCents)
        #expect(fromNewYork?.overtimeCents == 0)
    }
}
