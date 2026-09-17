import Foundation

/// Hours enter the engine as whole minutes and leave as whole minutes. The
/// app stores `hoursWorked: Double` (what `ShiftTimes` produces from two
/// punches); the adapter converts it here, once, and every wage in the
/// engine is integer arithmetic on minutes (Design 1, "Arithmetic: integers
/// only"). The conversion is lossless for every value two punches can
/// produce: 383/60 hours is exactly 383 minutes after rounding.
public enum WorkedMinutes {
    /// `Int((hours * 60).rounded())`, the one conversion from decimal hours
    /// to minutes. Half-away-from-zero, matching `Double.rounded()`.
    public static func minutes(fromHours hours: Double) -> Int {
        Int((hours * 60).rounded())
    }

    /// Decimal hours for a minute count, `minutes / 60`. Exports format this
    /// themselves (E1 fixture: 383 minutes exports as "6.3833", never "6.5").
    public static func hours(fromMinutes minutes: Int) -> Double {
        Double(minutes) / 60
    }

    /// The exact hours label every user-facing hours display uses: "6h 23m".
    /// Minutes are omitted only when they are exactly zero ("5h"), never
    /// rounded away otherwise: a punch is literal. This is
    /// `WageEstimate.hoursLabel` (the app helper) restated on minutes so the
    /// two can never disagree once the app reads from the engine.
    public static func hoursLabel(minutes totalMinutes: Int) -> String {
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(wholeHours)h" : "\(wholeHours)h \(minutes)m"
    }
}
