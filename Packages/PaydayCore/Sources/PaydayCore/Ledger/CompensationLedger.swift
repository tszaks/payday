import Foundation

/// Something the ledger had to ignore or repair in its inputs. Diagnostics
/// are never silent: a rejected calendar policy still produces valuations
/// (under the previous policy), and the diagnostic is what the debug sheet
/// and the tests read to prove the rejection happened.
public struct LedgerDiagnostic: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, CaseIterable, Sendable {
        /// A `PayrollCalendarPolicy` whose `effectiveFrom` is not a workweek
        /// start under the previous policy. Rejected; the previous policy
        /// stays in effect (Design 1, "Two policy types, not one").
        case calendarPolicyOffWorkweekBoundary
        /// A `ShiftInput.minutesWorked` below zero. Clamped to zero: a
        /// negative length would run the weekly threshold backwards and let
        /// a later shift move an earlier one's cents.
        case negativeMinutesClamped
    }

    public var kind: Kind
    /// The offending policy, when the diagnostic is about one.
    public var policyID: UUID?
    /// The offending shift, when the diagnostic is about one.
    public var shiftID: UUID?
    public var message: String

    public init(kind: Kind, policyID: UUID? = nil, shiftID: UUID? = nil, message: String) {
        self.kind = kind
        self.policyID = policyID
        self.shiftID = shiftID
        self.message = message
    }
}

/// Values every shift exactly once, so every total anywhere in Payday is a
/// sum of the same per-shift cents (Design 1).
///
/// Pure, order-independent, integer-only. No `Date`, no `Calendar.current`,
/// no `TimeZone.current`: the work day arrives as a `CivilDay` and the
/// payroll time zone is frozen on the calendar policy, so a travelling
/// device cannot reprice history.
///
/// Arithmetic lives in units of 1/6000 cent (the lowest common multiple of
/// 60 minutes and the 100ths a 1.5x multiplier needs), so a minute of work
/// at any integer rate and any hundredths multiplier is exact:
/// `regular = rate * minutes * 100`, `overtime = rate * minutes *
/// multiplierHundredths`, and `roundCents(x) = (2x + 6000) / 12000` half-up.
public enum CompensationLedger {
    /// Bumped whenever a change to this file could change a cent. Stamped on
    /// every `EarningsResult` and into the `InputManifest`.
    public static let engineVersion = InputManifest.currentEngineVersion

    /// 1 cent = 6000 ledger units.
    public static let unitsPerCent = 6000

    /// Exact wage units for `minutes` at `rateCents` per hour scaled by
    /// `multiplierHundredths` (100 = straight time, 150 = time and a half).
    /// `rate * minutes * 100` is the regular case because
    /// `rateCents/60 * minutes` cents = `rate * minutes * 100` units.
    static func wageUnits(rateCents: Int, minutes: Int, multiplierHundredths: Int) -> Int {
        rateCents * minutes * multiplierHundredths
    }

    /// `(2x + 6000) / 12000`, half-up. Reproduces today's `.rounded()` on
    /// positive values without ever touching a `Double`.
    public static func roundCents(_ units: Int) -> Int {
        IntegerRounding.divideHalfUp(units, by: unitsPerCent)
    }

    /// Everything a valuation run produced: the per-shift valuations in the
    /// engine's canonical order, the calendar policies that survived the
    /// boundary rule, and every diagnostic raised on the way.
    public struct Output: Hashable, Sendable {
        public var valuations: [ShiftValuation]
        public var acceptedCalendarPolicies: [PayrollCalendarPolicy]
        public var diagnostics: [LedgerDiagnostic]
        /// Whether the user has wages turned on at all: true when at least
        /// one rate policy exists. Feeds `Completeness.wageFeatureEnabled`.
        public var wageFeatureEnabled: Bool

        public init(
            valuations: [ShiftValuation],
            acceptedCalendarPolicies: [PayrollCalendarPolicy],
            diagnostics: [LedgerDiagnostic],
            wageFeatureEnabled: Bool
        ) {
            self.valuations = valuations
            self.acceptedCalendarPolicies = acceptedCalendarPolicies
            self.diagnostics = diagnostics
            self.wageFeatureEnabled = wageFeatureEnabled
        }

        /// Σ components over every valuation.
        public var totalComponents: EarningsComponents {
            valuations.reduce(.zero) { $0 + $1.components }
        }
    }

