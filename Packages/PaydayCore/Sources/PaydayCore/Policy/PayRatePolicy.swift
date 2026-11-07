import Foundation

/// Where a rate came from. `assumedFromLegacySetting` marks the single policy
/// migration fabricates from the old `baseHourlyWageCents` so every wage it
/// produces is reported as "estimated" until the user confirms
/// (Design 1, "No fabricated rate history").
public enum RateProvenance: String, Codable, CaseIterable, Sendable {
    case confirmed
    case assumedFromLegacySetting
}

/// An hourly rate in effect from `effectiveFrom` until the next policy's
/// `effectiveFrom`. May change on any day; the weekly overtime threshold is
/// continuous across a rate change.
public struct PayRatePolicy: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var effectiveFrom: CivilDay
    public var hourlyRateCents: Int
    public var provenance: RateProvenance
    /// The role this rate pays (bar, floor). Nil means every role, and is
    /// the only kind a shift with no role is paid at. A shift with a role
    /// uses the latest effective policy for that role, else the latest
    /// effective nil-role policy (`CompensationLedger`). Stored as typed;
    /// matched trimmed and case-insensitively (`ShiftRole.key`).
    public var roleName: String?

    public init(
        id: UUID,
        effectiveFrom: CivilDay,
        hourlyRateCents: Int,
        provenance: RateProvenance,
        roleName: String? = nil
    ) {
        self.id = id
        self.effectiveFrom = effectiveFrom
        self.hourlyRateCents = hourlyRateCents
        self.provenance = provenance
        self.roleName = ShiftRole.normalized(roleName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, effectiveFrom, hourlyRateCents, provenance, roleName
    }

    /// `roleName` is absent from every policy written before roles existed,
    /// so it decodes as nil ("every role"), and nil is encoded as absent so
    /// a policy without a role encodes byte-identically to before.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        effectiveFrom = try container.decode(CivilDay.self, forKey: .effectiveFrom)
        hourlyRateCents = try container.decode(Int.self, forKey: .hourlyRateCents)
        provenance = try container.decode(RateProvenance.self, forKey: .provenance)
        roleName = ShiftRole.normalized(try container.decodeIfPresent(String.self, forKey: .roleName))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(effectiveFrom, forKey: .effectiveFrom)
        try container.encode(hourlyRateCents, forKey: .hourlyRateCents)
        try container.encode(provenance, forKey: .provenance)
        try container.encodeIfPresent(roleName, forKey: .roleName)
    }
}

/// The rules for a shift's role name, in one place so the phone, the rate
/// policies and the ledger agree on what "the same role" means.
public enum ShiftRole {
    /// The longest role name, in UNICODE SCALARS, matching the
    /// `shifts.role_name` check: Postgres `length` and `left` count code
    /// points, while a Swift `Character` can be several (a family emoji is
    /// seven). Capping by scalars here means the server never cuts a name
    /// the phone sent, so a synced spelling always matches its rate policy.
    public static let maxLength = 40

    /// Trimmed, at most `maxLength` scalars, nil when empty. Stored as
    /// typed otherwise.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return capped(trimmed)
    }

    /// `text` cut to at most `maxLength` scalars, on a character boundary,
    /// so a multi-scalar character is kept whole or dropped whole.
    public static func capped(_ text: String) -> String {
        var result = ""
        var scalars = 0
        for character in text {
            let count = character.unicodeScalars.count
            guard scalars + count <= maxLength else { break }
            result.append(character)
            scalars += count
        }
        return result
    }

    /// The comparison key: trimmed and case-insensitive. Nil for no role.
    public static func key(_ raw: String?) -> String? {
        normalized(raw).map { $0.lowercased() }
    }
}
