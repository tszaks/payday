import Foundation
import Testing
@testable import PaydayCore

// MARK: - Fixture plumbing

private func loadSnapshot(_ id: String, asOf: CivilDay? = nil) throws -> EarningsSnapshot {
    let fixture = try FixtureLoader.load(id)
    guard let cutoff = asOf ?? fixture.asOf else {
        Issue.record("Fixture \(fixture.id) declares no asOf")
        throw FixtureLoader.Error.missing(id: fixture.id)
    }
    return try EarningsSnapshot.build(
        EarningsInputs(
            shifts: fixture.toShiftInputs(),
            paychecks: try fixture.toPaycheckInputs(),
            schedule: fixture.toScheduleInput(),
            rates: fixture.toRatePolicies(),
            calendars: try fixture.toCalendarPolicies(),
            asOf: cutoff
        ),
        generation: 1,
        computedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

private func day(_ iso: String) -> CivilDay {
    guard let day = CivilDay(iso: iso) else {
        fatalError("test wrote a malformed day literal: \(iso)")
    }
    return day
}

private func range(_ start: String, _ end: String) -> DayRange {
    DayRange(start: day(start), end: day(end))
}

/// W2's whole workweek, taken with the cutoff off, so the expectation is the
/// settled period and not a period to date.
private func w2Expectation() throws -> PaycheckReconciler.Expectation {
    let snap = try loadSnapshot("W2", asOf: .distantFuture)
    return PaycheckReconciler.Expectation(
        result: snap.range(range("2026-09-28", "2026-10-04")),
        stamp: snap.stamp
    )
}

/// A one-shift week carrying credit tips, cash tips, a tip-out and gratuity
/// at once, which no fixture does. Used only by the delta-independence test.
private func tipsAndGratuitySnapshot() throws -> EarningsSnapshot {
    try EarningsSnapshot.build(
        EarningsInputs(
            shifts: [
                ShiftInput(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!,
                    workDay: day("2026-09-29"),
                    period: .dinner,
                    voluntaryCashCents: 1_000,
                    voluntaryCreditCents: 8_000,
                    gratuityFeesCents: 1_500,
                    tipOutCents: 500,
                    minutesWorked: 360
                ),
            ],
            paychecks: [],
            schedule: nil,
            rates: [
                PayRatePolicy(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
                    effectiveFrom: day("2025-12-29"),
                    hourlyRateCents: 283,
                    provenance: .confirmed
                ),
            ],
            calendars: [
                PayrollCalendarPolicy(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!,
                    effectiveFrom: day("2025-12-29"),
                    workweekStartWeekday: 2,
                    payrollTimeZone: TimeZone(identifier: "America/New_York")!
                ),
            ],
            asOf: .distantFuture
        )
    )
}

/// A cash-only pay period: one 8h shift, $120.00 cash, no credit, no tip-out,
/// no gratuity, at $10/hr. The registry's fallback answers $120.00 for its
/// tips line; the audit answers nothing, because cash never runs through
/// payroll.
private func cashOnlyExpectation() throws -> PaycheckReconciler.Expectation {
    let snap = try EarningsSnapshot.build(
        EarningsInputs(
            shifts: [
                ShiftInput(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!,
                    workDay: day("2026-09-29"),
                    period: .dinner,
                    voluntaryCashCents: 12_000,
                    voluntaryCreditCents: 0,
                    gratuityFeesCents: 0,
                    tipOutCents: 0,
                    minutesWorked: 480
                ),
            ],
            paychecks: [],
            schedule: nil,
            rates: [
                PayRatePolicy(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!,
                    effectiveFrom: day("2025-12-29"),
                    hourlyRateCents: 1_000,
                    provenance: .confirmed
                ),
            ],
            calendars: [
                PayrollCalendarPolicy(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!,
                    effectiveFrom: day("2025-12-29"),
                    workweekStartWeekday: 2,
                    payrollTimeZone: TimeZone(identifier: "America/New_York")!
                ),
            ],
            asOf: .distantFuture
        )
    )
    return PaycheckReconciler.Expectation(
        result: snap.range(range("2026-09-28", "2026-10-04")),
        stamp: snap.stamp
    )
}

/// The same week with credit tips in it: $80.00 credit, $10.00 cash, $5.00
/// tipped out, so the audited tips line is $75.00.
private func creditTipsExpectation() throws -> PaycheckReconciler.Expectation {
    let snap = try tipsAndGratuitySnapshot()
    return PaycheckReconciler.Expectation(
        result: snap.range(range("2026-09-28", "2026-10-04")),
        stamp: snap.stamp
    )
}

// MARK: - The expected side

@Suite("PaycheckReconciler expected side")
struct PaycheckReconcilerExpectedTests {
    /// W2's week is 11320 regular + 3396 overtime = 14716, with no tips at
    /// all, so the whole expected check is the wage picture.
    @Test("W2: the expected check is the ledger's own week, per component")
    func w2Expectation_perComponent() throws {
        let expectation = try w2Expectation()
        #expect(expectation.isUnbacked == false)
        #expect(expectation.regularWagesCents == 11_320, "W2.week.regularWagesCents")
        #expect(expectation.overtimeWagesCents == 3_396, "W2.week.overtimeWagesCents")
        #expect(expectation.wagesCents == 14_716, "W2.week.wagesCents")
        #expect(expectation.overtimeMinutes == 480, "W2.week.overtimeMinutes")
        #expect(expectation.minutes == 2_880, "W2.week.minutes")
        #expect(expectation.tipsLineCents == 0, "no tips logged, so the stub's tips line is 0")
        #expect(expectation.gratuityFeesCents == nil, "no gratuity logged means no gratuity to audit")
        #expect(expectation.auditableTipsLineCents == nil, "no credit tips means the audit says nothing")
        #expect(expectation.grossCents == 14_716)
        #expect(expectation.hasAuditableWages)
    }

    /// The sum is the reconciler's, not a screen's: gross is the tips line
    /// plus gratuity plus the ledger's wages, over ONE result.
    @Test("the expected gross is the tips line plus gratuity plus the ledger's wages")
    func grossIsTheSumOfItsComponents() {
        let components = EarningsComponents(
            voluntaryCashCents: 1_000,
            voluntaryCreditCents: 8_000,
            gratuityFeesCents: 1_500,
            tipOutCents: 500,
            regularWagesCents: 11_320,
            overtimeWagesCents: 3_396
        )
        // Credit 8000 minus tip-out 500: cash never runs through payroll.
        #expect(PaycheckReconciler.tipsLineCents(from: components) == 7_500)
        #expect(PaycheckReconciler.tipsAndGratuityCents(from: components) == 9_000)
        #expect(PaycheckReconciler.grossCents(from: components) == 23_716)
    }

    @Test("a cash-only period falls back to all voluntary tips net of tip-out")
    func cashOnlyFallsBack() {
        let cashOnly = EarningsComponents(voluntaryCashCents: 5_000, tipOutCents: 800)
        #expect(PaycheckReconciler.tipsLineCents(from: cashOnly) == 4_200)
    }

    @Test("a tip-out larger than the credit side clamps at zero, never negative")
    func tipsLineClampsAtZero() {
        let clamped = EarningsComponents(voluntaryCreditCents: 1_000, tipOutCents: 4_000)
        #expect(PaycheckReconciler.tipsLineCents(from: clamped) == 0)
    }

    /// Rule 4 of the adapter contract, on the expectation itself: with no
    /// dataset there is no expectation, and nothing renders a currency
    /// figure for it. Never a zero-filled expectation, which is what turned
    /// an unreadable period into a green "+$95.00 / checked" verdict before
    /// wave 1 closed the same hole on the History comparison.
    @Test("an unbacked expectation answers nil everywhere and renders no currency")
    func unbackedRefuses() {
        let expectation = PaycheckReconciler.Expectation.unbacked
        #expect(expectation.isUnbacked)
        #expect(expectation.stamp == nil)
        #expect(expectation.components == nil)
        #expect(expectation.tipsLineCents == nil)
        #expect(expectation.auditableTipsLineCents == nil)
        #expect(expectation.tipsAndGratuityCents == nil)
        #expect(expectation.gratuityFeesCents == nil)
        #expect(expectation.grossCents == nil)
        #expect(expectation.regularWagesCents == nil)
        #expect(expectation.overtimeWagesCents == nil)
        #expect(expectation.wagesCents == nil)
        #expect(expectation.overtimeMinutes == nil)
        #expect(expectation.hasAuditableWages == false)
        #expect(expectation.grossFigure.isUnavailable)
        #expect(expectation.grossFigure.text == nil)
        #expect(expectation.auditableTipsLineFigure.isUnavailable)
        #expect(expectation.auditableTipsLineFigure.text == nil)
    }

    /// A stamp handed in without a result is not a dataset. Keeping the two
    /// in step is what makes `isUnbacked` and a nil stamp the same fact, so
    /// a cache keyed on the stamp cannot hold facts nothing stands behind.
    @Test("a stamp without a result is dropped")
    func stampRequiresAResult() throws {
        let snap = try loadSnapshot("W2")
        let expectation = PaycheckReconciler.Expectation(result: nil, stamp: snap.stamp)
        #expect(expectation.stamp == nil)
        #expect(expectation.isUnbacked)
    }

    /// The registry's allowed labels, which `MetricIDTests` asserts the
    /// registry side of.
    @Test("the figures carry the registry's labels and no other")
    func figuresCarryRegistryLabels() throws {
        let expectation = try w2Expectation()
        #expect(expectation.grossFigure.label == "Expected")
        #expect(MetricID.expectedPaycheckGross.allowedLabels.contains(expectation.grossFigure.label))
        #expect(expectation.grossFigure.metric == .expectedPaycheckGross)
        #expect(expectation.grossFigure.text == "$147.16")

        // W2 logs no credit tips, so this is the `.unavailable` branch: the
        // label is still the registry's, and there is no currency at all.
        #expect(expectation.auditableTipsLineFigure.label == "Your check's tips line")
        #expect(MetricID.expectedPaycheckTipsLine.allowedLabels
            .contains(expectation.auditableTipsLineFigure.label))
        #expect(expectation.auditableTipsLineFigure.metric == .expectedPaycheckTipsLine)
        #expect(expectation.auditableTipsLineFigure.text == nil)

        // And the branch that DOES print a figure, so this test is not
        // silently only about the absent one.
        let withCredit = try creditTipsExpectation()
        #expect(withCredit.auditableTipsLineFigure.label == "Your check's tips line")
        #expect(MetricID.expectedPaycheckTipsLine.allowedLabels
            .contains(withCredit.auditableTipsLineFigure.label))
        #expect(withCredit.auditableTipsLineFigure.metric == .expectedPaycheckTipsLine)
        #expect(withCredit.auditableTipsLineFigure.text == "$75.00")
    }

    /// **The disagreeing case for the sheet's tips line.** The figure
    /// `PaycheckEntrySheet` prints under the TIPS ON STUB field must be the
    /// same quantity the `tips-vs-logged` check compares the stub against, on
    /// BOTH sides of the credit/cash split — otherwise the sheet states an
    /// expectation about a payroll field the engine on the same screen will
    /// not audit.
    ///
    /// MEASURED before the narrowing: a cash-only period (one 8h shift,
    /// $120.00 cash, no credit) rendered "Your check's tips line $120.00"
    /// while `auditableTipsLineCents` was nil, `tipsDeltaCents` was nil and
    /// `PaycheckAudit` emitted no `tips-vs-logged` finding. Cash never runs
    /// through payroll, so the claim was false on its face.
    @Test("a cash-only period renders no tips-line figure; a credit period renders the audited one")
    func tipsLineFigureIsTheAuditedQuantity() throws {
        // Cash only: the fallback still answers, as the registry row says,
        // and the FIGURE refuses, because the audit refuses.
        let cashOnly = try cashOnlyExpectation()
        #expect(cashOnly.isUnbacked == false, "there IS a dataset; only the tips line is unknowable")
        #expect(cashOnly.tipsLineCents == 12_000, "the registry's cash fallback is unchanged")
        #expect(cashOnly.auditableTipsLineCents == nil)
        #expect(cashOnly.auditableTipsLineFigure.isUnavailable)
        #expect(cashOnly.auditableTipsLineFigure.text == nil)
        #expect(cashOnly.auditableTipsLineFigure.text != "$120.00",
                "the superseded fallback figure, stated under a payroll field the audit will not compare")
        // The whole-check comparison keeps the fallback: $120.00 of tips plus
        // 8h at $10/hr of wages.
        #expect(cashOnly.grossCents == 20_000)
        #expect(cashOnly.grossFigure.text == "$200.00")
        // And the audit is silent about the tips line either way, which is
        // the agreement the figure now honours.
        let stub = PaycheckReconciler.Observation(paidTipsCents: 0)
        let cashReconciliation = PaycheckReconciler.Reconciliation(
            expectation: cashOnly,
            observation: stub
        )
        #expect(cashReconciliation.tipsDeltaCents == nil)

        // Credit tips: the figure is present and equals the audited cents to
        // the cent, so this test cannot pass by withholding everything.
        let credit = try creditTipsExpectation()
        #expect(credit.auditableTipsLineCents == 7_500, "credit 8000 net of tip-out 500")
        #expect(credit.auditableTipsLineFigure.isUnavailable == false)
        #expect(credit.auditableTipsLineFigure.cents == credit.auditableTipsLineCents)
        #expect(credit.auditableTipsLineFigure.text == "$75.00")
        let creditReconciliation = PaycheckReconciler.Reconciliation(
            expectation: credit,
            observation: PaycheckReconciler.Observation(paidTipsCents: 7_000)
        )
        #expect(creditReconciliation.tipsDeltaCents == -500,
                "the figure the sheet prints is the figure the delta is measured against")
    }

    /// C1 is the partial fixture: an expectation over it is still a figure,
    /// but it carries its caption, because an expected check that silently
    /// omits an unpriced shift is the audit's headline defect under the word
    /// "Expected".
    @Test("a partial period's expected gross carries its completeness caption")
    func partialExpectationCarriesCaption() throws {
        let snap = try loadSnapshot("C1", asOf: .distantFuture)
        let whole = snap.range(range("2000-01-01", "2100-01-01"))
        let expectation = PaycheckReconciler.Expectation(result: whole, stamp: snap.stamp)
        guard case .partial = whole.completeness.state else {
            Issue.record("C1 is expected to be a partial wage picture, got \(whole.completeness.state)")
            return
        }
        #expect(expectation.grossFigure.caption == CompletenessCopy.caption(whole.completeness.state))
        #expect(expectation.grossFigure.caption != nil)
        #expect(expectation.grossFigure.mayBeCalledATotal == false)
    }

    /// With wages off there is no computed wage to audit a stub against, so
    /// the audit says nothing rather than reporting a real stub as "$X over"
    /// a zero. The tips line survives: it has no wage term.
    @Test("wages off leaves the wage side unauditable and the tips line intact")
    func wagesOffHasNoAuditableWages() throws {
        let fixture = try FixtureLoader.load("W2")
        let noRates = try EarningsSnapshot.build(
            EarningsInputs(
                shifts: fixture.toShiftInputs(),
                paychecks: [],
                schedule: fixture.toScheduleInput(),
                rates: [],
                calendars: try fixture.toCalendarPolicies(),
                asOf: .distantFuture
            )
        )
        let expectation = PaycheckReconciler.Expectation(
            result: noRates.range(range("2026-09-28", "2026-10-04")),
            stamp: noRates.stamp
        )
        #expect(expectation.completeness?.state == .off)
        #expect(expectation.hasAuditableWages == false)
        #expect(expectation.regularWagesCents == nil)
        #expect(expectation.wagesCents == nil)
        #expect(expectation.overtimeMinutes == nil)
        #expect(expectation.tipsLineCents == 0, "the tips line has no wage term")
    }
}

