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

    public init(
        version: Int = CompensationPolicies.currentVersion,
        rates: [PayRatePolicy] = [],
        calendars: [PayrollCalendarPolicy] = []
    ) {
        self.version = version
        self.rates = rates.sorted(by: CompensationPolicies.rateOrder)
        self.calendars = calendars.sorted(by: CompensationPolicies.calendarOrder)
    }

    public static let empty = CompensationPolicies()

    public var isEmpty: Bool { rates.isEmpty && calendars.isEmpty }

    private enum CodingKeys: String, CodingKey { case version, rates, calendars }

    /// A payload with no `version` is read as version 1 (the shape shipped
    /// here); missing arrays read as empty, so a partially written row never
    /// fails to decode into "no policies".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? CompensationPolicies.currentVersion
        let rates = try container.decodeIfPresent([PayRatePolicy].self, forKey: .rates) ?? []
        let calendars = try container.decodeIfPresent([PayrollCalendarPolicy].self, forKey: .calendars) ?? []
        self.init(version: version, rates: rates, calendars: calendars)
    }

    // MARK: Lookups

    /// The rate in effect on `day`: the last policy whose `effectiveFrom` is
    /// on or before it. Nil when the wage feature was never turned on, or
    /// when `day` predates the earliest rate.
    public func rate(on day: CivilDay) -> PayRatePolicy? {
        CompensationLedger.policy(in: rates, onOrBefore: day, key: \.effectiveFrom)
    }

    /// The calendar policy in effect on `day`, from the policies that survive
    /// the workweek-boundary rule.
    public func calendar(on day: CivilDay) -> PayrollCalendarPolicy? {
        CompensationLedger.policy(
            in: CompensationLedger.acceptCalendarPolicies(calendars).accepted,
            onOrBefore: day,
            key: \.effectiveFrom
        )
    }

    /// The most recent calendar policy, whatever its effective date: the one
    /// a new policy has to start on a boundary of, and the one whose frozen
    /// zone the app reads for "the payroll time zone".
    public var latestCalendar: PayrollCalendarPolicy? { calendars.last }

    /// The most recent rate, whatever its effective date: what Settings shows
    /// as "your rate" and what `baseHourlyWageCents` becomes a view of.
    public var latestRate: PayRatePolicy? { rates.last }

    /// The frozen payroll time zone: the latest calendar policy's. Nil when
    /// no calendar policy exists yet, which is the only moment the app is
    /// allowed to consult the device.
    public var payrollTimeZone: TimeZone? { latestCalendar?.payrollTimeZone }

    /// True when at least one valuation would come back `assumed`: there is a
    /// rate policy and every one of them is a legacy assumption. Gates the
    /// one-time rate-history prompt, alongside "the user actually has shifts".
    public var hasOnlyAssumedRates: Bool {
        !rates.isEmpty && rates.allSatisfy { $0.provenance == .assumedFromLegacySetting }
    }

    // MARK: Editing

    /// Returns a copy with `policy` added (or replaced, by id), renormalized.
    public func adding(rate policy: PayRatePolicy) -> CompensationPolicies {
        var updated = rates.filter { $0.id != policy.id }
        updated.append(policy)
        return CompensationPolicies(version: version, rates: updated, calendars: calendars)
    }

    /// Returns a copy with `policy` added (or replaced, by id), renormalized.
    public func adding(calendar policy: PayrollCalendarPolicy) -> CompensationPolicies {
        var updated = calendars.filter { $0.id != policy.id }
        updated.append(policy)
        return CompensationPolicies(version: version, rates: rates, calendars: updated)
    }

    public func removingRate(id: UUID) -> CompensationPolicies {
        CompensationPolicies(version: version, rates: rates.filter { $0.id != id }, calendars: calendars)
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
            payrollTimeZone: payrollTimeZone
        )
    }
}
