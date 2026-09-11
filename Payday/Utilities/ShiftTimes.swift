import Foundation

/// Turns a shift's clock-in/out into hours worked, so nobody hand-counts
/// "9:30, 10:30, 11:30…" — the app does the math. Pure and calendar-aware,
/// testable without SwiftData.
enum ShiftTimes {
    /// Payday's canonical lunch/dinner boundary. This matches the analytics
    /// fallback: a shift starting before 4 PM is lunch; 4 PM or later is
    /// dinner. The form can still override the inferred value explicitly.
    static func period(for start: Date, calendar: Calendar = .current) -> ShiftPeriod {
        let hour = calendar.component(.hour, from: start)
        return hour < 16 ? .lunch : .dinner
    }

    /// Hours between two times-of-day, wrap-aware: an overnight closeout
    /// (in 5 PM, out 1:30 AM) measures forward across midnight. Only the
    /// hour/minute components matter — the dates the pickers happen to
    /// carry are ignored, so a shift whose date gets edited later doesn't
    /// corrupt its length. EXACT — every minute, never rounded to the
    /// nearest quarter hour: a punch is literal (Tyler's law), and wages
    /// compute off this value, so rounding it would round pay too. Nil
    /// unless both ends are set; equal times read as "not set" rather than
    /// a 24-hour shift.
    static func hours(clockIn: Date?, clockOut: Date?, calendar: Calendar = .current) -> Double? {
        guard let clockIn, let clockOut else { return nil }
        let inComponents = calendar.dateComponents([.hour, .minute], from: clockIn)
        let outComponents = calendar.dateComponents([.hour, .minute], from: clockOut)
        let inMinutes = (inComponents.hour ?? 0) * 60 + (inComponents.minute ?? 0)
        let outMinutes = (outComponents.hour ?? 0) * 60 + (outComponents.minute ?? 0)
        let deltaMinutes = (outMinutes - inMinutes + 1440) % 1440
        guard deltaMinutes > 0 else { return nil }
        return Double(deltaMinutes) / 60.0
    }
}
