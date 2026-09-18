import Foundation

/// The wage half of one shift's valuation: how its minutes were split by the
/// weekly overtime threshold, and what each stream came to in cents after
/// the ledger's cumulative rounding.
///
/// `regularWagesCents` is NOT `roundCents(rate * regularMinutes * 100)` on
/// its own. It is that shift's slice of the week's running total
/// (Design 1, step 5), so the per-shift cents telescope exactly to the week
/// total and no later shift can move an earlier one.
public struct WageComponents: Hashable, Codable, Sendable {
    public var regularMinutes: Int
    public var overtimeMinutes: Int
    public var regularWagesCents: Int
    public var overtimeWagesCents: Int

    public init(
        regularMinutes: Int,
        overtimeMinutes: Int,
        regularWagesCents: Int,
        overtimeWagesCents: Int
    ) {
        self.regularMinutes = regularMinutes
        self.overtimeMinutes = overtimeMinutes
        self.regularWagesCents = regularWagesCents
        self.overtimeWagesCents = overtimeWagesCents
    }

    public static let zero = WageComponents(
        regularMinutes: 0, overtimeMinutes: 0, regularWagesCents: 0, overtimeWagesCents: 0
    )

    public var minutesWorked: Int { regularMinutes + overtimeMinutes }
    public var wagesCents: Int { regularWagesCents + overtimeWagesCents }
}

/// Why a shift carries no wage. Each reason is a distinct sentence the UI
/// says out loud; none of them is ever rendered as `$0`.
public enum WageUnavailableReason: String, Hashable, Codable, CaseIterable, Sendable {
    /// No `PayRatePolicy` is in effect on the work day (the wage feature is
    /// off, or the shift predates the earliest rate). The shift's minutes
    /// still count toward the weekly overtime threshold.
    case rateNotSet
    /// `ShiftInput.minutesWorked` is nil: hours were never logged.
    case hoursMissing
    /// No `PayrollCalendarPolicy` is in effect on the work day, so there is
    /// no workweek to allocate the shift into.
    case noCalendarPolicy
}

/// One shift's wage outcome. `.valued` carries `assumed: true` when the rate
/// policy that produced it has `provenance == .assumedFromLegacySetting`, so
/// completeness can report "wages estimated from your current rate"
/// (Design 1, step 8).
public enum WageValuation: Hashable, Codable, Sendable {
    case valued(WageComponents, assumed: Bool)
    case unavailable(WageUnavailableReason)

    public var components: WageComponents {
        switch self {
        case .valued(let components, _): return components
        case .unavailable: return .zero
        }
    }

    public var isValued: Bool {
        switch self {
        case .valued: return true
        case .unavailable: return false
        }
    }

    /// True only for a valued wage resting on the legacy rate assumption.
    public var isAssumed: Bool {
        switch self {
        case .valued(_, let assumed): return assumed
        case .unavailable: return false
        }
    }

    public var unavailableReason: WageUnavailableReason? {
        switch self {
        case .valued: return nil
        case .unavailable(let reason): return reason
        }
    }
}

/// What the ledger produces for one shift: the policies that governed it,
/// the workweek it was allocated in, its wage outcome, and the full
/// `EarningsComponents` (tips and wages together) that every aggregate in
/// the engine is a sum of.
public struct ShiftValuation: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var workDay: CivilDay
    /// Nil when no rate policy was in effect (`wage == .unavailable(.rateNotSet)`).
    public var ratePolicyID: UUID?
    /// Nil when no calendar policy was in effect.
    public var calendarPolicyID: UUID?
    /// The start of the workweek this shift was bucketed into, under the
    /// calendar policy in effect on `workDay`. Nil without a calendar policy.
    public var workweekStart: CivilDay?
    /// Copied from the input: nil means hours were never logged.
    public var minutesWorked: Int?
    /// `minutesWorked` under the workweek overtime threshold, and the rest.
    ///
    /// This is a CALENDAR fact, not a wage: it is the split the threshold
    /// produced for this shift's position in its workweek, and it survives
    /// a shift the engine cannot price. A shift with 300 logged minutes and
    /// no rate policy in effect reports `regularMinutes == 300` with
    /// `wage == .unavailable(.rateNotSet)` and zero cents, because the
    /// hours ARE known and only their value is not (fixture H1, which
    /// asserts `minutes 300, regularMinutes 300` for exactly that shift).
    ///
    /// Nil when there is nothing to split: no hours logged, or no calendar
    /// policy in effect to define a workweek.
    ///
    /// For a `.valued` wage these equal `wage.components.regularMinutes` and
    /// `.overtimeMinutes` — the ledger writes both from the same two locals
    /// in one place, and `thresholdSplitAgreesWithTheValuedWageSplit` pins
    /// it across every fixture. They are the same number for different
    /// reasons: this pair is "minutes under the threshold", that pair is
    /// "minutes priced at straight time", and only the first one exists
    /// when no rate does.
    public var regularMinutes: Int?
    public var overtimeMinutes: Int?
    public var wage: WageValuation
    /// Non-wage components plus the valued wage. The one number source for
    /// every day, month, period and range aggregate.
    public var components: EarningsComponents

    public init(
        id: UUID,
        workDay: CivilDay,
        ratePolicyID: UUID?,
        calendarPolicyID: UUID?,
        workweekStart: CivilDay?,
        minutesWorked: Int?,
        regularMinutes: Int? = nil,
        overtimeMinutes: Int? = nil,
        wage: WageValuation,
        components: EarningsComponents
    ) {
        self.id = id
        self.workDay = workDay
        self.ratePolicyID = ratePolicyID
        self.calendarPolicyID = calendarPolicyID
        self.workweekStart = workweekStart
        self.minutesWorked = minutesWorked
        self.regularMinutes = regularMinutes
        self.overtimeMinutes = overtimeMinutes
        self.wage = wage
        self.components = components
    }
}
