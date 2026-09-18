import Foundation
import Testing
@testable import PaydayCore

/// The presentation rules, asserted rather than described. Every migrated
/// screen in PR 5 gets its labels from `CompletenessCopy`, so these are the
/// tests that stand behind all of them.
@Suite("CompletenessCopy")
struct CompletenessCopyTests {
    // MARK: - The rule that matters

    @Test(".partial never returns the word Total, under any tip-out or gratuity")
    func partialIsNeverATotal() {
        let partials: [WageState] = [
            .partial(missingHours: 1, missingRate: 0),
            .partial(missingHours: 0, missingRate: 1),
            .partial(missingHours: 4, missingRate: 2),
            .partial(missingHours: 0, missingRate: 0),
        ]
        for state in partials {
            for tipOut in [0, 500] {
                for gratuity in [0, 1200] {
                    let label = CompletenessCopy.earnedIncomeLabel(
                        state,
                        tipOutCents: tipOut,
                        gratuityFeesCents: gratuity
                    )
                    #expect(label == "Known so far")
                    #expect(label != "Total")
                }
            }
        }
    }

    @Test("complete reads Total, and You kept once something was tipped out")
    func completeLabels() {
        #expect(CompletenessCopy.earnedIncomeLabel(.complete) == "Total")
        #expect(CompletenessCopy.earnedIncomeLabel(.complete, tipOutCents: 1) == "You kept")
        #expect(CompletenessCopy.earnedIncomeLabel(.estimated) == "Total")
        #expect(CompletenessCopy.earnedIncomeLabel(.estimated, tipOutCents: 4000) == "You kept")
    }

    @Test("wages off relabels the figure as tips, because that is the metric it now is")
    func offLabelsAndMetric() {
        #expect(CompletenessCopy.earnedIncomeLabel(.off) == "Tips")
        #expect(CompletenessCopy.earnedIncomeLabel(.off, gratuityFeesCents: 900) == "Tips & gratuity")
        // Tip-out does not turn a tips figure into "You kept": that label
        // belongs to earnedIncome, and this figure is nonWageEarnings.
        #expect(CompletenessCopy.earnedIncomeLabel(.off, tipOutCents: 900) == "Tips")
        #expect(CompletenessCopy.earnedIncomeMetric(.off) == .nonWageEarnings)
        #expect(CompletenessCopy.earnedIncomeMetric(.complete) == .earnedIncome)
        #expect(CompletenessCopy.earnedIncomeMetric(.partial(missingHours: 1, missingRate: 0)) == .earnedIncome)
    }

