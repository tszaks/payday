import Foundation

/// The presentation rules for a wage picture, in ONE place.
///
/// `MetricID`'s header says "adding a case means adding a row to
/// `docs/METRICS.md` and a presentation rule in `CompletenessCopy`". This is
/// that file (Design 2, "Presentation rules for partial earnings"; the plan
/// files it under `PaydayCore/Copy/`).
///
/// It exists because the rules are cheap to state and expensive to restate.
/// Five screens deciding for themselves when a number may be called a
/// "Total" is five chances to call a partial one a total, which is the
/// audit's headline defect: a shift with no hours logged silently
/// contributed zero wages under an unchanged "Total".
///
/// Every label this returns is a member of the metric's `allowedLabels`.
/// `CompletenessCopyTests.everyLabelIsAllowedByItsMetric` asserts that over
/// every state, which is what keeps this file and the registry from drifting.
public enum CompletenessCopy {
    // MARK: - Labels

    /// The noun an `earnedIncome` figure may be headed with, for a given
    /// wage picture.
    ///
    /// The one rule that matters: **`.partial` never returns "Total"**. A
    /// selection where some shift's wage is unknown is "Known so far", by
    /// rule, on every surface.
    ///
    /// - Parameters:
    ///   - state: the selection's `Completeness.state`.
    ///   - tipOutCents: the selection's tip-out. When something was tipped
    ///     out, a complete figure reads "You kept" rather than "Total",
    ///     because the drawer above it already showed a bigger "Earned"
    ///     subtotal and "Total" next to the smaller number reads as a
    ///     contradiction.
    ///   - gratuityFeesCents: the selection's gratuity. Only consulted when
    ///     wages are `.off`, where the figure is `nonWageEarnings` and the
    ///     registry allows "Tips & gratuity".
    public static func earnedIncomeLabel(
        _ state: WageState,
        tipOutCents: Int = 0,
        gratuityFeesCents: Int = 0
    ) -> String {
        switch state {
        case .partial:
            // Never "Total". This is the rule the whole type exists for.
            return "Known so far"
        case .off:
            // Wages off means the figure IS nonWageEarnings, so it takes a
            // nonWageEarnings label. "Total" here is the widget's "TIPS"
            // bug in the other direction: a label that names a different
            // metric from the number under it.
            return gratuityFeesCents > 0 ? "Tips & gratuity" : "Tips"
        case .complete, .estimated, .noShifts:
            // `.noShifts` is grouped here DELIBERATELY, and it is a known
            // deferral rather than an oversight. Design 2 says `.noShifts`
            // "renders no currency figure"; Dashboard's empty pay period
            // shows `$0.00` under "Total" today, and a period with no shifts
            // genuinely earned nothing, so that zero is a fact and not a
            // placeholder. Whether an empty hero should show a figure at all
            // is a HERO decision (group 2.1, PR 5 wave 1), not a
            // shared-component one, so this file keeps today's answer and
            // does not quietly change five screens on the way past.
            return tipOutCents > 0 ? "You kept" : "Total"
        }
    }

    /// Which metric a figure presented under `earnedIncomeLabel` actually
    /// is. `.off` collapses to `nonWageEarnings`: numerically the same cents
    /// (there are no wages to add), but a different fact, and the label and
    /// the `MetricID` have to name the same one.
    public static func earnedIncomeMetric(_ state: WageState) -> MetricID {
        state == .off ? .nonWageEarnings : .earnedIncome
    }

    // MARK: - Captions

    /// The sentence that goes under the figure, or nil when the figure
    /// stands alone.
    ///
    /// - `.estimated`: "Wages estimated from your current rate" — shown
    ///   until the rate-history prompt in Settings is answered, because
    ///   PR 3's migration deliberately fabricated no rate history.
    /// - `.partial`: what is missing and for how many shifts, naming hours
    ///   or the rate specifically. "wages missing for 1 shift" is a fact
    ///   someone can act on; a bare asterisk is not.
    public static func caption(_ state: WageState) -> String? {
        switch state {
        case .off, .complete, .noShifts:
            return nil
        case .estimated:
            return "Wages estimated from your current rate"
        case .partial(let missingHours, let missingRate):
            // Hours first: it is the one the person can fix in the app.
            if missingHours > 0, missingRate > 0 {
                return "\(shiftCount(missingHours)) missing hours · no rate set for \(shiftCount(missingRate))"
            }
            if missingHours > 0 {
                return "wages missing for \(shiftCount(missingHours))"
            }
            if missingRate > 0 {
                return "no rate set for \(shiftCount(missingRate))"
            }
            // `.partial` with neither cause is unreachable from
            // `Completeness.state` (it derives the two counts from the same
            // three tallies), but a decoded payload could carry it. Say
            // something true rather than nothing.
            return "wages missing for some shifts"
        }
    }

