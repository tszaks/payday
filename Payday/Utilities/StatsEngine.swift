import Foundation

/// Plain, Sendable per-night fact — decoupled from SwiftData's TipEntry so
/// this stays a pure, easily-tested module, same pattern as
/// PayPeriodCalculator. Never crosses into money formatting or UI copy.
struct TipRecord: Sendable, Hashable {
    let date: Date
    let amountCents: Int
    let kind: TipKind
    let isDouble: Bool
    /// When this was logged — used only as a lunch-vs-dinner proxy, and only
    /// on the same calendar day it was earned (see InsightsFacts).
    let recordedAt: Date?

    init(date: Date, amountCents: Int, kind: TipKind, isDouble: Bool, recordedAt: Date? = nil) {
        self.date = date
        self.amountCents = amountCents
        self.kind = kind
        self.isDouble = isDouble
        self.recordedAt = recordedAt
    }
}

extension TipRecord {
    init(entry: TipEntry) {
        self.init(date: entry.date, amountCents: entry.amountCents, kind: entry.kind, isDouble: entry.isDouble, recordedAt: entry.recordedAt)
    }
}

/// What the post-log reveal is actually saying, before any copy is written.
/// The engine picks ONE true thing to lead with, in priority order: an
/// all-time record beats a weekday record beats a slow-night callout beats
/// the everyday weekday-average comparison.
enum RevealComparison: Equatable {
    case firstNightLogged
    case allTimeRecord(previousBestCents: Int)
    case firstShiftOfPeriod
    case weekdayRecord(weekday: Int, previousBestCents: Int)
    case slowestRecently
    case weekdayAverage(weekday: Int, deltaCents: Int, periodRank: Int?, periodNightCount: Int)
}

struct RevealResult: Equatable {
    let cents: Int
    let comparison: RevealComparison
    /// Drives the reveal's one flourish (green sweep + success haptic).
    let isRecord: Bool
}

/// A small pure module computing pace, records, baselines, and the post-log
/// reveal comparison. No I/O, no SwiftData — takes plain facts, returns
/// plain facts, fully unit-testable like PayPeriodCalculator.
struct StatsEngine {
    let records: [TipRecord]
    private let calendar: Calendar

    init(records: [TipRecord], calendar: Calendar = .current) {
        self.records = records
        var cal = calendar
        cal.timeZone = TimeZone.current
        self.calendar = cal
    }

    // MARK: Nightly totals

    /// One row per distinct calendar day with any logged record — a shift,
    /// not a row: one night can be two records (cash + credit).
    func nightlyTotals() -> [(date: Date, cents: Int)] {
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { (date: $0.key, cents: $0.value.reduce(0) { $0 + $1.amountCents }) }
            .sorted { $0.date < $1.date }
    }

    // MARK: Records

    func bestNightEver(excluding excludedDate: Date? = nil) -> (date: Date, cents: Int)? {
        nights(excluding: excludedDate).max { $0.cents < $1.cents }
    }

    func bestNight(in period: PayPeriod) -> (date: Date, cents: Int)? {
        nightlyTotals()
            .filter { $0.date >= period.start && $0.date <= period.end }
            .max { $0.cents < $1.cents }
    }

    func bestNight(forWeekday weekday: Int, excluding excludedDate: Date? = nil) -> (date: Date, cents: Int)? {
        nights(excluding: excludedDate)
            .filter { calendar.component(.weekday, from: $0.date) == weekday }
            .max { $0.cents < $1.cents }
    }

    func averageForWeekday(_ weekday: Int, excluding excludedDate: Date? = nil) -> Double? {
        let matching = nights(excluding: excludedDate).filter { calendar.component(.weekday, from: $0.date) == weekday }
        guard !matching.isEmpty else { return nil }
        return Double(matching.reduce(0) { $0 + $1.cents }) / Double(matching.count)
    }

    private func nights(excluding excludedDate: Date?) -> [(date: Date, cents: Int)] {
        guard let excludedDate else { return nightlyTotals() }
        return nightlyTotals().filter { !calendar.isDate($0.date, inSameDayAs: excludedDate) }
    }

