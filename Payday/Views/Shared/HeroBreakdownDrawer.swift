import SwiftUI

/// One breakdown row: a label and its dollar amount. A negative `cents`
/// renders with a minus sign (e.g. "Tipped out"); `emphasized` bolds the
/// row for the bottom total line.
///
/// `dividerAbove` draws a rule before the row, which is what lets a ledger run
/// additions → subtotal → subtractions → total instead of alternating signs
/// (Tyler, 2026-08-03: "instead of going up, down, up, down, go up, up, up,
/// down"). A reader can follow a column that only changes direction once.
///
/// `cents` is optional because a figure the engine could not produce renders
/// as a placeholder and never as `$0.00` (PR 5 adapter contract, rule 4).
struct BreakdownRow: Identifiable {
    var id: String { label }
    let label: String
    let cents: Int?
    let emphasized: Bool
    let dividerAbove: Bool

    init(_ label: String, cents: Int?, emphasized: Bool = false, dividerAbove: Bool = false) {
        self.label = label
        self.cents = cents
        self.emphasized = emphasized
        self.dividerAbove = dividerAbove
    }
}

// MARK: - Built from the engine

/// The drawer's contents, composed from ONE `EarningsResult`.
///
/// Dashboard and Period detail each build this list by hand, from their own
/// arithmetic, in the same order, with the same labels — and have drifted:
/// Period detail back-derives its tip-out as
/// `max(0, cash + credit + gratuity − net)` instead of reading the tip-out
/// the ledger already knew, so any rounding disagreement upstream becomes a
/// phantom "Tipped out" row.
///
/// **NOT YET CALLED BY EITHER SCREEN.** These four functions exist, are
/// tested (`HeroBreakdownDrawerSnapshotTests`) and are the one composition
/// wave 1 swaps onto — but as of PR 5 wave 0 they have zero production
/// callers. `DashboardView.heroWithDrawer` and `PeriodDetailFacts` still
/// compose their own rows, still back-derive the tip-out, and still write
/// `tipOutCents > 0 ? "You kept" : "Total"` (DashboardView.swift:570,
/// PeriodDetailView.swift:264) instead of `CompletenessCopy`'s label, so
/// Dashboard can still print "Total" over a partial period. The swap needs
/// the hero PERIOD's `EarningsResult`, which is the hero migration itself:
/// group 2.1 (Dashboard) and group 2.4 (Period detail), both wave 1. Do not
/// read `docs/METRICS.md` rows [SC-02] or [SC-03] as closing those.
///
/// Order is fixed and is the reason the component exists: everything that
/// ADDS, then the subtotal, then everything that SUBTRACTS, then what is
/// left. The old order ran cash, credit, tipped out, wages, overtime — plus,
/// plus, minus, plus, plus — so the eye had to track a sign that flipped
/// twice on the way down a five-row column.
extension BreakdownRow {
    /// The itemized rows above the bottom line.
    ///
    /// Every figure is a component `CompensationLedger` wrote; nothing here
    /// is added up except by the engine.
    ///
    /// The wage rows appear only when at least one selected shift was
    /// actually valued, so an all-unpriced selection shows no `$0.00` wage
    /// line. Their hour labels come from the CALENDAR split
    /// (`EarningsResult.regularMinutes`), which for a `.partial` selection
    /// covers more shifts than the cents do; that gap is what the total
    /// row's caption ("wages missing for N shifts") is for, and the headline
    /// label is "Known so far" rather than "Total" precisely so the pair is
    /// not read as a settled figure.
    static func ledgerRows(_ result: EarningsResult) -> [BreakdownRow] {
        let components = result.knownComponents
        var rows: [BreakdownRow] = [
            BreakdownRow("Cash tips", cents: components.voluntaryCashCents),
            BreakdownRow("Credit tips", cents: components.voluntaryCreditCents),
        ]
        if components.gratuityFeesCents > 0 {
            rows.append(BreakdownRow("Gratuity & fees", cents: components.gratuityFeesCents))
        }
        if result.completeness.shiftsWageValued > 0 {
            // Regular hours only. `result.minutes` is the TOTAL, so labeling
            // this row with it would claim the base-rate line covers hours
            // that are actually priced at 1.5x on the Overtime row below it.
            rows.append(BreakdownRow(
                "Wages · \(WorkedMinutes.hoursLabel(minutes: result.regularMinutes))",
                cents: components.regularWagesCents
            ))
            if components.overtimeWagesCents > 0 {
                rows.append(BreakdownRow(
                    "Overtime · \(WorkedMinutes.hoursLabel(minutes: result.overtimeMinutes))",
                    cents: components.overtimeWagesCents
                ))
            }
        }
        // The subtotal only earns its rule when something is subtracted
        // below it; with no tip-out logged, "Earned" and the bottom line
        // would be the same number printed twice.
        if components.tipOutCents > 0 {
            rows.append(BreakdownRow(
                "Earned",
                cents: components.grossBeforeTipOutCents,
                dividerAbove: true
            ))
            rows.append(BreakdownRow("Tipped out", cents: -components.tipOutCents))
        }
        return rows
    }

