import Foundation

/// A real pay stub next to what the engine expected for the same pay period,
/// as ONE answer.
///
/// PR 5 group 2.5. This is the type `docs/design/PAYDAYCORE_PLAN.md` names as
/// absorbing `PredictedPaycheck`, `PaycheckAudit` and
/// `PaycheckRecord.reconciledTipsCents`. It owns three things, and the reason
/// each one is here rather than on a screen is written next to it:
///
/// 1. **The expected side, from one `EarningsResult`.** Period detail renders
///    "Expected $X" and the sheet it opens audits a stub against the same
///    period. Those were two compositions over two bases and diverged by
///    $310.00 on a measured fixture (`Expectation`'s header and
///    `PaycheckAuditBasisParityTests`). One value, handed down, cannot.
///
/// 2. **The observed side, from one stub.** Every sum a stub's own lines
///    produce — tips + wages + gratuity against the printed gross, gross
///    minus taxes against the printed net, regular + overtime against the
///    computed wage — lives on `Observation`, so `PaycheckAudit` is copy over
///    integers it did not add up and `PaycheckEntrySheet` holds no
///    arithmetic at all.
///
/// 3. **The ±100c correction as a PROPOSAL.** `MetricID.observedPaidTips` is
///    "the stub field exactly as entered"; `MetricID
///    .proposedPaidTipsCorrection` is a separate value, "never auto-applied".
///    Fixture P1 is the case: stub tips 10000, regular 5000, gross 15050, so
///    the gross equation implies 10050. Before this type, the inference was
///    substituted SILENTLY at every read — `PaycheckRecord
///    .reconciledPaidTipsCents` returned 10050 to the periods list, to period
///    detail's "check paid", to the editor's prefill (so an unedited Save
///    wrote 10050 over the person's own 10000), and to the scan path before
///    the value ever reached the sheet. `Proposal` carries the 10050 and the
///    "Looks like $100.50 (accept?)" label; `Observation.paidTipsCents` stays
///    10000 until a person says otherwise.
///
/// Every delta is per COMPONENT and never summed across components, per
/// `MetricID.reconciliationDelta`: "tips = observedPaidTips −
/// expectedPaycheckTipsLine; gratuity = stub gratuity − gratuityFees; …". A
/// component is absent when either side is absent, and an absent component
/// produces no delta rather than a delta against zero.
public enum PaycheckReconciler {
    // MARK: - The expected side, as formulas

    /// `MetricID.expectedPaycheckTipsLine`: credit tips net of tip-out, or
    /// all voluntary tips net of tip-out when no credit was logged at all.
    ///
    /// Cash never runs through payroll and tip-out is withheld from declared
    /// tips (Tyler, 2026-08-03), so the stub's Tips line is the credit side
    /// minus the tip-out. The cash fallback exists for legacy all-cash
    /// periods, which would otherwise expect nothing on a stub that plainly
    /// paid something. Clamped at zero: a stub never prints a negative line.
    public static func tipsLineCents(from components: EarningsComponents) -> Int {
        let base = components.voluntaryCreditCents > 0
            ? components.voluntaryCreditCents
            : components.voluntaryTipsCents
        return max(0, base - components.tipOutCents)
    }

    /// The stub's Tips line plus its Gratuity line: the "expected" half of
    /// the History row's delta and of period detail's verdict. Two registry
    /// rows summed, kept in one function because that is the figure both
    /// surfaces render.
    public static func tipsAndGratuityCents(from components: EarningsComponents) -> Int {
        tipsLineCents(from: components) + components.gratuityFeesCents
    }

    /// `MetricID.expectedPaycheckGross`: the whole pre-tax check. Wages come
    /// from the components, so a period whose wages are `.unavailable`
    /// contributes zero for them and the `Completeness` on the result says
    /// so — which is why `Expectation.grossFigure` carries the caption.
    public static func grossCents(from components: EarningsComponents) -> Int {
        tipsAndGratuityCents(from: components) + components.wagesCents
    }

    /// `MetricID.reconciliationDelta` for one component: observed minus
    /// expected. Negative reads short, and only a negative reads red.
    public static func deltaCents(observed: Int, expected: Int) -> Int {
        observed - expected
    }

    // MARK: - The expected side, as a value