    // MARK: Pace

    /// Sum of everything logged in `period`, through `date` (inclusive).
    func periodToDateTotal(period: PayPeriod, asOf date: Date) -> Int {
        let cutoff = min(calendar.startOfDay(for: date), period.end)
        return records
            .filter { $0.date >= period.start && $0.date <= cutoff }
            .reduce(0) { $0 + $1.amountCents }
    }

    /// The prior period's total through the same number of elapsed days —
    /// day 3 of this period vs. day 3 of last period, never vs. last
    /// period's grand total (that's not a fair pace comparison).
    func priorPeriodComparableTotal(currentPeriod: PayPeriod, priorPeriod: PayPeriod, asOf date: Date) -> Int {
        let daysElapsed = calendar.dateComponents([.day], from: currentPeriod.start, to: calendar.startOfDay(for: date)).day ?? 0
        guard let comparableEnd = calendar.date(byAdding: .day, value: daysElapsed, to: priorPeriod.start) else { return 0 }
        let cappedEnd = min(comparableEnd, priorPeriod.end)
        return records
            .filter { $0.date >= priorPeriod.start && $0.date <= cappedEnd }
            .reduce(0) { $0 + $1.amountCents }
    }

    // MARK: Anomalies

    func isFirstShiftOfPeriod(date: Date, period: PayPeriod) -> Bool {
        let day = calendar.startOfDay(for: date)
        return !records.contains { $0.date >= period.start && $0.date < day }
    }

    /// True when tonight is at or below the floor of the last `lookbackShifts`
    /// nights (excluding tonight itself). Needs at least 4 prior nights of
    /// history before it will ever fire — not enough data isn't an anomaly.
    func isSlowestRecently(date: Date, cents: Int, lookbackShifts: Int) -> Bool {
        let priorNights = nights(excluding: date)
        guard priorNights.count >= 4 else { return false }
        let recent = priorNights.suffix(lookbackShifts)
        guard let minCents = recent.map(\.cents).min() else { return false }
        return cents <= minCents
    }

    // MARK: Reveal

    /// Picks the one most interesting true thing about tonight, in priority
    /// order: all-time record, first shift of a period, weekday record,
    /// notably slow night, then the everyday weekday-average comparison.
    func reveal(forNightAt date: Date, cents: Int, period: PayPeriod) -> RevealResult {
        if bestNightEver(excluding: date) == nil {
            return RevealResult(cents: cents, comparison: .firstNightLogged, isRecord: false)
        }
        if let best = bestNightEver(excluding: date), cents > best.cents {
            return RevealResult(cents: cents, comparison: .allTimeRecord(previousBestCents: best.cents), isRecord: true)
        }
        if isFirstShiftOfPeriod(date: date, period: period) {
            return RevealResult(cents: cents, comparison: .firstShiftOfPeriod, isRecord: false)
        }
        let weekday = calendar.component(.weekday, from: date)
        if let bestWeekday = bestNight(forWeekday: weekday, excluding: date), cents > bestWeekday.cents {
            return RevealResult(cents: cents, comparison: .weekdayRecord(weekday: weekday, previousBestCents: bestWeekday.cents), isRecord: true)
        }
        if isSlowestRecently(date: date, cents: cents, lookbackShifts: 8) {
            return RevealResult(cents: cents, comparison: .slowestRecently, isRecord: false)
        }
        let average = averageForWeekday(weekday, excluding: date) ?? Double(cents)
        let deltaCents = cents - Int(average.rounded())
        let periodNights = nightlyTotals().filter { $0.date >= period.start && $0.date <= period.end }
        let rank = periodNights.filter { $0.cents > cents }.count + 1
        let qualifyingRank = (periodNights.count >= 3 && rank <= 3) ? rank : nil
        return RevealResult(
            cents: cents,
            comparison: .weekdayAverage(weekday: weekday, deltaCents: deltaCents, periodRank: qualifyingRank, periodNightCount: periodNights.count),
            isRecord: false
        )
    }