// MARK: - The observed side

@Suite("PaycheckReconciler observed side")
struct PaycheckReconcilerObservedTests
{
    @Test("the stub's own sums come off the observation, not off a view")
    func stubSums() {
        let observed = PaycheckReconciler.Observation(
            paidTipsCents: 10_000,
            regularWagesCents: 11_320,
            overtimeWagesCents: 3_396,
            gratuityCents: 1_500,
            grossCents: 26_266,
            taxesCents: 4_000,
            netCents: 22_266
        )
        #expect(observed.stubWagesCents == 14_716)
        #expect(observed.stubEarnedCents == 26_216)
        #expect(observed.grossMinusTaxesCents == 22_266)
        #expect(observed.paidTipEarningsCents == 11_500)
        #expect(observed.hasAnyWageField)
        #expect(observed.hasAnyNonWageField)
    }

    /// Zero-means-nil: a blank field is "not entered", not "entered as
    /// zero", and every sum that needs it refuses.
    @Test("a blank stub produces no sums at all")
    func blankStubHasNoSums() {
        let blank = PaycheckReconciler.Observation.empty
        #expect(blank.stubWagesCents == nil)
        #expect(blank.stubEarnedCents == nil)
        #expect(blank.grossMinusTaxesCents == nil)
        #expect(blank.paidTipEarningsCents == nil)
        #expect(blank.hasAnyWageField == false)
        #expect(blank.hasAnyNonWageField == false)
    }

