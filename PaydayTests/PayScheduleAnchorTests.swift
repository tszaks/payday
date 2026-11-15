import Foundation
import PaydayCore
import Testing
@testable import Payday

/// The primary schedule's anchor between the Settings and first-run pickers
/// (the phone's calendar) and the stored value `PayPeriodCalculator` reads
/// (a civil day in the payroll zone).
@Suite("Pay schedule anchor across two zones")
struct PayScheduleAnchorTests {
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    /// (payroll, phone): payroll west of the phone twice, then east of it.
    private static let payrollZones = [losAngeles, losAngeles, PaydayTestZone.newYork]
    private static let phoneZones = [PaydayTestZone.newYork, PaydayTestZone.tokyo, losAngeles]

    private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("the picked day is the day the calculator ends the period on",
          arguments: zip(payrollZones, phoneZones))
    func pickedDayIsThePeriodEnd(payroll: TimeZone, phone: TimeZone) {
        // Sunday Oct 4, as the phone's picker hands it over.
        let picked = at(2026, 10, 4, in: phone)
        let stored = PayScheduleAnchor.stored(picked: picked, payrollTimeZone: payroll, phoneTimeZone: phone)
        #expect(stored == at(2026, 10, 4, in: payroll))

        let calculator = PayPeriodCalculator(
            payrollTimeZone: payroll,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: stored, payDelayDays: 5))
        let period = calculator.period(containing: at(2026, 10, 1, hour: 12, in: payroll))
        #expect(CivilDay(period.end, in: payroll) == CivilDay(year: 2026, month: 10, day: 4))
        #expect(CivilDay(calculator.payDate(for: period), in: payroll) == CivilDay(year: 2026, month: 10, day: 9))
    }

    @Test("a stored anchor shows as the day that was picked",
          arguments: zip(payrollZones, phoneZones))
    func roundTrip(payroll: TimeZone, phone: TimeZone) {
        for hour in [0, 9, 23] {
            let picked = at(2026, 10, 4, hour: hour, in: phone)
            let stored = PayScheduleAnchor.stored(picked: picked, payrollTimeZone: payroll, phoneTimeZone: phone)
            let shown = PayScheduleAnchor.shown(stored: stored, payrollTimeZone: payroll, phoneTimeZone: phone)
            #expect(shown == at(2026, 10, 4, in: phone), "hour \(hour)")
        }
    }

    @Test("in one zone the stored anchor is the phone's start of day, bit for bit")
    func oneZoneIsStartOfDay() {
        for zone in [Self.losAngeles, PaydayTestZone.newYork, PaydayTestZone.tokyo, PaydayTestZone.payroll] {
            var calendar = Calendar.current
            calendar.timeZone = zone
            // A DST change week too: Nov 1 2026 in the US zones.
            for picked in [at(2026, 10, 4, hour: 15, in: zone), at(2026, 11, 1, hour: 15, in: zone)] {
                let stored = PayScheduleAnchor.stored(picked: picked, payrollTimeZone: zone, phoneTimeZone: zone)
                #expect(stored == calendar.startOfDay(for: picked))
                #expect(PayScheduleAnchor.shown(stored: stored, payrollTimeZone: zone, phoneTimeZone: zone) == stored)
            }
        }
    }

    // MARK: - The server's copy

    /// Midnight in Kiritimati (UTC+14) is the previous day on every other
    /// clock on Earth, so a reading through the phone's calendar cannot pass
    /// these by luck.
    private static let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!

    @Test("the server holds the anchor's payroll civil day, and gives the same anchor back")
    func wireDayIsThePayrollDay() {
        let stored = CivilDay(year: 2026, month: 10, day: 4).date(in: Self.kiritimati)
        #expect(PayScheduleAnchor.wireDay(stored: stored, payrollTimeZone: Self.kiritimati) == "2026-10-04")
        #expect(PayScheduleAnchor.stored(wireDay: "2026-10-04", payrollTimeZone: Self.kiritimati) == stored)
        #expect(PayScheduleAnchor.stored(wireDay: "October 4", payrollTimeZone: Self.kiritimati) == nil)
    }

    @Test("the settings row a phone uploads names the anchor's payroll day")
    @MainActor
    func uploadedSettingsNameThePayrollDay() {
        func freshDefaults() -> UserDefaults {
            let name = "com.szakacsmedia.payday.anchortests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }
        let policyStore = PolicyStore(defaults: freshDefaults())
        policyStore.replaceFromSupabase(CompensationPolicies(calendars: [
            PolicyMigration.frozenCalendarPolicy(workweekStartWeekday: 1, payrollTimeZone: Self.kiritimati)
        ]))
        let scheduleStore = PayScheduleStore(defaults: freshDefaults())
        scheduleStore.schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: CivilDay(year: 2026, month: 10, day: 4).date(in: Self.kiritimati)
        )

        let row = RemoteUserSettings(
            userID: UUID(),
            scheduleStore: scheduleStore,
            preferencesStore: UserPreferencesStore(defaults: freshDefaults(), wageDefaults: freshDefaults()),
            moveLedgerStore: MoveLedgerStore(defaults: freshDefaults()),
            policyStore: policyStore
        )
        #expect(row.anchorPeriodEnd == "2026-10-04")
    }
}
