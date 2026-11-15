import Foundation

/// The one owner of a stored day: the `Date` a shift's work day
/// (`ShiftRecord.workDate`) or a recorded paycheck's period day
/// (`PaycheckRecord.periodStart`, `periodEnd`) is kept as.
///
/// The rule: a stored day is the START of that civil day in the payroll zone
/// it is read in. For a work day that is the zone of the calendar policy in
/// effect on that day for the shift's job, the zone `civilDay(_:job:)` reads
/// it in for the engine. For a period day it is the job's latest zone, the
/// zone `PayPeriodCalculator` lays the job's periods out in, the zone the
/// paycheck is matched to its period in and the zone the engine reads it in
/// (`PaycheckInputAdapter`). Midnight in Tokyo on July 19 is
/// 8 AM on July 18 in Los Angeles, so storing the PHONE's midnight put a
/// shift logged in Tokyo for a Los Angeles payroll on the day before, in the
/// wrong workweek and the wrong pay period. The payroll zone's start of the
/// day is the one instant every reader names as the same day, wherever the
/// phone is.
///
/// Every conversion between a stored day and anything else goes through
/// here, as `PayScheduleAnchor` does for the pay schedule anchor: a picker
/// shows the phone's calendar (`stored(picked:job:)`, `shown(_:job:)`), a
/// reader that reads every day on one calendar gets the day's start there
/// (`start(of:job:in:)`), the server holds a `YYYY-MM-DD` day (`wireDay`,
/// `stored(wireDay:job:)`), and a row stored under the old phone-midnight
/// rule is re-anchored once (`repaired`). For an account with one payroll
/// zone, on a phone in that zone, every one of them is the identity, so
/// nothing it stores, sends or shows moves.
///
/// With no calendar policy at all (a first launch before the migration) the
/// zone falls back to the device's, the single moment the app is allowed to
/// consult it.
struct StoredDay {
    enum Kind {
        /// `ShiftRecord.workDate`: zone history applies, per job.
        case workDay
        /// `PaycheckRecord.periodStart` and `periodEnd`: the job's latest
        /// zone, as its pay periods are laid out.
        case periodDay
    }

    private let kind: Kind
    private let primaryCalendars: [PayrollCalendarPolicy]
    private let allCalendars: [PayrollCalendarPolicy]
    private let calendarsByJob: [String: [PayrollCalendarPolicy]]

    /// - Parameter calendars: every calendar policy, every job's, as
    ///   `CompensationPolicies.calendars` holds them. Each day reads its zone
    ///   from its OWN job's calendars (the `policies(forJob:)` partition); a
    ///   job with no calendar of its own reads the primary's. Sorted here,
    ///   once, into effect order, so no read sorts.
    init(_ kind: Kind, calendars unsorted: [PayrollCalendarPolicy]) {
        self.kind = kind
        let calendars = unsorted.sorted {
            ($0.effectiveFrom, $0.id.uuidString) < ($1.effectiveFrom, $1.id.uuidString)
        }
        allCalendars = calendars
        primaryCalendars = calendars.filter { $0.jobName == nil }
        var byJob: [String: [PayrollCalendarPolicy]] = [:]
        for calendar in calendars {
            guard let key = ShiftRole.key(calendar.jobName) else { continue }
            byJob[key, default: []].append(calendar)
        }
        calendarsByJob = byJob
    }

    // MARK: The reader

    /// The civil day a stored day names.
    ///
    /// A work day is read by the latest policy whose OWN reading of the
    /// instant is on or after its own `effectiveFrom`, walking from the
    /// latest policy back; when none qualifies, by the latest zone. The zone
    /// lives on the policy in effect on that day, and picking the policy
    /// needs the day, so each policy is asked in its own zone. That is what
    /// makes the reader give back the day the writer stored: the first day of
    /// a policy whose zone is east of a later one starts the evening before
    /// in the later zone, which a read in the latest zone alone would name.
    /// For one or two policies, the first from `.distantPast`, this is the
    /// same function as reading in the latest zone and then re-reading in the
    /// zone of the policy in effect on that day. A period day is read in the
    /// job's latest zone.
    func civilDay(_ stored: Date, job: String?) -> CivilDay {
        let calendars = calendars(for: job)
        let latestZone = Self.latestZone(in: calendars)
        guard kind == .workDay else { return CivilDay(stored, in: latestZone) }
        for policy in calendars.reversed() {
            let day = CivilDay(stored, in: policy.payrollTimeZone)
            if day >= policy.effectiveFrom { return day }
        }
        return CivilDay(stored, in: latestZone)
    }

    // MARK: The writer

    /// The stored day for `day`: its start in the zone it will be read in.
    func stored(_ day: CivilDay, job: String?) -> Date {
        day.date(in: zone(on: day, job: job))
    }

    // MARK: Pickers

    /// The stored day for a day a person picked on the phone's calendar.
    func stored(picked: Date, job: String?, phoneTimeZone: TimeZone = .current) -> Date {
        stored(CivilDay(picked, in: phoneTimeZone), job: job)
    }

    /// The date a picker, or anything that formats on the phone's calendar,
    /// must be given to show the stored day's own civil day.
    func shown(_ stored: Date, job: String?, phoneTimeZone: TimeZone = .current) -> Date {
        start(of: stored, job: job, in: phoneTimeZone)
    }

