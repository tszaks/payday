import Foundation

/// Plain, Sendable per-night fact — decoupled from SwiftData's TipEntry so
/// this stays a pure, easily-tested module, same pattern as
/// PayPeriodCalculator. Never crosses into money formatting or UI copy.
struct TipRecord: Sendable, Hashable {
    let date: Date
    let amountCents: Int
    let kind: TipKind
    /// Vestigial mirror of TipEntry.isDouble — never read for logic anymore
    /// (a "double" is now a day with 2+ distinct shiftIDs, see nightlyFacts).
    /// Kept only so this value type stays a faithful mirror of the model.
    let isDouble: Bool
    /// Groups the rows of one closeout (a shift). A shift = records sharing
    /// this id; a "double" is a calendar day with 2+ distinct shiftIDs.
    /// Optional for legacy records logged before shift grouping existed —
    /// the engine falls back to a day-derived key for those.
    let shiftID: UUID?
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
    /// Explicit lunch/dinner, when actually captured. Same single-record
    /// rule as the others above; the engine only ever falls back to the
    /// same-day-logged recordedAt proxy for legacy records with this nil.
    let shiftPeriod: ShiftPeriod?

    /// Clock-in/clock-out for the shift — shift-level like hoursWorked
    /// (lives on at most one of a shift's records, see ShiftDetails), used
    /// only to bucket shifts by start time for the start-time analysis
    /// below. Nil for legacy records and any shift where times were never
    /// logged.
    let clockIn: Date?
    let clockOut: Date?

    /// How many servers were on the floor this shift — shift-level like
    /// clockIn/clockOut, captured for future floor-size insights. No
    /// analytics reads this yet; it's here purely so the engine's mirror of
    /// TipEntry stays faithful once that analysis exists.
    let serverCount: Int?

    /// The worker's own note for this shift, passed through to Insights as
    /// context — a note like "POS outage, lunch tips paid out at dinner" is
    /// the difference between explaining an anomalous day and reading a
    /// pattern into it. Never used for arithmetic.
    let note: String?

    /// Gross minus any tip-out — "what you walked with." Every analytical
    /// sum in this engine (nightly totals, pace, insights totals) uses
    /// this, never amountCents directly, so a logged tip-out always nets
    /// out automatically wherever money gets added up. Tip percent is the
    /// one deliberate exception — it's measured against gross, matching
    /// how tip percent is measured everywhere in the industry.
    var netCents: Int { amountCents - (tipOutCents ?? 0) }

    init(date: Date, amountCents: Int, kind: TipKind, isDouble: Bool, recordedAt: Date? = nil, hoursWorked: Double? = nil, tipOutCents: Int? = nil, salesCents: Int? = nil, shiftPeriod: ShiftPeriod? = nil, shiftID: UUID? = nil, clockIn: Date? = nil, clockOut: Date? = nil, serverCount: Int? = nil, note: String? = nil) {
        self.date = date
        self.amountCents = amountCents
        self.kind = kind
        self.isDouble = isDouble
        self.recordedAt = recordedAt
        self.hoursWorked = hoursWorked
        self.tipOutCents = tipOutCents
        self.salesCents = salesCents
        self.shiftPeriod = shiftPeriod
        self.shiftID = shiftID
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.serverCount = serverCount
        self.note = note
    }
}

