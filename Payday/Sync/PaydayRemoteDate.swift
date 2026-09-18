import Foundation

/// Wire-format date helpers, extracted VERBATIM from `PaydayRemoteModels.swift`
/// so the widget target can compile `PaydaySyncState.swift` without also
/// compiling 900 lines of remote models it never uses.
///
/// The move is what makes the sync checkpoint readable out of process. The
/// widget needs exactly one fact from that checkpoint —
/// `shiftsAreAuthoritativeForCurrentAccount` — and `PaydaySyncState` parses
/// timestamps with this enum, so the file would not build in the widget
/// target without it. The alternative was a second copy of the flag on a
/// standalone App Group key, which `design-lint.sh` pins against precisely
/// because `AppGroup.swift` is already in the widget target: such a copy
/// would compile, and nothing would cover the divergence while the Lock
/// Screen showed pre-conversion numbers and the app showed post-conversion
/// ones.
///
/// No behaviour change. Foundation only; `CryptoKit` stays with the models
/// that hash, which this does not.
enum PaydayRemoteDate {
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let standardFormatter = ISO8601DateFormatter()

    /// The one calendar `stableDay` renders in. Fixed at UTC on purpose: see
    /// `stableDay`.
    nonisolated(unsafe) private static let fixedDayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// The calendar day a stored date names, as a pure function of the instant
    /// — it does not depend on where the device is now. Used for VERSIONING a
    /// local row, never for the wire value (see `RemoteTipEntry.businessValue`
    /// for why those are deliberately separate).
    ///
    /// Every date this app persists is local midnight in whatever zone the row
    /// was written in: `Calendar.current.startOfDay(...)` in ShiftWriter,
    /// LogTipSheet and `PayPeriodCalculator.period(containing:)`, or
    /// `parseDay` (which lands on local midnight too) on reconcile. Rendering
    /// such an instant back through `Calendar.current` is only correct while
    /// the device stays in the zone that wrote it: seen from any zone further
    /// west, midnight belongs to the PREVIOUS day. That is fatal for a version
    /// — `work_date` is inside the row's content fingerprint — because it
    /// would move every fingerprint in the history the first time the device
    /// flew west and put the whole history in the upload set with no user
    /// edit.
    ///
    /// No function of the instant alone can recover the intended day
    /// everywhere: inhabited UTC offsets span 25 hours (-11 through +14), so
    /// two different days collide. Midnight on Sep 5 in Kiritimati (UTC+14)
    /// and midnight on Sep 4 in Honolulu (UTC-10) are the SAME instant, and
    /// nothing stored in the row says which zone wrote it. So this picks a
    /// 24-hour window and names it: anchoring 13.5 hours past the stored
    /// instant and rendering in UTC returns the intended day for every offset
    /// in (UTC-10:30, UTC+13:30] — the Americas through New Zealand in summer
    /// time — with half an hour of slack at each edge for zones whose DST
    /// transition happens at midnight, where `startOfDay` lands at 01:00.
    ///
    /// Outside that window (UTC-11 and UTC+14, jointly under 60,000 people)
    /// this names the adjacent day. That costs a row one redundant upload of
    /// unchanged content on the seeding sync and nothing after, because the
    /// wire value is rendered separately and stays correct. A genuine date
    /// edit is a full 24 hours away, so it moves the digest from every zone.
    static func stableDay(_ date: Date) -> String {
        day(date.addingTimeInterval(13.5 * 3_600), calendar: fixedDayCalendar)
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    static func instant(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    static func parseDay(_ value: String, calendar: Calendar = .current) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func parseInstant(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
    }

    static func canonicalInstant(_ value: String?) -> String? {
        value.flatMap(parseInstant).map(instant)
    }
}