    /// What the engine expected of one pay period's stub.
    ///
    /// Built from ONE `EarningsResult` and handed to every consumer of that
    /// period, which is the structural fix rather than a second correct
    /// computation. MEASURED divergence when it was two: five 10h days at
    /// $10/hr with the POLICY workweek starting Sunday and the pay-period
    /// GRID set to Monday, plus a 6h/$200 shift at 18:00 on the period's
    /// final day — period detail expected $1,310.00 and the sheet audited
    /// against $1,000.00, because the sheet's own basis filtered entries by
    /// `date <= period.end` (and `PayPeriod.end` is that day's midnight, so
    /// the final-day shift vanished) and allocated overtime by the grid's
    /// weekday.
    ///
    /// Every figure is optional and nil means the same thing throughout: no
    /// dataset stands behind it, so nothing may render a currency figure for
    /// it (PR 5 adapter contract, rule 4). It is never zero-filled — a zero
    /// expectation and an unreadable one produced the same green "+$95.00 /
    /// checked" verdict before wave 1 closed the same hole on
    /// `PeriodCheckComparison`.
    public struct Expectation: Hashable, Sendable {
        /// The period's own result, or nil when the engine could not answer.
        public let result: EarningsResult?

        /// The dataset these figures were computed from, for the adapter
        /// contract's rule 3: a consumer caches on this rather than on a
        /// hand-written list of the inputs it thinks can move a number.
        ///
        /// Nil exactly when `result` is nil, because both come from the same
        /// snapshot: there is no dataset to stamp.
        public let stamp: SnapshotStamp?

        public init(result: EarningsResult?, stamp: SnapshotStamp?) {
            self.result = result
            self.stamp = result == nil ? nil : stamp
        }

        /// No dataset, so no expectation. Every check that needs one stays
        /// silent; the stub-internal ones still run, because they need
        /// nothing from the engine.
        public static let unbacked = Expectation(result: nil, stamp: nil)

        /// True when no dataset stands behind these figures.
        public var isUnbacked: Bool { result == nil }

        /// The period's known components — the same ones the hero, the
        /// drawer rows and the expected-gross figure read.
        public var components: EarningsComponents? { result?.knownComponents }

        public var completeness: Completeness? { result?.completeness }

        /// `MetricID.expectedPaycheckTipsLine`.
        public var tipsLineCents: Int? {
            components.map(PaycheckReconciler.tipsLineCents(from:))
        }

        /// The tips line the AUDIT compares a stub against, which is nil for
        /// a period with no credit tips at all.
        ///
        /// Deliberately narrower than `tipsLineCents`: a legacy all-cash
        /// period expects its whole cash total on the stub under the
        /// registry's fallback, and telling someone their card-tip line is
        /// "$500 short" because their tips were cash is nagging, not
        /// auditing. The History row and period detail's verdict keep using
        /// the fallback, because there the figure is a comparison the person
        /// asked for rather than a warning Payday volunteered.
        public var auditableTipsLineCents: Int? {
            guard let components, components.voluntaryCreditCents > 0 else { return nil }
            return PaycheckReconciler.tipsLineCents(from: components)
        }

        /// The Tips line plus the Gratuity line, the "expected" half of a
        /// paycheck comparison.
        public var tipsAndGratuityCents: Int? {
            components.map(PaycheckReconciler.tipsAndGratuityCents(from:))
        }

        /// `MetricID.gratuityFees` for the period, nil when none was logged:
        /// its own payroll category, compared independently so an overage in
        /// one cannot hide a shortage in the other.
        public var gratuityFeesCents: Int? {
            guard let components, components.gratuityFeesCents > 0 else { return nil }
            return components.gratuityFeesCents
        }

        /// `MetricID.expectedPaycheckGross`.
        public var grossCents: Int? {
            components.map(PaycheckReconciler.grossCents(from:))
        }

        /// Whether the period has a computed wage worth auditing a stub
        /// against.
        ///
        /// False with wages off and false when no shift was priced: there is
        /// then no computed wage, and the audit says nothing rather than
        /// reporting a real stub as "$X over" a zero. This is the rule
        /// `PeriodIncome.wages` used, restated on the engine's own
        /// completeness.
        public var hasAuditableWages: Bool {
            guard let completeness else { return false }
            return completeness.state != .off && completeness.shiftsWageValued > 0
        }

        /// `MetricID.regularWages` for the period, nil when there is no
        /// auditable wage picture.
        public var regularWagesCents: Int? {
            guard hasAuditableWages else { return nil }
            return components?.regularWagesCents
        }

        /// `MetricID.overtimeWages` for the period.
        public var overtimeWagesCents: Int? {
            guard hasAuditableWages else { return nil }
            return components?.overtimeWagesCents
        }

        /// regularWages + overtimeWages, the figure a stub's two wage lines
        /// are compared against as one.
        public var wagesCents: Int? {
            guard hasAuditableWages else { return nil }
            return components?.wagesCents
        }

