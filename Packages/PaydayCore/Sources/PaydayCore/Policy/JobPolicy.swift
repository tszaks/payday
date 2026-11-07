import Foundation

/// One of the person's jobs (PR E1, Pillar 9). A job is a NAME: shifts and
/// paychecks carry it as a tag (`job_name`, nil = the primary job), the way
/// a shift carries its role. The list lives inside `CompensationPolicies`
/// with the rates and calendars, so it syncs with them and needs no table.
///
/// `schedule` is the job's own pay schedule; nil means "same as the
/// primary". Periods still follow the primary schedule until E2.
public struct JobPolicy: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// Trimmed, at most 40 scalars (`ShiftRole` rules, the server's unit).
    public var name: String
    public var schedule: PayScheduleInput?
    public var isPrimary: Bool

    public init(id: UUID, name: String, schedule: PayScheduleInput?, isPrimary: Bool) {
        self.id = id
        self.name = ShiftRole.normalized(name) ?? ""
        self.schedule = schedule
        self.isPrimary = isPrimary
    }

    private enum CodingKeys: String, CodingKey { case id, name, schedule, isPrimary }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            schedule: try container.decodeIfPresent(PayScheduleInput.self, forKey: .schedule),
            isPrimary: try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encode(isPrimary, forKey: .isPrimary)
    }

    /// Primary first, then the order given (stable).
    static func ordered(_ jobs: [JobPolicy]) -> [JobPolicy] {
        jobs.filter(\.isPrimary) + jobs.filter { !$0.isPrimary }
    }
}