    /// "$120 ahead of last period at this point" — nil when there's no
    /// prior period yet to compare against (a brand-new schedule).
    func paceDelta(currentPeriod: PayPeriod, priorPeriod: PayPeriod?, asOf date: Date) -> Int? {
        guard let priorPeriod else { return nil }
        let currentTotal = periodToDateTotal(period: currentPeriod, asOf: date)
        let priorComparable = priorPeriodComparableTotal(currentPeriod: currentPeriod, priorPeriod: priorPeriod, asOf: date)
        return currentTotal - priorComparable
    }

    // MARK: Insights facts

    static let minimumShiftsForInsights = 5
    static let insightsRecentWindowDays = 180

    /// Every number Insights is allowed to talk about — computed here, not
    /// by the model. "The stats engine computes facts; the model narrates
    /// them. Never let the model do arithmetic." Nil when there isn't
    /// enough recent history yet.
    func insightsFacts(referenceDate: Date = .now) -> InsightsFacts? {
        let cutoff = calendar.date(byAdding: .day, value: -Self.insightsRecentWindowDays, to: referenceDate) ?? .distantPast
        let recent = records.filter { $0.date >= cutoff }
        let nights = Dictionary(grouping: recent) { calendar.startOfDay(for: $0.date) }
            .map { (date: $0.key, cents: $0.value.reduce(0) { $0 + $1.amountCents }) }
            .sorted { $0.date < $1.date }

        guard nights.count >= Self.minimumShiftsForInsights else { return nil }

        let totalCents = nights.reduce(0) { $0 + $1.cents }
        let topDays = nights.sorted { $0.cents > $1.cents }.prefix(3).map { InsightsFacts.DayAmount(date: $0.date, cents: $0.cents) }
        let cashCents = recent.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amountCents }
        let creditCents = recent.filter { $0.kind == .credit }.reduce(0) { $0 + $1.amountCents }

        return InsightsFacts(
            totalCents: totalCents,
            shiftCount: nights.count,
            averagePerShiftCents: totalCents / nights.count,
            topDays: Array(topDays),
            cashCents: cashCents,
            creditCents: creditCents,
            lunchDinner: lunchDinnerFacts(from: recent),
            doublesSolo: doublesSoloFacts(from: nights, records: recent)
        )
    }

    /// Same honesty rule the reveal and old Insights both used: a logged
    /// time only means something as a lunch-vs-dinner proxy when the tip
    /// was recorded the same day it was earned — a backfilled entry's
    /// logged time isn't the shift time, so it's excluded rather than lied
    /// about.
    private func lunchDinnerFacts(from recent: [TipRecord]) -> LunchDinnerFacts? {
        let sameDayLogged = recent.filter { record in
            guard let recordedAt = record.recordedAt else { return false }
            return calendar.isDate(recordedAt, inSameDayAs: record.date)
        }
        guard sameDayLogged.count >= Self.minimumShiftsForInsights else { return nil }

        var lunchCents = 0, lunchCount = 0, dinnerCents = 0, dinnerCount = 0
        for record in sameDayLogged {
            let hour = calendar.component(.hour, from: record.recordedAt!)
            if hour < 16 {
                lunchCents += record.amountCents
                lunchCount += 1
            } else {
                dinnerCents += record.amountCents
                dinnerCount += 1
            }
        }
        guard lunchCount > 0, dinnerCount > 0 else { return nil }
        return LunchDinnerFacts(lunchCents: lunchCents, lunchShiftCount: lunchCount, dinnerCents: dinnerCents, dinnerShiftCount: dinnerCount)
    }

    private func doublesSoloFacts(from nights: [(date: Date, cents: Int)], records: [TipRecord]) -> DoublesSoloFacts? {
        let doubleDates = Set(records.filter(\.isDouble).map { calendar.startOfDay(for: $0.date) })
        guard !doubleDates.isEmpty else { return nil }
        let doubleNights = nights.filter { doubleDates.contains($0.date) }
        let soloNights = nights.filter { !doubleDates.contains($0.date) }
        guard !doubleNights.isEmpty, !soloNights.isEmpty else { return nil }

        let doubleTotal = doubleNights.reduce(0) { $0 + $1.cents }
        let soloTotal = soloNights.reduce(0) { $0 + $1.cents }
        return DoublesSoloFacts(
            doubleAverageCents: doubleTotal / doubleNights.count,
            doubleCount: doubleNights.count,
            soloAverageCents: soloTotal / soloNights.count,
            soloCount: soloNights.count
        )
    }
}