        /// The ledger's overtime minutes for the period — the hours facet of
        /// `MetricID.overtimeWages`. Nil under the same rule as the cents:
        /// no auditable wage picture, nothing to claim.
        public var overtimeMinutes: Int? {
            guard hasAuditableWages else { return nil }
            return result?.overtimeMinutes
        }

        /// Σ minutes over covered shifts.
        public var minutes: Int? {
            guard hasAuditableWages else { return nil }
            return result?.minutes
        }

        /// `MetricID.expectedPaycheckGross` as the figure a view renders.
        ///
        /// Unavailable rather than zero when no dataset stands behind it, so
        /// the sheet cannot print "$0.00" next to "Expected" for a period
        /// Payday could not read. A `.partial` or `.estimated` period carries
        /// its caption, because an expectation that silently omits an
        /// unpriced shift is the audit's headline defect wearing the word
        /// "Expected".
        public var grossFigure: EarningsFigure {
            guard let result, let cents = grossCents else {
                return EarningsFigure(
                    metric: .expectedPaycheckGross,
                    amount: .unavailable,
                    label: "Expected",
                    caption: nil,
                    completeness: .empty
                )
            }
            return EarningsFigure(
                metric: .expectedPaycheckGross,
                amount: .cents(cents),
                label: "Expected",
                caption: CompletenessCopy.caption(result.completeness.state),
                completeness: result.completeness
            )
        }

        /// `MetricID.expectedPaycheckTipsLine` as the figure a view renders,
        /// under the registry's only allowed label for it — and the ONLY
        /// figure form of that metric, because no surface renders the
        /// fallback as a figure.
        ///
        /// **Built on `auditableTipsLineCents`, not on `tipsLineCents`, and
        /// named for it so the two can never be confused at a call site.**
        /// The only surface that renders this figure is
        /// `PaycheckEntrySheet`, directly under the TIPS ON STUB field, where
        /// the label "Your check's tips line" is a claim about what payroll
        /// printed on the person's stub. The registry's cash FALLBACK cannot
        /// make that claim: cash never runs through payroll (Tyler,
        /// 2026-08-03, this file's header), so for a cash-only period the
        /// fallback figure is not a quiet over-estimate, it is false.
        ///
        /// MEASURED before this was narrowed: a cash-only pay period (one 8h
        /// shift, $120.00 cash, no credit) rendered "Your check's tips line
        /// $120.00" under the stub's tips field while
        /// `auditableTipsLineCents` was nil for the same period, so
        /// `Reconciliation.tipsDeltaCents` was nil and `PaycheckAudit` emitted
        /// no `tips-vs-logged` finding at all. One screen stated an
        /// expectation about a payroll field that the engine behind the same
        /// screen refused to compare — and a person who typed $120.00 to
        /// match what Payday told them to expect would have written a false
        /// `observedPaidTips` that then read back as a green "reconciles".
        ///
        /// So: nil means unknown, and unknown renders nothing. For a period
        /// with no credit tips logged, Payday does not know how much of that
        /// money ran through the check, which is exactly `.unavailable` —
        /// "the engine could not answer", per the adapter contract's rule 4.
        /// `expectedFigureLine` withholds the whole line for an unavailable
        /// figure, so the sheet stays silent rather than printing an en dash.
        ///
        /// The fallback keeps its two homes, both whole-check comparisons the
        /// person asked for rather than guidance Payday volunteered:
        /// `grossCents` / `grossFigure` (the sheet's "Expected" line and
        /// period detail's "Expected $X"), and `tipsAndGratuityCents` /
        /// `Reconciliation.tipEarningsDeltaCents` (the History row's verdict).
        public var auditableTipsLineFigure: EarningsFigure {
            guard let result, let cents = auditableTipsLineCents else {
                return EarningsFigure(
                    metric: .expectedPaycheckTipsLine,
                    amount: .unavailable,
                    label: "Your check's tips line",
                    caption: nil,
                    completeness: .empty
                )
            }
            return EarningsFigure(
                metric: .expectedPaycheckTipsLine,
                amount: .cents(cents),
                label: "Your check's tips line",
                // The tips line has no wage term, so a partial wage picture
                // cannot make it partial. `MetricID
                // .expectedPaycheckTipsLine`'s missing-data rule is "none".
                caption: nil,
                completeness: result.completeness
            )
        }
    }

    // MARK: - The observed side

