import Foundation

/// The JSON the device uploads and `/v1/summary` serves back.
///
/// ## The distinction this whole type rests on
///
/// Design 3 says "the server does no money math". Taken literally that is
/// impossible -- `/v1/summary` accepts an arbitrary `start_date`/`end_date`,
/// and no fixed set of precomputed totals can answer an arbitrary range.
///
/// The rule that is actually load-bearing is narrower and it is the one
/// worth writing down: **the server applies no POLICY.** Summing integers
/// cannot make two surfaces disagree. Allocating overtime across a workweek,
/// rounding a wage, deciding which day a shift belongs to, choosing whether a
/// duplicated receipt counts once -- those are policy, every one of them has
/// been implemented more than once in this codebase, and every duplicate has
/// disagreed with its original.
///
/// So the document carries **per-day component totals**, already valued by
/// `CompensationLedger`, and a range query is `reduce(.zero, +)` over the
/// days it covers. `EarningsComponents` is `AdditiveArithmetic` precisely so
/// that sum is the same operation on the device and on the server. The
/// wage allocation that produced those daily figures happened once, on
/// device, under one engine version.
///
/// ## Why per-day and not per-shift
///
/// A day is the smallest unit any surface actually asks about: the calendar
/// tile, the day detail, the chart point. Per-shift would be larger and buys
/// nothing the API exposes. Per-period would be smaller and could not answer
/// a range that straddles a period boundary, which is exactly the query that
/// lost $11.31 of overtime in the audit.
///
/// ## What it deliberately does NOT carry, said out loud
///
/// `shiftIDs`. `EarningsResult` carries them and this does not, so a range
/// reconstructed from a document cannot name its shifts. No API surface asks
/// for that today -- `/v1/summary` returns aggregates, and `list_shifts`
/// reads `public.shifts` directly. Stated rather than left to be discovered
/// as a missing field, and `documentMatchesTheEngineOnEveryRange` asserts
/// parity on everything else rather than quietly excluding more.
public struct SnapshotDocument: Codable, Sendable, Equatable {

    /// Bumped when the shape changes in a way an older reader cannot handle.
    /// The server stores it beside `engine_version` so a reader can refuse a
    /// document it does not understand instead of misreading one.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let engineVersion: Int
    /// Optional because the engine's is. A nil `asOf` means NO CLAMP, which
    /// is a real state (a snapshot built for a closed period), and inventing
    /// a date here would silently start clipping future-dated rows that the
    /// app includes.
    public let asOf: CivilDay?
    public let manifestDigest: String
    /// Carried at document level because it is a setting, not a per-day fact.
    public let wageFeatureEnabled: Bool
    /// Sorted ascending and unique by `day`, so a range scan is a slice and
    /// two documents over the same data are byte-identical.
    public let days: [Day]

    public struct Day: Codable, Sendable, Equatable {
        public let day: CivilDay
        /// Every shift on the day. Wages appear only where they were valued.
        public let knownComponents: EarningsComponents
        /// Only the shifts with hours, so `$/hr` divides comparable sides.
        public let coveredComponents: EarningsComponents
        public let minutes: Int
        public let regularMinutes: Int
        public let overtimeMinutes: Int
        /// The completeness counters are ADDITIVE, which is what lets a range
        /// report its own completeness without re-deriving it from shifts the
        /// server does not have.
        public let totalShifts: Int
        public let shiftsWithHours: Int
        public let shiftsWageValued: Int
        public let shiftsWageAssumed: Int

        public init(
            day: CivilDay,
            knownComponents: EarningsComponents,
            coveredComponents: EarningsComponents,
            minutes: Int,
            regularMinutes: Int,
            overtimeMinutes: Int,
            totalShifts: Int,
            shiftsWithHours: Int,
            shiftsWageValued: Int,
            shiftsWageAssumed: Int
        ) {
            self.day = day
            self.knownComponents = knownComponents
            self.coveredComponents = coveredComponents
            self.minutes = minutes
            self.regularMinutes = regularMinutes
            self.overtimeMinutes = overtimeMinutes
            self.totalShifts = totalShifts
            self.shiftsWithHours = shiftsWithHours
            self.shiftsWageValued = shiftsWageValued
            self.shiftsWageAssumed = shiftsWageAssumed
        }
    }