struct InsightsFacts: Equatable, Codable, Sendable {
    struct DayAmount: Equatable, Codable, Sendable {
        let date: Date
        let cents: Int
    }

    let totalCents: Int
    let shiftCount: Int
    let averagePerShiftCents: Int
    let topDays: [DayAmount]
    let cashCents: Int
    let creditCents: Int
    let lunchDinner: LunchDinnerFacts?
    let doublesSolo: DoublesSoloFacts?
}

struct LunchDinnerFacts: Equatable, Codable, Sendable {
    let lunchCents: Int
    let lunchShiftCount: Int
    let dinnerCents: Int
    let dinnerShiftCount: Int
}

struct DoublesSoloFacts: Equatable, Codable, Sendable {
    let doubleAverageCents: Int
    let doubleCount: Int
    let soloAverageCents: Int
    let soloCount: Int
}

/// Turns the engine's plain facts into the exact calm, specific copy the
/// reveal and pace line show. Deterministic and templated — not narrated by
/// a model; that's reserved for Insights, where facts are more numerous and
/// varied than a single line can hold.
enum RevealCopy {
    private static func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }

    static func headline(cents: Int) -> String {
        "\(Money.string(fromCents: cents)) tonight."
    }

    static func comparison(for result: RevealComparison) -> String {
        switch result {
        case .firstNightLogged:
            return "Your first logged night. Nice start."
        case .allTimeRecord(let previousBestCents):
            return allTimeRecordText(previousBestCents: previousBestCents)
        case .firstShiftOfPeriod:
            return "First shift of the period."
        case .weekdayRecord(let weekday, let previousBestCents):
            return weekdayRecordText(weekday: weekday, previousBestCents: previousBestCents)
        case .slowestRecently:
            return "Your quietest night in a while."
        case .weekdayAverage(let weekday, let deltaCents, let periodRank, let periodNightCount):
            return weekdayAverageText(weekday: weekday, deltaCents: deltaCents, periodRank: periodRank, periodNightCount: periodNightCount)
        }
    }

    private static func allTimeRecordText(previousBestCents: Int) -> String {
        "Best night ever, topping your previous record of \(Money.string(fromCents: previousBestCents))."
    }

    private static func weekdayRecordText(weekday: Int, previousBestCents: Int) -> String {
        "Best \(weekdayName(weekday)) yet, topping your previous best of \(Money.string(fromCents: previousBestCents))."
    }

    private static func weekdayAverageText(weekday: Int, deltaCents: Int, periodRank: Int?, periodNightCount: Int) -> String {
        let isAbove = deltaCents >= 0
        let base = "\(Money.string(fromCents: abs(deltaCents))) \(isAbove ? "above" : "below") your \(weekdayName(weekday)) average."
        guard let periodRank else { return base }
        let rankText: String
        switch periodRank {
        case 1: rankText = "Best night this period."
        case 2: rankText = "Second-best night this period."
        case 3: rankText = "Third-best night this period."
        default: return base
        }
        return "\(base) \(rankText)"
    }

    static func paceLine(deltaCents: Int) -> String {
        if deltaCents == 0 { return "Even with last period at this point." }
        let direction = deltaCents > 0 ? "ahead of" : "behind"
        return "\(Money.string(fromCents: abs(deltaCents))) \(direction) last period at this point."
    }
}

