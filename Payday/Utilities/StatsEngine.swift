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
    /// Hours worked this shift, when logged. Only ever set on one of a
    /// night's records (see LogTipSheet) — summing per-day never
    /// double-counts a dual cash+credit night's hours.
    let hoursWorked: Double?
    /// What got tipped out this shift, in cents. Same single-record rule as
    /// hoursWorked — set on exactly one of a night's records.
    let tipOutCents: Int?
    /// Total sales this shift, in cents. Same single-record rule as the
    /// others above.
    let salesCents: Int?

    /// Gross minus any tip-out — "what you walked with." Every analytical
    /// sum in this engine (nightly totals, pace, insights totals) uses
    /// this, never amountCents directly, so a logged tip-out always nets
    /// out automatically wherever money gets added up. Tip percent is the
    /// one deliberate exception — it's measured against gross, matching
    /// how tip percent is measured everywhere in the industry.
    var netCents: Int { amountCents - (tipOutCents ?? 0) }

    init(date: Date, amountCents: Int, kind: TipKind, isDouble: Bool, recordedAt: Date? = nil, hoursWorked: Double? = nil, tipOutCents: Int? = nil, salesCents: Int? = nil) {
        self.date = date
        self.amountCents = amountCents
        self.kind = kind
        self.isDouble = isDouble
        self.recordedAt = recordedAt
        self.hoursWorked = hoursWorked
        self.tipOutCents = tipOutCents
        self.salesCents = salesCents
    }
}

extension TipRecord {
    init(entry: TipEntry) {
        self.init(date: entry.date, amountCents: entry.amountCents, kind: entry.kind, isDouble: entry.isDouble, recordedAt: entry.recordedAt, hoursWorked: entry.hoursWorked, tipOutCents: entry.tipOutCents, salesCents: entry.salesCents)
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
    case firstWeekdayLogged(weekday: Int)
    case slowestRecently
    case weekdayAverage(weekday: Int, deltaCents: Int, periodRank: Int?, periodNightCount: Int)
}

struct RevealResult: Equatable {
    let cents: Int
    let comparison: RevealComparison
    /// Drives the reveal's one flourish (green sweep + success haptic).
    let isRecord: Bool
    /// Nil whenever tonight's shift has no hours logged — a rate clause is
    /// never fabricated from a fallback.
    let rateClause: RevealRateClause?
}

/// A second, independent fact stacked under the reveal's main comparison —
/// only appears when hours were logged for tonight's shift.
enum RevealRateClause: Equatable {
    case rate(dollarsPerHour: Double, isBestThisPeriod: Bool)
}

/// One calendar night's canonical shift-level facts — the single place the
/// "hours/tip-out/sales live on at most one of a night's records" rule
/// gets enforced on the READ side too, not just when LogTipSheet writes
/// (see ShiftDetails, the same rule applied to TipEntry). If a night ever
/// has more than one record and more than one holds a value — legacy data,
/// or a bug — this always resolves to ONE number, preferring the credit
/// record's value when there is one, else the cash record's, and NEVER
/// sums a value across records, so corrupted or "wrong-entry" data can't
/// double-count.
private struct NightFacts {
    let date: Date
    let grossCents: Int
    let tipOutCents: Int?
    let hoursWorked: Double?
    let salesCents: Int?
    let isDouble: Bool

    /// Gross minus the one canonical tip-out for the night — see the type
    /// doc above for why this is never a per-record sum.
    var netCents: Int { grossCents - (tipOutCents ?? 0) }
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

