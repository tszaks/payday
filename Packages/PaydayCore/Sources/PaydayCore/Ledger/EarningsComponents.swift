import Foundation

/// The six integer components every earnings figure in Payday is a sum of.
/// All values are cents. Every aggregate anywhere in the engine is
/// `Σ components` over the selected shifts (Design 1, step 6), so this type
/// is `AdditiveArithmetic`: a month is `days.reduce(.zero, +)`.
///
/// - `voluntaryCashCents`, `voluntaryCreditCents`: tips the guest chose to
///   leave.
/// - `gratuityFeesCents`: service charges / auto-gratuity, kept separate so
///   "Tips" never silently includes a fee.
/// - `tipOutCents`: what the server paid out to support staff. Subtracted.
/// - `regularWagesCents`, `overtimeWagesCents`: hourly wages, valued by the
///   ledger. Zero when wages are `.unavailable` for a shift; the matching
///   `Completeness` says so.
public struct EarningsComponents: AdditiveArithmetic, Hashable, Codable, Sendable {
    public var voluntaryCashCents: Int
    public var voluntaryCreditCents: Int
    public var gratuityFeesCents: Int
    public var tipOutCents: Int
    public var regularWagesCents: Int
    public var overtimeWagesCents: Int

    public init(
        voluntaryCashCents: Int = 0,
        voluntaryCreditCents: Int = 0,
        gratuityFeesCents: Int = 0,
        tipOutCents: Int = 0,
        regularWagesCents: Int = 0,
        overtimeWagesCents: Int = 0
    ) {
        self.voluntaryCashCents = voluntaryCashCents
        self.voluntaryCreditCents = voluntaryCreditCents
        self.gratuityFeesCents = gratuityFeesCents
        self.tipOutCents = tipOutCents
        self.regularWagesCents = regularWagesCents
        self.overtimeWagesCents = overtimeWagesCents
    }

    /// `MetricID.voluntaryTips`: cash + credit.
    public var voluntaryTipsCents: Int { voluntaryCashCents + voluntaryCreditCents }

    /// `MetricID.nonWageEarnings`: cash + credit + gratuityFees - tipOut.
    public var nonWageEarningsCents: Int {
        voluntaryCashCents + voluntaryCreditCents + gratuityFeesCents - tipOutCents
    }

    /// regularWages + overtimeWages.
    public var wagesCents: Int { regularWagesCents + overtimeWagesCents }

    /// `MetricID.earnedIncome`: nonWageEarnings + wages.
    public var earnedIncomeCents: Int { nonWageEarningsCents + wagesCents }

    // MARK: AdditiveArithmetic

    public static let zero = EarningsComponents()

    public static func + (lhs: EarningsComponents, rhs: EarningsComponents) -> EarningsComponents {
        EarningsComponents(
            voluntaryCashCents: lhs.voluntaryCashCents + rhs.voluntaryCashCents,
            voluntaryCreditCents: lhs.voluntaryCreditCents + rhs.voluntaryCreditCents,
            gratuityFeesCents: lhs.gratuityFeesCents + rhs.gratuityFeesCents,
            tipOutCents: lhs.tipOutCents + rhs.tipOutCents,
            regularWagesCents: lhs.regularWagesCents + rhs.regularWagesCents,
            overtimeWagesCents: lhs.overtimeWagesCents + rhs.overtimeWagesCents
        )
    }

    public static func - (lhs: EarningsComponents, rhs: EarningsComponents) -> EarningsComponents {
        EarningsComponents(
            voluntaryCashCents: lhs.voluntaryCashCents - rhs.voluntaryCashCents,
            voluntaryCreditCents: lhs.voluntaryCreditCents - rhs.voluntaryCreditCents,
            gratuityFeesCents: lhs.gratuityFeesCents - rhs.gratuityFeesCents,
            tipOutCents: lhs.tipOutCents - rhs.tipOutCents,
            regularWagesCents: lhs.regularWagesCents - rhs.regularWagesCents,
            overtimeWagesCents: lhs.overtimeWagesCents - rhs.overtimeWagesCents
        )
    }
}
