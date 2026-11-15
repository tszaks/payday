import Foundation
import SwiftData
import Testing
@testable import Payday

/// A stored day (`ShiftRecord.workDate`, `PaycheckRecord.periodStart` and
/// `periodEnd`) is the start of its civil day in the payroll zone it is read
/// in, so it is the same day on every phone (`StoredDay`). Every zone here is
/// named, phone and payroll alike, so nothing depends on the simulator's.
@Suite("Stored days")
@MainActor
struct StoredDayTests {
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in zone: TimeZone) -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func calendarPolicy(
        _ zone: TimeZone,
        from day: CivilDay = .distantPast,
        id: String,
        job: String? = nil
    ) -> PayrollCalendarPolicy {
        PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("storedday/\(id)"),
            effectiveFrom: day,
            workweekStartWeekday: 2,
            payrollTimeZone: zone,
            jobName: job
        )
    }

    /// New York until Monday Aug 3, Los Angeles from then on.
    static let zoneHistory = [
        calendarPolicy(newYork, id: "history/newyork"),
        calendarPolicy(losAngeles, from: CivilDay(year: 2026, month: 8, day: 3), id: "history/losangeles"),
    ]

    static func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// The real save path, with the phone's zone stated.
    static func save(
        picked: Date,
        calendars: [PayrollCalendarPolicy],
        phone: TimeZone,
        in context: ModelContext
    ) throws -> ShiftRecord {
        try ShiftCommands.create(
            in: context, workDate: picked, calendars: calendars,
            cashTipsCents: 5_000, phoneTimeZone: phone)
    }

    static func workDay(_ record: ShiftRecord, _ calendars: [PayrollCalendarPolicy]) -> CivilDay {
        ShiftInputAdapter.input(from: record, calendars: calendars).workDay
    }

    static func wireDay(_ record: ShiftRecord, _ calendars: [PayrollCalendarPolicy]) -> String {
        RemoteShift(record: record, userID: userID, calendars: calendars).workDate
    }

    static let july19 = CivilDay(year: 2026, month: 7, day: 19)

    // MARK: A, B: saving on a phone outside the payroll zone

    /// A. Tokyo is 13 hours ahead of New York in July, so its midnight on
    /// Jul 19 is 11 AM on Jul 18 in New York.
    @Test("A: a shift saved on a phone in Tokyo for a New York payroll is New York's Jul 19")
    func savedEastOfPayroll() throws {
        let calendars = [Self.calendarPolicy(Self.newYork, id: "a")]
        for picked in [Self.at(2026, 7, 19, in: Self.tokyo), Self.at(2026, 7, 19, hour: 22, in: Self.tokyo)] {
            let record = try Self.save(picked: picked, calendars: calendars, phone: Self.tokyo, in: Self.context())
            #expect(record.workDate == Self.at(2026, 7, 19, in: Self.newYork))
            #expect(Self.workDay(record, calendars) == Self.july19)
            #expect(Self.wireDay(record, calendars) == "2026-07-19")
        }
    }

    /// B. Los Angeles is west of New York: its midnight on Jul 19 is 3 AM on
    /// Jul 19 in New York, and New York's midnight is 9 PM on Jul 18 there.
    @Test("B: a shift saved on a phone in Los Angeles for a New York payroll shows Jul 19 on that phone")
    func savedWestOfPayroll() throws {
        let calendars = [Self.calendarPolicy(Self.newYork, id: "b")]
        let storedDay = StoredDay(.workDay, calendars: calendars)
        let record = try Self.save(
            picked: Self.at(2026, 7, 19, hour: 23, in: Self.losAngeles),
            calendars: calendars, phone: Self.losAngeles, in: Self.context())
        #expect(record.workDate == Self.at(2026, 7, 19, in: Self.newYork))
        #expect(Self.workDay(record, calendars) == Self.july19)
        #expect(Self.wireDay(record, calendars) == "2026-07-19")
        let shown = storedDay.shown(record.workDate, job: nil, phoneTimeZone: Self.losAngeles)
        #expect(CivilDay(shown, in: Self.losAngeles) == Self.july19)
        #expect(shown == Self.at(2026, 7, 19, in: Self.losAngeles))
    }

    /// "Today" is the phone's: a future pick is clamped to the phone's own
    /// today, then stored as that day's start in the payroll zone.
    @Test("a future pick is clamped to the phone's today, stored in the payroll zone")
    func futurePickClampsToThePhonesToday() throws {
        let calendars = [Self.calendarPolicy(Self.newYork, id: "today")]
        let before = CivilDay(.now, in: Self.tokyo)
        let record = try Self.save(
            picked: Date.now.addingTimeInterval(86_400 * 7),
            calendars: calendars, phone: Self.tokyo, in: Self.context())
        // Either side of the save, in case Tokyo's midnight falls between.
        let phoneToday = Self.workDay(record, calendars)
        #expect([before, CivilDay(.now, in: Self.tokyo)].contains(phoneToday))
        #expect(record.workDate == phoneToday.date(in: Self.newYork))
    }

    // MARK: D: rows stored under the old rule

    /// D. An earlier build on a phone in Tokyo stored Tokyo's midnights for a
    /// Los Angeles payroll. The repair moves them across, once, and the sync
    /// does not see an edit.
    @Test("D: the upgrade repair moves old rows to their days, once, without an edit")
    func upgradeRepair() throws {
        let calendars = [Self.calendarPolicy(Self.losAngeles, id: "d")]
        let context = try Self.context()
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        let shifts = (13...19).map { day in
            ShiftRecord(workDate: Self.at(2026, 7, day, in: Self.tokyo), cashTipsCents: 1_000, modifiedAt: stamp)
        }
        shifts.forEach(context.insert)
        let check = PaycheckRecord(
            periodStart: Self.at(2026, 7, 13, in: Self.tokyo),
            periodEnd: Self.at(2026, 7, 19, in: Self.tokyo),
            paidTipsCents: 7_000)
        check.touch(at: stamp)
        context.insert(check)
        try context.save()
        // Before: every day one early.
        #expect(shifts.map { Self.workDay($0, calendars).day } == Array(12...18))
        let shiftVersions = try PaydayRowFingerprint.values(shifts)
        let checkVersion = try PaydayRowFingerprint.value(check)

        #expect(try StoredDayRepair.reanchor(in: context, calendars: calendars, phoneTimeZone: Self.tokyo))
        #expect(shifts.map { Self.workDay($0, calendars).day } == Array(13...19))
        #expect(shifts.map(\.workDate) == (13...19).map { Self.at(2026, 7, $0, in: Self.losAngeles) })
        #expect(check.periodStart == Self.at(2026, 7, 13, in: Self.losAngeles))
        #expect(check.periodEnd == Self.at(2026, 7, 19, in: Self.losAngeles))
        #expect(shifts.map { Self.wireDay($0, calendars) } == (13...19).map { "2026-07-\($0)" })

        // Not an edit.
        #expect(shifts.allSatisfy { $0.modifiedAt == stamp })
        #expect(check.modifiedAt == stamp)
        #expect(PaydaySyncState.changedIDs(current: try PaydayRowFingerprint.values(shifts), acknowledged: shiftVersions).isEmpty)
        #expect(try PaydayRowFingerprint.value(check) == checkVersion)

        // Idempotent.
        let afterFirst = shifts.map(\.workDate)
        #expect(try !StoredDayRepair.reanchor(in: context, calendars: calendars, phoneTimeZone: Self.tokyo))
        #expect(shifts.map(\.workDate) == afterFirst)
    }

    /// A phone that has since moved: the old rows are not its midnights any
    /// more, so `stableDay` names their day.
    @Test("D: a row the phone wrote in another zone is recovered by stableDay's day")
    func repairFromAThirdZone() {
        let storedDay = StoredDay(.workDay, calendars: [Self.calendarPolicy(Self.losAngeles, id: "d/third")])
        let written = Self.at(2026, 7, 19, in: Self.tokyo)
        #expect(storedDay.repaired(written, job: nil, phoneTimeZone: Self.newYork) == Self.at(2026, 7, 19, in: Self.losAngeles))
    }

    // MARK: E: a phone that never leaves its payroll zone

    /// One zone per whole-hour offset from UTC-11 to UTC+14, a fixed-offset
    /// zone for each hour, and the zones with half-hour offsets, summer time,
    /// or a clock change at midnight.
    static let sweepZones: [TimeZone] = {
        let named = [
            "Pacific/Pago_Pago", "Pacific/Honolulu", "America/Adak", "Pacific/Marquesas",
            "America/Anchorage", "America/Los_Angeles", "America/Denver", "America/Phoenix",
            "America/Chicago", "America/Mexico_City", "America/New_York", "America/Havana",
            "America/Bogota", "America/Santiago", "America/Asuncion", "America/Halifax",
            "America/St_Johns", "America/Sao_Paulo", "America/Nuuk", "America/Noronha",
            "Atlantic/Azores", "Atlantic/Cape_Verde", "Europe/London", "Africa/Abidjan",
            "Europe/Paris", "Africa/Lagos", "Europe/Athens", "Africa/Cairo", "Asia/Beirut",
            "Europe/Moscow", "Asia/Tehran", "Asia/Dubai", "Asia/Kabul", "Asia/Karachi",
            "Asia/Kolkata", "Asia/Kathmandu", "Asia/Dhaka", "Asia/Yangon", "Asia/Bangkok",
            "Asia/Shanghai", "Australia/Eucla", "Asia/Tokyo", "Australia/Adelaide",
            "Australia/Sydney", "Australia/Lord_Howe", "Pacific/Noumea", "Pacific/Norfolk",
            "Pacific/Auckland", "Pacific/Fiji", "Pacific/Chatham", "Pacific/Tongatapu",
            "Pacific/Apia", "Pacific/Kiritimati",
        ].map { TimeZone(identifier: $0)! }
        let fixed = (-11...14).map { TimeZone(secondsFromGMT: $0 * 3_600)! }
        return named + fixed
    }()

    /// E. The pin. For a phone in its payroll zone the stored instant, the
    /// downloaded instant, the wire string, the engine's day and the repair
    /// are exactly what they were before `StoredDay` existed, every day of
    /// 2025 to 2027, so each zone's clock changes are in the sweep.
    @Test("E: for a phone that never leaves its payroll zone nothing changes")
    func sameZoneSweep() {
        var disagreements: [String] = []
        var checked = 0
        let first = CivilDay(year: 2025, month: 1, day: 1)
        let last = CivilDay(year: 2027, month: 12, day: 31)
        for zone in Self.sweepZones {
            let calendar = Self.calendar(zone)
            let calendars = [Self.calendarPolicy(zone, id: "e")]
            for kind in [StoredDay.Kind.workDay, .periodDay] {
                let storedDay = StoredDay(kind, calendars: calendars)
                for number in first.dayNumber...last.dayNumber {
                    let day = CivilDay(dayNumber: number)
                    checked += 1
                    let evening = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 21))!
                    let saved = storedDay.stored(picked: evening, job: nil, phoneTimeZone: zone)
                    let downloaded = storedDay.stored(wireDay: day.iso, job: nil)
                    let wire = storedDay.wireDay(saved, job: nil)
                    let pass = saved == calendar.startOfDay(for: evening)
                        && downloaded == PaydayRemoteDate.parseDay(day.iso, calendar: calendar)
                        && wire == PaydayRemoteDate.day(saved, calendar: calendar)
                        && storedDay.civilDay(saved, job: nil) == CivilDay(saved, in: zone)
                        && CivilDay(saved, in: zone) == day
                        && storedDay.repaired(saved, job: nil, phoneTimeZone: zone) == saved
                        && storedDay.shown(saved, job: nil, phoneTimeZone: zone) == saved
                    if !pass { disagreements.append("\(zone.identifier) \(kind) \(day.iso)") }
                }
            }
        }
        #expect(checked == Self.sweepZones.count * 1_095 * 2)
        #expect(disagreements.isEmpty, "\(disagreements.prefix(20))")
    }

    /// E, through the real writers rather than the helper they call.
    @Test("E: the save, the download and the upload are unchanged in the phone's own zone",
          arguments: ["America/New_York", "Asia/Tokyo", "America/Havana", "Pacific/Kiritimati", "Pacific/Pago_Pago"])
    func sameZoneRealWriters(_ identifier: String) throws {
        let zone = TimeZone(identifier: identifier)!
        let calendar = Self.calendar(zone)
        let calendars = [Self.calendarPolicy(zone, id: "e/real")]
        let context = try Self.context()
        let picked = Self.at(2026, 3, 8, hour: 21, in: zone)
        let record = try Self.save(picked: picked, calendars: calendars, phone: zone, in: context)
        #expect(record.workDate == calendar.startOfDay(for: picked))
        #expect(Self.wireDay(record, calendars) == PaydayRemoteDate.day(record.workDate, calendar: calendar))

        let row = RemoteShift(record: record, userID: Self.userID, calendars: calendars)
        let downloaded = try Self.context()
        _ = try PaydaySyncService.reconcileShifts([row], in: downloaded, calendars: calendars)
        let copy = try #require(try downloaded.fetch(FetchDescriptor<ShiftRecord>()).first)
        #expect(copy.workDate == PaydayRemoteDate.parseDay(row.workDate, calendar: calendar))
        #expect(try !StoredDayRepair.reanchor(in: context, calendars: calendars, phoneTimeZone: zone))
    }

    // MARK: F: travel west after writing

    /// F. Written at home in New York; the phone is now in Los Angeles,
    /// where New York's midnight is the previous evening. The screen shows
    /// the engine's day, the upload sends the same day, and opening the
    /// shift untouched writes nothing.
    @Test("F: after travelling west the screen, the engine and the wire agree")
    func travelWestAfterWriting() throws {
        let calendars = [Self.calendarPolicy(Self.newYork, id: "f")]
        let storedDay = StoredDay(.workDay, calendars: calendars)
        let record = try Self.save(
            picked: Self.at(2026, 7, 19, hour: 20, in: Self.newYork),
            calendars: calendars, phone: Self.newYork, in: Self.context())
        let shown = storedDay.shown(record.workDate, job: nil, phoneTimeZone: Self.losAngeles)
        #expect(CivilDay(shown, in: Self.losAngeles) == Self.workDay(record, calendars))
        #expect(Self.wireDay(record, calendars) == "2026-07-19")
        // The shipped render on the phone's calendar named the day before.
        #expect(PaydayRemoteDate.day(record.workDate, calendar: Self.calendar(Self.losAngeles)) == "2026-07-18")
        #expect(storedDay.stored(picked: shown, job: nil, phoneTimeZone: Self.losAngeles) == record.workDate)
        #expect(storedDay.repaired(record.workDate, job: nil, phoneTimeZone: Self.losAngeles) == record.workDate)
    }

    /// The wire day never depends on the phone: a Tokyo payroll's midnight is
    /// the previous evening on any phone west of Tokyo.
    @Test("the wire day is the payroll zone's civil day on a phone west of it")
    func wireDayIgnoresThePhone() {
        let calendars = [Self.calendarPolicy(Self.tokyo, id: "wire")]
        let record = ShiftRecord(workDate: Self.at(2026, 7, 19, in: Self.tokyo), cashTipsCents: 1_000)
        #expect(Self.wireDay(record, calendars) == "2026-07-19")
    }

    // MARK: H: zone history, jobs

    /// H. Each row is anchored and read in the zone of the policy in effect
    /// on its own day.
    @Test("H: with a zone change each day is stored and read in its own policy's zone")
    func zoneHistory() throws {
        let calendars = Self.zoneHistory
        let context = try Self.context()
        let before = try Self.save(
            picked: Self.at(2026, 7, 19, in: Self.tokyo), calendars: calendars, phone: Self.tokyo, in: context)
        let after = try Self.save(
            picked: Self.at(2026, 8, 10, in: Self.tokyo), calendars: calendars, phone: Self.tokyo, in: context)
        #expect(before.workDate == Self.at(2026, 7, 19, in: Self.newYork))
        #expect(after.workDate == Self.at(2026, 8, 10, in: Self.losAngeles))
        #expect(Self.workDay(before, calendars) == Self.july19)
        #expect(Self.workDay(after, calendars) == CivilDay(year: 2026, month: 8, day: 10))
        #expect(Self.wireDay(before, calendars) == "2026-07-19")
        #expect(Self.wireDay(after, calendars) == "2026-08-10")
        // The first day of the new policy and the last of the old one.
        let storedDay = StoredDay(.workDay, calendars: calendars)
        for day in [CivilDay(year: 2026, month: 8, day: 2), CivilDay(year: 2026, month: 8, day: 3)] {
            #expect(storedDay.civilDay(storedDay.stored(day, job: nil), job: nil) == day)
        }
        #expect(try !StoredDayRepair.reanchor(in: context, calendars: calendars, phoneTimeZone: Self.tokyo))
    }

    /// H. A change that reaches back over stored rows (here a download that
    /// replaces New York with Los Angeles from the start) re-anchors them.
    @Test("H: a retroactive change to a zone further west re-anchors the rows it covers",
          arguments: ["America/New_York", "Asia/Tokyo"])
    func retroactiveChange(_ phone: String) throws {
        let newYork = [Self.calendarPolicy(Self.newYork, id: "h/newyork")]
        let losAngeles = [Self.calendarPolicy(Self.losAngeles, id: "h/losangeles")]
        let context = try Self.context()
        let record = try Self.save(
            picked: Self.at(2026, 7, 19, hour: 20, in: Self.newYork),
            calendars: newYork, phone: Self.newYork, in: context)
        let version = try PaydayRowFingerprint.value(record)
        // Read under the new policies before the repair: a day early.
        #expect(Self.workDay(record, losAngeles) == CivilDay(year: 2026, month: 7, day: 18))

        #expect(try StoredDayRepair.reanchor(in: context, calendars: losAngeles, phoneTimeZone: TimeZone(identifier: phone)!))
        #expect(record.workDate == Self.at(2026, 7, 19, in: Self.losAngeles))
        #expect(Self.workDay(record, losAngeles) == Self.july19)
        #expect(try PaydayRowFingerprint.value(record) == version)
    }

    /// The previous calendars name each stored day exactly, so a change away
    /// from a zone outside `stableDay`'s window keeps every day. The phone is
    /// in a third zone, so neither its calendar nor `stableDay` could.
    @Test("H: a zone change away from the edge of the clock keeps every shift and paycheck day",
          arguments: [("Pacific/Kiritimati", "America/New_York"), ("Pacific/Pago_Pago", "Asia/Tokyo")])
    func changeAwayFromTheEdgeOfTheClock(_ before: String, _ phone: String) throws {
        let edge = TimeZone(identifier: before)!
        let phoneZone = TimeZone(identifier: phone)!
        let previous = [Self.calendarPolicy(edge, id: "h/edge")]
        let losAngeles = [Self.calendarPolicy(Self.losAngeles, id: "h/edge/losangeles")]
        let context = try Self.context()
        let shift = try Self.save(
            picked: Self.at(2026, 7, 19, hour: 9, in: edge), calendars: previous, phone: edge, in: context)
        let paycheck = PaycheckRecord(
            periodStart: Self.at(2026, 7, 13, in: edge), periodEnd: Self.at(2026, 7, 19, in: edge), paidTipsCents: 15_000)
        context.insert(paycheck)

        #expect(try StoredDayRepair.reanchor(in: context, from: previous, calendars: losAngeles, phoneTimeZone: phoneZone))
        #expect(shift.workDate == Self.at(2026, 7, 19, in: Self.losAngeles))
        #expect(paycheck.periodStart == Self.at(2026, 7, 13, in: Self.losAngeles))
        #expect(paycheck.periodEnd == Self.at(2026, 7, 19, in: Self.losAngeles))
        #expect(try !StoredDayRepair.reanchor(in: context, from: losAngeles, calendars: losAngeles, phoneTimeZone: phoneZone))
    }

    /// The app's own path: the policy store remembers the calendars the
    /// stored days follow, and each pass re-anchors from them.
    @Test("H: the repair re-anchors from the calendars the policy store last repaired under")
    func repairsFromTheCalendarsTheStoreRemembers() throws {
        let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
        let suite = "com.szakacsmedia.payday.storedday.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policyStore = PolicyStore(defaults: defaults)
        policyStore.replaceFromSupabase(CompensationPolicies(rates: [], calendars: [Self.calendarPolicy(kiritimati, id: "h/store/edge")]))
        let context = try Self.context()
        let shift = try Self.save(
            picked: Self.at(2026, 7, 19, hour: 9, in: kiritimati),
            calendars: policyStore.policies.calendars, phone: kiritimati, in: context)

        StoredDayRepair.run(in: context, policyStore: policyStore)
        #expect(shift.workDate == Self.at(2026, 7, 19, in: kiritimati))

        policyStore.replaceFromSupabase(CompensationPolicies(rates: [], calendars: [Self.calendarPolicy(Self.losAngeles, id: "h/store/losangeles")]))
        StoredDayRepair.run(in: context, policyStore: policyStore)
        #expect(shift.workDate == Self.at(2026, 7, 19, in: Self.losAngeles))
        #expect(Self.workDay(shift, policyStore.policies.calendars) == Self.july19)
    }

    /// A second job in its own zone is stored and read in that zone.
    @Test("H: a job with its own zone stores its days in that zone")
    func jobInItsOwnZone() throws {
        let calendars = [
            Self.calendarPolicy(Self.newYork, id: "job/primary"),
            Self.calendarPolicy(Self.losAngeles, id: "job/cafe", job: "Cafe"),
        ]
        let record = try ShiftCommands.create(
            in: Self.context(), workDate: Self.at(2026, 7, 19, in: Self.tokyo), calendars: calendars,
            cashTipsCents: 5_000, jobName: "Cafe", phoneTimeZone: Self.tokyo)
        #expect(record.workDate == Self.at(2026, 7, 19, in: Self.losAngeles))
        #expect(Self.workDay(record, calendars) == Self.july19)
        #expect(Self.wireDay(record, calendars) == "2026-07-19")
    }

    // MARK: I: zones outside stableDay's window

    /// I. Kiritimati (UTC+14) and Pago Pago (UTC-11) lie outside the window
    /// `stableDay` covers. A phone in that same zone stores, sends and keeps
    /// exactly what it did before.
    @Test("I: a payroll zone outside stableDay's window, phone in the same zone, changes nothing",
          arguments: ["Pacific/Kiritimati", "Pacific/Pago_Pago"])
    func outsideTheWindowSameZone(_ identifier: String) throws {
        let zone = TimeZone(identifier: identifier)!
        let calendars = [Self.calendarPolicy(zone, id: "i")]
        let context = try Self.context()
        let record = try Self.save(picked: Self.at(2026, 9, 5, hour: 9, in: zone), calendars: calendars, phone: zone, in: context)
        #expect(record.workDate == Self.at(2026, 9, 5, in: zone))
        #expect(Self.wireDay(record, calendars) == "2026-09-05")
        let version = try PaydayRowFingerprint.value(record)
        #expect(try !StoredDayRepair.reanchor(in: context, calendars: calendars, phoneTimeZone: zone))
        #expect(try PaydayRowFingerprint.value(record) == version)
    }

    /// I. The one case the repair does change a fingerprint: a row moved INTO
    /// a zone outside the window. It uploads once, with the day the server
    /// already holds.
    @Test("I: a row moved into a zone outside the window uploads once, with the same day")
    func outsideTheWindowMovedRow() throws {
        let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
        let calendars = [Self.calendarPolicy(kiritimati, id: "i/moved")]
        let record = ShiftRecord(workDate: Self.at(2026, 9, 5, in: Self.tokyo), cashTipsCents: 1_000)
        let version = try PaydayRowFingerprint.value(record)
        let repaired = StoredDay(.workDay, calendars: calendars).repaired(record.workDate, job: nil, phoneTimeZone: Self.tokyo)
        record.workDate = repaired
        #expect(repaired == Self.at(2026, 9, 5, in: kiritimati))
        #expect(Self.wireDay(record, calendars) == "2026-09-05")
        #expect(try PaydayRowFingerprint.value(record) != version)
    }

    // MARK: J: clock-change days

    /// J. Havana's clocks go from 00:00 to 01:00 on Mar 8 2026, Santiago's on
    /// Sep 6 2026 and Beirut's on Mar 29 2026, so those days start at 01:00.
    @Test("J: a day whose clocks change at midnight is stored at its real start",
          arguments: ["America/Havana 2026-03-08", "America/Santiago 2026-09-06", "Asia/Beirut 2026-03-29"])
    func clockChangeAtMidnight(_ change: String) throws {
        let parts = change.split(separator: " ")
        let identifier = String(parts[0])
        let civil = try #require(CivilDay(iso: String(parts[1])))
        let (month, day) = (civil.month, civil.day)
        let zone = TimeZone(identifier: identifier)!
        let calendar = Self.calendar(zone)
        let calendars = [Self.calendarPolicy(zone, id: "j")]
        let storedDay = StoredDay(.workDay, calendars: calendars)
        let start = calendar.startOfDay(for: Self.at(2026, month, day, hour: 12, in: zone))
        #expect(calendar.component(.hour, from: start) == 1)

        for phone in [zone, Self.tokyo, Self.losAngeles] {
            let record = try Self.save(
                picked: civil.date(in: phone), calendars: calendars, phone: phone, in: Self.context())
            #expect(record.workDate == start)
            #expect(Self.workDay(record, calendars) == civil)
            #expect(Self.wireDay(record, calendars) == civil.iso)
            #expect(storedDay.repaired(record.workDate, job: nil, phoneTimeZone: phone) == start)
        }
        // A row an earlier build stored at that 01:00 start, for a payroll
        // zone elsewhere, is that day.
        let elsewhere = StoredDay(.workDay, calendars: [Self.calendarPolicy(Self.losAngeles, id: "j/elsewhere")])
        #expect(elsewhere.repaired(start, job: nil, phoneTimeZone: zone) == civil.date(in: Self.losAngeles))
    }

    // MARK: K: the CSV export

    /// K. Saved on a phone in Tokyo for Monday Jul 20, under the New York
    /// policy then in effect, with Los Angeles the latest zone: the Date cell
    /// is Jul 20 and lies inside the Period cell.
    @Test("K: after a zone change the CSV Date cell is the civil day, inside the Period cell")
    func csvAfterAZoneChange() throws {
        let calendars = Self.zoneHistory
        let record = try Self.save(
            picked: Self.at(2026, 7, 20, hour: 21, in: Self.tokyo), calendars: calendars, phone: Self.tokyo, in: Self.context())
        let policies = CompensationPolicies(rates: [], calendars: calendars)
        let calculator = PayPeriodCalculator(
            payrollTimeZone: Self.losAngeles,
            schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: Self.at(2026, 7, 19, in: Self.losAngeles), firstWeekday: 2)
        )
        let snapshot = try #require(
            HistoryEarnings.build(records: [record], policies: policies, payrollTimeZone: Self.losAngeles).snapshot)
        let csv = CSVExporter.export(
            records: [record], paycheckRecords: [], calculator: calculator,
            valuations: CSVExporter.valuations(from: snapshot))
        let lines = csv.split(separator: "\n").map(String.init)
        let header = lines[0].split(separator: ",").map(String.init)
        let cells = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        func cell(_ name: String) -> String? { header.firstIndex(of: name).map { cells[$0] } }
        #expect(cell("Date") == "2026-07-20")
        #expect(cell("Period") == "2026-07-20 to 2026-08-02")
    }

    // MARK: L: the reader

    /// The reader as it shipped before `StoredDay`, copied from the adapter
    /// so the pin below compares against a fixed rule, not against itself.
    static func shippedReader(_ stored: Date, job: String?, _ allCalendars: [PayrollCalendarPolicy]) -> CivilDay {
        let primary = allCalendars.filter { $0.jobName == nil }
        var byJob: [String: [PayrollCalendarPolicy]] = [:]
        for calendar in allCalendars {
            guard let key = ShiftRole.key(calendar.jobName) else { continue }
            byJob[key, default: []].append(calendar)
        }
        let calendars: [PayrollCalendarPolicy]
        if let key = ShiftRole.key(job), let own = byJob[key] {
            calendars = own
        } else {
            calendars = primary.isEmpty ? allCalendars : primary
        }
        let latestZone = calendars.last?.payrollTimeZone ?? .current
        let provisional = CivilDay(stored, in: latestZone)
        let zone = calendars
            .sorted { ($0.effectiveFrom, $0.id.uuidString) < ($1.effectiveFrom, $1.id.uuidString) }
            .last { $0.effectiveFrom <= provisional }?.payrollTimeZone ?? latestZone
        return zone == latestZone ? provisional : CivilDay(stored, in: zone)
    }

    /// L. The engine's reading of a stored instant is unchanged for every
    /// instant, a time of day included: every 37 minutes across a zone
    /// change, for the primary, a job with its own zone history and a job
    /// with no calendar of its own.
    @Test("L: the engine reads every instant exactly as before")
    func readerUnchanged() {
        let calendars = Self.zoneHistory + [
            Self.calendarPolicy(Self.tokyo, id: "l/cafe", job: "Cafe"),
            Self.calendarPolicy(Self.newYork, from: CivilDay(year: 2026, month: 8, day: 5), id: "l/cafe2", job: "Cafe"),
        ]
        var mismatches: [String] = []
        var instant = Self.at(2026, 7, 28, in: Self.newYork)
        let end = Self.at(2026, 8, 12, in: Self.newYork)
        while instant < end {
            for job in [nil, "Cafe", "Bar"] as [String?] {
                let record = ShiftRecord(workDate: instant, cashTipsCents: 1_000, jobName: job)
                let read = ShiftInputAdapter.input(from: record, calendars: calendars).workDay
                if read != Self.shippedReader(instant, job: job, calendars) {
                    mismatches.append("\(instant) \(job ?? "primary")")
                }
            }
            instant = instant.addingTimeInterval(37 * 60)
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")
        // Noon in the payroll zone is that day, as it always was.
        let noon = ShiftRecord(workDate: Self.at(2026, 7, 19, hour: 12, in: Self.newYork), cashTipsCents: 1_000)
        #expect(Self.workDay(noon, [Self.calendarPolicy(Self.newYork, id: "l/noon")]) == Self.july19)
    }

    // MARK: Screens that read a stored day on the phone's calendar

    /// The nudge's "already logged tonight" compares the stored day's own
    /// civil day with the phone's today. A Tokyo payroll's midnight is the
    /// previous evening on any phone west of Tokyo, which read as "not
    /// logged" when the instant itself was compared on the phone's calendar.
    @Test("a shift stored for today in a payroll zone east of the phone suppresses tonight's nudge")
    func loggedTonightSuppressesTheNudge() throws {
        // `nextFireDate` runs on the phone's own calendar.
        let phone = TimeZone.current
        let storedDay = StoredDay(.workDay, calendars: [Self.calendarPolicy(Self.tokyo, id: "nudge")])
        let today = CivilDay(.now, in: phone)
        let morning = today.date(in: phone).addingTimeInterval(30 * 60)
        let stored = storedDay.stored(picked: morning, job: nil, phoneTimeZone: phone)
        #expect(stored == today.date(in: Self.tokyo))

        let unlogged = try #require(SmartNudgeScheduler.nextFireDate(
            usualWeekdays: Set(1...7), typicalLogHour: 23, loggedDays: [], from: morning))
        #expect(CivilDay(unlogged, in: phone) == today)
        let logged = try #require(SmartNudgeScheduler.nextFireDate(
            usualWeekdays: Set(1...7), typicalLogHour: 23,
            loggedDays: [storedDay.civilDay(stored, job: nil)], from: morning))
        #expect(CivilDay(logged, in: phone) == today.adding(days: 1))
    }

    /// Insights names the weekday of a stored day as the engine reads it, in
    /// the payroll zone. Tokyo's Sunday midnight is Saturday on any phone
    /// west of Tokyo.
    @Test("Insights' weekday unlock names the payroll zone's weekday, not the phone's")
    func unlockWeekdayIsThePayrollZones() {
        let zone = Self.tokyo
        let policies = CompensationPolicies(rates: [], calendars: [Self.calendarPolicy(zone, id: "unlock")])
        let calendar = PayrollCalendar.gridCalendar(in: zone)
        let now = calendar.startOfDay(for: .now)
        let today = CivilDay(now, in: zone)
        let sunday = today.adding(days: -(today.weekday - 1) - 7)
        #expect(sunday.weekday == 1)
        let records = [sunday, sunday.adding(days: -7)].map {
            ShiftRecord(workDate: $0.date(in: zone), cashTipsCents: 10_000)
        }
        let dataset = InsightsEarnings.build(records: records, policies: policies, payrollTimeZone: zone)
        let facts = InsightsPageFacts(dataset: dataset, payrollTimeZone: zone, calendar: calendar, now: now)
        #expect(facts.unlocks.map(\.kind).contains(.weekday(1)), "\(facts.unlocks)")
        #expect(!facts.unlocks.map(\.kind).contains(.weekday(7)))
    }

    // MARK: The repair's cost

    /// The repair runs at every launch, so a store that already follows the
    /// rule must cost little more than reading each row's day. Measured as a
    /// launch meets it: the rows are written and saved through one container,
    /// and the repair reads them from disk through a new one, so nothing it
    /// reads is already in memory.
    @Test("the repair over a 10,000-shift history that needs nothing stays inside a launch budget")
    func repairCost() throws {
        let calendars = [Self.calendarPolicy(Self.newYork, id: "cost")]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("payday-repair-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        func open() throws -> ModelContext {
            let context = ModelContext(try ModelContainer(
                for: SharedModelContainer.schema, configurations: ModelConfiguration(url: url)))
            context.autosaveEnabled = false
            return context
        }

        let writer = try open()
        for index in 0..<10_000 {
            writer.insert(ShiftRecord(
                workDate: CivilDay(year: 2016, month: 1, day: 1).adding(days: index).date(in: Self.newYork),
                cashTipsCents: 1_000))
        }
        try writer.save()

        let launch = try open()
        let began = Date()
        let moved = try StoredDayRepair.reanchor(in: launch, calendars: calendars, phoneTimeZone: Self.tokyo)
        let elapsed = Date().timeIntervalSince(began)
        #expect(!moved)
        #expect(try launch.fetchCount(FetchDescriptor<ShiftRecord>()) == 10_000)
        // MEASURED at 0.14s on the simulator in Debug; the budget fails a pass
        // several times slower.
        #expect(
            elapsed < 0.5 * LogShiftPreviewPerformanceTests.budgetScale,
            "the repair took \(elapsed) seconds over 10,000 rows read from disk against a 0.5s budget")
    }
}