    public init(
        schemaVersion: Int = SnapshotDocument.currentSchemaVersion,
        engineVersion: Int,
        asOf: CivilDay?,
        manifestDigest: String,
        wageFeatureEnabled: Bool,
        days: [Day]
    ) {
        self.schemaVersion = schemaVersion
        self.engineVersion = engineVersion
        self.asOf = asOf
        self.manifestDigest = manifestDigest
        self.wageFeatureEnabled = wageFeatureEnabled
        self.days = days.sorted { $0.day < $1.day }
    }
}

public extension SnapshotDocument {

    /// Project a snapshot into the uploadable document.
    ///
    /// Only days that carry a shift are emitted. An empty day sums to zero
    /// either way, so including them would grow the payload without changing
    /// any answer.
    init(_ snapshot: EarningsSnapshot) {
        let grouped = Dictionary(grouping: snapshot.shifts, by: \.workDay)
        let days = grouped.keys.sorted().map { workDay -> Day in
            let result = snapshot.day(workDay)
            return Day(
                day: workDay,
                knownComponents: result.knownComponents,
                coveredComponents: result.coveredComponents,
                minutes: result.minutes,
                regularMinutes: result.regularMinutes,
                overtimeMinutes: result.overtimeMinutes,
                totalShifts: result.completeness.totalShifts,
                shiftsWithHours: result.completeness.shiftsWithHours,
                shiftsWageValued: result.completeness.shiftsWageValued,
                shiftsWageAssumed: result.completeness.shiftsWageAssumed
            )
        }
        self.init(
            engineVersion: snapshot.stamp.engineVersion,
            asOf: snapshot.stamp.asOf,
            manifestDigest: snapshot.stamp.manifest.digest,
            wageFeatureEnabled: snapshot.completeness.wageFeatureEnabled,
            days: days
        )
    }

    /// Sum the days a range covers. Addition only -- no policy.
    ///
    /// `asOf` clamps the range end exactly as the engine does, so a document
    /// queried for a period that runs past today reports the same to-date
    /// figure the app shows rather than a projection.
    ///
    /// **`nil` means "use the document's own cutoff", never "no cutoff"** --
    /// mirroring `EarningsSnapshot.toDate`, whose header records this as a
    /// PR 4 review P1: omitting an argument must not silently change a span.
    ///
    /// Written the other way round first (nil = no clamp) and caught on the
    /// parity sweep's first run, where the document reported six shifts and
    /// 3360 minutes against the engine's five and 2880. A default that
    /// silently WIDENS is the same defect as one that silently narrows, and
    /// it is the one that makes a server total exceed the app's.
    func range(_ range: DayRange, asOf: CivilDay? = nil) -> SnapshotDocument.Total {
        let cutoff = asOf ?? self.asOf
        let clamped = cutoff.map { range.clamped(to: $0) } ?? range
        var total = SnapshotDocument.Total.zero
        for entry in days where clamped.contains(entry.day) {
            total.knownComponents += entry.knownComponents
            total.coveredComponents += entry.coveredComponents
            total.minutes += entry.minutes
            total.regularMinutes += entry.regularMinutes
            total.overtimeMinutes += entry.overtimeMinutes
            total.totalShifts += entry.totalShifts
            total.shiftsWithHours += entry.shiftsWithHours
            total.shiftsWageValued += entry.shiftsWageValued
            total.shiftsWageAssumed += entry.shiftsWageAssumed
        }
        return total
    }

    struct Total: Equatable, Sendable {
        public var knownComponents = EarningsComponents.zero
        public var coveredComponents = EarningsComponents.zero
        public var minutes = 0
        public var regularMinutes = 0
        public var overtimeMinutes = 0
        public var totalShifts = 0
        public var shiftsWithHours = 0
        public var shiftsWageValued = 0
        public var shiftsWageAssumed = 0

        public static let zero = Total()
    }
}
