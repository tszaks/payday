import Foundation

/// What every query on an `EarningsSnapshot` returns. One `MetricID`, one
/// range, sums over the selected shifts, and a `Completeness` that says how
/// much of the wage picture is known.
///
/// `knownComponents` is Σ over ALL selected shifts (wages only where valued).
/// `coveredComponents` is Σ over the shifts that have hours; it is the
/// numerator of `hourlyRateCents` so a shift without hours is excluded from
/// both sides of the rate (H1 fixture).
public struct EarningsResult: Hashable, Codable, Sendable {
    public var metric: MetricID
    /// The selection, already clamped by `asOf`. Nil for a query with no range (e.g. a single shift).
    public var range: DayRange?
    /// The clamp that was applied, if any.
    public var asOf: CivilDay?
    public var knownComponents: EarningsComponents
    public var coveredComponents: EarningsComponents
    /// Σ minutesWorked over covered shifts.
    public var minutes: Int
    public var regularMinutes: Int
    public var overtimeMinutes: Int
    public var completeness: Completeness
    /// The selected shifts, in the engine's canonical order.
    public var shiftIDs: [UUID]
    /// `InputManifest.currentEngineVersion` of the engine that produced this
    /// result. PR 1 types carry the current constant; `EarningsSnapshot` (PR 4)
    /// stamps it from the snapshot that answered the query.
    public var engineVersion: Int
    /// `InputManifest.digest` of the inputs this result was computed from, so
    /// two consumers can prove they are showing the same dataset. Nil until
    /// `EarningsSnapshot` (PR 4) fills it; the shell type has no snapshot yet.
    public var manifestDigest: String?

    public init(
        metric: MetricID,
        range: DayRange?,
        asOf: CivilDay?,
        knownComponents: EarningsComponents,
        coveredComponents: EarningsComponents,
        minutes: Int,
        regularMinutes: Int,
        overtimeMinutes: Int,
        completeness: Completeness,
        shiftIDs: [UUID],
        engineVersion: Int = InputManifest.currentEngineVersion,
        manifestDigest: String? = nil
    ) {
        self.metric = metric
        self.range = range
        self.asOf = asOf
        self.knownComponents = knownComponents
        self.coveredComponents = coveredComponents
        self.minutes = minutes
        self.regularMinutes = regularMinutes
        self.overtimeMinutes = overtimeMinutes
        self.completeness = completeness
        self.shiftIDs = shiftIDs
        self.engineVersion = engineVersion
        self.manifestDigest = manifestDigest
    }

    /// `MetricID.hourlyRate`: `coveredComponents.earnedIncomeCents * 60 / minutes`,
    /// rounded half-up in integer arithmetic, nil when `minutes == 0`.
    public var hourlyRateCents: Int? {
        guard minutes > 0 else { return nil }
        return IntegerRounding.divideHalfUp(coveredComponents.earnedIncomeCents * 60, by: minutes)
    }

    /// Shifts covered by hours, for the "N of M shifts" caption.
    public var coveredShiftCount: Int { completeness.shiftsWithHours }

    /// A result with nothing selected. `engineVersion` is the current engine,
    /// `manifestDigest` is nil (no snapshot produced it; PR 4 fills both).
    public static func empty(metric: MetricID) -> EarningsResult {
        EarningsResult(
            metric: metric,
            range: nil,
            asOf: nil,
            knownComponents: .zero,
            coveredComponents: .zero,
            minutes: 0,
            regularMinutes: 0,
            overtimeMinutes: 0,
            completeness: .empty,
            shiftIDs: [],
            engineVersion: InputManifest.currentEngineVersion,
            manifestDigest: nil
        )
    }
}

/// Integer rounding helpers shared by the engine. No floating point anywhere.
public enum IntegerRounding {
    /// `n / d` rounded half-up (toward +infinity on a tie), as
    /// `floor((2n + d) / (2d))`. For non-negative `n` this is exactly the
    /// `(2*n + d) / (2*d)` form; the floor makes it hold for negative `n`
    /// too, where Swift's `/` would truncate toward zero instead.
    /// `d` must be positive.
    public static func divideHalfUp(_ n: Int, by d: Int) -> Int {
        precondition(d > 0, "divisor must be positive")
        return floorDivide(2 * n + d, 2 * d)
    }

    /// Floor division for a positive divisor.
    static func floorDivide(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }
}
