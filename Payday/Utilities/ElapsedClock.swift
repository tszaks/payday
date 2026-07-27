import Foundation

/// The live shift band's elapsed readout: always H:MM:SS ("0:00:07" from
/// the very first second) — Tyler's call, so the clock never changes shape
/// mid-shift. The hour digit stays single (Apple's own post-hour grammar)
/// rather than zero-padded. Pure so the digit-rolling TimelineView clock
/// (see LiveShiftClock) stays a dumb renderer.
enum ElapsedClock {
    static func string(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