    @Test("every label this file can return is allowed by the metric it names")
    func everyLabelIsAllowedByItsMetric() {
        let states: [WageState] = [
            .off, .complete, .estimated, .noShifts,
            .partial(missingHours: 1, missingRate: 0),
            .partial(missingHours: 0, missingRate: 3),
        ]
        for state in states {
            for tipOut in [0, 750] {
                for gratuity in [0, 750] {
                    let label = CompletenessCopy.earnedIncomeLabel(
                        state,
                        tipOutCents: tipOut,
                        gratuityFeesCents: gratuity
                    )
                    let metric = CompletenessCopy.earnedIncomeMetric(state)
                    #expect(
                        metric.allowedLabels.contains(label),
                        "\(label) is not in \(metric).allowedLabels for \(state)"
                    )
                }
            }
        }
    }

    // MARK: - Captions

    @Test("the partial caption names the cause and counts the shifts")
    func partialCaptions() {
        #expect(CompletenessCopy.caption(.partial(missingHours: 1, missingRate: 0)) == "wages missing for 1 shift")
        #expect(CompletenessCopy.caption(.partial(missingHours: 3, missingRate: 0)) == "wages missing for 3 shifts")
        #expect(CompletenessCopy.caption(.partial(missingHours: 0, missingRate: 1)) == "no rate set for 1 shift")
        #expect(
            CompletenessCopy.caption(.partial(missingHours: 2, missingRate: 1))
                == "2 shifts missing hours · no rate set for 1 shift"
        )
    }

    @Test("estimated carries its caption; complete and off carry none")
    func otherCaptions() {
        #expect(CompletenessCopy.caption(.estimated) == "Wages estimated from your current rate")
        #expect(CompletenessCopy.caption(.complete) == nil)
        #expect(CompletenessCopy.caption(.off) == nil)
        #expect(CompletenessCopy.caption(.noShifts) == nil)
    }

    // MARK: - EarningsFigure

    @Test("an unavailable figure renders no currency at all, and never zero")
    func unavailableRendersNoCurrency() {
        let figure = EarningsFigure.unavailable()
        #expect(figure.text == nil)
        #expect(figure.wholeDollarText == nil)
        #expect(figure.cents == nil)
        #expect(figure.isUnavailable)
        #expect(figure.mayBeCalledATotal == false)
        // The literal assertion, stated as the plan states it: no currency
        // text, and in particular not this string.
        #expect(figure.text != Money.string(fromCents: 0))
    }

    @Test("a missing shift is unavailable, not a zero-cent shift")
    func aMissingShiftIsUnavailable() {
        let figure = EarningsFigure.shiftEarnedIncome(nil, wageFeatureEnabled: true)
        #expect(figure.isUnavailable)
        #expect(figure.text == nil)
    }

    @Test("a real zero is a number: a shift that genuinely earned nothing renders $0.00")
    func arealZeroStillRenders() {
        let valuation = ShiftValuation(
            id: UUID(),
            workDay: CivilDay(year: 2026, month: 9, day: 18),
            ratePolicyID: nil,
            calendarPolicyID: nil,
            workweekStart: nil,
            minutesWorked: nil,
            wage: .unavailable(.hoursMissing),
            components: .zero
        )
        let figure = EarningsFigure.shiftEarnedIncome(valuation, wageFeatureEnabled: false)
        #expect(figure.cents == 0)
        #expect(figure.text == Money.string(fromCents: 0))
        // Wages are off, so it is a tips figure.
        #expect(figure.metric == .nonWageEarnings)
        #expect(figure.label == "Tips")
    }

    @Test("a partial result's figure is knownComponents, labelled Known so far")
    func partialFigureUsesKnownComponents() {
        let result = EarningsResult(
            metric: .earnedIncome,
            scope: .day(CivilDay(year: 2026, month: 9, day: 18)),
            range: nil,
            asOf: nil,
            knownComponents: EarningsComponents(
                voluntaryCashCents: 4000,
                voluntaryCreditCents: 6000,
                gratuityFeesCents: 0,
                tipOutCents: 0,
                regularWagesCents: 330,
                overtimeWagesCents: 0
            ),
            coveredComponents: .zero,
            minutes: 0,
            regularMinutes: 0,
            overtimeMinutes: 0,
            completeness: Completeness(
                totalShifts: 5,
                shiftsWithHours: 4,
                shiftsWageValued: 4,
                shiftsWageAssumed: 0,
                wageFeatureEnabled: true
            ),
            shiftIDs: []
        )
        let figure = EarningsFigure.earnedIncome(result)
        #expect(figure.cents == 10330)
        #expect(figure.label == "Known so far")
        #expect(figure.mayBeCalledATotal == false)
        #expect(figure.caption == "wages missing for 1 shift")
        #expect(figure.metric == .earnedIncome)
    }

    @Test("wages off makes the figure nonWageEarnings, not earnedIncome")
    func offFigureIsNonWage() {
        let result = EarningsResult(
            metric: .earnedIncome,
            scope: nil,
            range: nil,
            asOf: nil,
            knownComponents: EarningsComponents(
                voluntaryCashCents: 1000,
                voluntaryCreditCents: 2000,
                gratuityFeesCents: 500,
                tipOutCents: 300
            ),
            coveredComponents: .zero,
            minutes: 0,
            regularMinutes: 0,
            overtimeMinutes: 0,
            completeness: Completeness(
                totalShifts: 2,
                shiftsWithHours: 2,
                shiftsWageValued: 0,
                shiftsWageAssumed: 0,
                wageFeatureEnabled: false
            ),
            shiftIDs: []
        )
        let figure = EarningsFigure.earnedIncome(result)
        #expect(figure.metric == .nonWageEarnings)
        #expect(figure.label == "Tips & gratuity")
        #expect(figure.cents == 3200)
    }

    /// **The tips-only figure a page that DECLARED a tips-only basis needs.**
    ///
    /// `earnedIncome(_:)` is not it: on a `.partial` selection it returns
    /// `knownComponents.earnedIncomeCents`, a wage-inclusive number, under
    /// "Known so far". PR 5 wave 2 measured that on Insights — the chart drew
    /// 26,500c for a day the rest of the page called 10,500c, under a note
    /// reading "Every figure below is tips only" and a bar labelled "Total".
    @Test("nonWageEarnings drops the wages a partial earnedIncome figure keeps")
    func nonWageFigureOnAPartialSelection() {
        let result = EarningsResult(
            metric: .earnedIncome,
            scope: nil,
            range: nil,
            asOf: nil,
            knownComponents: EarningsComponents(
                voluntaryCashCents: 0,
                voluntaryCreditCents: 12_000,
                gratuityFeesCents: 0,
                tipOutCents: 1_500,
                regularWagesCents: 16_000
            ),
            coveredComponents: .zero,
            minutes: 0,
            regularMinutes: 0,
            overtimeMinutes: 0,
            completeness: Completeness(
                totalShifts: 5,
                shiftsWithHours: 4,
                shiftsWageValued: 4,
                shiftsWageAssumed: 0,
                wageFeatureEnabled: true
            ),
            shiftIDs: []
        )

        let wageInclusive = EarningsFigure.earnedIncome(result)
        #expect(wageInclusive.cents == 26_500)
        #expect(wageInclusive.metric == .earnedIncome)

        let tipsOnly = EarningsFigure.nonWageEarnings(result)
        #expect(tipsOnly.cents == 10_500)
        #expect(tipsOnly.metric == .nonWageEarnings)
        #expect(tipsOnly.label == "Tips")
        #expect(tipsOnly.mayBeCalledATotal == false)
        // No caption: `nonWageEarnings`' missing-data rule is "none", so
        // there is nothing about a tips figure to hedge.
        #expect(tipsOnly.caption == nil)
        // The wage picture is still carried whole — it is what told the
        // caller to be on this basis.
        #expect(tipsOnly.completeness == result.completeness)
        #expect(tipsOnly.cents != wageInclusive.cents)
    }

    @Test("a nonWageEarnings figure takes a nonWageEarnings label, gratuity included")
    func nonWageFigureLabels() {
        func figure(gratuity: Int, tipOut: Int) -> EarningsFigure {
            EarningsFigure.nonWageEarnings(
                EarningsResult(
                    metric: .earnedIncome,
                    scope: nil,
                    range: nil,
                    asOf: nil,
                    knownComponents: EarningsComponents(
                        voluntaryCashCents: 1_000,
                        voluntaryCreditCents: 2_000,
                        gratuityFeesCents: gratuity,
                        tipOutCents: tipOut
                    ),
                    coveredComponents: .zero,
                    minutes: 0,
                    regularMinutes: 0,
                    overtimeMinutes: 0,
                    completeness: .empty,
                    shiftIDs: []
                )
            )
        }
        #expect(figure(gratuity: 0, tipOut: 0).label == "Tips")
        #expect(figure(gratuity: 500, tipOut: 0).label == "Tips & gratuity")
        // A tip-out never turns a tips figure into "You kept": that label
        // belongs to earnedIncome.
        #expect(figure(gratuity: 0, tipOut: 900).label == "Tips")
        for gratuity in [0, 500] {
            let label = figure(gratuity: gratuity, tipOut: 0).label
            #expect(MetricID.nonWageEarnings.allowedLabels.contains(label))
        }
    }
}
