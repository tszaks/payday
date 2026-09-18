import Foundation

/// One tile in Insights' Numbers grid — a green uppercase label, a big
/// value, and a short context line. Built from already-computed figures, so
/// it's on screen instantly and never waits on the network.
///
/// No tile performs arithmetic on cents except the two per-shift averages
/// that divide an already-summed total by its own shift count (LUNCH,
/// DINNER), which is the count that total was built from. The one figure that
/// used to be a rate divided here is HOURLY, and it now arrives from
/// `EarningsResult.hourlyRateCents` — see `rows(for:hourly:excluding:)`.
struct InsightsNumberTile: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let context: String
}

/// The flat 2-column stat grid that replaced Insights' content-dump prose.
/// Rows are computed explicitly, not flowed from one long array, because
/// the LUNCH/DINNER and DOUBLES/SOLO pairs must land side by side and a
/// flowing grid can't guarantee that: any independent single tile ahead of
/// a pair (hourly, say, when tip percent isn't available) would shift
/// parity and split the pair across two rows. Each pair is safe as its own
/// row anyway, since it's sourced from one InsightsFacts sub-struct that
/// StatsEngine only ever populates with both sides present (see
/// lunchDinnerFacts/doublesSoloFacts's own guards).
enum InsightsNumbersGrid {
    /// Below three shifts a tile's caption says so outright, not just by
    /// printing a small count. It was the hedge the deleted narration prompt
    /// enforced ([ID-12] onward); the grid makes the same claims, so it keeps
    /// the same hedge.
    private static let earlyReadSuffix = " · early read"
    /// A tile's own sample count stops earning a place in its caption once
    /// it clears this bar — below it, the count IS the honesty signal
    /// (design law: every number states its basis when the basis is thin)
    /// and must survive; at or above it, restating "across 160 shifts" on
    /// every tile just repeats the same fact and says nothing new. Same
    /// calibration as StatsEngine.MoveThresholds.minimumShiftsForAnnualizedImpact,
    /// applied here to captions instead of Moves' dollar projections.
    private static let minimumShiftsForFullSample = 8

    /// - Parameters:
    ///   - hourly: `MetricID.hourlyRate` as the ENGINE answered it, from
    ///     `InsightsEarnings.hourlyRate(...)`. Passed in rather than read off
    ///     `facts.rate` because a $/hr figure is a division this grid has no
    ///     business performing: [IL-13] recorded the old tile as
    ///     "nonWage/hour" against a registry `hourlyRate` that is
    ///     `earnedIncome`-based, and its denominator was a shift COUNT used
    ///     only to hedge the caption while the value was a mean of per-shift
    ///     rates. `EarningsResult.hourlyRateCents` is `coveredComponents`
    ///     over `minutes`, both taken over the covered shifts only, so a
    ///     shift with tips and no hours is excluded from BOTH sides instead
    ///     of inflating the numerator. Nil when the engine cannot answer, and
    ///     then the tile is absent — never a fabricated `$0/hr`.
    static func rows(
        for facts: InsightsFacts,
        hourly: InsightsEarnings.HourlyRate?,
        excluding excludedTileIDs: Set<String> = []
    ) -> [[InsightsNumberTile]] {
        var rows: [[InsightsNumberTile]] = []

        var rateRow: [InsightsNumberTile] = []
        if let hourly {
            rateRow.append(hourlyTile(hourly))
        }
        if let sales = facts.sales {
            rateRow.append(tipPercentTile(sales))
        }
        if !rateRow.isEmpty { rows.append(rateRow) }

        if let receipt = facts.receiptPerformance {
            var receiptRow: [InsightsNumberTile] = []
            if let spendPerGuest = receipt.averageSpendPerGuestCents {
                receiptRow.append(spendPerGuestTile(receipt, cents: spendPerGuest))
            }
            if let tipsPerTable = receipt.netTipsPerTableCents {
                receiptRow.append(tipsPerTableTile(receipt, cents: tipsPerTable))
            }
            if !receiptRow.isEmpty { rows.append(receiptRow) }
        }

        if let lunchDinner = facts.lunchDinner {
            rows.append([lunchTile(lunchDinner), dinnerTile(lunchDinner)])
        }

        if let doublesSolo = facts.doublesSolo {
            rows.append([doublesTile(doublesSolo), soloTile(doublesSolo)])
        }

        if let cashWeekday = facts.cashWeekday {
            rows.append([cashNightsTile(cashWeekday)])
        }

        if let startTime = facts.startTime {
            rows.append([startTimesTile(startTime)])
        }

        // An observation may already explain one of these exact facts in
        // prose (start time is the common case). Keep the underlying fact in
        // InsightsFacts, but don't make the reader process it twice on the
        // same screen. Filtering after explicit row construction preserves
        // the paired-row guarantees above for every tile that remains.
        return rows
            .map { row in row.filter { !excludedTileIDs.contains($0.id) } }
            .filter { !$0.isEmpty }
    }