    /// A stub that prints regular wages and leaves overtime blank is
    /// claiming zero overtime, so the wage sum exists and equals the regular
    /// line. That is what makes the missing-overtime check fire.
    @Test("a stub with only a regular wage line still has a wage sum")
    func regularOnlyHasAWageSum() {
        let observed = PaycheckReconciler.Observation(
            paidTipsCents: nil,
            regularWagesCents: 11_320
        )
        #expect(observed.stubWagesCents == 11_320)
        #expect(observed.stubEarnedCents == nil, "no tips line entered")
    }
}

// MARK: - The proposal (fixture P1)

@Suite("PaycheckReconciler proposal")
struct PaycheckReconcilerProposalTests {
    /// P1, whole. The gross equation implies 10050; the observation stays
    /// 10000; the label is the registry's.
    @Test("P1: the correction is a proposal and the observation is untouched")
    func p1Proposal() throws {
        let fixture = try FixtureLoader.load("P1")
        guard let stub = try fixture.toPaycheckInputs().first else {
            Issue.record("P1 declares no paycheck")
            return
        }
        let observed = PaycheckReconciler.Observation(
            paidTipsCents: stub.paidTipsCents,
            regularWagesCents: stub.regularWagesCents,
            overtimeWagesCents: stub.overtimeWagesCents,
            gratuityCents: stub.gratuityCents,
            grossCents: stub.grossPayCents
        )
        guard let proposal = PaycheckReconciler.proposal(for: observed) else {
            Issue.record("P1 declares a proposal is present")
            return
        }
        #expect(proposal.observedCents == 10_000, "P1.observedPaidTipsCents")
        #expect(proposal.proposedCents == 10_050, "P1.proposedPaidTipsCorrection.inferredTipsCents")
        #expect(proposal.correctionCents == 50, "P1.proposedPaidTipsCorrection.correctionCents")
        #expect(proposal.label == "Looks like $100.50 (accept?)",
                "P1.proposedPaidTipsCorrection.label")
        #expect(MetricID.proposedPaidTipsCorrection.allowedLabels == ["Looks like $X (accept?)"])