    // MARK: Readers that work on one calendar

    /// The start, in `zone`, of the stored day's own civil day: what a reader
    /// that reads every day on one calendar (a stats engine, a grouping, a
    /// day key) must be given. Rows of another policy or another job sit at
    /// their own zone's midnight, which that one calendar can name as the day
    /// before.
    func start(of stored: Date, job: String?, in zone: TimeZone) -> Date {
        civilDay(stored, job: job).date(in: zone)
    }

    // MARK: The wire

    /// The `YYYY-MM-DD` day the server holds for a stored day.
    func wireDay(_ stored: Date, job: String?) -> String {
        civilDay(stored, job: job).iso
    }

    /// The stored day for a day the server holds. Nil for anything that is
    /// not a `YYYY-MM-DD` day.
    func stored(wireDay: String, job: String?) -> Date? {
        CivilDay(iso: wireDay).map { stored($0, job: job) }
    }

    // MARK: Rows stored under the old rule

    /// The stored day a row should hold, given the instant it holds now.
    ///
    /// Before this type, every writer stored midnight on the phone's own
    /// calendar, and a zone change in the policies can leave a row in a zone
    /// it is no longer read in. In this order:
    ///
    /// 1. Already the start of its day in the zone it is read in: kept.
    /// 2. The start of a day on the phone's calendar now: most likely this
    ///    phone wrote it, so that is the day.
    /// 3. Otherwise the day `PaydayRemoteDate.stableDay` names, the same day
    ///    the upload fingerprint has always digested.
    ///
    /// The day then moves across to its start in the zone it is read in.
    /// Idempotent: the result is always kept by step 1 on the next run.
    /// Cheap on its common path: when the job's calendars hold one zone,
    /// step 1 is an offset check with no calendar arithmetic.
    ///
    /// The limit is the instant itself, which does not say which zone wrote
    /// it. A row written in a third zone, neither the phone's current zone
    /// nor the payroll zone, is recovered only when that zone lies in
    /// `stableDay`'s window (UTC-10:30, UTC+13:30]. The same holds after a
    /// payroll zone change AWAY from a zone outside that window (UTC-11,
    /// UTC+14): a row stored at that zone's midnight is not this phone's
    /// midnight, so `stableDay` names its day, and that can be the day next
    /// to the one it was. The row then moves to that adjacent day and its
    /// upload fingerprint, which digests the same `stableDay`, does not
    /// change, so nothing uploads to correct it.
    func repaired(_ stored: Date, job: String?, phoneTimeZone: TimeZone = .current) -> Date {
        if let zone = singleZone(for: job), Self.isMidnight(stored, in: zone) { return stored }
        let day = civilDay(stored, job: job)
        if self.stored(day, job: job) == stored { return stored }
        let phoneDay = CivilDay(stored, in: phoneTimeZone)
        let meant = phoneDay.date(in: phoneTimeZone) == stored
            ? phoneDay
            : CivilDay(iso: PaydayRemoteDate.stableDay(stored)) ?? day
        return self.stored(meant, job: job)
    }

    // MARK: Zones

    private func calendars(for job: String?) -> [PayrollCalendarPolicy] {
        if let key = ShiftRole.key(job), let own = calendarsByJob[key] { return own }
        return primaryCalendars.isEmpty ? allCalendars : primaryCalendars
    }

    /// The latest policy's zone, or the device's when there is no policy.
    private static func latestZone(in calendars: [PayrollCalendarPolicy]) -> TimeZone {
        calendars.last?.payrollTimeZone ?? .current
    }

    /// The zone `day` is stored in: the policy in effect on that day.
    private func zone(on day: CivilDay, job: String?) -> TimeZone {
        let calendars = calendars(for: job)
        let latestZone = Self.latestZone(in: calendars)
        guard kind == .workDay else { return latestZone }
        return Self.policy(in: calendars, onOrBefore: day)?.payrollTimeZone ?? latestZone
    }

    /// The one zone every day of this job is read in, when there is one.
    private func singleZone(for job: String?) -> TimeZone? {
        let calendars = calendars(for: job)
        let latestZone = Self.latestZone(in: calendars)
        guard kind == .workDay else { return latestZone }
        return calendars.allSatisfy { $0.payrollTimeZone == latestZone } ? latestZone : nil
    }

    /// Local midnight exactly. A day whose clocks change at midnight starts
    /// at 01:00, fails this, and takes the calendar path, which keeps it.
    /// It also accepts a midnight that is not a day's start: on a day whose
    /// clocks fall back at midnight, the second 00:00. That instant is kept
    /// as stored. Every reader names the same civil day for it, because
    /// readers compare civil days, never stored instants.
    private static func isMidnight(_ date: Date, in zone: TimeZone) -> Bool {
        let local = date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
        return local.truncatingRemainder(dividingBy: 86_400) == 0
    }

    /// The last calendar policy effective on or before `day`. Same rule as
    /// `CompensationPolicies.calendar(on:)`, which takes a whole
    /// `CompensationPolicies`; this one takes the sorted array it is given.
    private static func policy(
        in calendars: [PayrollCalendarPolicy],
        onOrBefore day: CivilDay
    ) -> PayrollCalendarPolicy? {
        calendars.last { $0.effectiveFrom <= day }
    }
}
