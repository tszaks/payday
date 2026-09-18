import Foundation

/// One coherent answer to every earnings question, computed once per input
/// change.
///
/// This is the type the whole plan exists for. Every consumer — Dashboard,
/// Calendar, DayDetail, PeriodDetail, Insights, the chart, CSV, the widget,
/// Siri, the agent API — asks the SAME snapshot, so two surfaces cannot
/// disagree about the same fact. A query here does no arithmetic on money:
/// the cents were fixed by `CompensationLedger` when the snapshot was built,
/// and a query only selects and adds them.
///
/// ## What makes the totals agree
///
/// - Every aggregate is `Σ components` over whole `ShiftValuation`s. A day,
///   a month, a pay period and an arbitrary range differ only in which
///   shifts they select, so `month + month == the containing range` and
///   `range == Σ days` are arithmetic rather than hope.
/// - The wage split inside each valuation was allocated over the COMPLETE
///   workweek, so a pay period that straddles a workweek keeps the overtime
///   the week produced instead of re-deriving it from the period's own
///   hours.
/// - `shifts` is held in the ledger's canonical order and re-sorted on every
///   construction, including `init(from:)`. The range queries binary-search
///   it, so a decoded payload that arrived out of order cannot silently
///   return a partial range.
///
/// ## The `asOf` rule
///
/// `stamp.asOf` is the default cutoff. The to-date queries (`range`,
/// `month`, `payPeriod`, `yearToDate`, `days`) clamp their range's END to it
/// exactly as `StatsEngine.periodToDateTotal` does (`min(end, asOf)`, start
/// unchanged), and the clamp drops whole shifts, so it applies to tips AND
/// wages alike (fixture S2). Pass an explicit `asOf` to override, or
/// `CivilDay.distantFuture` to opt out.
///
/// `day(_:)`, `shift(_:)` and the paycheck scope are deliberately NOT
/// clamped: a single day and a single shift are facts someone can open, not
/// period-to-date totals, so DayDetail on a future-dated shift shows that
/// shift instead of `$0`; and a recorded paycheck covers a period the payer
/// already settled (METRICS.md `expectedPaycheckTipsLine`: "no `asOf`").
/// That asymmetry is pinned by test, and it is why every result carries
/// `scope`: `day(d)` and `days(in:)` share a metric and can still
/// legitimately differ, as can `payPeriod(p)` and the paycheck for `p`.
///
/// The clamped and unclamped paths are two separate private functions,
/// `toDate` and `settled`, rather than one function with an optional
/// cutoff, because `asOf: nil` reads as "no cutoff" and means "use the
/// stamp's cutoff" — which is how the paycheck scope was silently narrowed
/// (PR 4 review, P1).
public struct EarningsSnapshot: Codable, Sendable, Equatable {
    /// Which inputs, which engine, as of when.
    public let stamp: SnapshotStamp

    /// Every shift, valued exactly once, in the ledger's canonical order
    /// (work day, then id).
    public let shifts: [ShiftValuation]

    /// Recorded paychecks, verbatim as entered. `paidTipsCents` is the
    /// OBSERVED figure and is never rewritten here; the ±100c correction is
    /// a proposal PR 5's `PaycheckReconciler` offers, never an edit the
    /// engine performs (`MetricID.observedPaidTips`).
    public let paychecks: [PaycheckInput]

    /// Whether the user has wages turned on at all: true when at least one
    /// rate policy exists. Feeds every `Completeness.wageFeatureEnabled`.
    public let wageFeatureEnabled: Bool

    /// What the ledger had to reject or repair. Never silent, never fatal.
    public let diagnostics: [LedgerDiagnostic]

    /// Shifts whose receipt payload would not decode, so their gratuity
    /// reads as zero (see `EarningsInputs.unreadableReceiptShiftIDs`).
    public let unreadableReceiptShiftIDs: [UUID]

    /// Rebuilt, never encoded. See `Index`.
    private let index: Index

    // MARK: - Construction