    /// "1 shift" / "N shifts". The one place the plural lives.
    public static func shiftCount(_ count: Int) -> String {
        count == 1 ? "1 shift" : "\(count) shifts"
    }
}

/// One money figure as the engine answered it, together with the words the
/// completeness rules allow next to it.
///
/// **This is the type a view renders.** It has no public initializer taking
/// a bare `Int`: a figure a view added up itself cannot become one of these.
/// That is what turns "money never appears as arithmetic in a view" from an
/// aspiration into something a reviewer can check by grep — a `Text` in a
/// migrated view takes `figure.text`, and a `figure` can only come from an
/// `EarningsResult` or a `ShiftValuation`.
///
/// The second rule it carries: **a failed read is `.unavailable`, not zero.**
/// `text` returns nil for it, so a view is forced to supply a
/// non-currency placeholder. Rendering `$0.00` for "Payday could not read
/// your shifts" is the lie this type makes unspellable.
public struct EarningsFigure: Hashable, Sendable {
    /// The amount, or the honest absence of one.
    public enum Amount: Hashable, Sendable {
        /// The engine answered. `cents` may legitimately be 0 — a day with
        /// no shifts earned nothing, and that IS a number.
        case cents(Int)
        /// The engine could not answer: no snapshot yet, no such shift in
        /// the dataset, a fetch that threw. Never an amount, never "$0.00".
        case unavailable
    }

    /// Which metric this figure is, after `.off` collapses earned income to
    /// non-wage earnings.
    public let metric: MetricID
    public let amount: Amount
    /// A member of `metric.allowedLabels`.
    public let label: String
    public let caption: String?
    /// The wage picture behind the figure, for a view that needs more than
    /// the label (hollow chart bars, an "N of M shifts" coverage line).
    public let completeness: Completeness

    public init(
        metric: MetricID,
        amount: Amount,
        label: String,
        caption: String?,
        completeness: Completeness
    ) {
        self.metric = metric
        self.amount = amount
        self.label = label
        self.caption = caption
        self.completeness = completeness
    }

    /// The currency string a view prints, or nil when there is no honest
    /// amount to print.
    public var text: String? {
        switch amount {
        case .cents(let cents): return Money.string(fromCents: cents)
        case .unavailable: return nil
        }
    }

    /// The whole-dollar spelling, for tight spaces (a calendar tile, a
    /// chart annotation). Nil under the same rule as `text`.
    public var wholeDollarText: String? {
        switch amount {
        case .cents(let cents): return Money.wholeDollarString(fromCents: cents)
        case .unavailable: return nil
        }
    }

    /// The cents, or nil when unavailable. For a chart's bar height and for
    /// tests. Deliberately NOT defaulted to 0 anywhere.
    public var cents: Int? {
        switch amount {
        case .cents(let cents): return cents
        case .unavailable: return nil
        }
    }

    public var isUnavailable: Bool { amount == .unavailable }

    /// True only when the figure may be headed with the word "Total".
    /// `.partial` is false by construction, which is the assertion every
    /// migrated screen's copy test makes.
    public var mayBeCalledATotal: Bool { label == "Total" }

    // MARK: - Construction from the engine

    /// The `earnedIncome` of one query result, labelled by its own
    /// completeness.
    ///
    /// Uses `knownComponents`, per the `.partial` rule: the headline shows
    /// what IS known and says so, rather than showing a total that quietly
    /// excludes an unpriced shift. When wages are `.off` the figure is
    /// `nonWageEarnings` and the label follows.
    public static func earnedIncome(_ result: EarningsResult) -> EarningsFigure {
        let state = result.completeness.state
        let components = result.knownComponents
        let cents = state == .off
            ? components.nonWageEarningsCents
            : components.earnedIncomeCents
        return EarningsFigure(
            metric: CompletenessCopy.earnedIncomeMetric(state),
            amount: .cents(cents),
            label: CompletenessCopy.earnedIncomeLabel(
                state,
                tipOutCents: components.tipOutCents,
                gratuityFeesCents: components.gratuityFeesCents
            ),
            caption: CompletenessCopy.caption(state),
            completeness: result.completeness
        )
    }

