import Testing
import Foundation
@testable import Payday

/// Fresh, isolated UserDefaults suites per test — never `.standard` or the
/// real app-group suite, so these cannot bleed into a real device's policies.
private func freshDefaults() -> UserDefaults {
    let suiteName = "com.szakacsmedia.payday.settingstests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CivilDay {
    CivilDay(validating: year, month: month, day: dayOfMonth)!
}

// ═══════════════════════════════════════════════════════════════════════════
//  PR 5 group 2.15: Settings, one row.
//
//  `docs/METRICS.md` [ST-01] — Settings > Payroll > "Hourly wage". It is the
//  app's only figure with no `MetricID`: a policy INPUT, not a dated earnings
//  answer, so it is not an `EarningsFigure` and there is nothing here for
//  `EarningsSnapshot` to answer. What the row owes the contract is rule 4's
//  second half — an unavailable read renders no currency — and the inventory
//  row recorded the breach in so many words: "The rendered placeholder
//  '$0.00' is a money string shown for a nil value, which the contract
//  (Section 4, rule 4) forbids."
// ═══════════════════════════════════════════════════════════════════════════
@Suite("Settings hourly wage row reads the rate policy")
struct SettingsWageRowTests {

    /// Rule 4: nil means the wage feature is off, and "$0.00" would be a
    /// claim that the rate is zero on real worked hours.
    @Test("no rate policy renders 'Not set', never a currency string")
    func noRateRendersNoCurrency() {
        #expect(PayrollSettingsSection.rateDisplay(nil) == "Not set")
        #expect(!PayrollSettingsSection.rateDisplay(nil).contains("$"))
    }

    @Test("a rate policy renders its own rate with cents")
    func rateRendersItself() {
        #expect(PayrollSettingsSection.rateDisplay(283) == Money.string(fromCents: 283))
        #expect(PayrollSettingsSection.rateDisplay(1_500) == Money.string(fromCents: 1_500))
    }

    /// The row reads the POLICY. The legacy scalar
    /// (`UserPreferencesStore.baseHourlyWageCents`) is a one-way mirror
    /// written on edit for the shipped 1.0 build, the widget and the Siri
    /// intent; nothing in Settings reads it back, so a stale mirror cannot
    /// put a different rate on screen.
    @Test("the row follows the rate policy, not the legacy scalar")
    func rowFollowsThePolicy() {
        let store = PolicyStore(defaults: freshDefaults())
        #expect(store.currentHourlyRateCents == nil)

        store.applyRateEdit(hourlyRateCents: 1_500)
        #expect(store.currentHourlyRateCents == 1_500)
        #expect(PayrollSettingsSection.rateDisplay(store.currentHourlyRateCents) == "$15.00")

        // A dated raise moves the row to the new rate without rewriting the
        // old policy: the history is what prices old shifts.
        store.applyRateChange(hourlyRateCents: 2_000, effectiveFrom: day(2026, 6, 1))
        #expect(store.policies.rates.count == 2)
        #expect(PayrollSettingsSection.rateDisplay(store.currentHourlyRateCents) == "$20.00")
        #expect(store.policies.rate(on: day(2026, 5, 31))?.hourlyRateCents == 1_500)

        // Turning the wage off removes every rate policy, and the row says so
        // in words rather than in dollars.
        store.applyRateEdit(hourlyRateCents: nil)
        #expect(store.policies.rates.isEmpty)
        #expect(PayrollSettingsSection.rateDisplay(store.currentHourlyRateCents) == "Not set")
    }

    /// A typed `0` is not a rate: `Int("0")` is 0 and not nil, so the digits
    /// rule has to reject it explicitly or a `.confirmed` $0.00/hr policy
    /// reaches the ledger.
    @Test("zero and empty digits are both 'no rate', so the row never prints $0.00")
    func zeroIsNotARate() {
        #expect(PayrollSettingsSection.rateCents(fromDigits: "") == nil)
        #expect(PayrollSettingsSection.rateCents(fromDigits: "0") == nil)
        #expect(PayrollSettingsSection.rateCents(fromDigits: "00") == nil)
        #expect(PayrollSettingsSection.rateCents(fromDigits: "1500") == 1_500)
        // 4-digit cap: $99.99/hr.
        #expect(PayrollSettingsSection.rateCents(fromDigits: "123456") == 1_234)
        #expect(PayrollSettingsSection.rateDisplay(PayrollSettingsSection.rateCents(fromDigits: "0")) == "Not set")
    }

    /// The display/editor pairing, pinned. `currentHourlyRateCents` is
    /// `latestRate` (newest policy on file) while `policies.rate(on:)` is the
    /// effective-dated lookup, and the row uses the former because
    /// `applyRateEdit` rewrites the former IN PLACE. That is only safe while
    /// no rate policy can be effective in the FUTURE — `RateChangeSheet`'s
    /// date picker is bounded `in: ...Date.now`, so every policy the UI can
    /// write is effective today or earlier, and the two lookups agree.
    ///
    /// The second half of the test is the counterexample, so the claim is
    /// measured rather than asserted: with a future-dated policy forced in,
    /// the two DO diverge, which is why this pairing is written down.
    @Test("for every policy set the UI can write, latestRate is the rate in effect today")
    func latestRateIsTodaysRateForEveryUIWritablePolicySet() throws {
        let store = PolicyStore(defaults: freshDefaults())
        let today = CivilDay(.now, in: store.payrollTimeZone)

        store.applyRateEdit(hourlyRateCents: 1_200)
        store.applyRateChange(hourlyRateCents: 1_800, effectiveFrom: day(2026, 1, 15))
        store.applyRateChange(hourlyRateCents: 2_400, effectiveFrom: today)

        #expect(store.policies.rates.count == 3)
        #expect(store.currentHourlyRateCents == store.policies.rate(on: today)?.hourlyRateCents)
        #expect(store.currentHourlyRateCents == 2_400)

        // The counterexample: a future-dated policy, which no Settings
        // control can produce. `latestRate` would show a rate nobody is
        // being paid yet. Nothing writes this, and this test is the record
        // of why the date picker's upper bound matters.
        let future = CivilDay(Date.now.addingTimeInterval(60 * 60 * 24 * 30), in: store.payrollTimeZone)
        let queued = CompensationPolicies(
            version: store.policies.version,
            rates: store.policies.rates + [PayRatePolicy(
                id: PolicyMigration.deterministicID("settings/test/queued"),
                effectiveFrom: future,
                hourlyRateCents: 9_900,
                provenance: .confirmed
            )],
            calendars: store.policies.calendars
        )
        #expect(queued.latestRate?.hourlyRateCents == 9_900)
        #expect(queued.rate(on: today)?.hourlyRateCents == 2_400)
    }
}
