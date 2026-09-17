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

    public init(id: UUID, effectiveFrom: CivilDay, hourlyRateCents: Int, provenance: RateProvenance) {
        self.id = id
        self.effectiveFrom = effectiveFrom
        self.hourlyRateCents = hourlyRateCents
        self.provenance = provenance
    }
}