    /// Assembles a snapshot from already-valued shifts. `build` is the usual
    /// entry point; this initializer exists for tests and for a decoded
    /// payload.
    public init(
        stamp: SnapshotStamp,
        shifts: [ShiftValuation],
        paychecks: [PaycheckInput] = [],
        wageFeatureEnabled: Bool,
        diagnostics: [LedgerDiagnostic] = [],
        unreadableReceiptShiftIDs: [UUID] = []
    ) {
        let ordered = shifts.sorted(by: CompensationLedger.canonicalOrder)
        self.stamp = stamp
        self.shifts = ordered
        self.paychecks = paychecks.sorted(by: EarningsSnapshot.paycheckOrder)
        self.wageFeatureEnabled = wageFeatureEnabled
        self.diagnostics = diagnostics
        self.unreadableReceiptShiftIDs = unreadableReceiptShiftIDs
        self.index = Index(
            shifts: ordered,
            paychecks: self.paychecks,
            wageFeatureEnabled: wageFeatureEnabled
        )
    }

    /// Values `inputs` through `CompensationLedger` and stamps the result.
    ///
    /// Pure and `Sendable` in and out, which is what lets `EarningsStore`
    /// run it on a detached task while the main actor keeps rendering the
    /// previous snapshot.
    ///
    /// Throws `InputManifest.ValidationError` when the inputs cannot be
    /// canonically fingerprinted. That is a refusal, not a crash: a snapshot
    /// with no honest digest would be a dataset two consumers could not
    /// compare.
    public static func build(
        _ inputs: EarningsInputs,
        generation: UInt64 = 0,
        computedAt: Date = Date(),
        serverDatasetRevision: Int64? = nil
    ) throws -> EarningsSnapshot {
        let manifest = try inputs.manifest()
        let output = CompensationLedger.evaluate(
            inputs.shifts,
            rates: inputs.rates,
            calendars: inputs.calendars
        )
        return EarningsSnapshot(
            stamp: SnapshotStamp(
                generation: generation,
                manifest: manifest.summary,
                computedAt: computedAt,
                serverDatasetRevision: serverDatasetRevision
            ),
            shifts: output.valuations,
            paychecks: inputs.paychecks,
            wageFeatureEnabled: output.wageFeatureEnabled,
            diagnostics: output.diagnostics,
            unreadableReceiptShiftIDs: inputs.unreadableReceiptShiftIDs
        )
    }

    // MARK: - Completeness

    /// Completeness over EVERY shift in the snapshot. Each query reports its
    /// own completeness over the shifts it selected.
    public var completeness: Completeness { index.completeness }

    // MARK: - Queries

    /// One shift, by id. Nil for an unknown id rather than a zeroed result:
    /// "this shift is not in the dataset" and "this shift earned nothing"
    /// are different facts and only one of them is a number.
    ///
    /// Not clamped by `asOf`.
    public func shift(_ id: UUID) -> EarningsResult? {
        guard let valuation = index.byID[id] else { return nil }
        return result(
            scope: .shift(id),
            requested: nil,
            asOf: nil,
            selected: [valuation]
        )
    }

    /// The `ShiftValuation` itself, for a row that renders one shift's own
    /// wage split (`ShiftDayRow` in PR 5).
    public func valuation(_ id: UUID) -> ShiftValuation? { index.byID[id] }

    /// One civil day. Never clamped: see the type note.
    public func day(_ day: CivilDay) -> EarningsResult {
        result(
            scope: .day(day),
            requested: DayRange(day: day),
            asOf: nil,
            selected: index.byDay[day.dayNumber] ?? []
        )
    }

    /// One calendar month, clamped to `asOf`.
    public func month(_ month: YearMonth, asOf: CivilDay? = nil) -> EarningsResult {
        toDate(scope: .month(month), requested: month.range, asOf: asOf)
    }

    /// One pay period, clamped to `asOf`. The period arrives as the civil
    /// days a `PayPeriodCalculator` laid out, so changing the pay schedule
    /// changes which shifts this selects — and `stamp.manifest
    /// .scheduleDigest` is how a consumer knows that is what changed.
    public func payPeriod(_ period: DayRange, asOf: CivilDay? = nil) -> EarningsResult {
        toDate(scope: .payPeriod(period), requested: period, asOf: asOf)
    }