        // P1.observedPaidTipsCentsAfterProposal. The whole point: asking for
        // the proposal does not change the answer to "what did the stub say".
        #expect(observed.paidTipsCents == 10_000)
        #expect(observed.paidTipsCents != proposal.proposedCents)
    }

    /// P1's own wrongAnswers list: 10050 substituted for the observation is
    /// the defect, at every read.
    @Test("P1: the proposed figure is never the observed figure")
    func p1WrongAnswerIsNotProduced() throws {
        let fixture = try FixtureLoader.load("P1")
        guard let stub = try fixture.toPaycheckInputs().first else {
            Issue.record("P1 declares no paycheck")
            return
        }
        let expectation = PaycheckReconciler.Expectation.unbacked
        let reconciliation = PaycheckReconciler.Reconciliation(
            expectation: expectation,
            observation: PaycheckReconciler.Observation(
                paidTipsCents: stub.paidTipsCents,
                regularWagesCents: stub.regularWagesCents,
                overtimeWagesCents: stub.overtimeWagesCents,
                gratuityCents: stub.gratuityCents,
                grossCents: stub.grossPayCents
            )
        )
        #expect(reconciliation.observation.paidTipsCents == 10_000)
        #expect(reconciliation.proposal?.proposedCents == 10_050)
        #expect(reconciliation.observation.paidTipEarningsCents == 10_000,
                "P1.reconciliationObservedTipsSideCents: the comparison's observed side is 10000")
    }

    @Test("no proposal without both a regular wage line and a gross")
    func proposalNeedsItsInputs() {
        let noGross = PaycheckReconciler.Observation(
            paidTipsCents: 10_000,
            regularWagesCents: 5_000
        )
        #expect(PaycheckReconciler.proposal(for: noGross) == nil)

        let noRegular = PaycheckReconciler.Observation(
            paidTipsCents: 10_000,
            grossCents: 15_050
        )
        #expect(PaycheckReconciler.proposal(for: noRegular) == nil)

        let noTips = PaycheckReconciler.Observation(
            paidTipsCents: nil,
            regularWagesCents: 5_000,
            grossCents: 15_050
        )
        #expect(PaycheckReconciler.proposal(for: noTips) == nil)
    }

    @Test("exactly 100c is proposed and 101c is not")
    func proposalBoundary() {
        func proposal(gross: Int) -> PaycheckReconciler.Proposal? {
            PaycheckReconciler.proposal(for: PaycheckReconciler.Observation(
                paidTipsCents: 10_000,
                regularWagesCents: 5_000,
                overtimeWagesCents: 0,
                gratuityCents: 0,
                grossCents: gross
            ))
        }
        #expect(proposal(gross: 15_100)?.correctionCents == 100)
        #expect(proposal(gross: 15_101) == nil, "101c is a real discrepancy, not a misread digit")
        #expect(proposal(gross: 14_900)?.correctionCents == -100)
        #expect(proposal(gross: 14_899) == nil)
        #expect(proposal(gross: 15_000) == nil, "no correction means no proposal")
    }

    @Test("a gross equation implying negative tips proposes nothing")
    func negativeInferenceProposesNothing() {
        let observed = PaycheckReconciler.Observation(
            paidTipsCents: 20,
            regularWagesCents: 5_000,
            overtimeWagesCents: 0,
            gratuityCents: 0,
            grossCents: 4_950
        )
        #expect(PaycheckReconciler.proposal(for: observed) == nil)
    }
}

