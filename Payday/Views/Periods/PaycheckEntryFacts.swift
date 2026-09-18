import Foundation

/// Everything `PaycheckEntrySheet` renders, from ONE
/// `PaycheckReconciler.Reconciliation`.
///
/// PR 5 group 2.5, and the four rules of `Payday/Earnings/SnapshotFacts.swift`
/// applied to a sheet rather than to a screen:
///
/// **Rule 1, presentation only.** Not one cent is added, subtracted, scaled or
/// rounded in this file. The expected side arrives as
/// `PaycheckReconciler.Expectation`, the stub's own sums arrive on
/// `PaycheckReconciler.Observation`, every delta is a property of the
/// reconciliation, and `PaycheckAudit` turns them into sentences.
///
/// **Rule 2, the snapshot plus this sheet's own inputs.** The expectation is
/// built by the screen that opened the sheet, off the snapshot it is already
/// rendering (`PaycheckReconciler.Expectation.init(snapshot:period:payrollTimeZone:)`).
/// The sheet takes no `[TipEntry]`, no wage, no `firstWeekday` and no
/// `TimeZone` — it used to take the first and derive the rest, and audited a
/// real stub against a basis $310.00 away from the one the screen behind it
/// showed.
///
/// **Rule 3, the stamp and no `Key`.** This sheet used to cache its audit
/// context with NO key at all: an `AuditContext` filled once by a `.task`,
/// refreshed only on `ModelContext.didSave`, so changing the wage or the
/// workweek start while the sheet was open left every CHECKS sentence
/// standing on the old numbers, silently. `stamp` is `SnapshotStamp?`, whose
/// `digest` is a SHA-256 over every input that can move a result — including
/// the rate history and the workweek — so `reusing(_:expectation:observation:)`
/// re-derives on a wage change by construction rather than by remembering to.
///
/// **Rule 4, figures not cents.** `expectedGross` and `expectedTipsLine` are
/// `EarningsFigure`s, so a period Payday could not read renders no currency
/// at all instead of "$0.00", and a `.partial` period cannot be headed
/// "Total".
struct PaycheckEntryFacts: SnapshotFacts, Equatable {
    /// The dataset the expected side was computed from. Nil when no dataset
    /// stands behind these facts, which is `isUnbacked`.
    let stamp: SnapshotStamp?

    /// The expected side of the period, as the screen behind the sheet holds
    /// it.
    let expectation: PaycheckReconciler.Expectation

    /// The stub as entered right now.
    let observation: PaycheckReconciler.Observation

    /// The whole answer, for the deltas and the proposal.
    let reconciliation: PaycheckReconciler.Reconciliation

    /// `MetricID.expectedPaycheckGross` for the period. Rendered next to the
    /// stub's own gross so a person auditing a check can see what Payday
    /// expected without leaving the sheet — the same figure, from the same
    /// property, that period detail's "Expected $X · Oct 4" caption reads.
    let expectedGross: EarningsFigure

    /// `MetricID.expectedPaycheckTipsLine`, shown under the tips field
    /// because the tips line is the one number this sheet exists to verify.
    ///
    /// The AUDITABLE form of the metric, i.e. the same figure the
    /// `tips-vs-logged` check compares the stub against, so this sheet cannot
    /// state an expectation about a payroll field that the engine on the same
    /// sheet then refuses to compare. It is `.unavailable` — and therefore
    /// renders no line at all — for a period with no credit tips logged, where
    /// Payday does not know how much of that money ran through the check.
    /// MEASURED: with the registry's cash fallback here instead, a cash-only
    /// period ($120.00 cash, no credit) printed "Your check's tips line
    /// $120.00" under the stub's tips field and produced no CHECKS finding.
    /// The fallback still stands behind `expectedGross`, which is a
    /// whole-check comparison rather than guidance about one printed line.
    let expectedTipsLine: EarningsFigure

    /// `MetricID.proposedPaidTipsCorrection`, or nil when the stub's own
    /// gross equation implies no correction. A PROPOSAL: rendering it is the
    /// whole of applying it, until a person taps.
    let proposal: PaycheckReconciler.Proposal?

    /// Every audit sentence, reconciling ones included.
    let findings: [PaycheckAudit.Finding]

    init(
        expectation: PaycheckReconciler.Expectation,
        observation: PaycheckReconciler.Observation
    ) {
        let reconciliation = PaycheckReconciler.Reconciliation(
            expectation: expectation,
            observation: observation
        )
        stamp = expectation.stamp
        self.expectation = expectation
        self.observation = observation
        self.reconciliation = reconciliation
        expectedGross = expectation.grossFigure
        expectedTipsLine = expectation.auditableTipsLineFigure
        proposal = reconciliation.proposal
        findings = PaycheckAudit.run(reconciliation)
    }

    /// The sentences worth showing. A check that reconciles is the absence of
    /// news, and six lines of good news buries the one line that is not.
    var actionableFindings: [PaycheckAudit.Finding] {
        findings.filter { finding in
            switch finding.severity {
            case .reconciles: false
            case .note, .discrepancy: true
            }
        }
    }

    /// Whether the expected figures may be shown at all. With no dataset
    /// there is no expectation, and the sheet says so once rather than
    /// printing an en dash beside every field.
    var hasExpectation: Bool { !isUnbacked }

    // MARK: - The cache (adapter contract, rule 3)

    /// `cached` when it was computed from the same dataset and the same stub,
    /// otherwise freshly derived.
    ///
    /// The key is the pair the contract names: the snapshot's `stamp` and
    /// this sheet's own presentational input, which is the stub being typed.
    /// A hand-written key is a key with something missing from it — this
    /// sheet's previous one was missing the wage and the workweek, which is
    /// exactly what a stamp includes.
    ///
    /// The WHOLE stamp, not `stamp.digest`, and the difference is a spurious
    /// miss rather than a stale hit: `SnapshotStamp` carries `computedAt`, so
    /// rebuilding the snapshot from byte-identical inputs produces an unequal
    /// stamp and re-derives facts that would have been the same. Deriving
    /// them is an audit over seven integers, so the cost of the miss is
    /// nothing and the cost of the opposite mistake — treating two datasets
    /// as one because a narrower key could not tell them apart — is the bug
    /// this whole file exists to close.
    static func reusing(
        _ cached: PaycheckEntryFacts?,
        expectation: PaycheckReconciler.Expectation,
        observation: PaycheckReconciler.Observation
    ) -> PaycheckEntryFacts {
        if let cached,
           cached.stamp == expectation.stamp,
           cached.expectation == expectation,
           cached.observation == observation {
            return cached
        }
        return PaycheckEntryFacts(expectation: expectation, observation: observation)
    }
}