    // MARK: The one entry point

    /// Values `shifts` under `rates` and `calendars`.
    ///
    /// The returned array is in the engine's canonical order regardless of
    /// the order `shifts` arrived in, and the cents in it never depend on the
    /// caller's date range: the weekly overtime threshold is always split
    /// over the COMPLETE workweek (Design 1, step 2).
    public static func value(
        _ shifts: [ShiftInput],
        rates: [PayRatePolicy],
        calendars: [PayrollCalendarPolicy]
    ) -> [ShiftValuation] {
        evaluate(shifts, rates: rates, calendars: calendars).valuations
    }

    /// `value(_:rates:calendars:)` plus the diagnostics and the accepted
    /// policy list. The debug sheet and the tests use this; screens use
    /// `value`.
    public static func evaluate(
        _ shifts: [ShiftInput],
        rates: [PayRatePolicy],
        calendars: [PayrollCalendarPolicy]
    ) -> Output {
        var diagnostics: [LedgerDiagnostic] = []
        let acceptedCalendars = acceptCalendarPolicies(calendars, diagnostics: &diagnostics)
        let sortedRates = rates.sorted(by: ratePolicyOrder)

        // Canonical order first, so every bucket iterates identically no
        // matter how the caller ordered its input.
        let ordered = shifts.sorted(by: canonicalOrder)

        // Bucket by (calendar policy, workweek start). The boundary rule
        // makes a workweek that spans two calendar policies unrepresentable,
        // so the policy id in the key is belt and braces, not semantics.
        struct WeekKey: Hashable {
            var calendarPolicyID: UUID
            var workweekStart: CivilDay
        }

        var weekOrder: [WeekKey] = []
        var weeks: [WeekKey: [ShiftInput]] = [:]
        var unbucketed: [ShiftInput] = []
        var policyForWeek: [WeekKey: PayrollCalendarPolicy] = [:]

        for shift in ordered {
            guard let policy = policy(in: acceptedCalendars, onOrBefore: shift.workDay, key: \.effectiveFrom) else {
                unbucketed.append(shift)
                continue
            }
            let key = WeekKey(
                calendarPolicyID: policy.id,
                workweekStart: shift.workDay.startOfWorkweek(startingOn: policy.workweekStartWeekday)
            )
            if weeks[key] == nil {
                weeks[key] = []
                weekOrder.append(key)
                policyForWeek[key] = policy
            }
            weeks[key]?.append(shift)
        }

        var valuations: [ShiftValuation] = []
        valuations.reserveCapacity(ordered.count)

        for key in weekOrder {
            guard let policy = policyForWeek[key], let weekShifts = weeks[key] else { continue }
            valuations.append(contentsOf: value(
                week: weekShifts,
                calendar: policy,
                workweekStart: key.workweekStart,
                rates: sortedRates,
                diagnostics: &diagnostics
            ))
        }

        // A shift with no calendar policy in effect has no workweek to be
        // allocated into, so it carries its tips and nothing else.
        for shift in unbucketed {
            valuations.append(ShiftValuation(
                id: shift.id,
                workDay: shift.workDay,
                ratePolicyID: nil,
                calendarPolicyID: nil,
                workweekStart: nil,
                minutesWorked: shift.minutesWorked,
                wage: .unavailable(.noCalendarPolicy),
                components: shift.nonWageComponents
            ))
        }

        // One canonical order for the whole result, not per bucket.
        valuations.sort(by: canonicalOrder)

        return Output(
            valuations: valuations,
            acceptedCalendarPolicies: acceptedCalendars,
            diagnostics: diagnostics,
            wageFeatureEnabled: !rates.isEmpty
        )
    }

    // MARK: One workweek

