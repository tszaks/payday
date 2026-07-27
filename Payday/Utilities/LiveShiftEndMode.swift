import Foundation

/// The exact punches a `.new` log sheet should adopt when it exists to close
/// out the shift already running, rather than log an unrelated new one.
struct LiveShiftEndMode: Equatable {
    let clockIn: Date
    let clockOut: Date
}

/// Pure resolver behind LogTipSheet's "every creation path becomes the
/// closeout while a shift runs" rule: fires only for a genuinely blank `.new`
/// target. Editing an existing shift, or a target that already carries its
/// own explicit punches (the pendingEnd-pop flow), is left untouched — those
/// already know exactly what they're logging.
enum LiveShiftEndModeResolver {
    static func resolve(isEditing: Bool, providedClockIn: Date?, providedClockOut: Date?, activeStart: Date?, now: Date = .now) -> LiveShiftEndMode? {
        guard !isEditing, providedClockIn == nil, providedClockOut == nil, let activeStart else { return nil }
        return LiveShiftEndMode(clockIn: activeStart, clockOut: now)
    }
}
