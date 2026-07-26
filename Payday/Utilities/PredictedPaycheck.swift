import Foundation

/// The single formula for "what the stub's tips line should read" for a
/// period — shared by the Dashboard's payday moment, the period detail
/// screen, and the payday push notification, so the number on a lock-screen
/// banner and the number in the app can never quietly drift apart.
/// Credit tips are what land on a stub; cash never does. Falls back to gross
/// (cash + credit) only when no credit tips were logged at all, so a
/// cash-only period still gets a number to check against.
enum PredictedPaycheck {
    static func cents(from breakdown: TipBreakdown) -> Int {
        breakdown.creditCents > 0 ? breakdown.creditCents : breakdown.grossTotalCents
    }

    static func hasCreditTips(_ breakdown: TipBreakdown) -> Bool {
        breakdown.creditCents > 0
    }
}
