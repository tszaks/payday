import Foundation

/// The live shift band's elapsed readout, matching Text(timerInterval:)'s
/// own format so swapping the renderer changed nothing visually: MM:SS
/// under an hour, H:MM:SS from the hour mark on. Pure so the digit-rolling
/// TimelineView clock (see LiveShiftClock) stays a dumb renderer.
enum ElapsedClock {
    static func string(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