    /// Allocates one complete workweek. `weekShifts` must already be in
    /// canonical order.
    private static func value(
        week weekShifts: [ShiftInput],
        calendar calendarPolicy: PayrollCalendarPolicy,
        workweekStart: CivilDay,
        rates: [PayRatePolicy],
        diagnostics: inout [LedgerDiagnostic]
    ) -> [ShiftValuation] {
        var result: [ShiftValuation] = []
        result.reserveCapacity(weekShifts.count)

        // The weekly threshold is continuous across a rate change, so the
        // minute cursor is per week and the rate is per shift.
        var cumulativeMinutes = 0
        var regularUnits = 0
        var overtimeUnits = 0
        var regularCentsAllocated = 0
        var overtimeCentsAllocated = 0

        for shift in weekShifts {
            let ratePolicy = policy(in: rates, onOrBefore: shift.workDay, key: \.effectiveFrom)

            guard let rawMinutes = shift.minutesWorked else {
                // Hours were never logged: no minutes toward the threshold,
                // no wage, tips intact.
                result.append(ShiftValuation(
                    id: shift.id,
                    workDay: shift.workDay,
                    ratePolicyID: ratePolicy?.id,
                    calendarPolicyID: calendarPolicy.id,
                    workweekStart: workweekStart,
                    minutesWorked: nil,
                    wage: .unavailable(.hoursMissing),
                    components: shift.nonWageComponents
                ))
                continue
            }

            var minutes = rawMinutes
            if minutes < 0 {
                diagnostics.append(LedgerDiagnostic(
                    kind: .negativeMinutesClamped,
                    shiftID: shift.id,
                    message: "Shift \(shift.id) on \(shift.workDay.iso) had \(rawMinutes) minutes; clamped to 0."
                ))
                minutes = 0
            }

            let remainingRegular = max(0, calendarPolicy.overtimeThresholdMinutes - cumulativeMinutes)
            let regularMinutes = min(remainingRegular, minutes)
            let overtimeMinutes = minutes - regularMinutes
            // Minutes count toward the threshold even when the rate is
            // unknown: a shift the engine cannot value still pushes the rest
            // of the week into overtime (Design 1, step 4).
            cumulativeMinutes += minutes

            guard let ratePolicy else {
                result.append(ShiftValuation(
                    id: shift.id,
                    workDay: shift.workDay,
                    ratePolicyID: nil,
                    calendarPolicyID: calendarPolicy.id,
                    workweekStart: workweekStart,
                    minutesWorked: minutes,
                    wage: .unavailable(.rateNotSet),
                    components: shift.nonWageComponents
                ))
                continue
            }

            regularUnits += wageUnits(
                rateCents: ratePolicy.hourlyRateCents,
                minutes: regularMinutes,
                multiplierHundredths: 100
            )
            overtimeUnits += wageUnits(
                rateCents: ratePolicy.hourlyRateCents,
                minutes: overtimeMinutes,
                multiplierHundredths: calendarPolicy.overtimeMultiplierHundredths
            )

            // Cumulative rounding per stream: this shift gets the difference
            // between the week's running rounded total before and after it,
            // so Σ shift cents == roundCents(Σ exact units) and appending a
            // later shift can never change this row (Design 1, step 5).
            let regularCents = roundCents(regularUnits) - regularCentsAllocated
            let overtimeCents = roundCents(overtimeUnits) - overtimeCentsAllocated
            regularCentsAllocated += regularCents
            overtimeCentsAllocated += overtimeCents

            let wage = WageComponents(
                regularMinutes: regularMinutes,
                overtimeMinutes: overtimeMinutes,
                regularWagesCents: regularCents,
                overtimeWagesCents: overtimeCents
            )

            var components = shift.nonWageComponents
            components.regularWagesCents = regularCents
            components.overtimeWagesCents = overtimeCents

            result.append(ShiftValuation(
                id: shift.id,
                workDay: shift.workDay,
                ratePolicyID: ratePolicy.id,
                calendarPolicyID: calendarPolicy.id,
                workweekStart: workweekStart,
                minutesWorked: minutes,
                wage: .valued(wage, assumed: ratePolicy.provenance == .assumedFromLegacySetting),
                components: components
            ))
        }

        return result
    }

    // MARK: Policy selection

    /// The calendar policies that survive the boundary rule, in effect order.
    /// A policy whose `effectiveFrom` is not a workweek start under the
    /// previous policy is dropped with a diagnostic, which leaves the
    /// previous policy in effect and makes overlapping or broken workweeks
    /// unrepresentable.
    public static func acceptCalendarPolicies(
        _ calendars: [PayrollCalendarPolicy]
    ) -> (accepted: [PayrollCalendarPolicy], diagnostics: [LedgerDiagnostic]) {
        var diagnostics: [LedgerDiagnostic] = []
        let accepted = acceptCalendarPolicies(calendars, diagnostics: &diagnostics)
        return (accepted, diagnostics)
    }