// MARK: - Per-component deltas

@Suite("PaycheckReconciler deltas")
struct PaycheckReconcilerDeltaTests {
    /// The registry: "observed - expected, computed per component and never
    /// summed across components". The disagreeing case, so the test can
    /// fail: the stub is short on tips and over on gratuity at once, and
    /// neither hides the other.
    @Test("an overage in one component does not hide a shortage in another")
    func componentsAreIndependent() throws {
        // Built here rather than from a fixture because no fixture carries
        // credit tips AND gratuity at once, and this test is about the
        // comparison rather than about the ledger: the ledger's own
        // arithmetic is pinned by the W2 cases above.
        let snap = try tipsAndGratuitySnapshot()
        let whole = snap.range(range("2026-09-28", "2026-10-04"))
        let expectation = PaycheckReconciler.Expectation(result: whole, stamp: snap.stamp)
        guard let expectedTips = expectation.auditableTipsLineCents,
              let expectedGratuity = expectation.gratuityFeesCents
        else {
            Issue.record("the fixture is expected to carry both credit tips and gratuity; got tips \(String(describing: expectation.auditableTipsLineCents)), gratuity \(String(describing: expectation.gratuityFeesCents))")
            return
        }
        #expect(expectedTips == 7_500, "credit 8000 net of tip-out 500")
        #expect(expectedGratuity == 1_500)
        let reconciliation = PaycheckReconciler.Reconciliation(
            expectation: expectation,
            observation: PaycheckReconciler.Observation(
                paidTipsCents: expectedTips - 700,
                gratuityCents: expectedGratuity + 700
            )
        )
        #expect(reconciliation.tipsDeltaCents == -700, "short on tips")
        #expect(reconciliation.gratuityDeltaCents == 700, "over on gratuity")
        // Summed they would cancel to zero and report a clean stub.
        #expect(reconciliation.tipsDeltaCents != reconciliation.gratuityDeltaCents)
    }

