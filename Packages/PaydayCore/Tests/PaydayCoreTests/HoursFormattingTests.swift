import Foundation
import Testing
@testable import PaydayCore

/// Fixture E1's contract, against the real formatter.
///
/// E1 was one of the two golden fixtures with no engine-level assertion. It
/// names three wrong answers explicitly, which is the useful part: a test that
/// only checked `6.3833` would pass against a formatter that got there by a
/// coincidence of rounding.
@Suite("Hours formatting (fixture E1)")
struct HoursFormattingTests {
    /// 383 minutes is 6h23m. The shipped CSV exporter rounded this to the
    /// quarter hour and wrote 6.5, contradicting the punches-are-literal
    /// ruling. A payroll dispute is argued from the exported file.
    @Test("E1: 383 minutes exports as 6.3833 and 6:23")
    func e1RendersBothWays() {
        #expect(HoursFormatting.decimalHours(minutes: 383) == "6.3833")
        #expect(HoursFormatting.clockHours(minutes: 383) == "6:23")
    }

    /// The three answers E1 declares wrong, refused by name.
    @Test("E1: the quarter-hour, one-decimal and two-decimal answers are all refused")
    func e1RefusesTheWrongAnswers() {
        let decimal = HoursFormatting.decimalHours(minutes: 383)
        #expect(decimal != "6.5", "quarter-hour rounding, what the shipped exporter did")
        #expect(decimal != "6.4", "one decimal place")
        #expect(decimal != "6.38", "two decimal places")
    }

    /// The adapter's half of E1: the same 383 minutes must come back out of
    /// the legacy Double, or the wage math and the export disagree.
    @Test("E1: the legacy hours Double round-trips to 383 minutes")
    func e1RoundTripsThroughTheLegacyDouble() {
        #expect(HoursFormatting.minutes(fromHours: 6.383333333333334) == 383)
    }

    /// Rounded, not truncated. Multiplying by 60 lands just under an integer
    /// for some inputs, and truncation would lose a minute silently.
    @Test("minutes are rounded rather than truncated")
    func minutesRoundRatherThanTruncate() {
        #expect(HoursFormatting.minutes(fromHours: 0.9999999999) == 60)
        #expect(HoursFormatting.minutes(fromHours: 6.5) == 390)
        #expect(HoursFormatting.minutes(fromHours: 0) == 0)
    }

    /// Half-up at the fourth place. One minute is 0.016666…, which must not
    /// render 0.0166.
    @Test("the fourth decimal place rounds half-up")
    func fourthPlaceRoundsHalfUp() {
        #expect(HoursFormatting.decimalHours(minutes: 1) == "0.0167")
        #expect(HoursFormatting.decimalHours(minutes: 5) == "0.0833")
        #expect(HoursFormatting.decimalHours(minutes: 50) == "0.8333")
    }

    /// Fixed width, trailing zeros kept. A spreadsheet column of mixed
    /// precision is harder to compute on, and this file exists to be computed
    /// on.
    @Test("whole hours keep four decimal places")
    func wholeHoursKeepTheirPlaces() {
        #expect(HoursFormatting.decimalHours(minutes: 360) == "6.0000")
        #expect(HoursFormatting.decimalHours(minutes: 0) == "0.0000")
        #expect(HoursFormatting.clockHours(minutes: 360) == "6:00")
    }

    @Test("minutes under an hour and over a day both render")
    func edgesRender() {
        #expect(HoursFormatting.clockHours(minutes: 23) == "0:23")
        #expect(HoursFormatting.decimalHours(minutes: 23) == "0.3833")
        // A 26-hour total is real for a pay period column, and must not wrap.
        #expect(HoursFormatting.clockHours(minutes: 1_560) == "26:00")
        #expect(HoursFormatting.decimalHours(minutes: 1_560) == "26.0000")
    }

    /// Negative minutes are not a legitimate shift, but a correction column
    /// can carry one, and it must not render as a wrapped positive.
    @Test("a negative duration keeps its sign in both renderings")
    func negativesKeepTheirSign() {
        #expect(HoursFormatting.decimalHours(minutes: -383) == "-6.3833")
        #expect(HoursFormatting.clockHours(minutes: -383) == "-6:23")
    }
}