    private static func acceptCalendarPolicies(
        _ calendars: [PayrollCalendarPolicy],
        diagnostics: inout [LedgerDiagnostic]
    ) -> [PayrollCalendarPolicy] {
        var accepted: [PayrollCalendarPolicy] = []
        for candidate in calendars.sorted(by: calendarPolicyOrder) {
            if let previous = accepted.last,
               candidate.effectiveFrom.weekday != previous.workweekStartWeekday {
                diagnostics.append(LedgerDiagnostic(
                    kind: .calendarPolicyOffWorkweekBoundary,
                    policyID: candidate.id,
                    message: "Calendar policy \(candidate.id) takes effect \(candidate.effectiveFrom.iso) "
                        + "(weekday \(candidate.effectiveFrom.weekday)), which is not a workweek start under "
                        + "the previous policy (weekday \(previous.workweekStartWeekday)). "
                        + "Rejected; the previous policy stays in effect."
                ))
                continue
            }
            accepted.append(candidate)
        }
        return accepted
    }

    /// The last policy whose `effectiveFrom` is on or before `day`, from a
    /// list already in effect order. Nil when every policy starts later.
    static func policy<P>(in policies: [P], onOrBefore day: CivilDay, key: KeyPath<P, CivilDay>) -> P? {
        var found: P?
        for policy in policies {
            if policy[keyPath: key] <= day { found = policy } else { break }
        }
        return found
    }

    // MARK: Canonical orders

    /// Order within a workweek, and the order of the whole result: work day,
    /// then period rank (lunch, dinner, untagged), then `recordedAt` (a nil
    /// recording time sorts first, as the earliest thing known), then id.
    /// Total and deterministic, which is what makes the ledger
    /// order-independent (Design 1, step 3).
    static func canonicalOrder(_ lhs: ShiftInput, _ rhs: ShiftInput) -> Bool {
        canonicalKey(lhs) < canonicalKey(rhs)
    }

    static func canonicalOrder(_ lhs: ShiftValuation, _ rhs: ShiftValuation) -> Bool {
        (lhs.workDay.dayNumber, lhs.id.uuidString) < (rhs.workDay.dayNumber, rhs.id.uuidString)
    }

    private static func canonicalKey(_ shift: ShiftInput) -> (Int, Int, Double, String) {
        (
            shift.workDay.dayNumber,
            shift.period?.rank ?? untaggedPeriodRank,
            shift.recordedAt?.timeIntervalSinceReferenceDate ?? -.greatestFiniteMagnitude,
            shift.id.uuidString
        )
    }

    /// Untagged shifts sort after lunch and dinner.
    static let untaggedPeriodRank = 2

    private static func ratePolicyOrder(_ lhs: PayRatePolicy, _ rhs: PayRatePolicy) -> Bool {
        (lhs.effectiveFrom.dayNumber, lhs.id.uuidString) < (rhs.effectiveFrom.dayNumber, rhs.id.uuidString)
    }

    private static func calendarPolicyOrder(_ lhs: PayrollCalendarPolicy, _ rhs: PayrollCalendarPolicy) -> Bool {
        (lhs.effectiveFrom.dayNumber, lhs.id.uuidString) < (rhs.effectiveFrom.dayNumber, rhs.id.uuidString)
    }
}

public extension Completeness {
    /// Derives completeness from a set of valuations: the shape every query
    /// on `EarningsSnapshot` (PR 4) will report, computed here so the ledger
    /// tests can assert it straight off `CompensationLedger.value`.
    init(valuations: [ShiftValuation], wageFeatureEnabled: Bool) {
        self.init(
            totalShifts: valuations.count,
            shiftsWithHours: valuations.filter { $0.minutesWorked != nil }.count,
            shiftsWageValued: valuations.filter { $0.wage.isValued }.count,
            shiftsWageAssumed: valuations.filter { $0.wage.isAssumed }.count,
            wageFeatureEnabled: wageFeatureEnabled
        )
    }
}

public extension CompensationLedger.Output {
    /// Completeness over every valuation in this output.
    var completeness: Completeness {
        Completeness(valuations: valuations, wageFeatureEnabled: wageFeatureEnabled)
    }
}
