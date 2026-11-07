import Foundation

/// The seven integer components every earnings figure in Payday is a sum of.
/// All values are cents. Every aggregate anywhere in the engine is
/// `Σ components` over the selected shifts (Design 1, step 6), so this type
/// is `AdditiveArithmetic`: a month is `days.reduce(.zero, +)`.
///
/// - `voluntaryCashCents`, `voluntaryCreditCents`: tips the guest chose to
///   leave.
/// - `gratuityFeesCents`: service charges / auto-gratuity, kept separate so
///   "Tips" never silently includes a fee.
/// - `tipOutCents`: what the server paid out to support staff. Subtracted.
/// - `tipShareInCents`: a tip share or pool payout the person RECEIVED from
///   co-workers. Added. Earned money, but never "tips the guest left", so it
///   stays out of `voluntaryTipsCents` and every tip-percent figure.
/// - `regularWagesCents`, `overtimeWagesCents`: hourly wages, valued by the
///   ledger. Zero when wages are `.unavailable` for a shift; the matching
///   `Completeness` says so.
public struct EarningsComponents: AdditiveArithmetic, Hashable, Codable, Sendable {
    public var voluntaryCashCents: Int
    public var voluntaryCreditCents: Int
    public var gratuityFeesCents: Int
    public var tipOutCents: Int
    public var tipShareInCents: Int
    public var regularWagesCents: Int
    public var overtimeWagesCents: Int

    public init(
        voluntaryCashCents: Int = 0,
        voluntaryCreditCents: Int = 0,
        gratuityFeesCents: Int = 0,
        tipOutCents: Int = 0,
        tipShareInCents: Int = 0,
        regularWagesCents: Int = 0,
        overtimeWagesCents: Int = 0
    ) {
        self.voluntaryCashCents = voluntaryCashCents
        self.voluntaryCreditCents = voluntaryCreditCents
        self.gratuityFeesCents = gratuityFeesCents
        self.tipOutCents = tipOutCents
        self.tipShareInCents = tipShareInCents
        self.regularWagesCents = regularWagesCents
        self.overtimeWagesCents = overtimeWagesCents
    }

    /// `MetricID.voluntaryTips`: cash + credit.
    public var voluntaryTipsCents: Int { voluntaryCashCents + voluntaryCreditCents }

    /// `MetricID.nonWageEarnings`: cash + credit + gratuityFees + tipShareIn - tipOut.
    public var nonWageEarningsCents: Int {
        voluntaryCashCents + voluntaryCreditCents + gratuityFeesCents + tipShareInCents - tipOutCents
    }

    /// regularWages + overtimeWages.
    public var wagesCents: Int { regularWagesCents + overtimeWagesCents }

    /// `MetricID.earnedIncome`: nonWageEarnings + wages.
    public var earnedIncomeCents: Int { nonWageEarningsCents + wagesCents }

    /// Everything that ADDS, before the tip-out is taken back out: cash +
    /// credit + gratuityFees + tipShareIn + wages, i.e. `earnedIncomeCents + tipOutCents`.
    ///
    /// The hero drawer's "Earned" subtotal row, and the same figure its
    /// collapsed lip quotes. It lives here rather than in the two screens
    /// that show it because both of them were composing it by hand from
    /// their own four-term addition, which is two chances to leave a term
    /// out; Period detail was additionally BACK-DERIVING its tip-out from
    /// the difference between this figure and its net, so a rounding
    /// disagreement anywhere upstream became a phantom tip-out row.
    public var grossBeforeTipOutCents: Int { earnedIncomeCents + tipOutCents }

    // MARK: AdditiveArithmetic

    public static let zero = EarningsComponents()

    public static func + (lhs: EarningsComponents, rhs: EarningsComponents) -> EarningsComponents {
        EarningsComponents(
            voluntaryCashCents: lhs.voluntaryCashCents + rhs.voluntaryCashCents,
            voluntaryCreditCents: lhs.voluntaryCreditCents + rhs.voluntaryCreditCents,
            gratuityFeesCents: lhs.gratuityFeesCents + rhs.gratuityFeesCents,
            tipOutCents: lhs.tipOutCents + rhs.tipOutCents,
            tipShareInCents: lhs.tipShareInCents + rhs.tipShareInCents,
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
            tipShareInCents: lhs.tipShareInCents - rhs.tipShareInCents,
            regularWagesCents: lhs.regularWagesCents - rhs.regularWagesCents,
            overtimeWagesCents: lhs.overtimeWagesCents - rhs.overtimeWagesCents
        )
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case voluntaryCashCents, voluntaryCreditCents, gratuityFeesCents, tipOutCents
        case tipShareInCents, regularWagesCents, overtimeWagesCents
    }

    /// `tipShareInCents` decodes as 0 when absent, so a snapshot written
    /// before the component existed still reads. Every other key stays
    /// required, as it was under the synthesized decoder.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.voluntaryCashCents = try c.decode(Int.self, forKey: .voluntaryCashCents)
        self.voluntaryCreditCents = try c.decode(Int.self, forKey: .voluntaryCreditCents)
        self.gratuityFeesCents = try c.decode(Int.self, forKey: .gratuityFeesCents)
        self.tipOutCents = try c.decode(Int.self, forKey: .tipOutCents)
        self.tipShareInCents = try c.decodeIfPresent(Int.self, forKey: .tipShareInCents) ?? 0
        self.regularWagesCents = try c.decode(Int.self, forKey: .regularWagesCents)
        self.overtimeWagesCents = try c.decode(Int.self, forKey: .overtimeWagesCents)
    }
}