    /// W2's wage week against a stub that pays the regular line and no
    /// overtime: the wage delta is exactly the overtime premium the stub
    /// left off, and the overtime component says so on its own.
    @Test("W2: a stub with no overtime line is short by the whole overtime")
    func w2MissingOvertime() throws {
        let expectation = try w2Expectation()
        let reconciliation = PaycheckReconciler.Reconciliation(
            expectation: expectation,
            observation: PaycheckReconciler.Observation(
                paidTipsCents: nil,
                regularWagesCents: 11_320,
                overtimeWagesCents: nil
            )
        )
        // The stub's two lines are compared as the one figure payroll pays:
        // $113.20 of regular against the ledger's $113.20 plus $33.96 of
        // overtime the stub never printed.
        #expect(reconciliation.wagesDeltaCents == -3_396, "W2.week.overtimeWagesCents, unpaid")
    }

    /// "A component is absent when either side is absent." Not a delta
    /// against zero, which would report every blank field as a shortfall.
    @Test("an absent side produces no delta")
    func absentSidesProduceNoDelta() throws {
        let expectation = try w2Expectation()
        let blank = PaycheckReconciler.Reconciliation(
            expectation: expectation,
            observation: .empty
        )
        #expect(blank.tipsDeltaCents == nil)
        #expect(blank.gratuityDeltaCents == nil)
        #expect(blank.wagesDeltaCents == nil)
        #expect(blank.tipEarningsDeltaCents == nil)

        let unbacked = PaycheckReconciler.Reconciliation(
            expectation: .unbacked,
            observation: PaycheckReconciler.Observation(
                paidTipsCents: 9_500,
                regularWagesCents: 1_000,
                overtimeWagesCents: 0,
                gratuityCents: 0,
                grossCents: 10_500,
                taxesCents: 500,
                netCents: 10_000
            )
        )
        #expect(unbacked.tipsDeltaCents == nil, "no dataset, no expectation, no verdict")
        #expect(unbacked.tipEarningsDeltaCents == nil)
        #expect(unbacked.wagesDeltaCents == nil)
        // The stub-internal checks need nothing from the engine, so they
        // still answer.
        #expect(unbacked.stubInternalGrossDeltaCents == 0)
        #expect(unbacked.stubInternalNetDeltaCents == 0)
        // And the proposal needs nothing from the engine either. This stub's
        // gross equation implies exactly what it printed (10500 - 1000 - 0 -
        // 0 == 9500), so there is no correction to propose — a proposal is
        // the difference, not the inference.
        #expect(unbacked.proposal == nil)
    }

