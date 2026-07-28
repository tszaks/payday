import Foundation

/// The Dashboard's one context-aware sentence, composed from facts the
/// engines already computed. Pure so the "which line tonight?" decision is
/// unit-testable; the view just renders whatever this returns.
///
/// This is ONLY the reveal echo now — the "You usually work Fridays"
/// rhythm fallback was removed on Tyler's order (2026-07-28): the app
/// telling you your own schedule reads as noise, not insight. The slot
/// stays empty until something true about TONIGHT exists.
enum TonightLine {
    /// - Returns: the line to show between the hero card and the Shifts
    ///   list, or nil when there's nothing worth saying (nothing logged
    ///   today, or the payday moment owns the slot).
    static func compose(
        tonightRevealText: String?,
        isPaydayMoment: Bool
    ) -> String? {
        // The payday moment is the bigger statement; don't compete with it.
        if isPaydayMoment { return nil }
        return tonightRevealText
    }
}