    /// January 1 through December 31 of `year`, clamped to `asOf`. A pay
    /// period that crosses the year boundary therefore contributes only its
    /// in-year days.
    public func yearToDate(year: Int, asOf: CivilDay? = nil) -> EarningsResult {
        let range = DayRange(
            start: CivilDay(year: year, month: 1, day: 1),
            end: CivilDay(year: year, month: 12, day: 31)
        )
        return toDate(scope: .yearToDate(year: year), requested: range, asOf: asOf)
    }

    /// An arbitrary span, clamped to `asOf`.
    public func range(_ range: DayRange, asOf: CivilDay? = nil) -> EarningsResult {
        toDate(scope: .range(range), requested: range, asOf: asOf)
    }

    /// One result per day of `range` after the `asOf` clamp, in order,
    /// including days with no shifts.
    ///
    /// Clamped like `range(_:asOf:)` on purpose: this is the series a chart
    /// draws under a headline, and `Σ days(in: r) == range(r)` has to hold
    /// for the chart and its total to agree (Definition of Done #5).
    public func days(in range: DayRange, asOf: CivilDay? = nil) -> [EarningsResult] {
        clamp(range, asOf: asOf).days.map { day(unclamped: $0) }
    }

    /// The recorded paycheck whose period ends on `periodEnd`, paired with
    /// what the engine expected for the paycheck's WHOLE period, with no
    /// `asOf` clamp — including when `periodEnd` is still in the future,
    /// which the ungated "Add paycheck" button on an open period makes a
    /// normal user action. Clamping here would hand PR 5's
    /// `PaycheckReconciler` a period-to-date expectation to compare a
    /// whole-period stub against, and it would report a shortfall equal to
    /// the period's remaining days.
    ///
    /// Nil when no paycheck was recorded for that period end. With two
    /// paychecks sharing a period end (nothing forbids it), this returns the
    /// first in canonical `(periodEnd, periodStart, id)` order — a
    /// deterministic choice rather than an arbitrary one, so two consumers
    /// pick the same row.
    public func paycheck(periodEnd: CivilDay) -> PaycheckReconciliation? {
        guard let paycheck = index.paycheckByPeriodEnd[periodEnd.dayNumber] else { return nil }
        return PaycheckReconciliation(
            paycheck: paycheck,
            expected: settled(
                scope: .paycheck(periodEnd: periodEnd),
                requested: paycheck.period
            )
        )
    }

    /// Every recorded paycheck with its expected figures, in canonical
    /// order. Unclamped, exactly as `paycheck(periodEnd:)`.
    public var paycheckReconciliations: [PaycheckReconciliation] {
        paychecks.map { paycheck in
            PaycheckReconciliation(
                paycheck: paycheck,
                expected: settled(
                    scope: .paycheck(periodEnd: paycheck.periodEnd),
                    requested: paycheck.period
                )
            )
        }
    }

    // MARK: - Selection

    /// The valuations whose work day falls in `range`, by binary search over
    /// the canonical order.
    public func valuations(in range: DayRange) -> ArraySlice<ShiftValuation> {
        guard !range.isEmpty else { return shifts[shifts.startIndex..<shifts.startIndex] }
        let lower = lowerBound(dayNumber: range.start.dayNumber)
        let upper = lowerBound(dayNumber: range.end.dayNumber + 1)
        return shifts[lower..<upper]
    }

