import Foundation

/// Every compensation policy the engine needs, as one versioned value.
///
/// This is the on-disk shape in the App Group (`PolicyStore`), the shape of
/// the `user_settings.compensation_policies` jsonb column, and the shape the
/// widget reads, so all three processes and the server agree by construction
/// rather than by convention. `version` is the payload's own schema version:
/// a future field is added by bumping it and decoding the old shape.
public struct CompensationPolicies: Hashable, Codable, Sendable {
    /// Bump when the JSON shape changes. Not the engine version.
    public static let currentVersion = 1

    public var version: Int
    /// Rate history, normalized to effect order.
    public var rates: [PayRatePolicy]
    /// Payroll calendar history, normalized to effect order.
    public var calendars: [PayrollCalendarPolicy]
    /// The person's jobs (PR E1), primary first. Empty for everyone with one
    /// job: a job list appears only when a second job is added, so an
    /// account that never adds one keeps today's JSON byte for byte.
    public var jobs: [JobPolicy]
    /// The job TAG the lookups below answer for (E2b). Nil on every value
    /// except one returned by `policies(forJob:)`, so an unfiltered value
    /// always answers for the primary and a job's filtered value answers
    /// for that job. Never encoded: it describes a view, not stored data.
    public private(set) var lookupJob: String?

    public init(
        version: Int = CompensationPolicies.currentVersion,
        rates: [PayRatePolicy] = [],
        calendars: [PayrollCalendarPolicy] = [],
        jobs: [JobPolicy] = []
    ) {
        self.version = version
        self.rates = rates.sorted(by: CompensationPolicies.rateOrder)
        self.calendars = calendars.sorted(by: CompensationPolicies.calendarOrder)
        self.jobs = JobPolicy.ordered(jobs)
    }

    public static let empty = CompensationPolicies()

    /// Nothing stored at all. Jobs count (PR E1): a payload that carries a
    /// job list and nothing else is still a state worth adopting from sync.
    public var isEmpty: Bool { rates.isEmpty && calendars.isEmpty && jobs.isEmpty }

    private enum CodingKeys: String, CodingKey { case version, rates, calendars, jobs }

