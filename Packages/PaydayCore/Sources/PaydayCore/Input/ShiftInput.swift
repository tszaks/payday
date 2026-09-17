import Foundation

/// Lunch or dinner. Named `ShiftPeriodTag` so it never collides with the
/// app's `ShiftPeriod` while both exist; PR 5 retires the app one.
public enum ShiftPeriodTag: String, Codable, CaseIterable, Sendable {
    case lunch
    case dinner

    /// Order within a workweek for the overtime threshold split
    /// (Design 1, step 3): lunch, dinner, then untagged.
    public var rank: Int {
        switch self {
        case .lunch: return 0
        case .dinner: return 1
        }
    }
}

/// One shift as the engine sees it: a plain value, no storage, no time zone.
/// The adapter builds these from `ShiftRecord` (app) exactly once per
/// rebuild. Receipt normalization has already happened, so
/// `voluntaryCreditCents` is always voluntary and `gratuityFeesCents` is
/// always separate.
public struct ShiftInput: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var workDay: CivilDay
    public var period: ShiftPeriodTag?
    /// When the shift was logged; a tiebreaker in the weekly ordering only.
    public var recordedAt: Date?
    public var voluntaryCashCents: Int
    public var voluntaryCreditCents: Int
    public var gratuityFeesCents: Int
    /// Nil means "not entered", which the ledger treats as 0 cents.
    public var tipOutCents: Int?
    /// Nil means hours were never logged: the shift contributes no wage and
    /// counts as `missingHours` in `Completeness`.
    public var minutesWorked: Int?

    public init(
        id: UUID,
        workDay: CivilDay,
        period: ShiftPeriodTag? = nil,
        recordedAt: Date? = nil,
        voluntaryCashCents: Int = 0,
        voluntaryCreditCents: Int = 0,
        gratuityFeesCents: Int = 0,
        tipOutCents: Int? = nil,
        minutesWorked: Int? = nil
    ) {
        self.id = id
        self.workDay = workDay
        self.period = period
        self.recordedAt = recordedAt
        self.voluntaryCashCents = voluntaryCashCents
        self.voluntaryCreditCents = voluntaryCreditCents
        self.gratuityFeesCents = gratuityFeesCents
        self.tipOutCents = tipOutCents
        self.minutesWorked = minutesWorked
    }

    /// The non-wage components this shift contributes, before any valuation.
    public var nonWageComponents: EarningsComponents {
        EarningsComponents(
            voluntaryCashCents: voluntaryCashCents,
            voluntaryCreditCents: voluntaryCreditCents,
            gratuityFeesCents: gratuityFeesCents,
            tipOutCents: tipOutCents ?? 0
        )
    }
}
