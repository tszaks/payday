import Foundation

/// How much of a result's wage picture is actually known. Every
/// `EarningsResult` carries one so presentation can say "Known so far"
/// instead of pretending a partial number is a total (Design 2,
/// "Presentation rules for partial earnings").
public struct Completeness: Hashable, Codable, Sendable {
    /// Shifts selected by the query.
    public var totalShifts: Int
    /// Shifts with `minutesWorked` present.
    public var shiftsWithHours: Int
    /// Shifts whose wage is `.valued` (hours present AND a rate and calendar policy in effect).
    public var shiftsWageValued: Int
    /// Valued shifts whose rate policy is `.assumedFromLegacySetting`.
    public var shiftsWageAssumed: Int
    /// Whether the user has wages turned on at all.
    public var wageFeatureEnabled: Bool

    public init(
        totalShifts: Int,
        shiftsWithHours: Int,
        shiftsWageValued: Int,
        shiftsWageAssumed: Int,
        wageFeatureEnabled: Bool
    ) {
        self.totalShifts = totalShifts
        self.shiftsWithHours = shiftsWithHours
        self.shiftsWageValued = shiftsWageValued
        self.shiftsWageAssumed = shiftsWageAssumed
        self.wageFeatureEnabled = wageFeatureEnabled
    }

    /// Nothing selected, wages off.
    public static let empty = Completeness(
        totalShifts: 0, shiftsWithHours: 0, shiftsWageValued: 0, shiftsWageAssumed: 0,
        wageFeatureEnabled: false
    )

    /// Derived, in this order:
    /// 1. `totalShifts == 0` → `.noShifts`
    /// 2. `!wageFeatureEnabled` → `.off`
    /// 3. every shift valued, none assumed → `.complete`
    /// 4. every shift valued, some assumed → `.estimated`
    /// 5. otherwise `.partial(missingHours: total - withHours, missingRate: withHours - valued)`
    public var state: WageState {
        if totalShifts == 0 { return .noShifts }
        if !wageFeatureEnabled { return .off }
        if shiftsWageValued == totalShifts {
            return shiftsWageAssumed == 0 ? .complete : .estimated
        }
        return .partial(
            missingHours: totalShifts - shiftsWithHours,
            missingRate: shiftsWithHours - shiftsWageValued
        )
    }
}

/// The five presentation states of a wage picture.
public enum WageState: Equatable, Hashable, Codable, Sendable {
    /// Wages are not a feature the user has turned on: amounts are non-wage and labelled "Tips".
    case off
    /// Every selected shift has a confirmed wage: plain amount, "Total".
    case complete
    /// Every selected shift has a wage, but some rest on the legacy rate assumption: plain amount plus "Wages estimated from your current rate".
    case estimated
    /// Some selected shifts have no wage. `missingHours` lack hours; `missingRate` have hours but no rate policy in effect. Headline is "Known so far".
    case partial(missingHours: Int, missingRate: Int)
    /// The selection is empty.
    case noShifts
}
