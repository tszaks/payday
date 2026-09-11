import Foundation

/// Day-grouping and human labels for the Dashboard's Shifts list. A shift is
/// a day worked, not a row — one night is often two TipEntry rows (cash +
/// credit), and showing it as two events doubles the visual noise. Pure and
/// generic so it's testable without SwiftData.
enum ShiftDays {
    /// Groups items into calendar days, newest day first. Items within a day
    /// keep their given order.
    static func groupedByDay<T>(_ items: [T], date: (T) -> Date, calendar: Calendar = .current) -> [(day: Date, items: [T])] {
        var order: [Date] = []
        var buckets: [Date: [T]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order
            .sorted(by: >)
            .map { (day: $0, items: buckets[$0] ?? []) }
    }

    /// Groups items into shifts (one closeout), newest day first, and within
    /// a day ordered lunch → dinner so a double day's two rows read top to
    /// bottom. A shift is all items sharing a `shiftID`; items with a nil id
    /// (legacy rows not yet migrated) fall back to a stable day-derived id so
    /// nothing is ever dropped and all of a day's un-migrated rows stay one
    /// shift. Returns the day each shift belongs to alongside its id.
    static func groupedByShift<T>(
        _ items: [T],
        shiftID: (T) -> UUID?,
        date: (T) -> Date,
        period: (T) -> ShiftPeriod? = { _ in nil },
        calendar: Calendar = .current
    ) -> [(day: Date, shiftID: UUID, items: [T])] {
        var order: [UUID] = []
        var buckets: [UUID: [T]] = [:]
        for item in items {
            let id = shiftID(item) ?? deterministicShiftID(for: date(item), calendar: calendar)
            if buckets[id] == nil { order.append(id) }
            buckets[id, default: []].append(item)
        }

        // Sort key per shift: newest day first, then lunch before dinner
        // (nil period last), then earliest item as a stable tie-break.
        func periodRank(_ p: ShiftPeriod?) -> Int {
            switch p {
            case .lunch: return 0
            case .dinner: return 1
            case nil: return 2
            }
        }
        return order
            .map { id -> (day: Date, shiftID: UUID, items: [T]) in
                let group = buckets[id] ?? []
                let day = calendar.startOfDay(for: group.map(date).min() ?? .now)
                return (day: day, shiftID: id, items: group)
            }
            .sorted { lhs, rhs in
                if lhs.day != rhs.day { return lhs.day > rhs.day }
                let lp = periodRank(lhs.items.compactMap(period).first)
                let rp = periodRank(rhs.items.compactMap(period).first)
                if lp != rp { return lp < rp }
                let lEarliest = lhs.items.map(date).min() ?? .now
                let rEarliest = rhs.items.map(date).min() ?? .now
                return lEarliest < rEarliest
            }
    }

    /// The label for one shift's row. Shift labels stay structurally stable:
    /// every row shows its exact date and, when known, its period. This avoids
    /// making recent rows look like a different kind of record from older rows.
    /// A multiple-shift day with no saved periods can still fall back to an
    /// ordinal when its caller has one.
    static func shiftLabel(
        day: Date,
        period: ShiftPeriod?,
        dayHasMultipleShifts: Bool,
        ordinal: Int? = nil,
        relativeTo now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let base = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        if let period {
            return "\(base) · \(period.displayName)"
        }
        if dayHasMultipleShifts, let ordinal {
            return "\(base) · \(ordinalWord(ordinal))"
        }
        return base
    }

    private static func ordinalWord(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    /// A stable UUID for a calendar day — same day in, same UUID out, on any
    /// device, with no persistence. Used both by the shift-grouping fallback
    /// above and by MigrationRunner's legacy backfill so the two agree.
    static func deterministicShiftID(for someDate: Date, calendar: Calendar = .current) -> UUID {
        let dayIndex = Int(calendar.startOfDay(for: someDate).timeIntervalSinceReferenceDate / 86_400)
        var bytes = [UInt8](repeating: 0, count: 16)
        // Fixed prefix namespaces these ids so they can't collide with a
        // random UUID minted for a real new log.
        bytes[0] = 0x5A
        bytes[1] = 0xAC
        bytes[2] = 0x5D
        bytes[3] = 0x00
        let magnitude = UInt64(bitPattern: Int64(dayIndex))
        for i in 0..<8 {
            bytes[8 + i] = UInt8((magnitude >> (UInt64(i) * 8)) & 0xFF)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The label a person would use for the day: "Today", "Yesterday",
    /// a bare weekday inside the last week, then "Friday, Jul 11".
    /// The year is deliberately never shown — it's always this one.
    /// "Today" (not "Tonight") because a shift is a whole day: a lunch
    /// logged at 2pm is still today, and this label is read at any hour.
    static func humanLabel(for day: Date, relativeTo now: Date = .now, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0

        switch daysAgo {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return day.formatted(.dateTime.weekday(.wide))
        default: return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}