    /// The engine's `hourlyRateCents`, with the coverage it can honestly
    /// claim.
    ///
    /// Its caption is NOT run through `hedged(...)`, which is the one
    /// deliberate departure from every other tile here. `hedged` drops a
    /// tile's sample count once it clears eight shifts, on the reasoning that
    /// "across 160 shifts" restated on every tile says nothing new. Coverage
    /// is a different claim: "across 141 of 160 shifts" says nineteen shifts
    /// have no hours logged and are in neither half of this division, and
    /// that stays true and material at any sample size. `docs/METRICS.md`'s
    /// presentation rules require it — `.partial` "makes $/hr show 'N of M
    /// shifts'" — so `HourlyRate.coverage` suppresses the fraction when, and
    /// only when, there is no shortfall to disclose.
    private static func hourlyTile(_ hourly: InsightsEarnings.HourlyRate) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "hourly",
            label: "HOURLY",
            value: "\(Money.wholeDollarString(fromCents: hourly.rateCents))/hr",
            context: hourly.coverage
        )
    }

    private static func tipPercentTile(_ sales: SalesFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "tipPercent",
            label: "TIP PERCENT",
            value: "\(String(format: "%.1f", sales.overallTipPercent))%",
            context: hedged("of sales", count: sales.nightsWithSales, countPhrase: shiftsPhrase(sales.nightsWithSales))
        )
    }

    private static func spendPerGuestTile(_ facts: ReceiptPerformanceFacts, cents: Int) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "spendPerGuest",
            label: "SPEND / GUEST",
            value: Money.string(fromCents: cents),
            context: hedged("pre-tax sales", count: facts.guestShiftCount, countPhrase: shiftsPhrase(facts.guestShiftCount))
        )
    }

    private static func tipsPerTableTile(_ facts: ReceiptPerformanceFacts, cents: Int) -> InsightsNumberTile {
        let estimated = facts.estimatedTableShiftCount
        let context = estimated > 0
            ? "net tips · tables estimated on \(estimated) of \(facts.tableShiftCount) shifts"
            : hedged(
                "net tips · confirmed tables",
                count: facts.tableShiftCount,
                countPhrase: shiftsPhrase(facts.tableShiftCount)
            )
        return InsightsNumberTile(
            id: "tipsPerTable",
            label: "TIPS / TABLE",
            value: Money.string(fromCents: cents),
            context: context
        )
    }

    /// Per-shift average, never the raw total — the shift counts differ
    /// between lunch and dinner. The division is
    /// `LunchDinnerFacts.lunchPerShiftCents`, computed beside the counts it
    /// divides by rather than here: a view that divides cents is a view that
    /// can compute (adapter contract, rule 1).
    private static func lunchTile(_ facts: LunchDinnerFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "lunch",
            label: "LUNCH",
            value: "\(Money.wholeDollarString(fromCents: facts.lunchPerShiftCents))/shift",
            context: hedged("", count: facts.lunchShiftCount, countPhrase: shiftsPhrase(facts.lunchShiftCount))
        )
    }

    private static func dinnerTile(_ facts: LunchDinnerFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "dinner",
            label: "DINNER",
            value: "\(Money.wholeDollarString(fromCents: facts.dinnerPerShiftCents))/shift",
            context: hedged("", count: facts.dinnerShiftCount, countPhrase: shiftsPhrase(facts.dinnerShiftCount))
        )
    }

    private static func doublesTile(_ facts: DoublesSoloFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "doubles",
            label: "DOUBLES",
            value: "\(Money.wholeDollarString(fromCents: facts.doublePerShiftCents))/shift",
            context: hedged("", count: facts.doubleCount, countPhrase: doubleDaysPhrase(facts.doubleCount))
        )
    }

    /// A solo day is one shift, so the day average already IS the per-shift
    /// figure — no division needed, unlike doublePerShiftCents above.
    private static func soloTile(_ facts: DoublesSoloFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "solo",
            label: "SOLO",
            value: "\(Money.wholeDollarString(fromCents: facts.soloAverageCents))/shift",
            context: hedged("", count: facts.soloCount, countPhrase: daysPhrase(facts.soloCount))
        )
    }

    /// The one cash fact Insights ever shows — a weekday that runs
    /// meaningfully more cash than the rest of the week (see
    /// StatsEngine.CashWeekdayFacts). Never a cash-vs-credit split.
    private static func cashNightsTile(_ facts: CashWeekdayFacts) -> InsightsNumberTile {
        let weekdayName = Calendar.current.weekdaySymbols[facts.weekday - 1]
        return InsightsNumberTile(
            id: "cashNights",
            label: "CASH NIGHTS",
            value: "\(Int(facts.sharePercent.rounded()))%",
            context: "of \(weekdayName) tips are cash · \(weekdayPhrase(facts.nightCount, name: weekdayName))"
        )
    }

    private static func weekdayPhrase(_ count: Int, name: String) -> String {
        count == 1 ? "1 \(name)" : "\(count) \(name)s"
    }

    private static func startTimesTile(_ facts: StartTimeFacts) -> InsightsNumberTile {
        let bestRate = Money.wholeDollarString(fromCents: facts.bestRateCents)
        let worstRate = Money.wholeDollarString(fromCents: facts.worstRateCents)
        let sampleCount = min(facts.bestShiftCount, facts.worstShiftCount)
        return InsightsNumberTile(
            id: "startTimes",
            label: "START TIMES",
            value: "\(bestRate)/hr at \(hourLabel(facts.bestStartHour))",
            context: hedged("vs \(worstRate)/hr at \(hourLabel(facts.worstStartHour))", count: sampleCount, countPhrase: shiftsPhrase(sampleCount))
        )
    }

    /// Builds a tile's caption from a non-count context (e.g. "of sales",
    /// or "" when a tile has nothing else to say) and the count phrase that
    /// backs it. Below minimumShiftsForFullSample, the count phrase
    /// survives (further flagged as an early read below 3); at or above
    /// it, only the non-count context remains.
    private static func hedged(_ nonCountContext: String, count: Int, countPhrase: String) -> String {
        guard count < minimumShiftsForFullSample else { return nonCountContext }
        let withCount = nonCountContext.isEmpty ? countPhrase : "\(nonCountContext) · \(countPhrase)"
        return count < 3 ? withCount + earlyReadSuffix : withCount
    }

    private static func shiftsPhrase(_ count: Int) -> String {
        count == 1 ? "1 shift" : "\(count) shifts"
    }

    private static func daysPhrase(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    private static func doubleDaysPhrase(_ count: Int) -> String {
        count == 1 ? "1 double day" : "\(count) double days"
    }

    /// Same locale-respecting rendering as StatsEngine's own hourLabel — an
    /// actual Date at that hour, formatted by Date.FormatStyle rather than
    /// hand-rolled am/pm math.
    private static func hourLabel(_ hour: Int) -> String {
        let calendar = Calendar.current
        let anchored = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return anchored.formatted(.dateTime.hour())
    }
}