extension TipRecord {
    init(entry: TipEntry) {
        self.init(date: entry.date, amountCents: entry.amountCents, kind: entry.kind, isDouble: entry.isDouble, recordedAt: entry.recordedAt, hoursWorked: entry.hoursWorked, tipOutCents: entry.tipOutCents, salesCents: entry.salesCents, shiftPeriod: entry.shiftPeriod, shiftID: entry.shiftID, clockIn: entry.clockIn, clockOut: entry.clockOut, serverCount: entry.serverCount, note: entry.note)
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
    case weekdayAverage(weekday: Int, deltaCents: Int, periodRank: Int?, periodNightCount: Int, sampleCount: Int)
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

/// One shift's (one closeout's) canonical facts — the single place the
/// "hours/tip-out/sales live on at most one of a shift's records" rule
/// gets enforced on the READ side too, not just when LogTipSheet writes
/// (see ShiftDetails, the same rule applied to TipEntry). If a shift ever
/// has more than one record and more than one holds a value — legacy data,
/// or a bug — this always resolves to ONE number, preferring the credit
/// record's value when there is one, else the cash record's, and NEVER
/// sums a value across records, so corrupted or "wrong-entry" data can't
/// double-count. A "double" is a calendar day with two of these.
private struct ShiftFacts {
    let shiftID: UUID
    /// The calendar day (startOfDay) this shift belongs to. Two shifts on a
    /// double day share the same date but different shiftIDs.
    let date: Date
    let grossCents: Int
    /// The cash portion of grossCents — summed across the shift's cash
    /// record(s), never resolved credit-preferred like the other fields
    /// above, since a shift can legitimately hold both a cash AND a credit
    /// record and both amounts are real money, not competing versions of
    /// the same fact.
    let cashCents: Int
    let tipOutCents: Int?
    let hoursWorked: Double?
    let salesCents: Int?
    let shiftPeriod: ShiftPeriod?
    let recordedAt: Date?
    /// Clock-in/clock-out, resolved the same credit-preferred way as every
    /// other shift-level field above — used only by the start-time bucketing
    /// below.
    let clockIn: Date?
    let clockOut: Date?
    /// How many servers were on the floor — resolved the same
    /// credit-preferred way, no analytics reads it yet (see TipRecord).
    let serverCount: Int?

    /// Gross minus the one canonical tip-out for the shift — see the type
    /// doc above for why this is never a per-record sum.
    var netCents: Int { grossCents - (tipOutCents ?? 0) }
}

/// A small pure module computing pace, records, baselines, and the post-log
/// reveal comparison. No I/O, no SwiftData — takes plain facts, returns
/// plain facts, fully unit-testable like PayPeriodCalculator.
struct StatsEngine {
    let records: [TipRecord]
    private let calendar: Calendar
    /// The reveal pipeline's ONLY wage-aware surface (Tyler's ruling,
    /// 2026-07-27): "for a shift, we don't differentiate [tips vs wages] —
    /// it's 1 amount." When set, revealComparison's own record/average/
    /// slowest checks price each shift at net tips + that shift's wages
    /// instead of net tips alone. Nil (the default) reproduces every
    /// existing behavior exactly — pace, charts, projections, Insights,
    /// Moves, $/hr, and tip percent never read this and stay tips-only
    /// regardless of what's passed here.
    private let wageCentsPerHour: Int?

    init(records: [TipRecord], calendar: Calendar = .current, wageCentsPerHour: Int? = nil) {
        self.records = records
        var cal = calendar
        cal.timeZone = TimeZone.current
        self.calendar = cal
        self.wageCentsPerHour = wageCentsPerHour
    }

    /// Groups records into one ShiftFacts per closeout, keyed on shiftID —
    /// the one and only place hours/tip-out/sales get resolved from raw
    /// records. Records with a nil shiftID (legacy rows not yet backfilled)
    /// fall back to a stable day-derived id, so all of a legacy day's rows
    /// stay one shift. Every per-shift function reads through this.
    private func shiftFacts(from source: [TipRecord], excludingShift: UUID? = nil) -> [ShiftFacts] {
        let keyed = source.map { record -> (id: UUID, record: TipRecord) in
            (id: record.shiftID ?? ShiftDays.deterministicShiftID(for: record.date, calendar: calendar), record: record)
        }
        let filtered = excludingShift.map { ex in keyed.filter { $0.id != ex } } ?? keyed
        return Dictionary(grouping: filtered, by: { $0.id })
            .map { shiftID, pairs -> ShiftFacts in
                let shiftRecords = pairs.map(\.record)
                let credit = shiftRecords.first { $0.kind == .credit }
                let cash = shiftRecords.first { $0.kind == .cash }
                return ShiftFacts(
                    shiftID: shiftID,
                    date: calendar.startOfDay(for: shiftRecords.map(\.date).min() ?? .now),
                    grossCents: shiftRecords.reduce(0) { $0 + $1.amountCents },
                    cashCents: shiftRecords.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amountCents },
                    tipOutCents: credit?.tipOutCents ?? cash?.tipOutCents,
                    hoursWorked: credit?.hoursWorked ?? cash?.hoursWorked,
                    salesCents: credit?.salesCents ?? cash?.salesCents,
                    shiftPeriod: credit?.shiftPeriod ?? cash?.shiftPeriod,
                    recordedAt: credit?.recordedAt ?? cash?.recordedAt,
                    clockIn: credit?.clockIn ?? cash?.clockIn,
                    clockOut: credit?.clockOut ?? cash?.clockOut,
                    serverCount: credit?.serverCount ?? cash?.serverCount
                )
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: Daily and per-shift totals

    /// One row per calendar DAY worked — a day's shifts summed. This is the
    /// per-day view: the chart, pace, work rhythm, and weekday moves all ask
    /// day-level questions (which day/weekday pays), so they read this.
    func nightlyTotals() -> [(date: Date, cents: Int)] {
        dayTotals()
    }

    private func dayTotals() -> [(date: Date, cents: Int)] {
        Dictionary(grouping: shiftFacts(from: records), by: { $0.date })
            .map { day, shifts in (date: day, cents: shifts.reduce(0) { $0 + $1.netCents }) }
            .sorted { $0.date < $1.date }
    }

    /// Per-SHIFT totals — one row per closeout — for records and the reveal,
    /// which fire once per closeout and must compare shift-to-shift so a
    /// double day's summed total can't crown a record over honest single
    /// shifts. Excludes by shiftID (the just-logged shift) and/or by a whole
    /// day, whichever the caller passes.
    private func shiftTotals(excludingDate: Date? = nil, excludingShift: UUID? = nil) -> [(shiftID: UUID, date: Date, cents: Int)] {
        shiftFacts(from: records)
            .filter { shift in
                if let excludingDate, calendar.isDate(shift.date, inSameDayAs: excludingDate) { return false }
                if let excludingShift, shift.shiftID == excludingShift { return false }
                return true
            }
            .map { (shiftID: $0.shiftID, date: $0.date, cents: $0.netCents) }
    }

    // MARK: Records (per-shift)

    func bestNightEver(excluding excludedDate: Date? = nil, excludingShift: UUID? = nil) -> (date: Date, cents: Int)? {
        shiftTotals(excludingDate: excludedDate, excludingShift: excludingShift)
            .map { (date: $0.date, cents: $0.cents) }
            .max { $0.cents < $1.cents }
    }

    /// Best single day this period — a period summary (the Dashboard hero),
    /// so it stays day-level: a double day counts as its combined total here.
    func bestNight(in period: PayPeriod) -> (date: Date, cents: Int)? {
        nightlyTotals()
            .filter { $0.date >= period.start && $0.date <= period.end }
            .max { $0.cents < $1.cents }
    }

    func bestNight(forWeekday weekday: Int, excluding excludedDate: Date? = nil, excludingShift: UUID? = nil) -> (date: Date, cents: Int)? {
        shiftTotals(excludingDate: excludedDate, excludingShift: excludingShift)
            .filter { calendar.component(.weekday, from: $0.date) == weekday }
            .map { (date: $0.date, cents: $0.cents) }
            .max { $0.cents < $1.cents }
    }

    func averageForWeekday(_ weekday: Int, excluding excludedDate: Date? = nil, excludingShift: UUID? = nil) -> Double? {
        let matching = shiftTotals(excludingDate: excludedDate, excludingShift: excludingShift)
            .filter { calendar.component(.weekday, from: $0.date) == weekday }
        guard !matching.isEmpty else { return nil }
        return Double(matching.reduce(0) { $0 + $1.cents }) / Double(matching.count)
    }

    /// Per-day weekday average — used only by the pace projection, which
    /// estimates a full day's earnings for a future "usual" weekday.
    private func averageDayForWeekday(_ weekday: Int) -> Double? {
        let matching = nightlyTotals().filter { calendar.component(.weekday, from: $0.date) == weekday }
        guard !matching.isEmpty else { return nil }
        return Double(matching.reduce(0) { $0 + $1.cents }) / Double(matching.count)
    }

    private func nights(excludingDate: Date? = nil, excludingShift: UUID? = nil) -> [(date: Date, cents: Int)] {
        shiftTotals(excludingDate: excludingDate, excludingShift: excludingShift)
            .map { (date: $0.date, cents: $0.cents) }
    }

    // MARK: Rate ($/hr)

    /// Every night that has BOTH a logged total and logged hours — the only
    /// nights any $/hr number is allowed to touch. Hours resolve through
    /// nightFacts (credit-preferred, never summed across records).
    private func nightlyRates(excluding excludedDate: Date? = nil) -> [(date: Date, cents: Int, hours: Double)] {
        shiftFacts(from: records).compactMap { shift in
            if let excludedDate, calendar.isDate(shift.date, inSameDayAs: excludedDate) { return nil }
            guard let hours = shift.hoursWorked, hours > 0 else { return nil }
            return (date: shift.date, cents: shift.netCents, hours: hours)
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
        shiftFacts(from: records).compactMap { shift in
            if let excludedDate, calendar.isDate(shift.date, inSameDayAs: excludedDate) { return nil }
            guard let sales = shift.salesCents, sales > 0 else { return nil }
            return (date: shift.date, grossCents: shift.grossCents, salesCents: sales)
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
            if rhythm.usualWeekdays.contains(weekday), let average = averageDayForWeekday(weekday) {
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
    func isSlowestRecently(date: Date, cents: Int, lookbackShifts: Int, excludingShift: UUID? = nil) -> Bool {
        let priorNights = excludingShift.map { nights(excludingShift: $0) } ?? nights(excludingDate: date)
        guard priorNights.count >= 4 else { return false }
        let recent = priorNights.suffix(lookbackShifts)
        guard let minCents = recent.map(\.cents).min() else { return false }
        return cents <= minCents
    }

    // MARK: Reveal

    /// A shift's reveal-basis cents: net tips, plus that shift's wages when
    /// BOTH this engine's wageCentsPerHour and the shift's own hoursWorked
    /// are known. Falls back to plain netCents whenever either is missing —
    /// which is also every value this returns when wageCentsPerHour is nil,
    /// so the fork below is byte-identical to the tips-only path by
    /// default. Used ONLY by revealComparison's own helpers; every other
    /// caller in this file reads shiftFacts/netCents directly and never
    /// sees a wage.
    private func revealCents(of shift: ShiftFacts) -> Int {
        guard let wageCentsPerHour,
              let hours = shift.hoursWorked,
              let wage = WageEstimate.cents(wageCentsPerHour: wageCentsPerHour, hours: hours)
        else { return shift.netCents }
        return shift.netCents + wage
    }

    /// The reveal-basis twin of shiftTotals(excludingDate:excludingShift:) —
    /// same shape and filtering, priced with revealCents instead of
    /// netCents. Forked rather than flag-guarded so nothing outside
    /// revealComparison can accidentally pick up a wage-inclusive total.
    private func shiftTotalsForReveal(excludingDate: Date? = nil, excludingShift: UUID? = nil) -> [(shiftID: UUID, date: Date, cents: Int)] {
        shiftFacts(from: records)
            .filter { shift in
                if let excludingDate, calendar.isDate(shift.date, inSameDayAs: excludingDate) { return false }
                if let excludingShift, shift.shiftID == excludingShift { return false }
                return true
            }
            .map { (shiftID: $0.shiftID, date: $0.date, cents: revealCents(of: $0)) }
    }

    /// Reveal-basis twin of bestNightEver(excluding:excludingShift:).
    private func bestNightEverForReveal(excluding excludedDate: Date? = nil, excludingShift: UUID? = nil) -> (date: Date, cents: Int)? {
        shiftTotalsForReveal(excludingDate: excludedDate, excludingShift: excludingShift)
            .map { (date: $0.date, cents: $0.cents) }
            .max { $0.cents < $1.cents }
    }

    /// Reveal-basis twin of bestNight(forWeekday:excluding:excludingShift:).
    private func bestNightForRevealWeekday(_ weekday: Int, excluding excludedDate: Date? = nil, excludingShift: UUID? = nil) -> (date: Date, cents: Int)? {
        shiftTotalsForReveal(excludingDate: excludedDate, excludingShift: excludingShift)
            .filter { calendar.component(.weekday, from: $0.date) == weekday }
            .map { (date: $0.date, cents: $0.cents) }
            .max { $0.cents < $1.cents }
    }

    /// Reveal-basis twin of averageForWeekday(_:excluding:excludingShift:).
    private func averageForRevealWeekday(_ weekday: Int, excluding excludedDate: Date? = nil, excludingShift: UUID? = nil) -> Double? {
        let matching = shiftTotalsForReveal(excludingDate: excludedDate, excludingShift: excludingShift)
            .filter { calendar.component(.weekday, from: $0.date) == weekday }
        guard !matching.isEmpty else { return nil }
        return Double(matching.reduce(0) { $0 + $1.cents }) / Double(matching.count)
    }

    /// Reveal-basis twin of the private nights(excludingDate:excludingShift:).
    private func nightsForReveal(excludingDate: Date? = nil, excludingShift: UUID? = nil) -> [(date: Date, cents: Int)] {
        shiftTotalsForReveal(excludingDate: excludingDate, excludingShift: excludingShift)
            .map { (date: $0.date, cents: $0.cents) }
    }

    /// Reveal-basis twin of isSlowestRecently(date:cents:lookbackShifts:excludingShift:).
    private func isSlowestRecentlyForReveal(date: Date, cents: Int, lookbackShifts: Int, excludingShift: UUID? = nil) -> Bool {
        let priorNights = excludingShift.map { nightsForReveal(excludingShift: $0) } ?? nightsForReveal(excludingDate: date)
        guard priorNights.count >= 4 else { return false }
        let recent = priorNights.suffix(lookbackShifts)
        guard let minCents = recent.map(\.cents).min() else { return false }
        return cents <= minCents
    }

    /// Picks the one most interesting true thing about tonight, in priority
    /// order: all-time record, first shift of a period, weekday record,
    /// notably slow night, then the everyday weekday-average comparison.
    /// Stacks an independent $/hr clause underneath when hours were logged.
    /// `cents` must be the SAME basis this engine's history is compared
    /// on: pass the shift's displayed total — net tips, plus wages when a
    /// wage is set on this engine (Tyler's ruling, 2026-07-27) — never a
    /// tips-only figure alongside a wage-aware engine or vice versa.
    func reveal(forNightAt date: Date, cents: Int, period: PayPeriod, hoursWorked: Double? = nil, shiftID: UUID? = nil) -> RevealResult {
        let (comparison, isRecord) = revealComparison(forNightAt: date, cents: cents, period: period, shiftID: shiftID)
        return RevealResult(
            cents: cents,
            comparison: comparison,
            isRecord: isRecord,
            rateClause: rateClause(forNightAt: date, cents: cents, period: period, hoursWorked: hoursWorked)
        )
    }

    /// Every record check here excludes the shift being revealed itself: by
    /// shiftID when the caller knows it (a freshly-logged closeout), so a
    /// double day's dinner is compared against its own lunch and every prior
    /// shift; otherwise by the whole day (tests, the Dashboard echo). Either
    /// way each comparison is shift-to-shift, never against a summed day.
    private func revealComparison(forNightAt date: Date, cents: Int, period: PayPeriod, shiftID: UUID?) -> (RevealComparison, Bool) {
        // When a shiftID is given, exclude only that shift; otherwise exclude
        // the whole day (the pre-shift-grouping behavior).
        let excludingDate: Date? = shiftID == nil ? date : nil
        if bestNightEverForReveal(excluding: excludingDate, excludingShift: shiftID) == nil {
            return (.firstNightLogged, false)
        }
        if let best = bestNightEverForReveal(excluding: excludingDate, excludingShift: shiftID), cents > best.cents {
            return (.allTimeRecord(previousBestCents: best.cents), true)
        }
        if isFirstShiftOfPeriod(date: date, period: period) {
            return (.firstShiftOfPeriod, false)
        }
        let weekday = calendar.component(.weekday, from: date)
        if let bestWeekday = bestNightForRevealWeekday(weekday, excluding: excludingDate, excludingShift: shiftID), cents > bestWeekday.cents {
            return (.weekdayRecord(weekday: weekday, previousBestCents: bestWeekday.cents), true)
        }
        if isSlowestRecentlyForReveal(date: date, cents: cents, lookbackShifts: 8, excludingShift: shiftID) {
            return (.slowestRecently, false)
        }
        // No prior history for this weekday to average against — falling
        // back to "compare tonight against tonight" would always read as
        // "$0.00 above your ‹weekday› average," a self-referential
        // non-comparison. Say plainly that this is the first one instead.
        guard let average = averageForRevealWeekday(weekday, excluding: excludingDate, excludingShift: shiftID) else {
            return (.firstWeekdayLogged(weekday: weekday), false)
        }
        let deltaCents = cents - Int(average.rounded())
        let periodShifts = shiftTotalsForReveal(excludingDate: excludingDate, excludingShift: shiftID)
            .filter { $0.date >= period.start && $0.date <= period.end }
        // Rank this shift among the period's other logged shifts, plus itself.
        let rank = periodShifts.filter { $0.cents > cents }.count + 1
        let periodShiftCount = periodShifts.count
        let qualifyingRank = (periodShiftCount >= 3 && rank <= 3) ? rank : nil
        let weekdaySampleCount = nights(excludingDate: excludingDate, excludingShift: shiftID)
            .filter { calendar.component(.weekday, from: $0.date) == weekday }.count
        return (.weekdayAverage(weekday: weekday, deltaCents: deltaCents, periodRank: qualifyingRank, periodNightCount: periodShiftCount, sampleCount: weekdaySampleCount), false)
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

    // MARK: Plan forward

    /// Looks one week ahead, deterministically: what the next 7 days
    /// probably pay at this person's own rhythm, plus — only when the data
    /// honestly supports it — the one pickup shift worth chasing. No
    /// model, no narration, same discipline as moves() and
    /// projectedPeriodTotal. Self-contained types so the widget target
    /// that compiles this file stays happy.
    func planForward(referenceDate: Date = .now) -> PlanForward? {
        let rhythm = workRhythm(referenceDate: referenceDate)
        // No rhythm yet = nothing honest to project — same suppression
        // rule projectedPeriodTotal uses.
        guard !rhythm.usualWeekdays.isEmpty else { return nil }

        let allShifts = nights()
        guard !allShifts.isEmpty else { return nil }
        let overallAverageCents = Int((Double(allShifts.reduce(0) { $0 + $1.cents }) / Double(allShifts.count)).rounded())

        let today = calendar.startOfDay(for: referenceDate)
        let upcomingWeekdays: [Int] = (1...7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return calendar.component(.weekday, from: day)
        }

        func weekdayShiftCents(_ weekday: Int) -> [Int] {
            allShifts.filter { calendar.component(.weekday, from: $0.date) == weekday }.map(\.cents)
        }

        let planNights: [PlanForward.Night] = upcomingWeekdays
            .filter { rhythm.usualWeekdays.contains($0) }
            .map { weekday in
                let cents = weekdayShiftCents(weekday)
                // Below the same 3-night bar every other weekday-specific
                // claim in this file requires (minimumNightsForWeekdayBest)
                // — barely clearing workRhythm's own 2-night "usual" floor
                // isn't enough to trust a weekday's own price yet, so it
                // borrows the overall average instead. Mark nothing; the
                // count alongside it speaks for itself.
                let averageCents = cents.count >= Self.minimumNightsForWeekdayBest
                    ? Int((Double(cents.reduce(0, +)) / Double(cents.count)).rounded())
                    : overallAverageCents
                return PlanForward.Night(weekday: weekday, averageNetCents: averageCents, nightCount: cents.count)
            }

        let projectedTotalCents = planNights.reduce(0) { $0 + $1.averageNetCents }
        let pickup = planPickup(upcomingWeekdays: upcomingWeekdays, usualWeekdays: rhythm.usualWeekdays, planNights: planNights, weekdayShiftCents: weekdayShiftCents)

        return PlanForward(nights: planNights, projectedTotalCents: projectedTotalCents, pickup: pickup)
    }

    /// The single non-usual weekday in the coming week worth chasing —
    /// beats the lowest-priced usual night by both a flat floor and the
    /// same variance guard weekdaySwapMove uses, so a few lucky nights on
    /// an off-day can't read as a real signal. Silence (nil) beats weak
    /// advice.
    private func planPickup(upcomingWeekdays: [Int], usualWeekdays: Set<Int>, planNights: [PlanForward.Night], weekdayShiftCents: (Int) -> [Int]) -> PlanForward.Pickup? {
        guard let lowestUsual = planNights.min(by: { $0.averageNetCents < $1.averageNetCents }) else { return nil }
        let usualCents = weekdayShiftCents(lowestUsual.weekday)

        let candidates = upcomingWeekdays
            .filter { !usualWeekdays.contains($0) }
            .compactMap { weekday -> (weekday: Int, average: Double, cents: [Int])? in
                let cents = weekdayShiftCents(weekday)
                guard cents.count >= Self.minimumNightsForWeekdayBest else { return nil }
                return (weekday, Double(cents.reduce(0, +)) / Double(cents.count), cents)
            }

        let qualifying = candidates.filter { candidate in
            let deltaCents = Int((candidate.average - Double(lowestUsual.averageNetCents)).rounded())
            guard deltaCents > 0 else { return false }
            let pooledSD = pooledStandardDeviationCents(candidate.cents, usualCents)
            let requiredDelta = max(MoveThresholds.minimumWeekdaySwapDeltaCents, Int((MoveThresholds.varianceGuardFactor * pooledSD).rounded()))
            return deltaCents >= requiredDelta
        }

        guard let best = qualifying.max(by: { $0.average < $1.average }) else { return nil }
        return PlanForward.Pickup(weekday: best.weekday, averageNetCents: Int(best.average.rounded()), nightCount: best.cents.count)
    }

    // MARK: Insights facts

    static let minimumShiftsForInsights = 5
    static let insightsRecentWindowDays = 180
    /// Lower bar than minimumShiftsForInsights on purpose — hours-logging
    /// is optional, so RATE facts should surface as soon as there's a
    /// handful of nights to blend, not wait for the full insights gate.
    static let minimumNightsForRate = 3
    /// Same reasoning as minimumNightsForRate, for sales-logging.
    static let minimumNightsForSales = 3
    /// A start-hour bucket (see StartTimeFacts) needs at least this many
    /// qualifying shifts before its blended rate counts as anything more
    /// than noise — same >= 3 floor every other weekday-keyed comparison
    /// in this file already requires.
    static let minimumShiftsPerStartBucket = 3
    /// A "best-paying weekday" claim needs at least this many nights on that
    /// weekday. One $50/hr Tuesday is an anecdote, not a pattern — Insights
    /// once told Tyler to "seek Tuesday shifts" off a single night.
    static let minimumNightsForWeekdayBest = 3
    /// The cash-weekday fact's rest-of-week pool needs this many qualifying
    /// shifts of its own before it's a fair baseline to compare against —
    /// same spirit as lapsedWinnerMove's own 6-night floor.
    static let minimumRestOfWeekShiftsForCashWeekday = 6
    /// Materiality floor for the cash-heavy-weekday fact, in cents — a
    /// weekday with barely $50 of actual cash isn't worth naming even if
    /// the percentage looks dramatic.
    static let minimumCashWeekdayCashCents = 5000
    /// Deliberate calibration, not derived from anything, same spirit as
    /// MoveThresholds.varianceGuardFactor: a weekday's cash share has to run
    /// at least 15 points hotter than the rest of the week, as a fraction
    /// (0.15 = 15 percentage points), before it's worth naming rather than
    /// noise.
    static let minimumCashWeekdayShareDelta = 0.15

    /// Every number Insights is allowed to talk about — computed here, not
    /// by the model. "The stats engine computes facts; the model narrates
    /// them. Never let the model do arithmetic." Nil when there isn't
    /// enough recent history yet.
    func insightsFacts(referenceDate: Date = .now) -> InsightsFacts? {
        let cutoff = calendar.date(byAdding: .day, value: -Self.insightsRecentWindowDays, to: referenceDate) ?? .distantPast
        let recent = records.filter { $0.date >= cutoff }
        let shifts = shiftFacts(from: recent)

        guard shifts.count >= Self.minimumShiftsForInsights else { return nil }

        let totalCents = shifts.reduce(0) { $0 + $1.netCents }
        // Top earning DAYS, not shifts — a double day's combined take is one
        // day's earnings here, so sum shifts back up per calendar day.
        let dayNet = Dictionary(grouping: shifts, by: { $0.date }).mapValues { $0.reduce(0) { $0 + $1.netCents } }
        let topDays = dayNet.sorted { $0.value > $1.value }.prefix(3).map { InsightsFacts.DayAmount(date: $0.key, cents: $0.value) }
        // Each shift's canonical tip-out, never the raw per-record sum — a
        // shift with a (legacy) value on both entries would otherwise
        // count it twice here too.
        let totalTipOutCents = shifts.compactMap(\.tipOutCents).reduce(0, +)

        // The worker's own notes, newest first — context the narration can
        // use to explain an anomalous day instead of reading a pattern into
        // it (a POS outage note beats any inference). Deduped per day+text
        // (a shift's rows share one note), capped in count and length so
        // the prompt stays bounded.
        var seenNoteKeys = Set<String>()
        let notes: [InsightsFacts.NoteFact] = recent
            .sorted { $0.date > $1.date }
            .compactMap { record in
                guard let raw = record.note?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
                let text = String(raw.prefix(200))
                let key = "\(record.date.timeIntervalSinceReferenceDate)|\(text)"
                guard seenNoteKeys.insert(key).inserted else { return nil }
                return InsightsFacts.NoteFact(date: record.date, text: text)
            }

        return InsightsFacts(
            totalCents: totalCents,
            shiftCount: shifts.count,
            averagePerShiftCents: totalCents / shifts.count,
            topDays: Array(topDays),
            lunchDinner: lunchDinnerFacts(from: shifts),
            doublesSolo: doublesSoloFacts(from: shifts),
            totalTipOutCents: totalTipOutCents,
            rate: rateFacts(from: shifts),
            sales: salesFacts(from: shifts),
            startTime: startTimeFacts(from: shifts),
            cashWeekday: cashWeekdayFacts(from: shifts),
            notes: Array(notes.prefix(10))
        )
    }

    /// The one cash fact Insights is allowed to surface: which weekday runs
    /// meaningfully more cash than the rest of the week — never a general
    /// cash-vs-credit split, which is just a server's known pay structure
    /// and never an insight. A shift only counts toward its weekday when it
    /// actually earned something (grossCents > 0), and every share is
    /// blended (total cash over total gross), never an average of nightly
    /// shares, so one $200 cash night can't outweigh three $20 ones.
    private func cashWeekdayFacts(from shifts: [ShiftFacts]) -> CashWeekdayFacts? {
        let qualifying = shifts.filter { $0.grossCents > 0 }
        let byWeekday = Dictionary(grouping: qualifying) { calendar.component(.weekday, from: $0.date) }

        let candidates = byWeekday.compactMap { weekday, weekdayShifts -> CashWeekdayFacts? in
            guard weekdayShifts.count >= Self.minimumNightsForWeekdayBest else { return nil }

            let restShifts = qualifying.filter { calendar.component(.weekday, from: $0.date) != weekday }
            guard restShifts.count >= Self.minimumRestOfWeekShiftsForCashWeekday else { return nil }

            let weekdayCash = weekdayShifts.reduce(0) { $0 + $1.cashCents }
            guard weekdayCash >= Self.minimumCashWeekdayCashCents else { return nil }
            let weekdayGross = weekdayShifts.reduce(0) { $0 + $1.grossCents }
            let weekdayShare = Double(weekdayCash) / Double(weekdayGross)

            let restCash = restShifts.reduce(0) { $0 + $1.cashCents }
            let restGross = restShifts.reduce(0) { $0 + $1.grossCents }
            guard restGross > 0 else { return nil }
            let restShare = Double(restCash) / Double(restGross)

            guard weekdayShare - restShare >= Self.minimumCashWeekdayShareDelta else { return nil }

            return CashWeekdayFacts(
                weekday: weekday,
                sharePercent: weekdayShare * 100,
                restSharePercent: restShare * 100,
                nightCount: weekdayShifts.count
            )
        }

        return candidates.max { ($0.sharePercent - $0.restSharePercent) < ($1.sharePercent - $1.restSharePercent) }
    }

    /// Explicit shiftPeriod wins when a night actually recorded one;
    /// legacy nights (logged before this field existed, or never set)
    /// fall back to the same-day-logged recordedAt proxy — a logged time
    /// only means something as a lunch-vs-dinner proxy when it was
    /// recorded the same day it was earned, so a backfilled legacy night
    /// stays excluded rather than guessed at. Shared by lunchDinnerFacts
    /// and rateFacts' own lunch/dinner split so both apply the identical
    /// rule.
    private func classifyByShiftPeriod(_ shifts: [ShiftFacts]) -> [(shiftID: UUID, date: Date, period: ShiftPeriod)] {
        shifts.compactMap { shift in
            if let explicit = shift.shiftPeriod { return (shift.shiftID, shift.date, explicit) }
            guard let recordedAt = shift.recordedAt, calendar.isDate(recordedAt, inSameDayAs: shift.date) else { return nil }
            let hour = calendar.component(.hour, from: recordedAt)
            return (shift.shiftID, shift.date, hour < 16 ? .lunch : .dinner)
        }
    }

    /// Same recent window as the rest of insightsFacts, reading sales
    /// through nightFacts — deliberately GROSS (grossCents, not netCents),
    /// same rule as tipPercent() above.
    private func salesFacts(from shifts: [ShiftFacts]) -> SalesFacts? {
        let salesNights = shifts.compactMap { shift -> (date: Date, grossCents: Int, salesCents: Int)? in
            guard let sales = shift.salesCents, sales > 0 else { return nil }
            return (date: shift.date, grossCents: shift.grossCents, salesCents: sales)
        }
        guard salesNights.count >= Self.minimumNightsForSales, let overall = blendedTipPercent(salesNights) else { return nil }

        let weekdayPercents = (1...7).compactMap { weekday -> (weekday: Int, percent: Double, count: Int)? in
            let matching = salesNights.filter { calendar.component(.weekday, from: $0.date) == weekday }
            guard let percent = blendedTipPercent(matching) else { return nil }
            return (weekday, percent, matching.count)
        }
        // Only weekdays with a real sample can compete for "best", and a
        // winner needs a runner-up to beat — see minimumNightsForWeekdayBest.
        let qualifiedPercents = weekdayPercents.filter { $0.count >= Self.minimumNightsForWeekdayBest }
        let bestWeekday = qualifiedPercents.count >= 2 ? qualifiedPercents.max { $0.percent < $1.percent } : nil

        return SalesFacts(
            overallTipPercent: overall,
            nightsWithSales: salesNights.count,
            bestWeekday: bestWeekday?.weekday,
            bestWeekdayTipPercent: bestWeekday?.percent,
            bestWeekdayNightCount: bestWeekday?.count
        )
    }

    /// Same recent window as the rest of insightsFacts — a $/hr number from
    /// a year-old shift wouldn't reflect what tonight's rate actually is.
    private func rateFacts(from shifts: [ShiftFacts]) -> RateFacts? {
        let rateShifts = shifts.compactMap { shift -> (shiftID: UUID, date: Date, cents: Int, hours: Double)? in
            guard let hours = shift.hoursWorked, hours > 0 else { return nil }
            return (shiftID: shift.shiftID, date: shift.date, cents: shift.netCents, hours: hours)
        }
        func rate(_ list: [(shiftID: UUID, date: Date, cents: Int, hours: Double)]) -> Double? {
            blendedRate(list.map { (date: $0.date, cents: $0.cents, hours: $0.hours) })
        }
        guard rateShifts.count >= Self.minimumNightsForRate, let overall = rate(rateShifts) else { return nil }

        let weekdayRates = (1...7).compactMap { weekday -> (weekday: Int, rate: Double, count: Int)? in
            let matching = rateShifts.filter { calendar.component(.weekday, from: $0.date) == weekday }
            guard let r = rate(matching) else { return nil }
            return (weekday, r, matching.count)
        }
        // Same sample floor as salesFacts' weekday-best — a single hot night
        // must never crown a weekday (see minimumNightsForWeekdayBest).
        let qualifiedRates = weekdayRates.filter { $0.count >= Self.minimumNightsForWeekdayBest }
        let bestWeekday = qualifiedRates.count >= 2 ? qualifiedRates.max { $0.rate < $1.rate } : nil

        // A "double" is a calendar day with 2+ shifts; split rates by whether
        // the shift was worked on such a day.
        let doubleDayDates = doubleDayDateSet(from: shifts)
        let doubleRate = rate(rateShifts.filter { doubleDayDates.contains($0.date) })
        let soloRate = rate(rateShifts.filter { !doubleDayDates.contains($0.date) })

        let classified = classifyByShiftPeriod(shifts)
        let lunchIDs = Set(classified.filter { $0.period == .lunch }.map(\.shiftID))
        let dinnerIDs = Set(classified.filter { $0.period == .dinner }.map(\.shiftID))
        let lunchRate = rate(rateShifts.filter { lunchIDs.contains($0.shiftID) })
        let dinnerRate = rate(rateShifts.filter { dinnerIDs.contains($0.shiftID) })

        return RateFacts(
            overallDollarsPerHour: overall,
            nightsWithHours: rateShifts.count,
            bestWeekday: bestWeekday?.weekday,
            bestWeekdayDollarsPerHour: bestWeekday?.rate,
            bestWeekdayNightCount: bestWeekday?.count,
            lunchDollarsPerHour: lunchRate,
            dinnerDollarsPerHour: dinnerRate,
            doubleDollarsPerHour: doubleRate,
            soloDollarsPerHour: soloRate
        )
    }

    /// $/hr by start-time bucket (see StartTimeFacts) — same recent window
    /// as the rest of insightsFacts. We only ever know a SHIFT's total, never
    /// how pay was distributed within it, so this is honestly a shift-vs-
    /// shift comparison by when the shift started, never a claim about which
    /// minute of a shift paid better. Buckets on the exact clock-in hour
    /// (17 = "5 PM starts"); a bucket needs >= minimumShiftsPerStartBucket
    /// qualifying shifts, and there need to be at least two such buckets,
    /// before there's anything to call "best" or "worst" against.
    private func startTimeFacts(from shifts: [ShiftFacts]) -> StartTimeFacts? {
        let qualifying = shifts.compactMap { shift -> (hour: Int, date: Date, cents: Int, hours: Double)? in
            guard let hours = shift.hoursWorked, hours > 0, let clockIn = shift.clockIn else { return nil }
            return (hour: calendar.component(.hour, from: clockIn), date: shift.date, cents: shift.netCents, hours: hours)
        }
        let buckets = Dictionary(grouping: qualifying, by: { $0.hour })
            .filter { $0.value.count >= Self.minimumShiftsPerStartBucket }
            .compactMap { hour, group -> (hour: Int, rate: Double, count: Int)? in
                guard let rate = blendedRate(group.map { (date: $0.date, cents: $0.cents, hours: $0.hours) }) else { return nil }
                return (hour: hour, rate: rate, count: group.count)
            }
        guard buckets.count >= 2,
              let best = buckets.max(by: { $0.rate < $1.rate }),
              let worst = buckets.min(by: { $0.rate < $1.rate }),
              best.hour != worst.hour
        else { return nil }
        return StartTimeFacts(
            bestStartHour: best.hour,
            bestDollarsPerHour: best.rate,
            bestShiftCount: best.count,
            worstStartHour: worst.hour,
            worstDollarsPerHour: worst.rate,
            worstShiftCount: worst.count
        )
    }

    /// A shift counts once here, never once per cash+credit record — see
    /// classifyByShiftPeriod for the explicit-vs-proxy rule. A double day
    /// correctly contributes both its lunch and its dinner shift.
    private func lunchDinnerFacts(from shifts: [ShiftFacts]) -> LunchDinnerFacts? {
        let classified = classifyByShiftPeriod(shifts)
        guard classified.count >= Self.minimumShiftsForInsights else { return nil }

        let shiftsByID = Dictionary(uniqueKeysWithValues: shifts.map { ($0.shiftID, $0) })
        let lunch = classified.filter { $0.period == .lunch }.compactMap { shiftsByID[$0.shiftID] }
        let dinner = classified.filter { $0.period == .dinner }.compactMap { shiftsByID[$0.shiftID] }
        guard !lunch.isEmpty, !dinner.isEmpty else { return nil }

        return LunchDinnerFacts(
            lunchCents: lunch.reduce(0) { $0 + $1.grossCents },
            lunchShiftCount: lunch.count,
            dinnerCents: dinner.reduce(0) { $0 + $1.grossCents },
            dinnerShiftCount: dinner.count
        )
    }

    /// The set of calendar days that hold 2+ shifts — the days that are
    /// "doubles" now that a double is emergent, not a flag.
    private func doubleDayDateSet(from shifts: [ShiftFacts]) -> Set<Date> {
        let byDay = Dictionary(grouping: shifts, by: { $0.date })
        return Set(byDay.filter { $0.value.count >= 2 }.keys)
    }

    // MARK: Moves

    private enum MoveThresholds {
        /// Below this, silence beats weak advice — the whole point of the
        /// materiality gate.
        static let minimumAnnualImpactCents = 10000
        static let minimumWeekdayDeltaCents = 1000
        /// Raised from the old flat $10 floor: weekdaySwapMove's variance
        /// guard uses this as the absolute minimum regardless of spread.
        static let minimumWeekdaySwapDeltaCents = 1500
        static let minimumRateDeltaCents = 300
        static let minimumTipPercentDelta = 3.0
        /// rateLeaderMove and tipPercentSignalMove each pick a "best"
        /// weekday from whichever weekday has the highest average — but an
        /// average of ONE night isn't a pattern, it's a coincidence dressed
        /// up as one ("Sunday pays best... across 1 night" is not a
        /// recommendation, it's noise). Both gate their cited weekday's own
        /// night count against this floor before firing.
        static let minimumWeekdayNightsForCitedMove = 2
        static let lapsedWindowDays = 21
        /// Every weekday-keyed move (swap, lapsed winner, rate leader)
        /// already requires >= 3 nights of history for that weekday before
        /// firing — treating that as "roughly weekly" is a fair, stated
        /// extrapolation, not a wild guess.
        static let assumedWeeksPerYear = 52.0
        /// Deliberate calibration, not derived from anything: a delta has
        /// to clear roughly 0.6x the pooled per-night spread (loosely,
        /// "more than half a standard deviation apart") before a weekday
        /// comparison counts as signal rather than noise. Tune here if
        /// Moves feels too eager or too quiet in practice.
        static let varianceGuardFactor = 0.6
        /// A Move's comparison can be real (the 3-night floor above lets it
        /// through) while a year-long dollar projection off it still
        /// overclaims - 23 Saturdays against 3 Tuesdays is a fair thing to
        /// notice, not a fair thing to annualize into a five-figure number.
        /// Both sides of a Move's comparison need this many qualifying
        /// shifts before it states its annualized figure; thinner than
        /// this on either side and it hedges instead (see annualizedClause).
        static let minimumShiftsForAnnualizedImpact = 8
    }

    /// One side of an annualized Move's comparison - how many qualifying
    /// shifts back it, and what to call it if it turns out to be the thin
    /// side of a hedge. See annualizedClause.
    private struct MoveComparisonSide {
        let count: Int
        let singular: String
        let plural: String
    }

    /// Every annualizing Move's closing clause routes through here. States
    /// the confident sentence only when BOTH sides of the comparison clear
    /// MoveThresholds.minimumShiftsForAnnualizedImpact; otherwise returns a
    /// plain hedge naming whichever side is thinner, with no dollar figure
    /// anywhere in it - the comparison itself may still be real (that's
    /// what each move's own 2-3 night gate already established), but a
    /// year-long projection off a handful of shifts is not.
    private func annualizedClause(_ sentence: @autoclosure () -> String, _ sideA: MoveComparisonSide, _ sideB: MoveComparisonSide) -> String {
        guard sideA.count >= MoveThresholds.minimumShiftsForAnnualizedImpact,
              sideB.count >= MoveThresholds.minimumShiftsForAnnualizedImpact
        else {
            let thin = sideA.count <= sideB.count ? sideA : sideB
            let noun = thin.count == 1 ? thin.singular : thin.plural
            return "Only \(thin.count) \(noun) to compare against so far."
        }
        return sentence()
    }

    /// Up to 3 dollar-quantified, ranked observations - deterministic and
    /// pure like the rest of this file, no model, no network. Silence over
    /// weak advice: an empty array is a valid, honest answer when nothing
    /// clears the materiality bar.
    ///
    /// Ranks by annualImpactCents first, THEN de-duplicates by weekday
    /// subject (see MoveCandidate) so the same weekday can't show up
    /// twice wearing two different Moves - "Saturday Beats Tuesday" and
    /// "Saturday Pays Best Per Hour" stacked is the same finding said
    /// twice, not two findings. The higher-ranked Move for a subject wins;
    /// the cap of 3 is applied last, after dedup.
    func moves(referenceDate: Date = .now) -> [Move] {
        let candidates = [
            weekdaySwapMove(),
            lapsedWinnerMove(referenceDate: referenceDate),
            doublesVerdictMove(referenceDate: referenceDate),
            rateLeaderMove(),
            tipPercentSignalMove(),
            startTimeLeaderMove()
        ].compactMap { $0 }
        let ranked = candidates
            .filter { $0.move.annualImpactCents >= MoveThresholds.minimumAnnualImpactCents }
            .sorted { $0.move.annualImpactCents > $1.move.annualImpactCents }

        var seenSubjects = Set<Int>()
        var deduped: [Move] = []
        for candidate in ranked {
            if let subject = candidate.weekdaySubject, !seenSubjects.insert(subject).inserted {
                continue
            }
            deduped.append(candidate.move)
            if deduped.count == 3 { break }
        }
        return deduped
    }

    /// One candidate out of moves()' own builders, paired with the single
    /// weekday it's "about," if any - the key moves() de-duplicates on.
    /// weekdaySwapMove/lapsedWinnerMove/rateLeaderMove are each fundamentally
    /// a "this weekday is the one to lean into" claim, so they carry the
    /// weekday they're praising. doublesVerdictMove/startTimeLeaderMove/
    /// tipPercentSignalMove are claims about a different axis (doubles,
    /// start hour, tip percent) and carry no subject, even where their own
    /// copy happens to name a weekday.
    private struct MoveCandidate {
        let move: Move
        let weekdaySubject: Int?
    }

    /// Best-paying weekday against worst-paying weekday, both net, both
    /// needing >= 3 nights of their own history to qualify, and gated by
    /// a variance guard so three lucky Fridays against three slow Mondays
    /// can't recommend a schedule change off pure noise.
    private func weekdaySwapMove() -> MoveCandidate? {
        let allNights = nightlyTotals()
        let weekdayAverages = weekdayNightAverages(allNights)
        guard weekdayAverages.count >= 2,
              let best = weekdayAverages.max(by: { $0.avg < $1.avg }),
              let worst = weekdayAverages.min(by: { $0.avg < $1.avg }),
              best.weekday != worst.weekday
        else { return nil }
        let deltaCents = Int((best.avg - worst.avg).rounded())

        let pooledSD = pooledStandardDeviationCents(best.nightCents, worst.nightCents)
        let requiredDelta = max(MoveThresholds.minimumWeekdaySwapDeltaCents, Int((MoveThresholds.varianceGuardFactor * pooledSD).rounded()))
        guard deltaCents >= requiredDelta else { return nil }

        let bestName = Calendar.current.weekdaySymbols[best.weekday - 1]
        let worstName = Calendar.current.weekdaySymbols[worst.weekday - 1]
        let annualImpact = Int(Double(deltaCents) * MoveThresholds.assumedWeeksPerYear)
        let closingClause = annualizedClause(
            "Over a year of regular shifts, that gap is worth about \(Money.wholeDollarString(fromCents: annualImpact)).",
            MoveComparisonSide(count: best.count, singular: bestName, plural: "\(bestName)s"),
            MoveComparisonSide(count: worst.count, singular: worstName, plural: "\(worstName)s")
        )
        let move = Move(
            id: "weekdaySwap",
            title: "\(bestName) Beats \(worstName)",
            body: "\(bestName)s average \(Money.string(fromCents: Int(best.avg.rounded()))) across \(best.count) \(bestName)s, against \(Money.string(fromCents: Int(worst.avg.rounded()))) across \(worst.count) \(worstName)s. \(closingClause)",
            annualImpactCents: annualImpact
        )
        return MoveCandidate(move: move, weekdaySubject: best.weekday)
    }

    /// Pooled per-night standard deviation across two independent samples —
    /// combines each group's own spread around its own mean, weighted by
    /// degrees of freedom, so the variance guard reflects how noisy BOTH
    /// weekdays actually are, not just one.
    private func pooledStandardDeviationCents(_ groupA: [Int], _ groupB: [Int]) -> Double {
        func sumSquaredDeviations(_ values: [Int]) -> Double {
            guard !values.isEmpty else { return 0 }
            let mean = Double(values.reduce(0, +)) / Double(values.count)
            return values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
        }
        let degreesOfFreedom = groupA.count + groupB.count - 2
        guard degreesOfFreedom > 0 else { return 0 }
        let pooledVariance = (sumSquaredDeviations(groupA) + sumSquaredDeviations(groupB)) / Double(degreesOfFreedom)
        return pooledVariance.squareRoot()
    }

    /// A weekday that used to pay well but hasn't shown up recently.
    private func lapsedWinnerMove(referenceDate: Date) -> MoveCandidate? {
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
        let closingClause = annualizedClause(
            "Getting back to a regular \(weekdayName) is worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year.",
            MoveComparisonSide(count: best.count, singular: weekdayName, plural: "\(weekdayName)s"),
            MoveComparisonSide(count: allNights.count, singular: "night", plural: "nights")
        )
        let move = Move(
            id: "lapsedWinner",
            title: "\(weekdayName) Has Gone Quiet",
            body: "You haven't worked a \(weekdayName) in a few weeks, but it's one of your best - averaging \(Money.string(fromCents: Int(best.avg.rounded()))) a day across \(best.count) \(weekdayName)s. \(closingClause)",
            annualImpactCents: annualImpact
        )
        return MoveCandidate(move: move, weekdaySubject: best.weekday)
    }

    /// Doubles are usually judged by $/shift (see doublesSoloFacts); this
    /// checks the same split by $/hr, which can point the other way once
    /// the extra hours are accounted for.
    private func doublesVerdictMove(referenceDate: Date) -> MoveCandidate? {
        let doubleDates = doubleDayDateSet(from: shiftFacts(from: records))
        guard !doubleDates.isEmpty else { return nil }
        let allRates = nightlyRates()
        let doubleRates = allRates.filter { doubleDates.contains($0.date) }
        let soloRates = allRates.filter { !doubleDates.contains($0.date) }
        guard !doubleRates.isEmpty, let doubleRate = blendedRate(doubleRates), let soloRate = blendedRate(soloRates) else { return nil }
        let deltaPerHourCents = Int(((doubleRate - soloRate) * 100).rounded())
        guard abs(deltaPerHourCents) >= MoveThresholds.minimumRateDeltaCents else { return nil }

        // A double is a calendar DAY with 2+ shifts, so count and project by
        // double-days, not by the individual closeouts that make them up.
        // Doubles don't land on a fixed weekly cadence, so extrapolate from
        // how often they've actually happened over the tenure so far.
        let doubleDayCount = Set(doubleRates.map(\.date)).count
        guard let earliestNight = nightlyTotals().first?.date, doubleDayCount > 0 else { return nil }
        let tenureDays = max(1, calendar.dateComponents([.day], from: earliestNight, to: referenceDate).day ?? 1)
        let doublesPerYear = Double(doubleDayCount) * 365.0 / Double(tenureDays)
        // Hours per double DAY (both closeouts), not per closeout.
        let avgDoubleHours = doubleRates.reduce(0.0) { $0 + $1.hours } / Double(doubleDayCount)
        let annualImpact = Int(abs(doubleRate - soloRate) * avgDoubleHours * doublesPerYear * 100)

        let doubleWins = doubleRate > soloRate
        let closingClause = annualizedClause(
            "At your current pace, that's worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year.",
            MoveComparisonSide(count: doubleDayCount, singular: "double", plural: "doubles"),
            MoveComparisonSide(count: soloRates.count, singular: "solo shift", plural: "solo shifts")
        )
        let move = Move(
            id: "doublesVerdict",
            title: doubleWins ? "Doubles Pay Off" : "Doubles Cost You",
            body: "Doubles average \(Money.wholeDollarString(fromCents: Int((doubleRate * 100).rounded())))/hr across \(countPhrase(doubleDayCount, singular: "double", plural: "doubles")), against \(Money.wholeDollarString(fromCents: Int((soloRate * 100).rounded())))/hr solo across \(countPhrase(soloRates.count, singular: "solo shift", plural: "solo shifts")) - doubles \(doubleWins ? "pay better" : "pay worse") per hour, not just per shift. \(closingClause)",
            annualImpactCents: annualImpact
        )
        return MoveCandidate(move: move, weekdaySubject: nil)
    }

    /// The best-paying weekday by $/hr against the overall $/hr average -
    /// a genuinely different fact from weekdaySwapMove, which compares
    /// $/night.
    private func rateLeaderMove() -> MoveCandidate? {
        guard let best = bestDollarsPerHourWeekday(), let overallRate = averageDollarsPerHour() else { return nil }
        let deltaPerHourCents = Int(((best.rate - overallRate) * 100).rounded())

        let allRates = nightlyRates()
        let weekdayRates = allRates.filter { calendar.component(.weekday, from: $0.date) == best.weekday }
        let otherRates = allRates.filter { calendar.component(.weekday, from: $0.date) != best.weekday }
        guard weekdayRates.count >= MoveThresholds.minimumWeekdayNightsForCitedMove, !otherRates.isEmpty else { return nil }

        // Same variance guard as weekdaySwapMove, applied to $/hr instead
        // of $/night: pools this weekday's per-night rates against every
        // other rate night so a couple of lucky high-rate nights can't
        // look like a real signal against noisy history.
        func centsPerHour(_ night: (date: Date, cents: Int, hours: Double)) -> Int {
            Int((Double(night.cents) / night.hours).rounded())
        }
        let pooledSD = pooledStandardDeviationCents(weekdayRates.map(centsPerHour), otherRates.map(centsPerHour))
        let requiredDelta = max(MoveThresholds.minimumRateDeltaCents, Int((MoveThresholds.varianceGuardFactor * pooledSD).rounded()))
        guard deltaPerHourCents >= requiredDelta else { return nil }

        let avgHours = weekdayRates.reduce(0.0) { $0 + $1.hours } / Double(weekdayRates.count)
        let annualImpact = Int((best.rate - overallRate) * avgHours * MoveThresholds.assumedWeeksPerYear * 100)
        guard annualImpact >= MoveThresholds.minimumAnnualImpactCents else { return nil }

        let weekdayName = Calendar.current.weekdaySymbols[best.weekday - 1]
        let closingClause = annualizedClause(
            "Working \(weekdayName)s regularly is worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year over your average rate.",
            MoveComparisonSide(count: weekdayRates.count, singular: weekdayName, plural: "\(weekdayName)s"),
            MoveComparisonSide(count: otherRates.count, singular: "shift", plural: "shifts")
        )
        let move = Move(
            id: "rateLeader",
            title: "\(weekdayName) Pays Best Per Hour",
            body: "\(weekdayName)s average \(Money.wholeDollarString(fromCents: Int((best.rate * 100).rounded())))/hr across \(countPhrase(weekdayRates.count, singular: "shift", plural: "shifts")), against \(Money.wholeDollarString(fromCents: Int((overallRate * 100).rounded())))/hr overall. \(closingClause)",
            annualImpactCents: annualImpact
        )
        return MoveCandidate(move: move, weekdaySubject: best.weekday)
    }

    /// Best-paying start-hour bucket against worst-paying (see
    /// StartTimeFacts) — a genuinely different fact from rateLeaderMove
    /// (which compares weekdays) and weekdaySwapMove ($/night): this is
    /// about WHEN a shift starts, recomputed over ALL history like every
    /// other Move here, not the 180-day insights window.
    private func startTimeLeaderMove() -> MoveCandidate? {
        guard let facts = startTimeFacts(from: shiftFacts(from: records)) else { return nil }
        let deltaPerHourCents = Int(((facts.bestDollarsPerHour - facts.worstDollarsPerHour) * 100).rounded())
        guard deltaPerHourCents >= MoveThresholds.minimumRateDeltaCents else { return nil }

        // Variance guard, same spirit as rateLeaderMove: pool the best
        // bucket's per-shift $/hr against the worst bucket's so a handful of
        // lucky late starts can't look like real signal against noisy history.
        let qualifying = shiftFacts(from: records).compactMap { shift -> (hour: Int, cents: Int, hours: Double)? in
            guard let hours = shift.hoursWorked, hours > 0, let clockIn = shift.clockIn else { return nil }
            return (hour: calendar.component(.hour, from: clockIn), cents: shift.netCents, hours: hours)
        }
        func centsPerHour(_ shift: (hour: Int, cents: Int, hours: Double)) -> Int {
            Int((Double(shift.cents) / shift.hours).rounded())
        }
        let bestGroup = qualifying.filter { $0.hour == facts.bestStartHour }
        let worstGroup = qualifying.filter { $0.hour == facts.worstStartHour }
        guard !bestGroup.isEmpty, !worstGroup.isEmpty else { return nil }
        let pooledSD = pooledStandardDeviationCents(bestGroup.map(centsPerHour), worstGroup.map(centsPerHour))
        let requiredDelta = max(MoveThresholds.minimumRateDeltaCents, Int((MoveThresholds.varianceGuardFactor * pooledSD).rounded()))
        guard deltaPerHourCents >= requiredDelta else { return nil }

        let avgHours = bestGroup.reduce(0.0) { $0 + $1.hours } / Double(bestGroup.count)
        let annualImpact = Int((facts.bestDollarsPerHour - facts.worstDollarsPerHour) * avgHours * MoveThresholds.assumedWeeksPerYear * 100)
        guard annualImpact >= MoveThresholds.minimumAnnualImpactCents else { return nil }

        // "later"/"earlier" is a real directional claim, not filler — get it
        // right regardless of which bucket happens to be the best one.
        let direction = facts.bestStartHour > facts.worstStartHour ? "later" : "earlier"
        let bestHourLabel = hourLabel(facts.bestStartHour)
        let worstHourLabel = hourLabel(facts.worstStartHour)
        let closingClause = annualizedClause(
            "The \(direction) start is worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year at your usual hours.",
            MoveComparisonSide(count: facts.bestShiftCount, singular: "\(bestHourLabel) start", plural: "\(bestHourLabel) starts"),
            MoveComparisonSide(count: facts.worstShiftCount, singular: "\(worstHourLabel) start", plural: "\(worstHourLabel) starts")
        )
        let move = Move(
            id: "startTimeLeader",
            title: "\(bestHourLabel) Starts Pay Best",
            body: "Shifts you start around \(bestHourLabel) average \(Money.wholeDollarString(fromCents: Int((facts.bestDollarsPerHour * 100).rounded())))/hr across \(countPhrase(facts.bestShiftCount, singular: "shift", plural: "shifts")), against \(Money.wholeDollarString(fromCents: Int((facts.worstDollarsPerHour * 100).rounded())))/hr around \(worstHourLabel). \(closingClause)",
            annualImpactCents: annualImpact
        )
        return MoveCandidate(move: move, weekdaySubject: nil)
    }

    /// Renders a start-hour bucket key as "5 PM" / "11 AM" — builds an
    /// actual Date at that hour and lets Date.FormatStyle render it, so the
    /// am/pm convention (or 24-hour clock, for locales that use one) always
    /// matches the user's own locale instead of hand-rolled am/pm math.
    private func hourLabel(_ hour: Int) -> String {
        let anchored = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return anchored.formatted(.dateTime.hour())
    }

    /// The best tip-percent weekday against the overall tip-percent average.
    private func tipPercentSignalMove() -> MoveCandidate? {
        guard let overallPercent = averageTipPercent() else { return nil }
        let weekdayPercents = (1...7).compactMap { weekday -> (weekday: Int, percent: Double)? in
            averageTipPercent(forWeekday: weekday).map { (weekday: weekday, percent: $0) }
        }
        guard weekdayPercents.count >= 2, let best = weekdayPercents.max(by: { $0.percent < $1.percent }) else { return nil }
        let deltaPercent = best.percent - overallPercent
        guard deltaPercent >= MoveThresholds.minimumTipPercentDelta else { return nil }

        let weekdaySales = nightlySalesRates().filter { calendar.component(.weekday, from: $0.date) == best.weekday }
        guard weekdaySales.count >= MoveThresholds.minimumWeekdayNightsForCitedMove else { return nil }
        let avgSales = Double(weekdaySales.reduce(0) { $0 + $1.salesCents }) / Double(weekdaySales.count)
        let annualImpact = Int((deltaPercent / 100) * avgSales * MoveThresholds.assumedWeeksPerYear)
        guard annualImpact >= MoveThresholds.minimumAnnualImpactCents else { return nil }

        let weekdayName = Calendar.current.weekdaySymbols[best.weekday - 1]
        let closingClause = annualizedClause(
            "At that rate on a typical \(weekdayName), the difference is worth about \(Money.wholeDollarString(fromCents: annualImpact)) a year.",
            MoveComparisonSide(count: weekdaySales.count, singular: weekdayName, plural: "\(weekdayName)s"),
            MoveComparisonSide(count: nightlySalesRates().count, singular: "shift", plural: "shifts")
        )
        let move = Move(
            id: "tipPercentSignal",
            title: "\(weekdayName) Tips Best",
            body: "You're tipped \(String(format: "%.1f", best.percent))% of sales on \(weekdayName)s across \(countPhrase(weekdaySales.count, singular: "shift", plural: "shifts")), against \(String(format: "%.1f", overallPercent))% overall. \(closingClause)",
            annualImpactCents: annualImpact
        )
        return MoveCandidate(move: move, weekdaySubject: nil)
    }

    /// Per-weekday averages over ALL of a person's history, requiring at
    /// least 3 nights on that weekday before it counts — shared by every
    /// "1 nights" is never acceptable copy — every Move/Insights count that
    /// can legitimately be 1 (unlike the weekday-keyed moves above, which
    /// already require >= 3) routes through this instead of hand-rolling
    /// pluralization at each call site.
    private func countPhrase(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// weekday-keyed move above. Carries the raw per-night cents too, for
    /// the variance guard's standard-deviation calculation.
    private func weekdayNightAverages(_ nights: [(date: Date, cents: Int)]) -> [(weekday: Int, avg: Double, count: Int, nightCents: [Int])] {
        (1...7).compactMap { weekday -> (weekday: Int, avg: Double, count: Int, nightCents: [Int])? in
            let matching = nights.filter { calendar.component(.weekday, from: $0.date) == weekday }
            guard matching.count >= 3 else { return nil }
            let nightCents = matching.map(\.cents)
            let avg = Double(nightCents.reduce(0, +)) / Double(nightCents.count)
            return (weekday, avg, nightCents.count, nightCents)
        }
    }

    /// Compares whole-DAY take-home on double days (2+ shifts) against solo
    /// days (1 shift). doubleCount/soloCount are counts of DAYS, and the
    /// averages are per day — the honest "is working a double worth it"
    /// question is about the day's total, not a single closeout.
    private func doublesSoloFacts(from shifts: [ShiftFacts]) -> DoublesSoloFacts? {
        let byDay = Dictionary(grouping: shifts, by: { $0.date })
        let doubleDays = byDay.filter { $0.value.count >= 2 }
        let soloDays = byDay.filter { $0.value.count == 1 }
        guard !doubleDays.isEmpty, !soloDays.isEmpty else { return nil }

        func dayNet(_ group: [ShiftFacts]) -> Int { group.reduce(0) { $0 + $1.netCents } }
        let doubleTotal = doubleDays.values.reduce(0) { $0 + dayNet($1) }
        let soloTotal = soloDays.values.reduce(0) { $0 + dayNet($1) }
        let doubleShiftCount = doubleDays.values.reduce(0) { $0 + $1.count }
        return DoublesSoloFacts(
            doubleAverageCents: doubleTotal / doubleDays.count,
            doubleCount: doubleDays.count,
            soloAverageCents: soloTotal / soloDays.count,
            soloCount: soloDays.count,
            doublePerShiftCents: doubleShiftCount > 0 ? doubleTotal / doubleShiftCount : 0
        )
    }

    // MARK: Follow-ups

    private enum FollowUpThresholds {
        static let minimumAgeDays = 28
        /// A recommendation only counts as "materially followed" once the
        /// gap between what actually happened and what the OLD pattern
        /// would have produced clears this - same silence-over-weak-advice
        /// discipline as MoveThresholds.minimumAnnualImpactCents, just
        /// scaled to a realized few-week window instead of an annualized
        /// projection.
        static let minimumEffectCents = 5000
    }

    /// Every calendar DAY as (date, net cents, isDouble) - the raw substrate
    /// followUps() compares before vs. after a Move was first shown. A day is
    /// "double" when it holds 2+ shifts. Kept separate from nightlyTotals()
    /// (which drops isDouble) so one predicate closure can filter on either a
    /// weekday or doubles.
    private func nightlyFacts() -> [(date: Date, netCents: Int, isDouble: Bool)] {
        let byDay = Dictionary(grouping: shiftFacts(from: records), by: { $0.date })
        return byDay
            .map { day, shifts in (date: day, netCents: shifts.reduce(0) { $0 + $1.netCents }, isDouble: shifts.count >= 2) }
            .sorted { $0.date < $1.date }
    }

    /// Checks every Move id in the ledger old enough to judge (>= 28 days
    /// since MoveLedgerStore first recorded it as shown) and asks one
    /// honest question: since then, did the recommended slice of nights
    /// actually get worked more or less than the PRIOR pattern would have
    /// predicted, and did that produce real dollars beyond what the old
    /// pattern would have. Both gates have to clear inside behaviorFollowUp
    /// - silence is the honest answer otherwise, same discipline as moves().
    func followUps(ledger: [String: Date], referenceDate: Date = .now) -> [FollowUp] {
        let minAge = TimeInterval(FollowUpThresholds.minimumAgeDays * 24 * 3600)
        return ledger
            .filter { referenceDate.timeIntervalSince($0.value) >= minAge }
            .compactMap { id, shownAt in followUp(forMoveID: id, shownAt: shownAt, referenceDate: referenceDate) }
            .sorted { abs($0.dollarEffectCents) > abs($1.dollarEffectCents) }
    }

    private func followUp(forMoveID id: String, shownAt: Date, referenceDate: Date) -> FollowUp? {
        switch id {
        case "weekdaySwap", "lapsedWinner", "rateLeader", "tipPercentSignal":
            guard let weekday = targetWeekday(forMoveID: id, shownAt: shownAt) else { return nil }
            let weekdayName = calendar.weekdaySymbols[weekday - 1]
            return behaviorFollowUp(
                moveID: id,
                title: "\(weekdayName) Update",
                singular: weekdayName,
                plural: "\(weekdayName)s",
                matches: { calendar.component(.weekday, from: $0.date) == weekday },
                shownAt: shownAt,
                referenceDate: referenceDate
            )
        case "doublesVerdict":
            return behaviorFollowUp(
                moveID: id,
                title: "Doubles Update",
                singular: "double",
                plural: "doubles",
                matches: { $0.isDouble },
                shownAt: shownAt,
                referenceDate: referenceDate
            )
        default:
            return nil
        }
    }

    /// Re-derives which weekday a given Move id was pointing at, using only
    /// records from BEFORE it was shown - what was actually true at the
    /// time, not what's true now. Mirrors each move function's own
    /// targeting logic exactly, just returning the weekday instead of a
    /// formatted Move.
    private func targetWeekday(forMoveID id: String, shownAt: Date) -> Int? {
        let engine = StatsEngine(records: records.filter { $0.date < shownAt }, calendar: calendar)
        switch id {
        case "weekdaySwap":
            let averages = engine.weekdayNightAverages(engine.nightlyTotals())
            guard averages.count >= 2 else { return nil }
            return averages.max(by: { $0.avg < $1.avg })?.weekday
        case "lapsedWinner":
            let allNights = engine.nightlyTotals()
            guard allNights.count >= 6 else { return nil }
            let overallAvg = Double(allNights.reduce(0) { $0 + $1.cents }) / Double(allNights.count)
            let cutoff = calendar.date(byAdding: .day, value: -MoveThresholds.lapsedWindowDays, to: shownAt) ?? shownAt
            let recentWeekdays = Set(allNights.filter { $0.date >= cutoff }.map { calendar.component(.weekday, from: $0.date) })
            let candidates = engine.weekdayNightAverages(allNights).filter { !recentWeekdays.contains($0.weekday) }
            guard let best = candidates.max(by: { $0.avg < $1.avg }), best.avg > overallAvg * 1.1 else { return nil }
            return best.weekday
        case "rateLeader":
            return engine.bestDollarsPerHourWeekday()?.weekday
        case "tipPercentSignal":
            let weekdayPercents = (1...7).compactMap { weekday -> (weekday: Int, percent: Double)? in
                engine.averageTipPercent(forWeekday: weekday).map { (weekday: weekday, percent: $0) }
            }
            return weekdayPercents.max(by: { $0.percent < $1.percent })?.weekday
        default:
            return nil
        }
    }

    /// Shared before/after comparison for any Move that recommends leaning
    /// into (or away from) a specific slice of nights - a weekday, or
    /// doubles. Splits every night at `shownAt`, projects what the BEFORE
    /// period's own per-week rate would have produced over the AFTER
    /// period's length, and reports the gap - in both occurrences and
    /// dollars - between that projection and what actually happened.
    private func behaviorFollowUp(
        moveID: String,
        title: String,
        singular: String,
        plural: String,
        matches: ((date: Date, netCents: Int, isDouble: Bool)) -> Bool,
        shownAt: Date,
        referenceDate: Date
    ) -> FollowUp? {
        let allNights = nightlyFacts()
        guard let earliestDate = allNights.map(\.date).min() else { return nil }
        let beforeWeeks = shownAt.timeIntervalSince(earliestDate) / (7 * 24 * 3600)
        let afterWeeks = referenceDate.timeIntervalSince(shownAt) / (7 * 24 * 3600)
        guard beforeWeeks >= 1, afterWeeks >= 1 else { return nil }

        let beforeMatching = allNights.filter { $0.date < shownAt }.filter(matches)
        let afterMatching = allNights.filter { $0.date >= shownAt }.filter(matches)
        guard !beforeMatching.isEmpty else { return nil }

        let beforeAvgCents = Double(beforeMatching.reduce(0) { $0 + $1.netCents }) / Double(beforeMatching.count)
        let beforeRatePerWeek = Double(beforeMatching.count) / beforeWeeks
        let expectedAfterCount = beforeRatePerWeek * afterWeeks
        let actualAfterCount = Double(afterMatching.count)
        let deltaCount = actualAfterCount - expectedAfterCount
        // Behavior-changed gate: at least one whole occurrence away from
        // what the old pace alone would have predicted.
        guard abs(deltaCount) >= 1.0 else { return nil }

        let actualAfterCents = afterMatching.reduce(0) { $0 + $1.netCents }
        let expectedAfterCents = Int((expectedAfterCount * beforeAvgCents).rounded())
        let dollarEffectCents = actualAfterCents - expectedAfterCents
        // Materiality gate, same spirit as moves(): a real gap, not noise.
        guard abs(dollarEffectCents) >= FollowUpThresholds.minimumEffectCents else { return nil }

        let roundedDelta = Int(abs(deltaCount).rounded())
        let noun = roundedDelta == 1 ? singular : plural
        let direction = deltaCount >= 0 ? "\(roundedDelta) more \(noun)" : "\(roundedDelta) fewer \(noun)"
        let verdict = dollarEffectCents >= 0
            ? "about \(Money.wholeDollarString(fromCents: dollarEffectCents)) more than your old pace would have"
            : "about \(Money.wholeDollarString(fromCents: abs(dollarEffectCents))) less than your old pace would have"
        let body = "Since we flagged this, you've worked \(direction) than before - bringing in \(verdict)."

        return FollowUp(id: moveID, title: title, body: body, dollarEffectCents: dollarEffectCents)
    }
}

/// StatsEngine.planForward(referenceDate:)'s result — a deterministic look
/// one week ahead. Self-contained (no dependency on any other Insights
/// type) so the widget target, which compiles this file alone, stays
/// happy.
struct PlanForward: Equatable {
    /// One usual night in the coming week, priced at that weekday's own
    /// historical per-shift net average — see planForward for the
    /// thin-sample fallback rule.
    struct Night: Equatable {
        let weekday: Int
        let averageNetCents: Int
        let nightCount: Int
    }

    /// The one non-usual weekday worth picking up next week, only present
    /// when the data honestly clears both the flat floor and the variance
    /// guard — see planForward.
    struct Pickup: Equatable {
        let weekday: Int
        let averageNetCents: Int
        let nightCount: Int
    }

    /// The next 7 calendar days' usual nights, in date order.
    let nights: [Night]
    let projectedTotalCents: Int
    let pickup: Pickup?
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

    /// A shift note passed through verbatim (dated, trimmed, length-capped) —
    /// the worker's own context for why a number looks the way it does.
    struct NoteFact: Equatable, Codable, Sendable {
        let date: Date
        let text: String
    }

    let totalCents: Int
    let shiftCount: Int
    let averagePerShiftCents: Int
    let topDays: [DayAmount]
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
    var startTime: StartTimeFacts? = nil
    // Replaces the old cashCents/creditCents pair (cash-vs-credit is a
    // known pay structure, never an insight — see CashWeekdayFacts). Kept
    // as var + default like the fields above; a persisted InsightsSnapshot
    // from before this field existed simply has this decode to nil
    // (JSONDecoder ignores its now-gone "cashCents"/"creditCents" keys
    // rather than failing), which self-heals on the next refresh.
    var cashWeekday: CashWeekdayFacts? = nil
    /// Newest-first, one per noted shift, capped — context for the narration,
    /// never an arithmetic input.
    var notes: [NoteFact] = []
}

/// The one cash fact Insights may ever surface: a weekday that runs
/// meaningfully more cash than the rest of the week — see
/// StatsEngine.cashWeekdayFacts. Never a general cash-vs-credit split; a
/// server already knows their own split, and it's never an insight.
/// sharePercent/restSharePercent are both 0-100, computed as blended totals
/// (total cash over total gross), never an average of nightly shares.
struct CashWeekdayFacts: Equatable, Codable, Sendable {
    let weekday: Int
    let sharePercent: Double
    let restSharePercent: Double
    let nightCount: Int
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
    /// The double-day take divided by the shifts worked those days — the only
    /// fair way to compare against a single shift. "A double day beats a solo
    /// shift" is arithmetic (you worked twice), not an insight; per-shift is
    /// where a real difference would show. var + default so pre-existing
    /// hand-built fixtures keep compiling (see InsightsFacts note above).
    var doublePerShiftCents: Int = 0
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
    /// How many nights the best-weekday rate above is actually blended
    /// from — every average that reaches the user carries its own n.
    let bestWeekdayNightCount: Int?
    let lunchDollarsPerHour: Double?
    let dinnerDollarsPerHour: Double?
    let doubleDollarsPerHour: Double?
    let soloDollarsPerHour: Double?
}

/// $/hr by start-time bucket — the only honest way to ask "does WHEN a
/// shift starts pay differently," since we only ever know a shift's total,
/// never how pay was distributed within it. Every comparison here is
/// shift-vs-shift by start hour, never a claim about a specific minute.
/// bestStartHour/worstStartHour are the exact clock-in hour (0-23; 17 means
/// shifts starting at 5 PM), only ever built from shifts that logged BOTH
/// hours and a clock-in.
struct StartTimeFacts: Equatable, Codable, Sendable {
    let bestStartHour: Int
    let bestDollarsPerHour: Double
    let bestShiftCount: Int
    let worstStartHour: Int
    let worstDollarsPerHour: Double
    let worstShiftCount: Int
}

/// Tip-percent facts — only ever built from nights that actually have
/// sales logged. Deliberately gross, not net (see StatsEngine.tipPercent).
struct SalesFacts: Equatable, Codable, Sendable {
    let overallTipPercent: Double
    let nightsWithSales: Int
    let bestWeekday: Int?
    let bestWeekdayTipPercent: Double?
    /// How many nights the best-weekday percent above is actually blended
    /// from — every average that reaches the user carries its own n.
    let bestWeekdayNightCount: Int?
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

/// A "since we told you..." check-in on a previously shown Move - see
/// StatsEngine.followUps(ledger:referenceDate:). id matches the originating
/// Move's id; a given Move id produces at most one FollowUp, only once
/// MoveLedgerStore has recorded it as shown for at least 28 days.
struct FollowUp: Equatable, Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let body: String
    /// Signed: positive means the recommended behavior change paid off,
    /// negative means it cost real money versus the prior pattern.
    let dollarEffectCents: Int
}

/// Turns the engine's plain facts into the exact calm, specific copy the
/// reveal and pace line show. Deterministic and templated — not narrated by
/// a model; that's reserved for Insights, where facts are more numerous and
/// varied than a single line can hold.
enum RevealCopy {
    private static func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }

    /// Names the shift when its ShiftPeriod is known, so a comparison never
    /// falls back to the generic "night" — lunch and dinner both fire this
    /// same reveal. "shift" is the honest fallback for legacy/unset periods.
    private static func shiftWord(_ period: ShiftPeriod?) -> String {
        switch period {
        case .lunch: return "lunch"
        case .dinner: return "dinner"
        case nil: return "shift"
        }
    }

    // Names its unit (tips, net per shift) rather than "today" — a lunch
    // shift logged at 2pm, or this line read back hours later, must never
    // look like the all-in "Today" total shown elsewhere on the Dashboard.
    // Tyler's ruling (2026-07-27): a shift speaks ONE number, the same
    // wage-inclusive total its Shifts row already shows — so `cents` is
    // that one figure, and `includesWages` just picks the honest unit for
    // it. "in tips" only when the amount actually IS tips (no wage set);
    // otherwise it's income, so the headline drops the word "tips"
    // entirely rather than call a wage-inclusive number "tips."
    static func headline(cents: Int, includesWages: Bool) -> String {
        includesWages
            ? "\(Money.string(fromCents: cents)) this shift."
            : "\(Money.string(fromCents: cents)) in tips this shift."
    }

    static func comparison(for result: RevealComparison, period: ShiftPeriod? = nil) -> String {
        switch result {
        case .firstNightLogged:
            return "Your first logged \(shiftWord(period)). Nice start."
        case .allTimeRecord(let previousBestCents):
            return allTimeRecordText(previousBestCents: previousBestCents, period: period)
        case .firstShiftOfPeriod:
            return "First shift of the period."
        case .weekdayRecord(let weekday, let previousBestCents):
            return weekdayRecordText(weekday: weekday, previousBestCents: previousBestCents)
        case .firstWeekdayLogged(let weekday):
            return "Your first logged \(weekdayName(weekday))."
        case .slowestRecently:
            return "Your quietest \(shiftWord(period)) in a while."
        case .weekdayAverage(let weekday, let deltaCents, let periodRank, let periodNightCount, let sampleCount):
            return weekdayAverageText(weekday: weekday, deltaCents: deltaCents, periodRank: periodRank, periodNightCount: periodNightCount, sampleCount: sampleCount, period: period)
        }
    }

    private static func allTimeRecordText(previousBestCents: Int, period: ShiftPeriod?) -> String {
        "Best \(shiftWord(period)) ever, topping your previous record of \(Money.string(fromCents: previousBestCents))."
    }

    private static func weekdayRecordText(weekday: Int, previousBestCents: Int) -> String {
        "Best \(weekdayName(weekday)) yet, topping your previous best of \(Money.string(fromCents: previousBestCents))."
    }

    /// Below 5 nights of history for this weekday, the average line
    /// self-discloses just how thin that average still is — a real number,
    /// stated honestly, not hidden behind confident-sounding phrasing.
    private static let minimumSampleForCleanAverage = 5

    private static func weekdayAverageText(weekday: Int, deltaCents: Int, periodRank: Int?, periodNightCount: Int, sampleCount: Int, period: ShiftPeriod?) -> String {
        let isAbove = deltaCents >= 0
        var base = "\(Money.string(fromCents: abs(deltaCents))) \(isAbove ? "above" : "below") your \(weekdayName(weekday)) average."
        if sampleCount < minimumSampleForCleanAverage {
            base = "\(Money.string(fromCents: abs(deltaCents))) \(isAbove ? "above" : "below") your \(weekdayName(weekday)) average (across \(sampleCount) \(weekdayName(weekday))s)."
        }
        guard let periodRank else { return base }
        let rankText: String
        switch periodRank {
        case 1: rankText = "Best \(shiftWord(period)) this period."
        case 2: rankText = "Second-best \(shiftWord(period)) this period."
        case 3: rankText = "Third-best \(shiftWord(period)) this period."
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

