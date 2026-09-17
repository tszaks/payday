import Foundation

/// The employer's payroll calendar: which weekday starts the overtime week,
/// the weekly threshold, the overtime multiplier, and the frozen payroll
/// time zone. `effectiveFrom` must fall on a workweek start under the
/// previous calendar policy (the engine rejects any that does not, PR 3).
///
/// `payrollTimeZone` is captured when the policy is created and changes only
/// when the user creates a new policy, so a device travelling never moves a
/// shift into another week. It is encoded as its identifier
/// (`"America/New_York"`).
///
/// `workweekStartWeekday` must be 1...7: the memberwise initializer traps on
/// anything else and `init(from:)` throws `DecodingError.dataCorrupted`, so a
/// bad stored value can never reach `CivilDay.startOfWorkweek(startingOn:)`.
public struct PayrollCalendarPolicy: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var effectiveFrom: CivilDay
    /// 1 = Sunday ... 7 = Saturday.
    public var workweekStartWeekday: Int
    /// Minutes per workweek before overtime begins. 2400 = 40 hours.
    public var overtimeThresholdMinutes: Int
    /// Overtime multiplier in hundredths. 150 = time and a half.
    public var overtimeMultiplierHundredths: Int
    public var payrollTimeZone: TimeZone

    public init(
        id: UUID,
        effectiveFrom: CivilDay,
        workweekStartWeekday: Int,
        overtimeThresholdMinutes: Int = 2400,
        overtimeMultiplierHundredths: Int = 150,
        payrollTimeZone: TimeZone
    ) {
        precondition(PayrollCalendarPolicy.weekdayRange.contains(workweekStartWeekday),
                     "workweekStartWeekday must be 1 (Sunday) ... 7 (Saturday), got \(workweekStartWeekday)")
        self.id = id
        self.effectiveFrom = effectiveFrom
        self.workweekStartWeekday = workweekStartWeekday
        self.overtimeThresholdMinutes = overtimeThresholdMinutes
        self.overtimeMultiplierHundredths = overtimeMultiplierHundredths
        self.payrollTimeZone = payrollTimeZone
    }

    /// 1 = Sunday ... 7 = Saturday, the `Calendar` convention shared with `CivilDay.weekday`.
    public static let weekdayRange = 1...7

    private enum CodingKeys: String, CodingKey {
        case id, effectiveFrom, workweekStartWeekday, overtimeThresholdMinutes,
             overtimeMultiplierHundredths, payrollTimeZone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        effectiveFrom = try container.decode(CivilDay.self, forKey: .effectiveFrom)
        let weekday = try container.decode(Int.self, forKey: .workweekStartWeekday)
        guard PayrollCalendarPolicy.weekdayRange.contains(weekday) else {
            throw DecodingError.dataCorruptedError(forKey: .workweekStartWeekday, in: container,
                debugDescription: "workweekStartWeekday must be 1 (Sunday) ... 7 (Saturday), got \(weekday)")
        }
        workweekStartWeekday = weekday
        overtimeThresholdMinutes = try container.decodeIfPresent(Int.self, forKey: .overtimeThresholdMinutes) ?? 2400
        overtimeMultiplierHundredths = try container.decodeIfPresent(Int.self, forKey: .overtimeMultiplierHundredths) ?? 150
        let identifier = try container.decode(String.self, forKey: .payrollTimeZone)
        guard let zone = TimeZone(identifier: identifier) else {
            throw DecodingError.dataCorruptedError(forKey: .payrollTimeZone, in: container,
                debugDescription: "Unknown time zone identifier \(identifier)")
        }
        payrollTimeZone = zone
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(effectiveFrom, forKey: .effectiveFrom)
        try container.encode(workweekStartWeekday, forKey: .workweekStartWeekday)
        try container.encode(overtimeThresholdMinutes, forKey: .overtimeThresholdMinutes)
        try container.encode(overtimeMultiplierHundredths, forKey: .overtimeMultiplierHundredths)
        try container.encode(payrollTimeZone.identifier, forKey: .payrollTimeZone)
    }
}