    /// Groups a set of records into one NightFacts per calendar day. The
    /// one and only place hours/tip-out/sales get resolved from raw
    /// records — every other function in this file reads through this
    /// rather than re-deriving its own grouping.
    private func nightFacts(from source: [TipRecord], excluding excludedDate: Date? = nil) -> [NightFacts] {
        let filtered = excludedDate.map { excluded in source.filter { !calendar.isDate($0.date, inSameDayAs: excluded) } } ?? source
        return Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
            .map { day, dayRecords -> NightFacts in
                let credit = dayRecords.first { $0.kind == .credit }
                let cash = dayRecords.first { $0.kind == .cash }
                return NightFacts(
                    date: day,
                    grossCents: dayRecords.reduce(0) { $0 + $1.amountCents },
                    tipOutCents: credit?.tipOutCents ?? cash?.tipOutCents,
                    hoursWorked: credit?.hoursWorked ?? cash?.hoursWorked,
                    salesCents: credit?.salesCents ?? cash?.salesCents,
                    isDouble: dayRecords.contains { $0.isDouble }
                )
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: Nightly totals

    /// One row per distinct calendar day with any logged record — a shift,
    /// not a row: one night can be two records (cash + credit).
    func nightlyTotals() -> [(date: Date, cents: Int)] {
        nightFacts(from: records).map { (date: $0.date, cents: $0.netCents) }
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

    // MARK: Rate ($/hr)

    /// Every night that has BOTH a logged total and logged hours — the only
    /// nights any $/hr number is allowed to touch. Hours resolve through
    /// nightFacts (credit-preferred, never summed across records).
    private func nightlyRates(excluding excludedDate: Date? = nil) -> [(date: Date, cents: Int, hours: Double)] {
        nightFacts(from: records, excluding: excludedDate).compactMap { night in
            guard let hours = night.hoursWorked, hours > 0 else { return nil }
            return (date: night.date, cents: night.netCents, hours: hours)
        }
    }

    /// $/hr for one specific night, when hours were logged that night.
    func dollarsPerHour(forNightAt date: Date) -> Double? {
        let day = calendar.startOfDay(for: date)
        guard let night = nightlyRates().first(where: { $0.date == day }) else { return nil }
        return Double(night.cents) / 100 / night.hours
    }

    /// Blended $/hr across every night with hours logged — total dollars
    /// over total hours, not an average-of-averages, so one long, low-rate
    /// double doesn't skew the same as a short, high-rate lunch.
    func averageDollarsPerHour(excluding excludedDate: Date? = nil) -> Double? {
        blendedRate(nightlyRates(excluding: excludedDate))
    }

    func averageDollarsPerHour(forWeekday weekday: Int, excluding excludedDate: Date? = nil) -> Double? {
        blendedRate(nightlyRates(excluding: excludedDate).filter { calendar.component(.weekday, from: $0.date) == weekday })
    }

    /// The single best-paying weekday by $/hr. Nil unless at least two
    /// distinct weekdays have rate history — a "best" with nothing to beat
    /// isn't a fact worth stating.
    func bestDollarsPerHourWeekday(excluding excludedDate: Date? = nil) -> (weekday: Int, rate: Double)? {
        let weekdayRates = (1...7).compactMap { weekday -> (weekday: Int, rate: Double)? in
            averageDollarsPerHour(forWeekday: weekday, excluding: excludedDate).map { (weekday: weekday, rate: $0) }
        }
        guard weekdayRates.count >= 2 else { return nil }
        return weekdayRates.max { $0.rate < $1.rate }
    }

    private func blendedRate(_ nights: [(date: Date, cents: Int, hours: Double)]) -> Double? {
        guard !nights.isEmpty else { return nil }
        let totalCents = nights.reduce(0) { $0 + $1.cents }
        let totalHours = nights.reduce(0.0) { $0 + $1.hours }
        guard totalHours > 0 else { return nil }
        return Double(totalCents) / 100 / totalHours
    }

    // MARK: Tip percent

    /// Every night with BOTH a logged total and logged sales — deliberately
    /// GROSS (nightFacts.grossCents, not netCents), matching how tip
    /// percent is always measured: against what the customer actually
    /// tipped, not what a server walked out with after tipping out. Sales
    /// resolve through nightFacts (credit-preferred, never summed).
    private func nightlySalesRates(excluding excludedDate: Date? = nil) -> [(date: Date, grossCents: Int, salesCents: Int)] {
        nightFacts(from: records, excluding: excludedDate).compactMap { night in
            guard let sales = night.salesCents, sales > 0 else { return nil }
            return (date: night.date, grossCents: night.grossCents, salesCents: sales)
        }
    }

    /// Tip percent for one specific night, when sales were logged that night.
    func tipPercent(forNightAt date: Date) -> Double? {
        let day = calendar.startOfDay(for: date)
        guard let night = nightlySalesRates().first(where: { $0.date == day }) else { return nil }
        return Double(night.grossCents) / Double(night.salesCents) * 100
    }

    /// Blended tip percent across every night with sales logged — total
    /// gross tips over total sales, same total-over-total rule as the rate
    /// blend above.
    func averageTipPercent(excluding excludedDate: Date? = nil) -> Double? {
        blendedTipPercent(nightlySalesRates(excluding: excludedDate))
    }

    func averageTipPercent(forWeekday weekday: Int, excluding excludedDate: Date? = nil) -> Double? {
        blendedTipPercent(nightlySalesRates(excluding: excludedDate).filter { calendar.component(.weekday, from: $0.date) == weekday })
    }

    private func blendedTipPercent(_ nights: [(date: Date, grossCents: Int, salesCents: Int)]) -> Double? {
        guard !nights.isEmpty else { return nil }
        let totalGross = nights.reduce(0) { $0 + $1.grossCents }
        let totalSales = nights.reduce(0) { $0 + $1.salesCents }
        guard totalSales > 0 else { return nil }
        return Double(totalGross) / Double(totalSales) * 100
    }

    // MARK: Pace

    /// Sum of everything logged in `period`, through `date` (inclusive).
    func periodToDateTotal(period: PayPeriod, asOf date: Date) -> Int {
        let cutoff = min(calendar.startOfDay(for: date), period.end)
        return records
            .filter { $0.date >= period.start && $0.date <= cutoff }
            .reduce(0) { $0 + $1.netCents }
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
            .reduce(0) { $0 + $1.netCents }
    }

    /// Current net total plus one estimated night for every remaining
    /// calendar day in the period that lands on a "usual" weekday (see
    /// workRhythm), each estimated at that weekday's own historical
    /// average. Nil whenever there's no rhythm to project from yet - a
    /// brand-new schedule has nothing honest to add on top of what's
    /// already logged.
    func projectedPeriodTotal(period: PayPeriod, asOf date: Date, rhythm: WorkRhythm) -> Int? {
        guard !rhythm.usualWeekdays.isEmpty else { return nil }
        let currentTotal = periodToDateTotal(period: period, asOf: date)
        let today = calendar.startOfDay(for: date)
        var cursor = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        var projectedAddition = 0
        while cursor <= period.end {
            let weekday = calendar.component(.weekday, from: cursor)
            if rhythm.usualWeekdays.contains(weekday), let average = averageForWeekday(weekday) {
                projectedAddition += Int(average.rounded())
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? period.end.addingTimeInterval(1)
        }
        return currentTotal + projectedAddition
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
    /// Stacks an independent $/hr clause underneath when hours were logged.
    func reveal(forNightAt date: Date, cents: Int, period: PayPeriod, hoursWorked: Double? = nil) -> RevealResult {
        let (comparison, isRecord) = revealComparison(forNightAt: date, cents: cents, period: period)
        return RevealResult(
            cents: cents,
            comparison: comparison,
            isRecord: isRecord,
            rateClause: rateClause(forNightAt: date, cents: cents, period: period, hoursWorked: hoursWorked)
        )
    }

    private func revealComparison(forNightAt date: Date, cents: Int, period: PayPeriod) -> (RevealComparison, Bool) {
        if bestNightEver(excluding: date) == nil {
            return (.firstNightLogged, false)
        }
        if let best = bestNightEver(excluding: date), cents > best.cents {
            return (.allTimeRecord(previousBestCents: best.cents), true)
        }
        if isFirstShiftOfPeriod(date: date, period: period) {
            return (.firstShiftOfPeriod, false)
        }
        let weekday = calendar.component(.weekday, from: date)
        if let bestWeekday = bestNight(forWeekday: weekday, excluding: date), cents > bestWeekday.cents {
            return (.weekdayRecord(weekday: weekday, previousBestCents: bestWeekday.cents), true)
        }
        if isSlowestRecently(date: date, cents: cents, lookbackShifts: 8) {
            return (.slowestRecently, false)
        }
        // No prior history for this weekday to average against — falling
        // back to "compare tonight against tonight" would always read as
        // "$0.00 above your ‹weekday› average," a self-referential
        // non-comparison. Say plainly that this is the first one instead.
        guard let average = averageForWeekday(weekday, excluding: date) else {
            return (.firstWeekdayLogged(weekday: weekday), false)
        }
        let deltaCents = cents - Int(average.rounded())
        let periodNights = nightlyTotals().filter { $0.date >= period.start && $0.date <= period.end }
        let rank = periodNights.filter { $0.cents > cents }.count + 1
        let qualifyingRank = (periodNights.count >= 3 && rank <= 3) ? rank : nil
        return (.weekdayAverage(weekday: weekday, deltaCents: deltaCents, periodRank: qualifyingRank, periodNightCount: periodNights.count), false)
    }

    /// $/hr for tonight, plus whether it beats every other night this period
    /// that also has hours logged. Nil whenever tonight has no hours — never
    /// fabricated from a fallback.
    private func rateClause(forNightAt date: Date, cents: Int, period: PayPeriod, hoursWorked: Double?) -> RevealRateClause? {
        guard let hoursWorked, hoursWorked > 0 else { return nil }
        let rate = Double(cents) / 100 / hoursWorked
        let otherPeriodRates = nightlyRates(excluding: date)
            .filter { $0.date >= period.start && $0.date <= period.end }
            .map { Double($0.cents) / 100 / $0.hours }
        let isBestThisPeriod = !otherPeriodRates.isEmpty && otherPeriodRates.allSatisfy { rate >= $0 }
        return .rate(dollarsPerHour: rate, isBestThisPeriod: isBestThisPeriod)
    }

    /// "$120 ahead of last period at this point" — nil when there's no
    /// prior period yet to compare against (a brand-new schedule).
    func paceDelta(currentPeriod: PayPeriod, priorPeriod: PayPeriod?, asOf date: Date) -> Int? {
        guard let priorPeriod else { return nil }
        let currentTotal = periodToDateTotal(period: currentPeriod, asOf: date)
        let priorComparable = priorPeriodComparableTotal(currentPeriod: currentPeriod, priorPeriod: priorPeriod, asOf: date)
        return currentTotal - priorComparable
    }

    // MARK: Work rhythm

    static let minimumNightsForRhythm = 2
    static let minimumSameDayLoggedForTypicalHour = 3

    /// Learned, never configured: which weekdays this person usually
    /// works, and roughly when they log — the smart nudge's entire basis.
    /// A weekday counts as "usual" once it's been worked at least
    /// `minimumNightsForRhythm` times AND on at least half of its actual
    /// occurrences since the first logged night (so an occasional Sunday
    /// pickup shift doesn't get treated the same as every-Friday routine).
    func workRhythm(referenceDate: Date = .now) -> WorkRhythm {
        let allNights = nightlyTotals()
        guard let earliest = allNights.first?.date else {
            return WorkRhythm(usualWeekdays: [], typicalLogHour: nil)
        }

        var occurrences: [Int: Int] = [:]
        var worked: [Int: Int] = [:]
        var cursor = startOfDay(earliest)
        let end = startOfDay(referenceDate)
        while cursor <= end {
            let weekday = calendar.component(.weekday, from: cursor)
            occurrences[weekday, default: 0] += 1
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }
        for night in allNights {
            let weekday = calendar.component(.weekday, from: night.date)
            worked[weekday, default: 0] += 1
        }

        let usualWeekdays = Set((1...7).filter { weekday in
            let workedCount = worked[weekday] ?? 0
            let occurrenceCount = occurrences[weekday] ?? 0
            guard workedCount >= Self.minimumNightsForRhythm, occurrenceCount > 0 else { return false }
            return Double(workedCount) / Double(occurrenceCount) >= 0.5
        })

        let sameDayLoggedHours = records.compactMap { record -> Int? in
            guard let recordedAt = record.recordedAt, calendar.isDate(recordedAt, inSameDayAs: record.date) else { return nil }
            return calendar.component(.hour, from: recordedAt)
        }.sorted()

        let typicalLogHour = sameDayLoggedHours.count >= Self.minimumSameDayLoggedForTypicalHour
            ? sameDayLoggedHours[sameDayLoggedHours.count / 2]
            : nil

        return WorkRhythm(usualWeekdays: usualWeekdays, typicalLogHour: typicalLogHour)
    }

    private func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    // MARK: Insights facts

    static let minimumShiftsForInsights = 5
    static let insightsRecentWindowDays = 180
    /// Lower bar than minimumShiftsForInsights on purpose — hours-logging
    /// is optional, so RATE facts should surface as soon as there's a
    /// handful of nights to blend, not wait for the full insights gate.
    static let minimumNightsForRate = 3
    /// Same reasoning as minimumNightsForRate, for sales-logging.
    static let minimumNightsForSales = 3

    /// Every number Insights is allowed to talk about — computed here, not
    /// by the model. "The stats engine computes facts; the model narrates
    /// them. Never let the model do arithmetic." Nil when there isn't
    /// enough recent history yet.
    func insightsFacts(referenceDate: Date = .now) -> InsightsFacts? {
        let cutoff = calendar.date(byAdding: .day, value: -Self.insightsRecentWindowDays, to: referenceDate) ?? .distantPast
        let recent = records.filter { $0.date >= cutoff }
        let nights = nightFacts(from: recent)

        guard nights.count >= Self.minimumShiftsForInsights else { return nil }

        let totalCents = nights.reduce(0) { $0 + $1.netCents }
        let topDays = nights.sorted { $0.netCents > $1.netCents }.prefix(3).map { InsightsFacts.DayAmount(date: $0.date, cents: $0.netCents) }
        // Composition of what came in, not take-home — stays gross on
        // purpose, same as the paycheck comparison.
        let cashCents = recent.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amountCents }
        let creditCents = recent.filter { $0.kind == .credit }.reduce(0) { $0 + $1.amountCents }
        // Nights' canonical tip-out, never the raw per-record sum — a
        // night with a (legacy) value on both entries would otherwise
        // count it twice here too.
        let totalTipOutCents = nights.compactMap(\.tipOutCents).reduce(0, +)

        return InsightsFacts(
            totalCents: totalCents,
            shiftCount: nights.count,
            averagePerShiftCents: totalCents / nights.count,
            topDays: Array(topDays),
            cashCents: cashCents,
            creditCents: creditCents,
            lunchDinner: lunchDinnerFacts(from: recent),
            doublesSolo: doublesSoloFacts(from: nights),
            totalTipOutCents: totalTipOutCents,
            rate: rateFacts(from: nights, sameDayLoggedRecords: recent),
            sales: salesFacts(from: nights)
        )
    }

    /// Same recent window as the rest of insightsFacts, reading sales
    /// through nightFacts — deliberately GROSS (grossCents, not netCents),
    /// same rule as tipPercent() above.
    private func salesFacts(from nights: [NightFacts]) -> SalesFacts? {
        let salesNights = nights.compactMap { night -> (date: Date, grossCents: Int, salesCents: Int)? in
            guard let sales = night.salesCents, sales > 0 else { return nil }
            return (date: night.date, grossCents: night.grossCents, salesCents: sales)
        }
        guard salesNights.count >= Self.minimumNightsForSales, let overall = blendedTipPercent(salesNights) else { return nil }

        let weekdayPercents = (1...7).compactMap { weekday -> (weekday: Int, percent: Double)? in
            blendedTipPercent(salesNights.filter { calendar.component(.weekday, from: $0.date) == weekday }).map { (weekday: weekday, percent: $0) }
        }
        let bestWeekday = weekdayPercents.count >= 2 ? weekdayPercents.max { $0.percent < $1.percent } : nil

        return SalesFacts(
            overallTipPercent: overall,
            nightsWithSales: salesNights.count,
            bestWeekday: bestWeekday?.weekday,
            bestWeekdayTipPercent: bestWeekday?.percent
        )
    }

    /// Same recent window as the rest of insightsFacts — a $/hr number from
    /// a year-old shift wouldn't reflect what tonight's rate actually is.
    /// `sameDayLoggedRecords` is only for the lunch/dinner split below,
    /// which needs `recordedAt`, a per-record fact nightFacts doesn't carry.
    private func rateFacts(from nights: [NightFacts], sameDayLoggedRecords recent: [TipRecord]) -> RateFacts? {
        let rateNights = nights.compactMap { night -> (date: Date, cents: Int, hours: Double)? in
            guard let hours = night.hoursWorked, hours > 0 else { return nil }
            return (date: night.date, cents: night.netCents, hours: hours)
        }
        guard rateNights.count >= Self.minimumNightsForRate, let overall = blendedRate(rateNights) else { return nil }

        let weekdayRates = (1...7).compactMap { weekday -> (weekday: Int, rate: Double)? in
            blendedRate(rateNights.filter { calendar.component(.weekday, from: $0.date) == weekday }).map { (weekday: weekday, rate: $0) }
        }
        let bestWeekday = weekdayRates.count >= 2 ? weekdayRates.max { $0.rate < $1.rate } : nil

        let doubleDates = Set(nights.filter(\.isDouble).map(\.date))
        let doubleRate = blendedRate(rateNights.filter { doubleDates.contains($0.date) })
        let soloRate = blendedRate(rateNights.filter { !doubleDates.contains($0.date) })

        let sameDayLogged = recent.filter { record in
            guard let recordedAt = record.recordedAt else { return false }
            return calendar.isDate(recordedAt, inSameDayAs: record.date)
        }
        let lunchDates = Set(sameDayLogged.filter { calendar.component(.hour, from: $0.recordedAt!) < 16 }.map { calendar.startOfDay(for: $0.date) })
        let dinnerDates = Set(sameDayLogged.filter { calendar.component(.hour, from: $0.recordedAt!) >= 16 }.map { calendar.startOfDay(for: $0.date) })
        let lunchRate = blendedRate(rateNights.filter { lunchDates.contains($0.date) })
        let dinnerRate = blendedRate(rateNights.filter { dinnerDates.contains($0.date) })

        return RateFacts(
            overallDollarsPerHour: overall,
            nightsWithHours: rateNights.count,
            bestWeekday: bestWeekday?.weekday,
            bestWeekdayDollarsPerHour: bestWeekday?.rate,
            lunchDollarsPerHour: lunchRate,
            dinnerDollarsPerHour: dinnerRate,
            doubleDollarsPerHour: doubleRate,
            soloDollarsPerHour: soloRate
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

    // MARK: Moves

    private enum MoveThresholds {
        /// Below this, silence beats weak advice — the whole point of the
        /// materiality gate.
        static let minimumAnnualImpactCents = 10000
        static let minimumWeekdayDeltaCents = 1000
        static let minimumRateDeltaCents = 300
        static let minimumTipPercentDelta = 3.0
        static let lapsedWindowDays = 21
        /// Every weekday-keyed move (swap, lapsed winner, rate leader)
        /// already requires >= 3 nights of history for that weekday before
        /// firing — treating that as "roughly weekly" is a fair, stated
        /// extrapolation, not a wild guess.
        static let assumedWeeksPerYear = 52.0
    }

    /// Up to 3 dollar-quantified, ranked observations - deterministic and
    /// pure like the rest of this file, no model, no network. Silence over
    /// weak advice: an empty array is a valid, honest answer when nothing
    /// clears the materiality bar.
    func moves(referenceDate: Date = .now) -> [Move] {
        let candidates = [
            weekdaySwapMove(),
            lapsedWinnerMove(referenceDate: referenceDate),
            doublesVerdictMove(referenceDate: referenceDate),
            rateLeaderMove(),
            tipPercentSignalMove()
        ].compactMap { $0 }
        return Array(
            candidates
                .filter { $0.annualImpactCents >= MoveThresholds.minimumAnnualImpactCents }
                .sorted { $0.annualImpactCents > $1.annualImpactCents }
                .prefix(3)
        )
    }

    /// Best-paying weekday against worst-paying weekday, both net, both
    /// needing >= 3 nights of their own history to qualify.
    private func weekdaySwapMove() -> Move? {
        let allNights = nightlyTotals()
        let weekdayAverages = weekdayNightAverages(allNights)
        guard weekdayAverages.count >= 2,
              let best = weekdayAverages.max(by: { $0.avg < $1.avg }),
              let worst = weekdayAverages.min(by: { $0.avg < $1.avg }),
              best.weekday != worst.weekday
        else { return nil }
        let deltaCents = Int((best.avg - worst.avg).rounded())
        guard deltaCents >= MoveThresholds.minimumWeekdayDeltaCents else { return nil }

        let bestName = Calendar.current.weekdaySymbols[best.weekday - 1]
        let worstName = Calendar.current.weekdaySymbols[worst.weekday - 1]
        let annualImpact = Int(Double(deltaCents) * MoveThresholds.assumedWeeksPerYear)
        return Move(
            id: "weekdaySwap",
            title: "\(bestName) Beats \(worstName)",
            body: "\(bestName) nights average \(Money.string(fromCents: Int(best.avg.rounded()))), against \(Money.string(fromCents: Int(worst.avg.rounded()))) on \(worstName)s. Over a year of regular shifts, that gap is worth about \(Money.wholeDollarString(fromCents: annualImpact)).",
            annualImpactCents: annualImpact
        )
    }

    /// A weekday that used to pay well but hasn't shown up recently.
    private func lapsedWinnerMove(referenceDate: Date) -> Move? {
        let allNights = nightlyTotals()
        guard allNights.count >= 6 else { return nil }
        let overallAvg = Double(allNights.reduce(0) { $0 + $1.cents }) / Double(allNights.count)
        let cutoff = calendar.date(byAdding: .day, value: -MoveThresholds.lapsedWindowDays, to: referenceDate) ?? referenceDate
        let recentWeekdays = Set(allNights.filter { $0.date >= cutoff }.map { calendar.component(.weekday, from: $0.date) })

        let candidates = weekdayNightAverages(allNights).filter { !recentWeekdays.contains($0.weekday) }
        guard let best = candidates.max(by: { $0.avg < $1.avg }), best.avg > overallAvg * 1.1 else { return nil }
        let deltaCents = Int((best.avg - overallAvg).rounded())
        guard deltaCents >= MoveThresholds.minimumWeekdayDeltaCents else { return nil }

        let weekdayName = Calendar.current.weekdaySymbols[best.weekday - 1]
        let annualImpact = Int(Double(deltaCents) * MoveThresholds.assumedWeeksPerYear)
        return Move(
            id: "lapsedWinner",
            title: "\(weekdayName) Has Gone Quiet",
            body: "You haven't worked a \(weekdayName) in a few weeks, but it's one of your best - averaging \(Money.string(fromCents: Int(best.avg.rounded()))) a night. Getting back to a regular \(weekdayName) is worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year.",
            annualImpactCents: annualImpact
        )
    }

    /// Doubles are usually judged by $/shift (see doublesSoloFacts); this
    /// checks the same split by $/hr, which can point the other way once
    /// the extra hours are accounted for.
    private func doublesVerdictMove(referenceDate: Date) -> Move? {
        let doubleDates = Set(nightFacts(from: records).filter(\.isDouble).map(\.date))
        guard !doubleDates.isEmpty else { return nil }
        let allRates = nightlyRates()
        let doubleRates = allRates.filter { doubleDates.contains($0.date) }
        let soloRates = allRates.filter { !doubleDates.contains($0.date) }
        guard !doubleRates.isEmpty, let doubleRate = blendedRate(doubleRates), let soloRate = blendedRate(soloRates) else { return nil }
        let deltaPerHourCents = Int(((doubleRate - soloRate) * 100).rounded())
        guard abs(deltaPerHourCents) >= MoveThresholds.minimumRateDeltaCents else { return nil }

        // Doubles don't land on a fixed weekly cadence, so extrapolate from
        // how often they've actually happened over the tenure so far,
        // rather than assuming a weekly occurrence like the weekday moves.
        guard let earliestNight = nightlyTotals().first?.date else { return nil }
        let tenureDays = max(1, calendar.dateComponents([.day], from: earliestNight, to: referenceDate).day ?? 1)
        let doublesPerYear = Double(doubleRates.count) * 365.0 / Double(tenureDays)
        let avgDoubleHours = doubleRates.reduce(0.0) { $0 + $1.hours } / Double(doubleRates.count)
        let annualImpact = Int(abs(doubleRate - soloRate) * avgDoubleHours * doublesPerYear * 100)

        let doubleWins = doubleRate > soloRate
        return Move(
            id: "doublesVerdict",
            title: doubleWins ? "Doubles Pay Off" : "Doubles Cost You",
            body: "Doubles average \(Money.wholeDollarString(fromCents: Int((doubleRate * 100).rounded())))/hr, against \(Money.wholeDollarString(fromCents: Int((soloRate * 100).rounded())))/hr solo - doubles \(doubleWins ? "pay better" : "pay worse") per hour, not just per shift. At your current pace, that's worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year.",
            annualImpactCents: annualImpact
        )
    }

    /// The best-paying weekday by $/hr against the overall $/hr average -
    /// a genuinely different fact from weekdaySwapMove, which compares
    /// $/night.
    private func rateLeaderMove() -> Move? {
        guard let best = bestDollarsPerHourWeekday(), let overallRate = averageDollarsPerHour() else { return nil }
        let deltaPerHourCents = Int(((best.rate - overallRate) * 100).rounded())
        guard deltaPerHourCents >= MoveThresholds.minimumRateDeltaCents else { return nil }

        let weekdayRates = nightlyRates().filter { calendar.component(.weekday, from: $0.date) == best.weekday }
        guard !weekdayRates.isEmpty else { return nil }
        let avgHours = weekdayRates.reduce(0.0) { $0 + $1.hours } / Double(weekdayRates.count)
        let annualImpact = Int((best.rate - overallRate) * avgHours * MoveThresholds.assumedWeeksPerYear * 100)
        guard annualImpact >= MoveThresholds.minimumAnnualImpactCents else { return nil }

        let weekdayName = Calendar.current.weekdaySymbols[best.weekday - 1]
        return Move(
            id: "rateLeader",
            title: "\(weekdayName) Pays Best Per Hour",
            body: "\(weekdayName)s average \(Money.wholeDollarString(fromCents: Int((best.rate * 100).rounded())))/hr, against \(Money.wholeDollarString(fromCents: Int((overallRate * 100).rounded())))/hr overall. Working \(weekdayName)s regularly is worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year over your average rate.",
            annualImpactCents: annualImpact
        )
    }

    /// The best tip-percent weekday against the overall tip-percent average.
    private func tipPercentSignalMove() -> Move? {
        guard let overallPercent = averageTipPercent() else { return nil }
        let weekdayPercents = (1...7).compactMap { weekday -> (weekday: Int, percent: Double)? in
            averageTipPercent(forWeekday: weekday).map { (weekday: weekday, percent: $0) }
        }
        guard weekdayPercents.count >= 2, let best = weekdayPercents.max(by: { $0.percent < $1.percent }) else { return nil }
        let deltaPercent = best.percent - overallPercent
        guard deltaPercent >= MoveThresholds.minimumTipPercentDelta else { return nil }

        let weekdaySales = nightlySalesRates().filter { calendar.component(.weekday, from: $0.date) == best.weekday }
        guard !weekdaySales.isEmpty else { return nil }
        let avgSales = Double(weekdaySales.reduce(0) { $0 + $1.salesCents }) / Double(weekdaySales.count)
        let annualImpact = Int((deltaPercent / 100) * avgSales * MoveThresholds.assumedWeeksPerYear)
        guard annualImpact >= MoveThresholds.minimumAnnualImpactCents else { return nil }

        let weekdayName = Calendar.current.weekdaySymbols[best.weekday - 1]
        return Move(
            id: "tipPercentSignal",
            title: "\(weekdayName) Tips Best",
            body: "You're tipped \(String(format: "%.1f", best.percent))% of sales on \(weekdayName)s, against \(String(format: "%.1f", overallPercent))% overall. At that rate on a typical \(weekdayName), the difference is worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year.",
            annualImpactCents: annualImpact
        )
    }

    /// Per-weekday averages over ALL of a person's history, requiring at
    /// least 3 nights on that weekday before it counts — shared by every
    /// weekday-keyed move above.
    private func weekdayNightAverages(_ nights: [(date: Date, cents: Int)]) -> [(weekday: Int, avg: Double, count: Int)] {
        (1...7).compactMap { weekday -> (weekday: Int, avg: Double, count: Int)? in
            let matching = nights.filter { calendar.component(.weekday, from: $0.date) == weekday }
            guard matching.count >= 3 else { return nil }
            let avg = Double(matching.reduce(0) { $0 + $1.cents }) / Double(matching.count)
            return (weekday, avg, matching.count)
        }
    }

    private func doublesSoloFacts(from nights: [NightFacts]) -> DoublesSoloFacts? {
        let doubleNights = nights.filter(\.isDouble)
        let soloNights = nights.filter { !$0.isDouble }
        guard !doubleNights.isEmpty, !soloNights.isEmpty else { return nil }

        let doubleTotal = doubleNights.reduce(0) { $0 + $1.netCents }
        let soloTotal = soloNights.reduce(0) { $0 + $1.netCents }
        return DoublesSoloFacts(
            doubleAverageCents: doubleTotal / doubleNights.count,
            doubleCount: doubleNights.count,
            soloAverageCents: soloTotal / soloNights.count,
            soloCount: soloNights.count
        )
    }
}

/// The smart nudge's entire basis — see StatsEngine.workRhythm(referenceDate:).
struct WorkRhythm: Equatable {
    /// Weekdays (Gregorian: 1=Sunday…7=Saturday) worked often enough to
    /// call "usual." Empty means not enough history yet, not "never works."
    let usualWeekdays: Set<Int>
    /// Typical hour-of-day (0–23) tips get logged, from same-day-logged
    /// records only. Nil without enough signal.
    let typicalLogHour: Int?
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
    // var + inline default (not let) so the synthesized memberwise init
    // both defaults these AND still accepts an explicit override — a `let`
    // with an inline default gets excluded from the init entirely. This
    // keeps InsightsFactsCopyTests' pre-existing hand-built fixtures
    // compiling without every call site needing to name them.
    var totalTipOutCents: Int = 0
    var rate: RateFacts? = nil
    var sales: SalesFacts? = nil
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

/// $/hr facts — only ever built from nights that actually have hours
/// logged, never estimated for the rest. Every field but the overall rate
/// and its night count is optional, since each needs its own qualifying
/// split (two-plus weekdays, at least one double and one solo night, etc).
struct RateFacts: Equatable, Codable, Sendable {
    let overallDollarsPerHour: Double
    let nightsWithHours: Int
    let bestWeekday: Int?
    let bestWeekdayDollarsPerHour: Double?
    let lunchDollarsPerHour: Double?
    let dinnerDollarsPerHour: Double?
    let doubleDollarsPerHour: Double?
    let soloDollarsPerHour: Double?
}

/// Tip-percent facts — only ever built from nights that actually have
/// sales logged. Deliberately gross, not net (see StatsEngine.tipPercent).
struct SalesFacts: Equatable, Codable, Sendable {
    let overallTipPercent: Double
    let nightsWithSales: Int
    let bestWeekday: Int?
    let bestWeekdayTipPercent: Double?
}

/// One dollar-quantified, ranked observation from StatsEngine.moves() — see
/// that function for the full materiality/annualization rules. id is a
/// stable per-move-type key ("weekdaySwap", "lapsedWinner", "doublesVerdict",
/// "rateLeader", "tipPercentSignal"), not a per-instance UUID, since a given
/// move type only ever appears once per call.
struct Move: Equatable, Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let body: String
    let annualImpactCents: Int
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
        case .firstWeekdayLogged(let weekday):
            return "Your first logged \(weekdayName(weekday))."
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

    static func projectionLine(cents: Int) -> String {
        "On pace for about \(Money.wholeDollarString(fromCents: cents))."
    }

    static func rateClause(for clause: RevealRateClause) -> String {
        switch clause {
        case .rate(let dollarsPerHour, let isBestThisPeriod):
            let rateString = Money.wholeDollarString(fromCents: Int((dollarsPerHour * 100).rounded()))
            return isBestThisPeriod
                ? "\(rateString)/hr, your best rate this period."
                : "\(rateString)/hr this shift."
        }
    }

    /// Same fact as paceLine, sized for the widget's systemSmall family —
    /// the full sentence overflows a caption2 line in that little space.
    static func compactPaceLine(deltaCents: Int) -> String {
        if deltaCents == 0 { return "Even vs last period" }
        let sign = deltaCents > 0 ? "+" : "-"
        return "\(sign)\(Money.string(fromCents: abs(deltaCents))) vs last period"
    }
}