    /// The emphasized bottom line.
    ///
    /// Its label is `CompletenessCopy`'s, never the screen's: a `.partial`
    /// selection reads "Known so far", a selection with a tip-out reads
    /// "You kept", and a selection with wages off reads "Tips". No screen
    /// writes `tipOut > 0 ? "You kept" : "Total"` again.
    static func total(_ result: EarningsResult) -> BreakdownRow {
        let figure = EarningsFigure.earnedIncome(result)
        return BreakdownRow(figure.label, cents: figure.cents, emphasized: true)
    }

    /// The collapsed lip: the one or two figures that have to reconcile to
    /// the hero directly above them.
    ///
    /// It used to show gross cash + credit, which sum to MORE than the hero
    /// (tip-out is already out of the hero, wages are already in), so the
    /// closed card presented two figures that could not be squared.
    static func lipText(_ result: EarningsResult) -> String {
        let components = result.knownComponents
        if components.tipOutCents > 0 {
            return "Earned \(Money.string(fromCents: components.grossBeforeTipOutCents))"
                + " · Tipped out \(Money.string(fromCents: components.tipOutCents))"
        }
        if components.gratuityFeesCents > 0 {
            return "Tips \(Money.string(fromCents: components.voluntaryTipsCents))"
                + " · Gratuity \(Money.string(fromCents: components.gratuityFeesCents))"
        }
        return "Cash \(Money.string(fromCents: components.voluntaryCashCents))"
            + " · Credit \(Money.string(fromCents: components.voluntaryCreditCents))"
    }

    /// A row's amount as it renders: negatives take a real U+2212 minus, and
    /// a figure the engine could not produce takes the placeholder rather
    /// than `$0.00` (PR 5 adapter contract, rule 4).
    static func amountText(_ cents: Int?) -> String {
        guard let cents else { return ShiftDayRow.unavailablePlaceholder }
        return cents < 0 ? "−\(Money.string(fromCents: -cents))" : Money.string(fromCents: cents)
    }

    /// Whether there is anything worth opening the drawer for. A selection
    /// with no tips at all (a wage-only shift) has no decomposition to show.
    static func hasBreakdown(_ result: EarningsResult) -> Bool {
        let components = result.knownComponents
        return components.voluntaryCashCents > 0
            || components.voluntaryCreditCents > 0
            || components.gratuityFeesCents > 0
    }
}

/// Fires the shared open/close animation for a hero's tucked breakdown
/// drawer — light haptic + a touch of overshoot so the drawer lands with a
/// small bounce (poppy, not dramatic, Tyler's call) — so every hero built on
/// HeroBreakdownDrawer toggles identically, whether the tap lands on the
/// card's tap gesture or a VoiceOver accessibility action. Reduce Motion
/// drops the spring/slide entirely — the drawer just snaps to its new state.
@MainActor
enum HeroBreakdownToggle {
    static func fire(_ isExpanded: Binding<Bool>, reduceMotion: Bool) {
        PaydayHaptics.lightTap()
        if reduceMotion {
            isExpanded.wrappedValue.toggle()
        } else {
            withAnimation(PaydayAnimation.drawerSpring) {
                isExpanded.wrappedValue.toggle()
            }
        }
    }
}

