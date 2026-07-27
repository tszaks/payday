import SwiftUI

/// One breakdown row: a label and its dollar amount. A negative `cents`
/// renders with a minus sign (e.g. "Tipped out"); `emphasized` bolds the
/// row for the bottom Total line.
struct BreakdownRow: Identifiable {
    let id = UUID()
    let label: String
    let cents: Int
    let emphasized: Bool

    init(_ label: String, cents: Int, emphasized: Bool = false) {
        self.label = label
        self.cents = cents
        self.emphasized = emphasized
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
            Text(row.cents < 0 ? "−\(Money.string(fromCents: -row.cents))" : Money.string(fromCents: row.cents))
                .font(row.emphasized ? PaydayFont.subheadline : PaydayFont.footnote)
                .foregroundStyle(row.emphasized ? PaydayColor.textPrimary : PaydayColor.textSecondary)
                .monospacedDigit()
        }
    }
}