    /// One pay stub as entered, plus every sum its own lines produce.
    ///
    /// Zero-means-nil is the sheet's convention and it is preserved here:
    /// "not entered" and "entered as zero" are different facts, and a check
    /// that needs a field stays silent when the field is blank rather than
    /// reporting it as a zero discrepancy.
    ///
    /// Nothing here is an engine metric except `paidTipsCents`
    /// (`MetricID.observedPaidTips`); the rest are stored stub observations,
    /// which `docs/METRICS.md` 1.3 records as owed registry rows. They live
    /// on this type anyway, because `reconciliationDelta` needs them as its
    /// observed side per component and because a sum a view performs is a
    /// sum no test can pin.
    public struct Observation: Hashable, Sendable {
        /// `MetricID.observedPaidTips`, exactly as entered. Never rewritten
        /// by anything in this file.
        public let paidTipsCents: Int?
        public let regularWagesCents: Int?
        public let overtimeWagesCents: Int?
        public let gratuityCents: Int?
        public let grossCents: Int?
        public let taxesCents: Int?
        public let netCents: Int?

        public init(
            paidTipsCents: Int?,
            regularWagesCents: Int? = nil,
            overtimeWagesCents: Int? = nil,
            gratuityCents: Int? = nil,
            grossCents: Int? = nil,
            taxesCents: Int? = nil,
            netCents: Int? = nil
        ) {
            self.paidTipsCents = paidTipsCents
            self.regularWagesCents = regularWagesCents
            self.overtimeWagesCents = overtimeWagesCents
            self.gratuityCents = gratuityCents
            self.grossCents = grossCents
            self.taxesCents = taxesCents
            self.netCents = netCents
        }

        /// Nothing entered at all.
        public static let empty = Observation(paidTipsCents: nil)

        /// Whether any field other than the wage lines was entered. The
        /// missing-overtime check needs it: a blank sheet is not a stub
        /// claiming no overtime.
        public var hasAnyNonWageField: Bool {
            paidTipsCents != nil || grossCents != nil || taxesCents != nil || netCents != nil
        }

        public var hasAnyWageField: Bool {
            regularWagesCents != nil || overtimeWagesCents != nil
        }

        /// The stub's two wage lines as one figure, nil when neither was
        /// entered. A blank overtime line on a stub that prints regular
        /// wages is a real zero, which is why the terms default and the
        /// nil-ness is decided by `hasAnyWageField`.
        public var stubWagesCents: Int? {
            guard hasAnyWageField else { return nil }
            return (regularWagesCents ?? 0) + (overtimeWagesCents ?? 0)
        }

        /// Tips + regular + overtime + gratuity: what the stub's own lines
        /// say the gross should be. Nil unless the tips line was entered,
        /// which is the anchor this sheet is built around.
        public var stubEarnedCents: Int? {
            guard let paidTipsCents else { return nil }
            return paidTipsCents
                + (regularWagesCents ?? 0)
                + (overtimeWagesCents ?? 0)
                + (gratuityCents ?? 0)
        }

        /// Gross minus taxes: what the net should be if nothing else was
        /// withheld.
        public var grossMinusTaxesCents: Int? {
            guard let grossCents, let taxesCents else { return nil }
            return grossCents - taxesCents
        }

        /// Tips + gratuity as paid, the "observed" half of a paycheck
        /// comparison. Kept for whole-check comparison only; the audit
        /// compares the two categories independently so one cannot hide a
        /// shortage in the other.
        public var paidTipEarningsCents: Int? {
            guard let paidTipsCents else { return nil }
            return paidTipsCents + (gratuityCents ?? 0)
        }
    }

    // MARK: - The proposal

    /// A ±100c correction to `observedPaidTips` that the stub's own gross
    /// equation implies, offered for a person to accept.
    ///
    /// `MetricID.proposedPaidTipsCorrection`: "a separate value from
    /// observedPaidTips, never auto-applied, never written back to the
    /// record, and never substituted in a comparison unless the user accepts
    /// it (fixture P1)".
    ///
    /// Larger differences produce no proposal on purpose: a $12 gap is more
    /// likely a real earnings row the stub printed and the sheet has no field
    /// for than a transposed digit, and "correcting" it would erase a
    /// discrepancy the audit exists to report.
    public struct Proposal: Hashable, Sendable {
        /// What the person entered. Unchanged by the existence of this type.
        public let observedCents: Int
        /// What the gross equation implies: gross − regular − overtime −
        /// gratuity.
        public let proposedCents: Int

        public init(observedCents: Int, proposedCents: Int) {
            self.observedCents = observedCents
            self.proposedCents = proposedCents
        }