    /// First index whose work day is >= `dayNumber`.
    private func lowerBound(dayNumber: Int) -> Int {
        var low = 0
        var high = shifts.count
        while low < high {
            let mid = low + (high - low) / 2
            if shifts[mid].workDay.dayNumber < dayNumber {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - Result assembly

    private func clamp(_ range: DayRange, asOf: CivilDay?) -> DayRange {
        guard let cutoff = asOf ?? stamp.asOf else { return range }
        return range.clamped(to: cutoff)
    }

    /// A period-TO-DATE span: the END is clamped to `asOf ?? stamp.asOf`,
    /// and `nil` therefore means "use the stamp's cutoff", never "no
    /// cutoff". A scope that must not be clamped calls `settled` instead —
    /// the two are separate functions precisely so that omitting an
    /// argument cannot silently narrow a span (PR 4 review, P1).
    private func toDate(scope: EarningsScope, requested: DayRange, asOf: CivilDay?) -> EarningsResult {
        let cutoff = asOf ?? stamp.asOf
        let clamped = clamp(requested, asOf: asOf)
        return result(
            scope: scope,
            requested: clamped,
            asOf: cutoff,
            selected: valuations(in: clamped)
        )
    }

    /// A SETTLED span: the whole range, with no cutoff at all, and
    /// `EarningsResult.asOf` nil because no clamp was applied. This is the
    /// paycheck scope: a stub in hand covers a period that already closed
    /// from the payer's side, so comparing it against a period-to-date
    /// figure would report a shortfall equal to the period's remaining days.
    private func settled(scope: EarningsScope, requested: DayRange) -> EarningsResult {
        result(
            scope: scope,
            requested: requested,
            asOf: nil,
            selected: valuations(in: requested)
        )
    }

    /// One day's result with no clamp, for `days(in:)` (whose range was
    /// already clamped once — clamping each day again would be the same
    /// answer at 31x the cost).
    private func day(unclamped day: CivilDay) -> EarningsResult {
        result(
            scope: .day(day),
            requested: DayRange(day: day),
            asOf: nil,
            selected: index.byDay[day.dayNumber] ?? []
        )
    }

    /// Sums the selected valuations. The ONLY place a query turns
    /// valuations into a result, so every query reports the same fields the
    /// same way.
    ///
    /// `minutes` is every covered minute and
    /// `regularMinutes`/`overtimeMinutes` are how the workweek threshold
    /// split them — `ShiftValuation.regularMinutes`, the calendar fact, not
    /// `wage.components.regularMinutes`, the priced one. A shift with 300
    /// hours-logged minutes and no rate policy therefore contributes
    /// `minutes 300, regularMinutes 300` and zero cents (fixture H1). Using
    /// the priced split here would report 0 regular minutes for hours the
    /// person demonstrably worked.
    private func result(
        metric: MetricID = .earnedIncome,
        scope: EarningsScope,
        requested: DayRange?,
        asOf: CivilDay?,
        selected: some Collection<ShiftValuation>
    ) -> EarningsResult {
        var known = EarningsComponents.zero
        var covered = EarningsComponents.zero
        var minutes = 0
        var regularMinutes = 0
        var overtimeMinutes = 0
        var ids: [UUID] = []
        ids.reserveCapacity(selected.count)

        for valuation in selected {
            known += valuation.components
            ids.append(valuation.id)
            if let worked = valuation.minutesWorked {
                covered += valuation.components
                minutes += worked
            }
            regularMinutes += valuation.regularMinutes ?? 0
            overtimeMinutes += valuation.overtimeMinutes ?? 0
        }

        return EarningsResult(
            metric: metric,
            scope: scope,
            range: requested,
            asOf: asOf,
            knownComponents: known,
            coveredComponents: covered,
            minutes: minutes,
            regularMinutes: regularMinutes,
            overtimeMinutes: overtimeMinutes,
            completeness: Completeness(
                valuations: Array(selected),
                wageFeatureEnabled: wageFeatureEnabled
            ),
            shiftIDs: ids,
            engineVersion: stamp.engineVersion,
            manifestDigest: stamp.digest
        )
    }

    static func paycheckOrder(_ lhs: PaycheckInput, _ rhs: PaycheckInput) -> Bool {
        (lhs.periodEnd.dayNumber, lhs.periodStart.dayNumber, lhs.id.uuidString)
            < (rhs.periodEnd.dayNumber, rhs.periodStart.dayNumber, rhs.id.uuidString)
    }

    // MARK: - Codable

    /// `index` is absent on purpose: it is derived, and encoding a derived
    /// structure invites a payload whose index disagrees with its shifts.
    /// `init(from:)` routes through the memberwise initializer, which
    /// re-sorts and re-indexes.
    private enum CodingKeys: String, CodingKey {
        case stamp, shifts, paychecks, wageFeatureEnabled, diagnostics, unreadableReceiptShiftIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            stamp: try container.decode(SnapshotStamp.self, forKey: .stamp),
            shifts: try container.decode([ShiftValuation].self, forKey: .shifts),
            paychecks: try container.decodeIfPresent([PaycheckInput].self, forKey: .paychecks) ?? [],
            wageFeatureEnabled: try container.decode(Bool.self, forKey: .wageFeatureEnabled),
            diagnostics: try container.decodeIfPresent([LedgerDiagnostic].self, forKey: .diagnostics) ?? [],
            unreadableReceiptShiftIDs: try container
                .decodeIfPresent([UUID].self, forKey: .unreadableReceiptShiftIDs) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stamp, forKey: .stamp)
        try container.encode(shifts, forKey: .shifts)
        try container.encode(paychecks, forKey: .paychecks)
        try container.encode(wageFeatureEnabled, forKey: .wageFeatureEnabled)
        try container.encode(diagnostics, forKey: .diagnostics)
        try container.encode(unreadableReceiptShiftIDs, forKey: .unreadableReceiptShiftIDs)
    }

    // MARK: - Equatable

    /// Compares the stored facts only. `index` is a function of them, so
    /// including it would be comparing the same data twice.
    public static func == (lhs: EarningsSnapshot, rhs: EarningsSnapshot) -> Bool {
        lhs.stamp == rhs.stamp
            && lhs.shifts == rhs.shifts
            && lhs.paychecks == rhs.paychecks
            && lhs.wageFeatureEnabled == rhs.wageFeatureEnabled
            && lhs.diagnostics == rhs.diagnostics
            && lhs.unreadableReceiptShiftIDs == rhs.unreadableReceiptShiftIDs
    }

    // MARK: - Index

    /// The lookups every screen hits on every render, built once per
    /// snapshot instead of scanned per query.
    ///
    /// A duplicate shift id keeps the FIRST valuation in canonical order in
    /// `byID` while both still contribute to every sum. The ledger cannot
    /// produce duplicates (its input is one row per shift), so this is about
    /// a decoded payload: `shift(id)` then answers deterministically rather
    /// than by dictionary insertion luck.
    private struct Index: Sendable {
        let byID: [UUID: ShiftValuation]
        let byDay: [Int: [ShiftValuation]]
        let paycheckByPeriodEnd: [Int: PaycheckInput]
        let completeness: Completeness

        init(shifts: [ShiftValuation], paychecks: [PaycheckInput], wageFeatureEnabled: Bool) {
            byID = Dictionary(shifts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            byDay = Dictionary(grouping: shifts, by: { $0.workDay.dayNumber })
            paycheckByPeriodEnd = Dictionary(
                paychecks.map { ($0.periodEnd.dayNumber, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            completeness = Completeness(valuations: shifts, wageFeatureEnabled: wageFeatureEnabled)
        }
    }
}

/// A recorded paycheck next to what the engine expected for the same period.
///
/// PR 4 carries the pair; the per-component deltas, the tips-line rule and
/// the ±100c proposal are `PaycheckReconciler` in PR 5. `expected` is the
/// `earnedIncome` result for the paycheck's own period, unclamped — a stub
/// in hand is a settled period, not a period to date.
public struct PaycheckReconciliation: Codable, Sendable, Equatable {
    public let paycheck: PaycheckInput
    public let expected: EarningsResult

    public init(paycheck: PaycheckInput, expected: EarningsResult) {
        self.paycheck = paycheck
        self.expected = expected
    }

    /// `MetricID.observedPaidTips`, exactly as entered.
    public var observedPaidTipsCents: Int { paycheck.paidTipsCents }
}

public extension EarningsInputs {
    /// These inputs with `draft` in place of the shift sharing its id, or
    /// appended when it is new.
    ///
    /// This is what `EarningsStore.preview(draft:)` runs: a sheet showing
    /// "this shift takes the day to $X" has to value the draft through the
    /// same weekly allocation as everything else, because a draft that
    /// crosses the overtime threshold changes its own wage and no earlier
    /// shift's.
    func substituting(_ draft: ShiftInput) -> EarningsInputs {
        var copy = self
        if let existing = copy.shifts.firstIndex(where: { $0.id == draft.id }) {
            copy.shifts[existing] = draft
        } else {
            copy.shifts.append(draft)
        }
        return copy
    }
}
