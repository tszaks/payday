import Foundation

/// How worked time is written down, in one place.
///
/// **Both renderings derive from integer minutes, never from a `Double`.**
/// `ShiftTimes` produces a decimal like `6.383333333333334`, and formatting
/// that directly invites two different bugs: a float that prints one digit
/// differently on another platform, and the temptation to "tidy" it by
/// rounding. Minutes are exact, so both strings below are exact functions of
/// the same integer.
///
/// **Nothing here rounds to a quarter hour.** The shipped CSV exporter did —
/// `String(format: "%.2f", (hours * 4).rounded() / 4)` — which turned a
/// 6h23m shift into `6.5` and contradicted PRODUCT.md's punches-are-literal
/// ruling of 2026-07-19. That is not a display nicety: a payroll dispute is
/// argued from the exported file, and 6.5 is not what the person worked.
/// Fixture E1 pins `6.3833` and names `6.5`, `6.4` and `6.38` as wrong
/// answers so the rounding cannot come back by accident.
public enum HoursFormatting {
    /// `383` minutes becomes `"6.3833"`.
    ///
    /// Four decimal places, always, including trailing zeros: a spreadsheet
    /// column of mixed precision is harder to compute on than one with a
    /// fixed width, and this file exists to be computed on.
    ///
    /// Half-up at the fourth place, in integer arithmetic. 383 minutes is
    /// 6.38333… hours, whose fourth place is a 3 either way, but a value like
    /// 1 minute is 0.016666… and must render `0.0167` rather than `0.0166`.
    public static func decimalHours(minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : ""
        let magnitude = abs(minutes)
        // (m / 60) to four places, half-up, without ever touching a Double.
        let tenThousandths = (magnitude * 10_000 + 30) / 60
        let whole = tenThousandths / 10_000
        let fraction = tenThousandths % 10_000
        return "\(sign)\(whole).\(String(format: "%04d", fraction))"
    }

    /// `383` minutes becomes `"6:23"`.
    ///
    /// The human rendering beside the machine one, because a server reading
    /// the file recognises their shift as 6:23 and not as 6.3833.
    public static func clockHours(minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : ""
        let magnitude = abs(minutes)
        return "\(sign)\(magnitude / 60):\(String(format: "%02d", magnitude % 60))"
    }

    /// The conversion the adapter performs, in one place so the CSV and the
    /// ledger cannot disagree about what 6.3833 hours means in minutes.
    ///
    /// Rounded rather than truncated: `6.383333333333334 * 60` is
    /// `383.00000000000006` on some inputs and `382.99999999999994` on
    /// others, and truncation would silently lose a minute.
    public static func minutes(fromHours hours: Double) -> Int {
        Int((hours * 60).rounded())
    }
}