/// The "hero card + tucked breakdown drawer" pattern shared by every hero in
/// the app (Dashboard, Period Detail): a lifted card sits above a
/// fieldBackground recess — a UnevenRoundedRectangle, square top / rounded
/// bottom — tucked `-PaydayRadius.xl + 2` underneath it, so the drawer reads
/// as a slice of one grey surface peeking out from behind the card, never a
/// second card (one raised object per screen; the drawer is a recess, not a
/// lift). ONE surface, ONE motion: expanding slides the grey shape's bottom
/// edge down with `PaydayAnimation.drawerSpring` while the rows themselves
/// are static ink revealed by the clipShape — `.transition(.opacity)` only,
/// never `.move` (a `.move` on the rows reads as a second drawer sliding out
/// from under the first, not the one shape simply opening further). The
/// chevron rotates 180° rather than swapping symbols, which would pop
/// mid-animation. Lip padding stays constant across both states so nothing
/// else shifts when it expands.
///
/// `card` is caller-supplied (and responsible for its own `.paydayCard()`)
/// so each hero keeps its own face content and its own VoiceOver grouping —
/// this component only owns the drawer and the shared tap-to-toggle physics.
struct HeroBreakdownDrawer<Card: View>: View {
    let lipText: String
    let rows: [BreakdownRow]
    let total: BreakdownRow
    let hasBreakdown: Bool
    @Binding var isExpanded: Bool
    @ViewBuilder let card: () -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            card()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard hasBreakdown else { return }
                    HeroBreakdownToggle.fire($isExpanded, reduceMotion: reduceMotion)
                }
                .zIndex(1)

            if hasBreakdown {
                drawer
                    .padding(.top, -PaydayRadius.xl + 2)
                    .zIndex(0)
            }
        }
    }

    /// Collapsed: a lip showing the caller's summary text with a chevron.
    /// Expanded: the itemized rows plus the bottom Total line.
    private var drawer: some View {
        let drawerShape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: PaydayRadius.xl,
                               bottomTrailing: PaydayRadius.xl, topTrailing: 0),
            style: .continuous
        )
        return VStack(spacing: 0) {
            // Collapsed lip: extra top padding clears the slice tucked
            // behind the card.
            HStack(spacing: PaydaySpacing.p8) {
                Text(lipText)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, PaydaySpacing.p20)
            .padding(.top, PaydayRadius.xl + PaydaySpacing.p12)
            // Constant in both states — a padding that changes with the
            // toggle is one more thing shifting mid-animation.
            .padding(.bottom, PaydaySpacing.p12)

            if isExpanded {
                VStack(spacing: PaydaySpacing.p8) {
                    ForEach(rows) { row in
                        if row.dividerAbove { Divider() }
                        breakdownRow(row)
                    }
                    Divider()
                    breakdownRow(total)
                }
                .padding(.horizontal, PaydaySpacing.p20)
                .padding(.bottom, PaydaySpacing.p20)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(drawerShape.fill(PaydayColor.fieldBackground))
        .clipShape(drawerShape)
    }

    private func breakdownRow(_ row: BreakdownRow) -> some View {
        HStack {
            Text(row.label)
                .font(row.emphasized ? PaydayFont.subheadline : PaydayFont.footnote)
                .foregroundStyle(row.emphasized ? PaydayColor.textPrimary : PaydayColor.textSecondary)
            Spacer(minLength: 0)
            Text(BreakdownRow.amountText(row.cents))
                .font(row.emphasized ? PaydayFont.subheadline : PaydayFont.footnote)
                .foregroundStyle(row.emphasized ? PaydayColor.textPrimary : PaydayColor.textSecondary)
                .monospacedDigit()
        }
    }

}
