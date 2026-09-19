import SwiftUI

/// The calendar grid's heat ramp: how strongly a day's tile is filled, given
/// where that day's earnings sit between zero and the month's best day.
///
/// A MAGNITUDE encoding, never a figure. It takes a fraction and returns an
/// opacity; no cents reach it. The tile prints the dollar amount itself, so
/// the fill only has to make the month's shape legible at a glance.
///
/// **Four steps, not a curve.** Three continuous ramps shipped on this grid
/// and two were reversed by eye — the hue walk (2026-07-19) and the linear
/// opacity (2026-07-20) — because nothing ever measured one. `fillOpacity`
/// was a private function on a `View` with no test, so "this reads better on
/// my phone" was the only evidence anyone could bring, and it pointed a
/// different direction each time.
///
/// Measured on a real month — Tyler's August, ten worked days from $52 to
/// $264 — the squared ramp this replaces separated adjacent ordinary days by
/// 0.015 to 0.056 alpha. $96 and $104 differed by 0.018; $134 and $139 by
/// 0.015. Neither is a difference anyone can see.
///
/// The cause was the curve, not the colour. Squaring was documented as
/// spending "more of the range on the differences that actually exist between
/// ordinary days" and it does the exact opposite: a square expands the TOP of
/// the range, where one outlier day sits by itself, and compresses the lower
/// middle, which is where every ordinary day actually is. The best day defines
/// the maximum, so the best day is always alone up there.
///
/// **Cut on magnitude, not rank.** True quartiles rank the days and spread
/// them evenly across four levels, which would put $96 and $104 in different
/// tiers — stating a difference of 8% as a difference of one whole step. Equal
/// money has to read equal, so the cuts are on the fraction itself. The cost
/// is that a month of near-identical days fills as one flat tier, which is
/// what a month of near-identical days should look like.
///
/// The green is Tyler's call (2026-07-28): every worked day is
/// `PaydayColor.primary` and heat is carried by opacity alone. That decision
/// was not the thing that was broken, and this does not revisit it.
enum CalendarHeat {
    /// The fill alpha of each step, quietest first.
    ///
    /// The floor stays the 0.22 Tyler tuned by looking at both modes, so the
    /// faintest worked day still reads as green rather than fading toward
    /// grey. The ceiling stays 1.0, so the month's best day reads at full
    /// intensity — each month self-normalizes, so each month has one.
    static let steps: [Double] = [0.22, 0.45, 0.70, 1.00]

    /// Which step a fraction falls in. Quarters of the magnitude range.
    ///
    /// Boundaries are inclusive at the top of each step so that a day sitting
    /// exactly on a cut lands in the quieter tier, and only a day that IS the
    /// month's best (fraction 1.0) reaches the top step.
    static func step(fraction: Double) -> Int {
        let clamped = min(1, max(0, fraction))
        if clamped <= 0.25 { return 0 }
        if clamped <= 0.50 { return 1 }
        if clamped <= 0.75 { return 2 }
        return 3
    }

    static func fillOpacity(fraction: Double) -> Double {
        steps[step(fraction: fraction)]
    }

    /// The page colour each mode composites the fill over.
    static func backgroundComponents(for colorScheme: ColorScheme) -> (r: Double, g: Double, b: Double) {
        if colorScheme == .dark {
            return (0.0196, 0.0196, 0.0196) // #050505
        }
        return (0.9804, 0.9804, 0.9804) // #FAFAFA
    }

    /// Contrast computed against the fill as it ACTUALLY composites —
    /// `PaydayColor.primary` at this step's alpha, blended over the mode's
    /// page background — rather than assumed. Picks the higher-contrast
    /// black/white foreground by WCAG's gamma-correct relative luminance, so
    /// every point on the ramp stays legible.
    static func textColor(fraction: Double, colorScheme: ColorScheme) -> Color {
        contrastRatios(fraction: fraction, colorScheme: colorScheme).black >= contrastRatios(
            fraction: fraction, colorScheme: colorScheme).white ? .black : .white
    }

    /// The two candidate contrast ratios, exposed so a test can assert the
    /// CHOSEN one clears a threshold rather than merely assert which colour
    /// came back. A ramp step can pick the better of two illegible options.
    static func contrastRatios(
        fraction: Double, colorScheme: ColorScheme
    ) -> (black: Double, white: Double) {
        let alpha = fillOpacity(fraction: fraction)
        let bg = backgroundComponents(for: colorScheme)
        let fgR = 0.0
        let fgG = colorScheme == .dark ? 0.7216 : 0.5216 // #00B83F / #00852F
        let fgB = colorScheme == .dark ? 0.2471 : 0.1843
        let r = fgR * alpha + bg.r * (1 - alpha)
        let g = fgG * alpha + bg.g * (1 - alpha)
        let b = fgB * alpha + bg.b * (1 - alpha)
        let luminance = 0.2126 * linearized(r) + 0.7152 * linearized(g) + 0.0722 * linearized(b)
        return ((luminance + 0.05) / 0.05, 1.05 / (luminance + 0.05))
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