    /// The `nonWageEarnings` of one query result, labelled as tips.
    ///
    /// For a surface that has **declared** a tips-only basis and has to keep
    /// every figure on it. `earnedIncome(_:)` is not that surface's figure:
    /// it folds wages in for every state except `.off`, so on a `.partial`
    /// selection it returns `knownComponents.earnedIncomeCents` under
    /// "Known so far" — a wage-inclusive number on a page that just said
    /// "every figure below is tips only". PR 5 wave 2 measured exactly that
    /// on Insights: the chart drew 26,500c for a day the rest of the page
    /// called 10,500c, under a bar labelled "Total".
    ///
    /// The label comes from `earnedIncomeLabel(.off, ...)` rather than being
    /// spelled here, so it stays a member of `MetricID.nonWageEarnings
    /// .allowedLabels` by the same route every other label does: "Tips", or
    /// "Tips & gratuity" when the selection holds gratuity.
    ///
    /// No caption. `nonWageEarnings`' missing-data rule is "none" — every
    /// shift has tips, so there is nothing about a tips figure to hedge, and
    /// `CompletenessCopy.caption(.off)` is nil for the same reason. The
    /// `completeness` is still carried whole: it is the wage picture of the
    /// selection, which is what told the caller to be on this basis in the
    /// first place, and a caller that wants to say so says it once.
    public static func nonWageEarnings(_ result: EarningsResult) -> EarningsFigure {
        let components = result.knownComponents
        return EarningsFigure(
            metric: .nonWageEarnings,
            amount: .cents(components.nonWageEarningsCents),
            label: CompletenessCopy.earnedIncomeLabel(
                .off,
                gratuityFeesCents: components.gratuityFeesCents
            ),
            caption: nil,
            completeness: result.completeness
        )
    }

    /// One shift's own earned income, from `snapshot.valuation(id)`.
    ///
    /// Nil `valuation` means "this shift is not in the dataset", which is a
    /// failed read and becomes `.unavailable` — not `$0`. That distinction
    /// is the reason `EarningsSnapshot.shift(_:)` returns an optional
    /// instead of a zeroed result.
    ///
    /// The cents are `valuation.components`, the ledger's slice of the
    /// WORKWEEK allocation. A row cannot compute this: overtime and the
    /// cumulative rounding are properties of the week, which is why W1's two
    /// shifts are 1203 and 1556 (summing to the week's 2759) and not 1203
    /// and 1557.
    public static func shiftEarnedIncome(
        _ valuation: ShiftValuation?,
        wageFeatureEnabled: Bool
    ) -> EarningsFigure {
        guard let valuation else {
            return EarningsFigure(
                metric: .earnedIncome,
                amount: .unavailable,
                // A label is still owed: VoiceOver reads it next to the
                // placeholder glyph.
                label: "Known so far",
                caption: nil,
                completeness: .empty
            )
        }
        let completeness = Completeness(
            valuations: [valuation],
            wageFeatureEnabled: wageFeatureEnabled
        )
        let state = completeness.state
        let components = valuation.components
        let cents = state == .off
            ? components.nonWageEarningsCents
            : components.earnedIncomeCents
        return EarningsFigure(
            metric: CompletenessCopy.earnedIncomeMetric(state),
            amount: .cents(cents),
            label: CompletenessCopy.earnedIncomeLabel(
                state,
                tipOutCents: components.tipOutCents,
                gratuityFeesCents: components.gratuityFeesCents
            ),
            caption: CompletenessCopy.caption(state),
            completeness: completeness
        )
    }

    /// The figure for a consumer with no snapshot at all: `EarningsStore` is
    /// `.loading`, or published `.unavailable`. Renders no currency.
    public static func unavailable(metric: MetricID = .earnedIncome) -> EarningsFigure {
        EarningsFigure(
            metric: metric,
            amount: .unavailable,
            label: "Known so far",
            caption: nil,
            completeness: .empty
        )
    }
}
