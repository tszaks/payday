import SwiftUI
import Testing
@testable import Payday

/// The heat ramp had no test for its entire existence. Three designs shipped
/// on this grid and two were reversed by eye, which is what happens when the
/// only available evidence is "it reads better to me": the next person looks
/// at a different month on a different screen and it reads better the other
/// way. These are the properties a ramp has to have, stated as numbers, so a
/// fourth redesign has something to disagree with.
@Suite("Calendar heat ramp")
struct CalendarHeatTests {
    /// The smallest alpha difference two tiles can differ by and still be
    /// told apart on a phone in daylight. The ramp this replaced put eight of
    /// ten of Tyler's August days inside 0.056 of each other.
    static let perceptibleAlpha = 0.15

    @Test("neighbouring steps differ by an alpha a person can actually see")
    func stepsAreDistinguishable() {
        let steps = CalendarHeat.steps
        #expect(steps.count == 4)
        let gaps = zip(steps, steps.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= Self.perceptibleAlpha },
                "gaps \(gaps) — a step below \(Self.perceptibleAlpha) is a step nobody sees")
        // Strictly increasing: a brighter day never fills fainter.
        #expect(gaps.allSatisfy { $0 > 0 })
    }

    @Test("the floor keeps the quietest worked day green, and the best day fills completely")
    func floorAndCeiling() {
        // 0.22 is the value Tyler tuned across both modes so the faintest
        // worked day reads as green rather than fading toward grey.
        #expect(CalendarHeat.steps.first == 0.22)
        // Each month self-normalizes, so each month HAS a best day, and it
        // reads at full intensity.
        #expect(CalendarHeat.fillOpacity(fraction: 1.0) == 1.0)
    }

    /// The defect, stated as the case that exposed it. Under the squared ramp
    /// these two differed by 0.018 alpha.
    @Test("$104 and $139 against a $264 month no longer fill identically")
    func theDayTylerCouldNotTellApart() {
        let monthMax = 264.0
        let a = CalendarHeat.fillOpacity(fraction: 104 / monthMax)
        let b = CalendarHeat.fillOpacity(fraction: 139 / monthMax)
        #expect(b - a >= Self.perceptibleAlpha, "104 -> \(a), 139 -> \(b)")
    }

    /// The reason the cuts are on magnitude and not on rank. Ranked into
    /// quartiles, these two land in different tiers and the grid states an 8%
    /// difference as one whole step of heat.
    @Test("two days within 8% of each other fill the same, because they are the same")
    func equalMoneyReadsEqual() {
        let monthMax = 264.0
        #expect(CalendarHeat.fillOpacity(fraction: 96 / monthMax)
                == CalendarHeat.fillOpacity(fraction: 104 / monthMax))
    }

    @Test("a day with nothing on it sits at no step of the ramp at all")
    func zeroIsNotAStep() {
        // The grid never asks for this — `hasTips` gates the fill — but a
        // fraction outside 0...1 must not index off the end of `steps`.
        #expect(CalendarHeat.step(fraction: 0) == 0)
        #expect(CalendarHeat.step(fraction: -1) == 0)
        #expect(CalendarHeat.step(fraction: 2) == CalendarHeat.steps.count - 1)
        #expect(CalendarHeat.step(fraction: .nan) >= 0)
    }

    /// Asserting WHICH colour came back proves nothing: a step can pick the
    /// better of two illegible options. This asserts the chosen one clears
    /// WCAG AA for the tile's bold small text, at every step, in both modes.
    @Test("every step stays legible in both modes, not merely better than the alternative")
    func everyStepIsLegible() {
        for (index, _) in CalendarHeat.steps.enumerated() {
            // A fraction landing squarely inside each step.
            let fraction = [0.1, 0.4, 0.65, 1.0][index]
            for scheme in [ColorScheme.light, .dark] {
                let ratios = CalendarHeat.contrastRatios(fraction: fraction, colorScheme: scheme)
                let chosen = max(ratios.black, ratios.white)
                #expect(chosen >= 4.5,
                        "step \(index) in \(scheme) composites to contrast \(chosen)")
            }
        }
    }

    @Test("a month whose days are all alike fills as one tier, not a manufactured gradient")
    func aFlatMonthLooksFlat() {
        let monthMax = 200.0
        let alike = [188.0, 192.0, 196.0, 200.0].map {
            CalendarHeat.fillOpacity(fraction: $0 / monthMax)
        }
        #expect(Set(alike).count == 1, "\(alike)")
    }
}
