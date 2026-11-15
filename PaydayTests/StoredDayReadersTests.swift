import Foundation
import SwiftData
import Testing
@testable import Payday

/// Stored days in an account with more than one payroll zone: a zone change
/// in its history, or a job in another zone. Each row sits at the start of
/// its day in the zone of ITS policy and ITS job (`StoredDay`), so a reader
/// that read every row in one zone named the day before, and the reader rule
/// itself has to give back what the writer stored. Every zone is named.
@Suite("Stored days across zones")
@MainActor
struct StoredDayReadersTests {
    static let newYork = StoredDayTests.newYork
    static let losAngeles = StoredDayTests.losAngeles
    static let tokyo = StoredDayTests.tokyo

    static func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in zone: TimeZone) -> Date {
        StoredDayTests.at(year, month, day, hour: hour, in: zone)
    }

    static func day(_ iso: String) -> CivilDay { CivilDay(iso: iso)! }

    // MARK: The account the readers are read against

    /// The primary: New York until Monday Aug 3, Los Angeles from then on.
    /// The Cafe job: Tokyo.
    static let calendars = StoredDayTests.zoneHistory + [
        StoredDayTests.calendarPolicy(tokyo, id: "readers/cafe", job: "Cafe"),
    ]
    static let policies = CompensationPolicies(rates: [], calendars: calendars)

    /// Weekly, Sunday to Saturday, the period ending Saturday Jul 18.
    static let schedule = PaySchedule(frequency: .weekly, anchorPeriodEnd: at(2026, 7, 18, in: losAngeles), firstWeekday: 1)

    /// Saved through the real save path on a phone in Los Angeles: the
    /// primary's Sunday Jul 19 and Monday Jul 20 (New York's policy), the
    /// Cafe's Monday Jul 20 (Tokyo), and the primary's Monday Aug 10 (Los
    /// Angeles' policy). Read in Los Angeles, the first three are Jul 18,
    /// Jul 19 and Jul 19.
    static func rows(in context: ModelContext) throws -> [ShiftRecord] {
        try [(19, nil), (20, nil), (20, "Cafe")].map { day, job in
            try ShiftCommands.create(
                in: context, workDate: at(2026, 7, day, hour: 12, in: losAngeles), calendars: calendars,
                cashTipsCents: 5_000, jobName: job, phoneTimeZone: losAngeles)
        } + [try ShiftCommands.create(
            in: context, workDate: at(2026, 8, 10, hour: 12, in: losAngeles), calendars: calendars,
            cashTipsCents: 5_000, phoneTimeZone: losAngeles)]
    }

    static let engineDays = ["2026-07-19", "2026-07-20", "2026-07-20", "2026-08-10"]

    static func engineDays(_ records: [ShiftRecord]) -> [String] {
        ShiftInputAdapter.inputs(from: records, calendars: calendars).map(\.workDay.iso)
    }

    // MARK: F2: readers that read every row on one calendar

    @Test("the rows are stored in their own zones and the engine reads their own days")
    func fixture() throws {
        let records = try Self.rows(in: StoredDayTests.context())
        #expect(records.map(\.workDate) == [
            Self.at(2026, 7, 19, in: Self.newYork), Self.at(2026, 7, 20, in: Self.newYork),
            Self.at(2026, 7, 20, in: Self.tokyo), Self.at(2026, 8, 10, in: Self.losAngeles),
        ])
        #expect(Self.engineDays(records) == Self.engineDays)
    }

    @Test("the stats rows and the nudge's projected rows carry the engine's day")
    func statsRows() throws {
        let records = try Self.rows(in: StoredDayTests.context())
        let stats = StatsRecordAdapter.tipRecords(from: records, calendars: Self.calendars, payrollTimeZone: Self.losAngeles)
        #expect(stats.map { CivilDay($0.date, in: Self.losAngeles).iso } == Self.engineDays)
        let storedDay = StoredDay(.workDay, calendars: Self.calendars)
        let projected = ShiftProjection.rows(for: records, storedDay: storedDay, in: Self.losAngeles)
        #expect(projected.map { CivilDay($0.date, in: Self.losAngeles).iso } == Self.engineDays)
        // Through the engine that reads them: one night per engine day, the
        // Cafe's and the primary's Monday summed.
        let nights = StatsEngine(payrollTimeZone: Self.losAngeles, records: stats).nightlyTotals()
        #expect(nights.map { CivilDay($0.date, in: Self.losAngeles).iso } == ["2026-07-19", "2026-07-20", "2026-08-10"])
        #expect(nights.map(\.cents) == [5_000, 10_000, 5_000])
    }

    @Test("the Dashboard's period rows and doubles are the engine's days")
    func dashboard() throws {
        let records = try Self.rows(in: StoredDayTests.context())
        let dataset = DashboardEarnings.build(records: records, policies: Self.policies, payrollTimeZone: Self.losAngeles)
        let facts = DashboardFacts(
            snapshot: dataset.snapshot, allShiftRecords: dataset.shiftRecordDays, calendars: Self.calendars,
            allTipRecords: dataset.tipRecords, withholdingModel: dataset.withholdingModel, schedule: Self.schedule,
            now: Self.at(2026, 7, 21, hour: 12, in: Self.losAngeles), forcedPaydayPhase: nil,
            dismissedClosedEnd: nil, dismissedCheckEnd: nil, payrollTimeZone: Self.losAngeles)
        // The period Sunday Jul 19 to Saturday Jul 25, newest day first.
        #expect(Set(facts.shiftRecordDays.map(\.id)) == Set(records.prefix(3).map(\.id)))
        #expect(facts.shiftRecordDays.last?.id == records[0].id)
        #expect(facts.multiShiftDays == [Self.day("2026-07-20")])
    }

    /// With two jobs each Dashboard card reads its own job's rows in that
    /// job's zone (`DashboardEarnings.facts(for:)`), so its stats rows are
    /// dated there: Tokyo's midnight is the morning before in Los Angeles.
    @Test("a job's Dashboard stats rows are dated in the zone its card reads in")
    func dashboardPerJob() throws {
        let policies = CompensationPolicies(
            rates: [],
            calendars: [
                StoredDayTests.calendarPolicy(Self.tokyo, id: "perjob/primary"),
                StoredDayTests.calendarPolicy(Self.losAngeles, id: "perjob/cafe", job: "Cafe"),
            ],
            jobs: Self.paycheckPolicies.jobs)
        let context = try StoredDayTests.context()
        let records = try [nil, "Cafe"].map { job in
            try ShiftCommands.create(
                in: context, workDate: Self.at(2026, 7, 20, hour: 12, in: Self.losAngeles), calendars: policies.calendars,
                cashTipsCents: 5_000, jobName: job, phoneTimeZone: Self.losAngeles)
        }
        let datasets = DashboardEarnings.buildPerJob(records: records, policies: policies, payrollTimeZone: Self.tokyo)
        #expect(datasets.map(\.job) == [.job(nil), .job("Cafe")])
        #expect(datasets[0].tipRecords.map { CivilDay($0.date, in: Self.tokyo).iso } == ["2026-07-20"])
        #expect(datasets[1].tipRecords.map { CivilDay($0.date, in: Self.losAngeles).iso } == ["2026-07-20"])
    }

    @Test("period detail counts a double on the engine's day")
    func periodDetail() throws {
        let records = try Self.rows(in: StoredDayTests.context())
        let build = HistoryEarnings.build(records: records, policies: Self.policies, payrollTimeZone: Self.losAngeles)
        let facts = PeriodDetailFacts(
            snapshot: build.snapshot, shiftRecordDays: build.shiftRecordDays, paycheckRecords: [],
            period: PayPeriod(start: Self.at(2026, 7, 19, in: Self.losAngeles), end: Self.at(2026, 7, 25, in: Self.losAngeles)),
            schedule: Self.schedule, payrollTimeZone: Self.losAngeles)
        #expect(Set(facts.shiftRecordDays.map(\.id)) == Set(records.prefix(3).map(\.id)))
        #expect(facts.multiShiftDays == [Self.day("2026-07-20")])
    }

    /// The day sheet's own grouping runs only when the snapshot could not be
    /// built. A recorded time with no whole-seconds value is refused by the
    /// engine's manifest, which is how this reaches it.
    @Test("the day sheet groups by the engine's day when it has no snapshot")
    func dayDetailWithoutASnapshot() throws {
        let context = try StoredDayTests.context()
        let records = try Self.rows(in: context)
        let refused = ShiftRecord(
            workDate: Self.at(2026, 8, 1, in: Self.losAngeles), cashTipsCents: 100,
            recordedAt: Date(timeIntervalSince1970: .infinity))
        for (date, expected) in [(Self.at(2026, 7, 20, hour: 12, in: Self.losAngeles), [1, 2]), (Self.at(2026, 7, 19, hour: 12, in: Self.losAngeles), [0])] {
            let facts = DayDetailFacts(
                shiftRecords: records + [refused], date: date, policies: Self.policies, payrollTimeZone: Self.losAngeles)
            #expect(facts.snapshot == nil, "precondition: the fallback runs")
            #expect(Set(facts.shiftRecords.map(\.id)) == Set(expected.map { records[$0].id }))
        }
    }

    @Test("Insights' weekday unlock names Sunday for Sundays of an older policy")
    func unlockProgress() throws {
        let context = try StoredDayTests.context()
        let sundays = try [12, 19].map { day in
            try ShiftCommands.create(
                in: context, workDate: Self.at(2026, 7, day, hour: 12, in: Self.losAngeles), calendars: Self.calendars,
                cashTipsCents: 5_000, phoneTimeZone: Self.losAngeles)
        }
        let dataset = InsightsEarnings.build(records: sundays, policies: Self.policies, payrollTimeZone: Self.losAngeles)
        let unlocks = UnlockProgress.nextUnlocks(
            records: dataset.tipRecords, asOf: Self.at(2026, 7, 21, in: Self.losAngeles),
            calendar: PayrollCalendar.gridCalendar(in: Self.losAngeles), limit: 4)
        #expect(unlocks.map(\.kind).contains(.weekday(1)), "\(unlocks)")
        #expect(!unlocks.map(\.kind).contains(.weekday(7)))
    }

    /// The nudge compares each stored day's own civil day with the phone's
    /// today: a Cafe shift stored for today at Tokyo's midnight is today.
    @Test("a job's shift stored for today in its own zone suppresses tonight's nudge")
    func nudgeAlreadyLogged() throws {
        let phone = TimeZone.current
        let storedDay = StoredDay(.workDay, calendars: Self.calendars)
        let today = CivilDay(.now, in: phone)
        let morning = today.date(in: phone).addingTimeInterval(30 * 60)
        let stored = storedDay.stored(picked: morning, job: "Cafe", phoneTimeZone: phone)
        #expect(stored == today.date(in: Self.tokyo))
        let logged = try #require(SmartNudgeScheduler.nextFireDate(
            usualWeekdays: Set(1...7), typicalLogHour: 23,
            loggedDays: [storedDay.civilDay(stored, job: "Cafe")], from: morning))
        #expect(CivilDay(logged, in: phone) == today.adding(days: 1))
    }

    @Test("the CSV Date cell and Double flag of a row the engine did not value are the engine's day")
    func csvWithoutValuations() throws {
        let records = try Self.rows(in: StoredDayTests.context())
        let csv = CSVExporter.export(
            records: records, paycheckRecords: [],
            calculatorForJob: { PolicyStore.calculator(forJob: $0, policies: Self.policies, primarySchedule: Self.schedule) },
            calendars: Self.calendars, valuations: [:])
        let lines = csv.split(separator: "\n").map(String.init)
        let header = lines[0].split(separator: ",").map(String.init)
        let cells = lines.dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        func column(_ name: String) -> [String] {
            let index = header.firstIndex(of: name)!
            return cells.map { $0[index] }
        }
        // In stored order: the primary's Jul 19, the Cafe's Jul 20, the
        // primary's Jul 20, Aug 10.
        #expect(column("Date") == ["2026-07-19", "2026-07-20", "2026-07-20", "2026-08-10"])
        #expect(column("Double") == ["N", "Y", "Y", "N"])
    }

    /// For an account with one payroll zone every conversion above is the
    /// identity: each reader is handed exactly the instant it read before.
    @Test("one payroll zone: every reader is handed exactly what it read before")
    func oneZonePin() throws {
        var disagreements: [String] = []
        let first = CivilDay(year: 2025, month: 1, day: 1)
        let last = CivilDay(year: 2027, month: 12, day: 31)
        for zone in StoredDayTests.sweepZones {
            let calendar = StoredDayTests.calendar(zone)
            let storedDay = StoredDay(.workDay, calendars: [StoredDayTests.calendarPolicy(zone, id: "readers/pin")])
            for number in first.dayNumber...last.dayNumber {
                let saved = storedDay.stored(CivilDay(dayNumber: number), job: nil)
                if storedDay.start(of: saved, job: nil, in: zone) != saved
                    || storedDay.civilDay(saved, job: nil) != CivilDay(saved, in: zone)
                    || calendar.startOfDay(for: saved) != saved {
                    disagreements.append("\(zone.identifier) \(CivilDay(dayNumber: number).iso)")
                }
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.prefix(20))")

        // Through the readers themselves, with doubles, in zones with a
        // clock change at midnight and outside stableDay's window.
        for identifier in ["America/New_York", "Asia/Tokyo", "America/Havana", "Pacific/Kiritimati", "Pacific/Pago_Pago", "Pacific/Chatham"] {
            let zone = TimeZone(identifier: identifier)!
            let calendars = [StoredDayTests.calendarPolicy(zone, id: "readers/pin/\(identifier)")]
            let policies = CompensationPolicies(rates: [], calendars: calendars)
            let context = try StoredDayTests.context()
            let records = try (1...40).flatMap { offset in
                try (0..<(offset % 3 == 0 ? 2 : 1)).map { _ in
                    try ShiftCommands.create(
                        in: context, workDate: CivilDay(year: 2026, month: 2, day: 20).adding(days: offset).date(in: zone).addingTimeInterval(18 * 3_600),
                        calendars: calendars, cashTipsCents: 1_000 * offset, phoneTimeZone: zone)
                }
            }
            #expect(StatsRecordAdapter.tipRecords(from: records, calendars: calendars, payrollTimeZone: zone).map(\.date)
                == records.map(\.workDate))
            #expect(ShiftProjection.rows(for: records, storedDay: StoredDay(.workDay, calendars: calendars), in: zone).map(\.date)
                == records.flatMap { ShiftProjection.rows(for: $0, day: $0.workDate) }.map(\.date))

            let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: CivilDay(year: 2026, month: 3, day: 7).date(in: zone), firstWeekday: 1)
            let now = CivilDay(year: 2026, month: 3, day: 12).date(in: zone).addingTimeInterval(12 * 3_600)
            let dataset = DashboardEarnings.build(records: records, policies: policies, payrollTimeZone: zone)
            let facts = DashboardFacts(
                snapshot: dataset.snapshot, allShiftRecords: dataset.shiftRecordDays, calendars: calendars,
                allTipRecords: dataset.tipRecords, withholdingModel: dataset.withholdingModel, schedule: schedule,
                now: now, forcedPaydayPhase: nil, dismissedClosedEnd: nil, dismissedCheckEnd: nil, payrollTimeZone: zone)
            // The shipped membership and double keys, read in the one zone.
            let grid = PayrollCalendar.gridCalendar(in: zone)
            let period = PayPeriodCalculator(payrollTimeZone: zone, schedule: schedule).period(containing: now)
            let range = DayRange(start: CivilDay(period.start, in: zone), end: CivilDay(period.end, in: zone))
            let shippedRows = records.filter { range.contains(CivilDay($0.workDate, in: zone)) }
            let shippedDoubles = Dictionary(grouping: shippedRows) { grid.startOfDay(for: $0.workDate) }.filter { $0.value.count >= 2 }.keys
            #expect(Set(facts.shiftRecordDays.map(\.id)) == Set(shippedRows.map(\.id)))
            #expect(facts.multiShiftDays == Set(shippedDoubles.map { CivilDay($0, in: zone) }))

            let csv = CSVExporter.export(
                records: records, paycheckRecords: [],
                calculatorForJob: { _ in PayPeriodCalculator(payrollTimeZone: zone, schedule: schedule) },
                calendars: calendars, valuations: [:])
            let oneZone = CSVExporter.export(
                records: records, paycheckRecords: [], calculator: PayPeriodCalculator(payrollTimeZone: zone, schedule: schedule),
                valuations: [:])
            #expect(csv == oneZone)
        }
    }

    // MARK: F1: a job's paycheck reaches the engine in the job's zone

    /// The primary in Los Angeles, the Cafe in New York, the phone in Los
    /// Angeles. New York's midnight is 9 PM the evening before in Los
    /// Angeles, so the primary's zone read every Cafe check a day early.
    static let paycheckPolicies = CompensationPolicies(
        rates: [],
        calendars: [
            StoredDayTests.calendarPolicy(losAngeles, id: "paycheck/primary"),
            StoredDayTests.calendarPolicy(newYork, id: "paycheck/cafe", job: "Cafe"),
        ],
        jobs: [
            JobPolicy(id: UUID(uuidString: "00000000-0000-4000-8000-00000000c0f1")!, name: "Bistro", schedule: nil, isPrimary: true),
            JobPolicy(
                id: UUID(uuidString: "00000000-0000-4000-8000-00000000c0f2")!, name: "Cafe",
                schedule: PayScheduleInput(frequency: "weekly", anchorPeriodEnd: CivilDay(year: 2026, month: 7, day: 19), payDelayDays: 2),
                isPrimary: false),
        ])

    static func periodDays(_ check: PaycheckRecord) -> [String] {
        let input = PaycheckInputAdapter.inputs(from: [check], calendars: paycheckPolicies.calendars)[0]
        return [input.periodStart.iso, input.periodEnd.iso]
    }

    @Test("a downloaded Cafe check reaches the engine as its own period")
    func downloadedJobPaycheck() throws {
        let row = try JSONDecoder().decode(RemotePaycheckRecord.self, from: Data("""
            {"id":"00000000-0000-4000-8000-00000000c0f3","user_id":"\(StoredDayTests.userID.uuidString)",
             "period_start":"2026-07-13","period_end":"2026-07-19","paid_tips_cents":7000,"job_name":"Cafe",
             "client_updated_at":"2026-09-18T00:00:00.000Z","deleted_at":null,
             "updated_at":"2026-09-18T00:00:00.000Z"}
            """.utf8))
        let context = try StoredDayTests.context()
        _ = try PaydaySyncService.reconcilePaychecks([row], in: context, calendars: Self.paycheckPolicies.calendars)
        let check = try #require(try context.fetch(FetchDescriptor<PaycheckRecord>()).first)
        #expect(check.periodStart == Self.at(2026, 7, 13, in: Self.newYork))
        #expect(Self.periodDays(check) == ["2026-07-13", "2026-07-19"])
    }

    @Test("a Cafe check the shipped build stored at the phone's midnight reaches the engine as its own period once repaired")
    func repairedJobPaycheck() throws {
        let context = try StoredDayTests.context()
        let check = PaycheckRecord(
            periodStart: Self.at(2026, 7, 13, in: Self.losAngeles), periodEnd: Self.at(2026, 7, 19, in: Self.losAngeles),
            paidTipsCents: 7_000)
        check.jobName = "Cafe"
        context.insert(check)
        #expect(try StoredDayRepair.reanchor(
            in: context, calendars: Self.paycheckPolicies.calendars, phoneTimeZone: Self.losAngeles))
        #expect(check.periodEnd == Self.at(2026, 7, 19, in: Self.newYork))
        #expect(Self.periodDays(check) == ["2026-07-13", "2026-07-19"])
    }

    @Test("a Cafe check written through the paycheck sheet's own period reaches the engine as that period")
    func enteredJobPaycheck() {
        let calculator = { (job: String?) in
            PolicyStore.calculator(forJob: job, policies: Self.paycheckPolicies, primarySchedule: Self.schedule)
        }
        // Entered from the primary's period screen for Jul 12 to Jul 18, the
        // Cafe picked: the Cafe's own week holding that period's last day.
        let screenPeriod = calculator(nil).period(containing: Self.at(2026, 7, 15, hour: 12, in: Self.losAngeles))
        let period = PaycheckEntryFacts.period(
            forJob: "Cafe", screenJob: nil, screenPeriod: screenPeriod,
            now: Self.at(2026, 7, 22, in: Self.losAngeles), calculator: calculator)
        let check = PaycheckRecord(periodStart: period.start, periodEnd: period.end, paidTipsCents: 7_000)
        check.jobName = "Cafe"
        #expect(Self.periodDays(check) == ["2026-07-13", "2026-07-19"])
    }

    /// The primary's checks read exactly as they did, in the primary's latest
    /// zone, for every instant, with a zone history and a job in the policies.
    @Test("a primary check reads exactly as before, for every instant")
    func primaryPaycheckPin() {
        let calendars = Self.calendars
        let latest = CompensationPolicies(rates: [], calendars: calendars).payrollTimeZone!
        var mismatches: [String] = []
        var instant = Self.at(2026, 7, 28, in: Self.newYork)
        while instant < Self.at(2026, 8, 12, in: Self.newYork) {
            let check = PaycheckRecord(periodStart: instant, periodEnd: instant.addingTimeInterval(6 * 86_400), paidTipsCents: 0)
            let input = PaycheckInputAdapter.inputs(from: [check], calendars: calendars)[0]
            if input.periodStart != CivilDay(check.periodStart, in: latest) || input.periodEnd != CivilDay(check.periodEnd, in: latest) {
                mismatches.append("\(instant)")
            }
            instant = instant.addingTimeInterval(37 * 60)
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")
    }

    // MARK: F3: the reader gives back what the writer stored

    /// New York, then Tokyo from Monday Aug 3, then Los Angeles from Monday
    /// Aug 31. Tokyo's midnight on Aug 3 is the afternoon of Aug 2 in Los
    /// Angeles and New York, so a read in the latest zone first picked New
    /// York's policy and named Aug 2.
    static let threeZones = [
        StoredDayTests.calendarPolicy(newYork, id: "three/newyork"),
        StoredDayTests.calendarPolicy(tokyo, from: CivilDay(year: 2026, month: 8, day: 3), id: "three/tokyo"),
        StoredDayTests.calendarPolicy(losAngeles, from: CivilDay(year: 2026, month: 8, day: 31), id: "three/losangeles"),
    ]

    @Test("three zones: a shift saved for the first day of the middle policy round-trips")
    func threePolicyRoundTrip() throws {
        let calendars = Self.threeZones
        let context = try StoredDayTests.context()
        let record = try StoredDayTests.save(
            picked: Self.at(2026, 8, 3, hour: 20, in: Self.tokyo), calendars: calendars, phone: Self.tokyo, in: context)
        #expect(record.workDate == Self.at(2026, 8, 3, in: Self.tokyo))
        #expect(StoredDayTests.workDay(record, calendars) == Self.day("2026-08-03"))
        #expect(StoredDayTests.wireDay(record, calendars) == "2026-08-03")
        #expect(try !StoredDayRepair.reanchor(in: context, calendars: calendars, phoneTimeZone: Self.tokyo))

        let downloaded = try StoredDayTests.context()
        _ = try PaydaySyncService.reconcileShifts(
            [RemoteShift(record: record, userID: StoredDayTests.userID, calendars: calendars)], in: downloaded, calendars: calendars)
        let copy = try #require(try downloaded.fetch(FetchDescriptor<ShiftRecord>()).first)
        #expect(copy.workDate == record.workDate)
        #expect(StoredDayTests.workDay(copy, calendars) == Self.day("2026-08-03"))
    }

    /// Every day round-trips through the writer and the reader, for every
    /// order of three zones less than a day apart, east and west of each
    /// other, around both changes; and the primary's rule is the job's.
    @Test("three zones in any order: every day round-trips")
    func threePolicySweep() {
        let zones = ["America/New_York", "America/Los_Angeles", "Asia/Tokyo", "Asia/Kolkata", "Pacific/Honolulu", "Pacific/Auckland"]
            .map { TimeZone(identifier: $0)! }
        var failures: [String] = []
        for first in zones {
            for second in zones {
                for third in zones {
                    for job in [nil, "Cafe"] as [String?] {
                        let calendars = [
                            StoredDayTests.calendarPolicy(first, id: "sweep/1", job: job),
                            StoredDayTests.calendarPolicy(second, from: CivilDay(year: 2026, month: 8, day: 3), id: "sweep/2", job: job),
                            StoredDayTests.calendarPolicy(third, from: CivilDay(year: 2026, month: 8, day: 31), id: "sweep/3", job: job),
                        ] + (job == nil ? [] : [StoredDayTests.calendarPolicy(Self.newYork, id: "sweep/primary")])
                        let storedDay = StoredDay(.workDay, calendars: calendars)
                        for number in CivilDay(year: 2026, month: 7, day: 25).dayNumber...CivilDay(year: 2026, month: 9, day: 7).dayNumber {
                            let day = CivilDay(dayNumber: number)
                            let stored = storedDay.stored(day, job: job)
                            if storedDay.civilDay(stored, job: job) != day
                                || storedDay.stored(wireDay: storedDay.wireDay(stored, job: job), job: job) != stored
                                || storedDay.repaired(stored, job: job, phoneTimeZone: first) != stored {
                                failures.append("\(first.identifier) \(second.identifier) \(third.identifier) \(job ?? "-") \(day.iso)")
                            }
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count): \(failures.prefix(10))")
    }

    /// For one policy, and for two whose first is the migration's
    /// `.distantPast` policy, the reader is the same function as the shipped
    /// two-step rule (`StoredDayTests.shippedReader`), for midnights and
    /// times of day alike, with and without a job.
    @Test("one or two policies: the reader is the shipped rule for every instant")
    func matchesTheShippedRule() {
        let zones = ["America/New_York", "America/Los_Angeles", "Asia/Tokyo", "Asia/Kolkata", "Pacific/Chatham",
                     "Pacific/Kiritimati", "Pacific/Pago_Pago", "Europe/London"].map { TimeZone(identifier: $0)! }
        let change = CivilDay(year: 2026, month: 8, day: 3)
        var setups: [[PayrollCalendarPolicy]] = []
        for zone in zones {
            setups.append([StoredDayTests.calendarPolicy(zone, id: "one/past")])
            setups.append([StoredDayTests.calendarPolicy(zone, from: change, id: "one/change")])
            for later in zones {
                setups.append([
                    StoredDayTests.calendarPolicy(zone, id: "two/first"),
                    StoredDayTests.calendarPolicy(later, from: change, id: "two/second"),
                ])
            }
        }
        // Every instant every 37 minutes across the change, and every zone's
        // own midnights either side of it.
        var instants: [Date] = []
        var instant = Self.at(2026, 7, 30, in: .gmt)
        while instant < Self.at(2026, 8, 7, in: .gmt) {
            instants.append(instant)
            instant = instant.addingTimeInterval(37 * 60)
        }
        for zone in zones {
            for day in 30...31 { instants.append(Self.at(2026, 7, day, in: zone)) }
            for day in 1...6 { instants.append(Self.at(2026, 8, day, in: zone)) }
        }

        var mismatches: [String] = []
        var checked = 0
        for setup in setups {
            for job in [nil, "Cafe"] as [String?] {
                // A job reads its own calendars; the primary's are New York.
                let calendars = job == nil
                    ? setup
                    : setup.map { var own = $0; own.jobName = job; return own } + [StoredDayTests.calendarPolicy(Self.newYork, id: "shipped/primary")]
                let storedDay = StoredDay(.workDay, calendars: calendars)
                for instant in instants {
                    checked += 1
                    if storedDay.civilDay(instant, job: job) != StoredDayTests.shippedReader(instant, job: job, calendars) {
                        mismatches.append("\(setup.map(\.payrollTimeZone.identifier)) \(job ?? "-") \(instant)")
                    }
                }
            }
        }
        #expect(checked == (zones.count * 2 + zones.count * zones.count) * 2 * instants.count)
        #expect(mismatches.isEmpty, "\(mismatches.count): \(mismatches.prefix(10))")
    }

    /// Two policies whose first starts on a real day (a job's first own
    /// calendar starts the day after it is set): the two rules differ only
    /// on instants that one of the two zones names as the day before the
    /// first policy and the other as its first day. On the first policy's
    /// own midnight of that day, the reader now gives back what the writer
    /// stored; the shipped rule named the day before when the first zone is
    /// east of the second, the fault of the three-policy case above.
    @Test("two policies from a real day: the rules differ only where the first day starts, and the reader round-trips it")
    func twoPoliciesFromARealDay() {
        let zones = ["America/New_York", "America/Los_Angeles", "Asia/Tokyo", "Asia/Kolkata", "Europe/London"]
            .map { TimeZone(identifier: $0)! }
        let start = CivilDay(year: 2026, month: 8, day: 3)
        var unexpected: [String] = []
        var shippedLost: [String] = []
        for first in zones {
            for second in zones {
                let calendars = [
                    StoredDayTests.calendarPolicy(first, from: start, id: "real/first", job: "Cafe"),
                    StoredDayTests.calendarPolicy(second, from: CivilDay(year: 2026, month: 8, day: 31), id: "real/second", job: "Cafe"),
                ]
                let storedDay = StoredDay(.workDay, calendars: calendars)
                var instant = Self.at(2026, 7, 30, in: .gmt)
                while instant < Self.at(2026, 8, 7, in: .gmt) {
                    let straddles = Set([CivilDay(instant, in: first), CivilDay(instant, in: second)]) == [start.adding(days: -1), start]
                    if !straddles, storedDay.civilDay(instant, job: "Cafe") != StoredDayTests.shippedReader(instant, job: "Cafe", calendars) {
                        unexpected.append("\(first.identifier) \(second.identifier) \(instant)")
                    }
                    instant = instant.addingTimeInterval(37 * 60)
                }
                let firstDay = storedDay.stored(start, job: "Cafe")
                #expect(firstDay == start.date(in: first))
                #expect(storedDay.civilDay(firstDay, job: "Cafe") == start)
                if StoredDayTests.shippedReader(firstDay, job: "Cafe", calendars) != start {
                    shippedLost.append("\(first.identifier) \(second.identifier)")
                }
            }
        }
        #expect(unexpected.isEmpty, "\(unexpected.prefix(10))")
        #expect(shippedLost.contains("Asia/Tokyo America/Los_Angeles"), "\(shippedLost)")
    }

    // MARK: F7: Siri completes today's shift of any job

    static func context(with records: [ShiftRecord]) throws -> ModelContext {
        let context = try StoredDayTests.context()
        records.forEach(context.insert)
        try context.save()
        return context
    }

    @Test("Siri finds today's shift of a job in another zone")
    func siriFindsAJobsShift() throws {
        // The primary in New York, the Cafe in Los Angeles, the phone in New
        // York at 8 PM on Jul 19: the Cafe's Jul 19 is stored at Los
        // Angeles' midnight, 3 AM in New York.
        let calendars = [
            StoredDayTests.calendarPolicy(Self.newYork, id: "siri/primary"),
            StoredDayTests.calendarPolicy(Self.losAngeles, id: "siri/cafe", job: "Cafe"),
        ]
        let cafe = ShiftRecord(workDate: Self.at(2026, 7, 19, in: Self.losAngeles), cashTipsCents: 1_000, jobName: "Cafe")
        let yesterday = ShiftRecord(workDate: Self.at(2026, 7, 18, in: Self.newYork), cashTipsCents: 1_000)
        let tomorrow = ShiftRecord(workDate: Self.at(2026, 7, 20, in: Self.losAngeles), cashTipsCents: 1_000, jobName: "Cafe")
        let context = try Self.context(with: [cafe, yesterday, tomorrow])
        let found = try LogTipsIntent.todaysRecords(
            in: context, now: Self.at(2026, 7, 19, hour: 20, in: Self.newYork), calendars: calendars, phoneTimeZone: Self.newYork)
        #expect(found.map(\.id) == [cafe.id])
    }

    /// One zone: exactly the rows the shipped fetch found, the ones stored
    /// at today's start in the payroll zone.
    @Test("Siri's today is unchanged for an account with one zone",
          arguments: ["America/New_York", "Asia/Tokyo", "Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Havana"])
    func siriOneZonePin(_ identifier: String) throws {
        let zone = TimeZone(identifier: identifier)!
        let calendars = [StoredDayTests.calendarPolicy(zone, id: "siri/pin")]
        let storedDay = StoredDay(.workDay, calendars: calendars)
        let records = (5...11).map { day in
            ShiftRecord(workDate: storedDay.stored(CivilDay(year: 2026, month: 3, day: day), job: nil), cashTipsCents: 1_000)
        }
        let context = try Self.context(with: records)
        for day in 6...10 {
            let now = StoredDayTests.at(2026, 3, day, hour: 21, in: zone)
            let shippedToday = storedDay.stored(picked: now, job: nil, phoneTimeZone: zone)
            let shipped = try context.fetch(FetchDescriptor<ShiftRecord>(predicate: #Predicate { $0.workDate == shippedToday }))
            let found = try LogTipsIntent.todaysRecords(in: context, now: now, calendars: calendars, phoneTimeZone: zone)
            #expect(found.map(\.id) == shipped.map(\.id))
            #expect(found.count == 1)
        }
    }
}