        /// Signed, proposed minus observed. P1: +50.
        public var correctionCents: Int { proposedCents - observedCents }

        /// The registry's only allowed label for this metric, with the
        /// figure substituted. P1: "Looks like $100.50 (accept?)".
        public var label: String {
            "Looks like \(Money.string(fromCents: proposedCents)) (accept?)"
        }
    }

    /// The proposal a stub implies, or nil when it implies none.
    ///
    /// Exists only when `regularWages` and `grossPay` are both present, the
    /// inferred value is non-negative, it differs from what was entered, and
    /// the difference is at most 100 cents. This is the same predicate
    /// `PaycheckRecord.reconciledTipsCents` used; what changed is that the
    /// answer is a proposal and not a substitution.
    public static func proposal(for observation: Observation) -> Proposal? {
        guard let observed = observation.paidTipsCents,
              let regular = observation.regularWagesCents,
              let gross = observation.grossCents
        else { return nil }
        let inferred = gross
            - regular
            - (observation.overtimeWagesCents ?? 0)
            - (observation.gratuityCents ?? 0)
        let correction = inferred - observed
        guard inferred >= 0, correction != 0, abs(correction) <= 100 else { return nil }
        return Proposal(observedCents: observed, proposedCents: inferred)
    }

    // MARK: - The whole answer

    /// One stub against one period's expectation, with every per-component
    /// delta and the proposal.
    ///
    /// This is the value a screen holds. `PaycheckAudit` turns it into
    /// sentences and `PaycheckEntrySheet` renders it; neither adds, subtracts
    /// or rounds a cent.
    public struct Reconciliation: Hashable, Sendable {
        public let expectation: Expectation
        public let observation: Observation

        public init(expectation: Expectation, observation: Observation) {
            self.expectation = expectation
            self.observation = observation
        }

        /// The dataset the expected side was computed from. The adapter
        /// contract's cache key.
        public var stamp: SnapshotStamp? { expectation.stamp }

        /// `MetricID.proposedPaidTipsCorrection`.
        public var proposal: Proposal? { PaycheckReconciler.proposal(for: observation) }

        // MARK: Per-component deltas, observed − expected

        /// Tips: observed paid tips − the auditable expected tips line. Nil
        /// when either side is absent, never a delta against zero.
        public var tipsDeltaCents: Int? {
            delta(observation.paidTipsCents, expectation.auditableTipsLineCents)
        }

        /// Gratuity, its own payroll category.
        public var gratuityDeltaCents: Int? {
            delta(observation.gratuityCents, expectation.gratuityFeesCents)
        }

        /// The stub's two wage lines against the ledger's two, as one
        /// figure. Present whenever either stub wage line was entered and
        /// the period has an auditable wage picture.
        ///
        /// One figure rather than two, because payroll prints a regular line
        /// and an overtime line and pays their sum: a stub that splits
        /// $1,220.00 as all-regular is not short, it is misclassified, and
        /// the independent `Expectation.overtimeMinutes` check is what names
        /// that. Per-LINE deltas are in the registry
        /// (`MetricID.reconciliationDelta` enumerates regular and overtime
        /// separately) and are deliberately NOT written here yet: no surface
        /// renders them, and an uncalled property is a registry row that
        /// looks closed and is not (PR 5 plan, "an inventory row marked
        /// closed that has no production caller").
        public var wagesDeltaCents: Int? {
            delta(observation.stubWagesCents, expectation.wagesCents)
        }

        /// The stub against ITSELF: printed gross − (tips + wages +
        /// gratuity). Needs nothing from the engine, so it survives an
        /// unbacked expectation.
        public var stubInternalGrossDeltaCents: Int? {
            delta(observation.grossCents, observation.stubEarnedCents)
        }

        /// The stub against itself again: printed net − (gross − taxes).
        /// Positive means the net exceeds gross minus taxes, which cannot
        /// both be true.
        public var stubInternalNetDeltaCents: Int? {
            delta(observation.netCents, observation.grossMinusTaxesCents)
        }

        /// The whole-check comparison both History surfaces render: (tips +
        /// gratuity) paid − (expected tips line + expected gratuity). Uses
        /// the registry's tips line WITH its cash fallback, because this is
        /// a comparison the person asked for rather than a warning.
        public var tipEarningsDeltaCents: Int? {
            delta(observation.paidTipEarningsCents, expectation.tipsAndGratuityCents)
        }

        private func delta(_ observed: Int?, _ expected: Int?) -> Int? {
            guard let observed, let expected else { return nil }
            return PaycheckReconciler.deltaCents(observed: observed, expected: expected)
        }
    }
}