    @Test("the stub-internal checks measure the stub against itself")
    func stubInternalDeltas() {
        let reconciliation = PaycheckReconciler.Reconciliation(
            expectation: .unbacked,
            observation: PaycheckReconciler.Observation(
                paidTipsCents: 5_000,
                grossCents: 6_000,
                taxesCents: 1_000,
                netCents: 4_500
            )
        )
        #expect(reconciliation.stubInternalGrossDeltaCents == 1_000,
                "$10 of the gross is unaccounted by the stub's own lines")
        #expect(reconciliation.stubInternalNetDeltaCents == -500,
                "$5 more was withheld than the taxes line explains")
    }

    /// Red strictly when the delta is negative, which is the registry's
    /// rule and stays as it is.
    @Test("only a negative delta is short")
    func onlyNegativeIsShort() {
        #expect(PaycheckReconciler.deltaCents(observed: 9_000, expected: 10_000) == -1_000)
        #expect(PaycheckReconciler.deltaCents(observed: 10_000, expected: 10_000) == 0)
        #expect(PaycheckReconciler.deltaCents(observed: 11_000, expected: 10_000) == 1_000)
    }

    /// The cache key the adapter contract asks for: the stamp travels with
    /// the answer, so two consumers holding the same reconciliation are
    /// provably looking at the same dataset.
    @Test("the reconciliation carries the expectation's stamp")
    func reconciliationCarriesTheStamp() throws {
        let expectation = try w2Expectation()
        let reconciliation = PaycheckReconciler.Reconciliation(
            expectation: expectation,
            observation: .empty
        )
        #expect(reconciliation.stamp == expectation.stamp)
        #expect(reconciliation.stamp != nil)
        #expect(PaycheckReconciler.Reconciliation(expectation: .unbacked, observation: .empty)
            .stamp == nil)
    }
}