    /// A payload with no `version` is read as version 1 (the shape shipped
    /// here); missing arrays read as empty, so a partially written row never
    /// fails to decode into "no policies".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? CompensationPolicies.currentVersion
        let rates = try container.decodeIfPresent([PayRatePolicy].self, forKey: .rates) ?? []
        let calendars = try container.decodeIfPresent([PayrollCalendarPolicy].self, forKey: .calendars) ?? []
        // Absent on every payload written before jobs.
        let jobs = try container.decodeIfPresent([JobPolicy].self, forKey: .jobs) ?? []
        self.init(version: version, rates: rates, calendars: calendars, jobs: jobs)
    }

    /// `jobs` is encoded only when there are any, so an account with one job
    /// writes exactly the JSON it wrote before jobs existed.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(rates, forKey: .rates)
        try container.encode(calendars, forKey: .calendars)
        // Always written, even empty: the server keeps the stored job list
        // only when the key is ABSENT (a build that predates jobs), so
        // `[]` is how a build that knows jobs says "there are none".
        try container.encode(jobs, forKey: .jobs)
    }

    // MARK: Jobs

    /// The primary job, when a job list exists.
    public var primaryJob: JobPolicy? { jobs.first(where: \.isPrimary) ?? jobs.first }

    /// Job names, primary first, then in the order they were added.
    public var jobNames: [String] { jobs.map(\.name) }

    /// The policies that belong to one job TAG (`JobPolicy.tag`): rates and
    /// calendars whose `jobName` matches it (trimmed, case-insensitive).
    /// Nil is the primary job, and only nil: this is exactly the partition
    /// `CompensationLedger.evaluate` makes, so a screen and the engine can
    /// never disagree about which policies price a shift. The primary's name
    /// is not a tag (see `JobPolicy.tag`) and answers with nothing. Jobs are
    /// carried through unchanged.
    public func policies(forJob tag: String?) -> CompensationPolicies {
        let key = ShiftRole.key(tag)
        var scoped = CompensationPolicies(
            version: version,
            rates: rates.filter { ShiftRole.key($0.jobName) == key },
            calendars: calendars.filter { ShiftRole.key($0.jobName) == key },
            jobs: jobs
        )
        scoped.lookupJob = ShiftRole.normalized(tag)
        return scoped
    }

    /// The rates and calendars the lookups answer from: the primary's
    /// (nil-tagged) on an unfiltered value, the job's on a value from
    /// `policies(forJob:)`. Without this, the first job-tagged calendar or
    /// rate would become the primary's "latest" and move its payroll zone
    /// and its "your rate" (the way `allRolesRates` already keeps a role's
    /// rate out of the account's answers).
    private var lookupRates: [PayRatePolicy] {
        let key = ShiftRole.key(lookupJob)
        return rates.filter { ShiftRole.key($0.jobName) == key }
    }

    private var lookupCalendars: [PayrollCalendarPolicy] {
        let key = ShiftRole.key(lookupJob)
        return calendars.filter { ShiftRole.key($0.jobName) == key }
    }

    // MARK: Lookups

    /// The rate in effect on `day`: the last policy whose `effectiveFrom` is
    /// on or before it. Nil when the wage feature was never turned on, or
    /// when `day` predates the earliest rate.
    ///
    /// The "All roles" rate only: a policy for one role never answers for
    /// the account as a whole (`CompensationLedger.ratePolicy` picks per
    /// shift).
    public func rate(on day: CivilDay) -> PayRatePolicy? {
        CompensationLedger.policy(in: allRolesRates, onOrBefore: day, key: \.effectiveFrom)
    }

    /// The calendar policy in effect on `day`, from the policies that survive
    /// the workweek-boundary rule.
    public func calendar(on day: CivilDay) -> PayrollCalendarPolicy? {
        CompensationLedger.policy(
            in: CompensationLedger.acceptCalendarPolicies(lookupCalendars).accepted,
            onOrBefore: day,
            key: \.effectiveFrom
        )
    }

    /// The most recent calendar policy, whatever its effective date: the one
    /// a new policy has to start on a boundary of, and the one whose frozen
    /// zone the app reads for "the payroll time zone".
    public var latestCalendar: PayrollCalendarPolicy? { lookupCalendars.last }

    /// The most recent rate, whatever its effective date: what Settings shows
    /// as "your rate" and what `baseHourlyWageCents` becomes a view of.
    /// The "All roles" rate: a role's own rate is never "your rate".
    public var latestRate: PayRatePolicy? { allRolesRates.last }

    /// The rates with no role, in effect order: what a shift without a role,
    /// or with a role that has no rate of its own, is paid at.
    public var allRolesRates: [PayRatePolicy] { lookupRates.filter { $0.roleName == nil } }

    /// One role's rates, in effect order (trimmed, case-insensitive match).
    public func rates(forRole role: String) -> [PayRatePolicy] {
        guard let key = ShiftRole.key(role) else { return [] }
        return rates.filter { ShiftRole.key($0.roleName) == key }
    }

    /// The roles that have a rate of their own, latest spelling, in the
    /// order their first rate takes effect.
    public var roleNames: [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for rate in rates {
            guard let name = rate.roleName, let key = ShiftRole.key(name), seen.insert(key).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// The frozen payroll time zone: the latest calendar policy's. Nil when
    /// no calendar policy exists yet, which is the only moment the app is
    /// allowed to consult the device.
    public var payrollTimeZone: TimeZone? { latestCalendar?.payrollTimeZone }

    /// True when at least one valuation would come back `assumed`: there is a
    /// rate policy and every one of them is a legacy assumption. Gates the
    /// one-time rate-history prompt, alongside "the user actually has shifts".
    public var hasOnlyAssumedRates: Bool {
        !allRolesRates.isEmpty && allRolesRates.allSatisfy { $0.provenance == .assumedFromLegacySetting }
    }

    // MARK: Editing

    /// Returns a copy with `policy` added (or replaced, by id), renormalized.
    public func adding(rate policy: PayRatePolicy) -> CompensationPolicies {
        var updated = rates.filter { $0.id != policy.id }
        updated.append(policy)
        return CompensationPolicies(version: version, rates: updated, calendars: calendars, jobs: jobs)
    }

    /// Returns a copy with `policy` added (or replaced, by id), renormalized.
    public func adding(calendar policy: PayrollCalendarPolicy) -> CompensationPolicies {
        var updated = calendars.filter { $0.id != policy.id }
        updated.append(policy)
        return CompensationPolicies(version: version, rates: rates, calendars: updated, jobs: jobs)
    }

    /// Returns a copy with every rate for `role` removed, so its shifts fall
    /// back to the "All roles" rate.
    public func removingRates(forRole role: String) -> CompensationPolicies {
        let key = ShiftRole.key(role)
        return CompensationPolicies(
            version: version,
            rates: rates.filter { ShiftRole.key($0.roleName) != key },
            calendars: calendars,
            jobs: jobs
        )
    }

    public func removingRate(id: UUID) -> CompensationPolicies {
        CompensationPolicies(version: version, rates: rates.filter { $0.id != id }, calendars: calendars, jobs: jobs)
    }

    // MARK: Editing jobs

    /// Returns a copy with a job added. The first extra job also creates the
    /// primary entry (`primaryName`, `primaryID`), because "one job" is
    /// stored as no list at all. A blank name, or one that matches an
    /// existing job (trimmed, case-insensitive), changes nothing.
    public func addingJob(
        id: UUID,
        name: String,
        schedule: PayScheduleInput?,
        primaryName: String,
        primaryID: UUID
    ) -> CompensationPolicies {
        guard let name = ShiftRole.normalized(name) else { return self }
        var updated = jobs
        if updated.isEmpty {
            guard ShiftRole.key(primaryName) != ShiftRole.key(name) else { return self }
            updated.append(JobPolicy(id: primaryID, name: primaryName, schedule: nil, isPrimary: true))
        }
        guard !updated.contains(where: { ShiftRole.key($0.name) == ShiftRole.key(name) }) else { return self }
        updated.append(JobPolicy(id: id, name: name, schedule: schedule, isPrimary: false))
        return replacing(jobs: updated)
    }

    /// Returns a copy with one job renamed, and every policy tagged with the
    /// old name retagged. A blank name or one another job has changes nothing.
    public func renamingJob(id: UUID, to newName: String) -> CompensationPolicies {
        guard let newName = ShiftRole.normalized(newName),
              let job = jobs.first(where: { $0.id == id }),
              !jobs.contains(where: { $0.id != id && ShiftRole.key($0.name) == ShiftRole.key(newName) })
        else { return self }
        let oldKey = ShiftRole.key(job.name)
        let updatedJobs = jobs.map { $0.id == id ? JobPolicy(id: $0.id, name: newName, schedule: $0.schedule, isPrimary: $0.isPrimary) : $0 }
        return retagging(rates: rates, calendars: calendars, jobs: updatedJobs) { tag in
            ShiftRole.key(tag) == oldKey ? newName : tag
        }
    }

    /// Returns a copy without one non-primary job (and without its
    /// policies). When only the primary would remain, the list goes away, so
    /// the stored JSON is the one-job shape again.
    public func removingJob(id: UUID) -> CompensationPolicies {
        guard let job = jobs.first(where: { $0.id == id }), !job.isPrimary else { return self }
        let key = ShiftRole.key(job.name)
        let remaining = jobs.filter { $0.id != id }
        return CompensationPolicies(
            version: version,
            rates: rates.filter { ShiftRole.key($0.jobName) != key },
            calendars: calendars.filter { ShiftRole.key($0.jobName) != key },
            jobs: remaining.count > 1 ? remaining : []
        )
    }

    private func replacing(jobs updated: [JobPolicy]) -> CompensationPolicies {
        CompensationPolicies(version: version, rates: rates, calendars: calendars, jobs: updated)
    }

    private func retagging(
        rates: [PayRatePolicy],
        calendars: [PayrollCalendarPolicy],
        jobs: [JobPolicy],
        _ tag: (String?) -> String?
    ) -> CompensationPolicies {
        CompensationPolicies(
            version: version,
            rates: rates.map { var rate = $0; rate.jobName = ShiftRole.normalized(tag($0.jobName)); return rate },
            calendars: calendars.map { var calendar = $0; calendar.jobName = ShiftRole.normalized(tag($0.jobName)); return calendar },
            jobs: jobs
        )
    }

    // MARK: Normal order

    static func rateOrder(_ lhs: PayRatePolicy, _ rhs: PayRatePolicy) -> Bool {
        (lhs.effectiveFrom.dayNumber, lhs.id.uuidString) < (rhs.effectiveFrom.dayNumber, rhs.id.uuidString)
    }

    static func calendarOrder(_ lhs: PayrollCalendarPolicy, _ rhs: PayrollCalendarPolicy) -> Bool {
        (lhs.effectiveFrom.dayNumber, lhs.id.uuidString) < (rhs.effectiveFrom.dayNumber, rhs.id.uuidString)
    }
}

/// The two one-time migrations from the pre-policy world, and the boundary
/// snapping the Settings UI needs. Pure functions in the package so they are
/// testable without a device, a store, or a UserDefaults suite; `PolicyStore`
/// (app target) owns only the "has this run" flag and the persistence.
public enum PolicyMigration {
    /// A UUID derived from `name` by SHA-256, so two devices migrating the
    /// same legacy settings independently mint the SAME policy id and a sync
    /// cannot produce two policies for one fact.
    public static func deterministicID(_ name: String) -> UUID {
        let hex = InputManifest.sha256Hex(name)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        while bytes.count < 16, index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        while bytes.count < 16 { bytes.append(0) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The first calendar policy, frozen from what the app was ALREADY
    /// effectively using, so the migration moves nobody's overtime:
    /// `workweekStartWeekday` is `PaySchedule.resolvedFirstWeekday` as it
    /// reads at migration time, and `payrollTimeZone` is the device zone
    /// captured once, here, and never consulted again.
    ///
    /// `effectiveFrom` is `.distantPast`: it is the first policy, so it has
    /// no previous policy to be on a boundary of, and every shift that
    /// already exists must be inside it.
    public static func frozenCalendarPolicy(
        workweekStartWeekday: Int,
        payrollTimeZone: TimeZone
    ) -> PayrollCalendarPolicy {
        PayrollCalendarPolicy(
            id: deterministicID("paydaycore/migration/calendar/1/\(workweekStartWeekday)/\(payrollTimeZone.identifier)"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: workweekStartWeekday,
            overtimeThresholdMinutes: 2400,
            overtimeMultiplierHundredths: 150,
            payrollTimeZone: payrollTimeZone
        )
    }

    /// The ONE rate policy the migration is allowed to create, from the old
    /// `baseHourlyWageCents`.
    ///
    /// No history is fabricated: a user who has had three raises gets one
    /// policy at their current rate, marked `.assumedFromLegacySetting`, so
    /// every wage it produces is reported as estimated until they answer the
    /// rate-history prompt. `effectiveFrom` is the earliest shift's work day
    /// (so nothing before their first shift is priced), or `.distantPast`
    /// when there are no shifts yet and there is therefore no history to be
    /// wrong about.
    public static func assumedRatePolicy(
        hourlyRateCents: Int,
        earliestShiftDay: CivilDay?
    ) -> PayRatePolicy {
        let effectiveFrom = earliestShiftDay ?? .distantPast
        return PayRatePolicy(
            id: deterministicID("paydaycore/migration/rate/1/\(effectiveFrom.iso)/\(hourlyRateCents)"),
            effectiveFrom: effectiveFrom,
            hourlyRateCents: hourlyRateCents,
            provenance: .assumedFromLegacySetting
        )
    }

    /// The date a NEW calendar policy may take effect on: the first workweek
    /// start, under `previous`, on or after `day`. Settings snaps the user's
    /// chosen date to this, which is why the engine can reject anything else
    /// as unrepresentable rather than guess.
    public static func snappedEffectiveFrom(
        onOrAfter day: CivilDay,
        previous: PayrollCalendarPolicy?
    ) -> CivilDay {
        guard let previous else { return day }
        return day.nextStartOfWorkweek(startingOn: previous.workweekStartWeekday)
    }

    /// A user-chosen change to the payroll calendar, snapped to a legal
    /// boundary and stamped with a fresh payroll zone.
    ///
    /// `id` is random rather than derived: two devices choosing a workweek
    /// change independently made two different decisions, and the sync's
    /// last-write-wins on the whole payload is what settles them. Only the
    /// migrations, which restate one existing fact, are deterministic.
    public static func calendarPolicy(
        effectiveFrom day: CivilDay,
        workweekStartWeekday: Int,
        payrollTimeZone: TimeZone,
        previous: PayrollCalendarPolicy?,
        id: UUID = UUID()
    ) -> PayrollCalendarPolicy {
        PayrollCalendarPolicy(
            id: id,
            effectiveFrom: snappedEffectiveFrom(onOrAfter: day, previous: previous),
            workweekStartWeekday: workweekStartWeekday,
            overtimeThresholdMinutes: previous?.overtimeThresholdMinutes ?? 2400,
            overtimeMultiplierHundredths: previous?.overtimeMultiplierHundredths ?? 150,
            payrollTimeZone: payrollTimeZone,
            // Carried forward like the threshold and multiplier, so changing
            // the workweek start or zone never turns daily overtime off.
            dailyOvertimeThresholdMinutes: previous?.dailyOvertimeThresholdMinutes
        )
    }
}
