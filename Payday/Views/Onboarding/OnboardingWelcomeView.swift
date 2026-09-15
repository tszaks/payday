import SwiftUI

/// The first screen of a new install.
///
/// Rebuilt 2026-09-14. The previous version stacked three identical cards —
/// tonight, this period, payday — which was a feature tour wearing the costume
/// of data: three invented dashboards belonging to a stranger, shown to
/// someone with no shifts logged. It had no focal object either, in breach of
/// DESIGN.md rule 9, because three things of equal weight fight rather than
/// lead, and its slack split into three awkward gaps.
///
/// This version does three things instead:
///
/// 1. **Opens a loop rather than listing features.** The hook is the question
///    a tipped worker genuinely cannot answer about their own income. Nothing
///    is asserted about the reader, so nothing here is unsubstantiated.
/// 2. **One focal object.** A single card, and the count-up is what draws the
///    eye to it — so it can lead without having to be the largest thing on
///    screen. The paycheck promise, the app's real differentiator, gets one
///    quiet line instead of a third competing card.
/// 3. **Composes the slack.** Brand, hook, and card form one centered block
///    and the CTA is pinned by `safeAreaInset`, so the leftover space collects
///    in one place instead of three.
///
/// Motion follows Emil Kowalski's frequency rule: an install sees this once,
/// which is the one place delight is affordable. Entrances stagger inside the
/// 30-80ms band on a strong ease-out, and the CTA arrives before the count
/// finishes so decoration never gates the tap.
struct OnboardingWelcomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onStart: () -> Void
    var onReturning: () -> Void

    @State private var hasAppeared = false
    @State private var hasCounted = false

    /// The illustrative night on the demo card. A round, ordinary Friday —
    /// not a brag figure, since an implausible number reads as marketing.
    private let demoNightDollars = 186

    var body: some View {
        // Exactly two Spacers, both at the ends. Putting one between every
        // element — the first attempt here — splits the leftover space evenly
        // and the composition floats: a gap under the subhead as large as the
        // gap under the card, and a closing line orphaned in the middle of
        // nowhere. Fixed gaps inside, slack only at the edges, so this reads
        // as one centered block.
        VStack(spacing: 0) {
            Spacer(minLength: PaydaySpacing.md)

            brandSignature
                .modifier(Entrance(isVisible: hasAppeared, delay: 0, reduceMotion: reduceMotion))
                .padding(.bottom, PaydaySpacing.xl)

            hook
                .padding(.bottom, PaydaySpacing.lg)

            demoCard
                .modifier(Entrance(isVisible: hasAppeared, delay: 0.18, reduceMotion: reduceMotion))
                .padding(.bottom, PaydaySpacing.sm)

            Text("Come payday, it knows what your check should say.")
                .font(PaydayFont.footnote)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
                .modifier(Entrance(isVisible: hasAppeared, delay: 0.24, reduceMotion: reduceMotion))

            Spacer(minLength: PaydaySpacing.md)
        }
        .padding(.horizontal, PaydaySpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        .safeAreaInset(edge: .bottom) { callsToAction }
        .onAppear { hasAppeared = true }
    }

    // MARK: - Pieces

    /// The name is a quiet signature here, not the headline. The hook below is
    /// the hero; an app that has just been installed does not need to shout
    /// its own name back at the person who chose it.
    private var brandSignature: some View {
        VStack(spacing: PaydaySpacing.xs) {
            Image("BrandMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .foregroundStyle(PaydayColor.primary)
                .accessibilityHidden(true)

            Text("PAYDAY")
                .font(PaydayFont.caption)
                .tracking(1.8)
                .foregroundStyle(PaydayColor.textSecondary)
        }
    }

    private var hook: some View {
        VStack(spacing: PaydaySpacing.sm) {
            Text("What did you make on your last shift?")
                .font(PaydayFont.displayLarge)
                .foregroundStyle(PaydayColor.textPrimary)
                .multilineTextAlignment(.center)
                .modifier(Entrance(isVisible: hasAppeared, delay: 0.06, reduceMotion: reduceMotion))

            Text("Most people have to guess.")
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
                .modifier(Entrance(isVisible: hasAppeared, delay: 0.12, reduceMotion: reduceMotion))
        }
    }

    /// The one focal object: Payday's post-log reveal, the moment the whole
    /// product is built around (PRODUCT.md Pillar 1). Label, amount, evidence
    /// — the same three-part shape every real card in the app uses, so this is
    /// a true sample of the product rather than an illustration of it.
    private var demoCard: some View {
        VStack(alignment: .leading, spacing: PaydaySpacing.xxs) {
            Text("LAST FRIDAY")
                .font(PaydayFont.caption3)
                .tracking(0.6)
                .foregroundStyle(PaydayColor.textSecondary)

            OnboardingCountUp(
                targetDollars: demoNightDollars,
                font: PaydayFont.displayLarge,
                duration: 0.9,
                startDelay: 0.34,
                onSettle: { hasCounted = true }
            )

            // Held in the layout from the start rather than inserted, so the
            // card cannot change height underneath the composition when the
            // evidence line arrives.
            Text("Your third-best night this period.")
                .font(PaydayFont.footnote)
                .foregroundStyle(PaydayColor.textSecondary)
                .opacity(reduceMotion || hasCounted ? 1 : 0)
                .animation(reduceMotion ? nil : PaydayAnimation.entrance, value: hasCounted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paydayCard(padding: PaydaySpacing.md, cornerRadius: PaydayRadius.xl)
    }

    private var callsToAction: some View {
        VStack(spacing: PaydaySpacing.xs) {
            Button(action: onStart) {
                Text("Get Started")
                    .font(PaydayFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PaydaySpacing.xxs)
            }
            .buttonStyle(.glassProminent)
            .tint(PaydayColor.primary)

            Button("I've used Payday before", action: onReturning)
                .font(PaydayFont.body)
                .foregroundStyle(PaydayColor.textPrimary)
                .buttonStyle(PressableButtonStyle())
                .padding(.top, PaydaySpacing.xxs)
        }
        .padding(.horizontal, PaydaySpacing.md)
        .padding(.bottom, PaydaySpacing.xs)
        // Arrives early and on its own short delay: a decorative stagger must
        // never stand between someone and the button they came to press.
        .modifier(Entrance(isVisible: hasAppeared, delay: 0.1, reduceMotion: reduceMotion))
    }
}

// MARK: - Entrance

/// Fade plus a short rise, on a staggered delay. Nothing scales up from
/// nothing and nothing travels far — the movement is only enough to give the
/// arrival a direction.
private struct Entrance: ViewModifier {
    let isVisible: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 10)
            .animation(
                reduceMotion ? nil : PaydayAnimation.entrance.delay(delay),
                value: isVisible
            )
    }
}

#Preview {
    OnboardingWelcomeView(onStart: {}, onReturning: {})
}
