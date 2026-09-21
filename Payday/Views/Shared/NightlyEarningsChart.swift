import SwiftUI
import Charts

enum EarningsChartAxisGranularity: Equatable {
    case day
    case week
    case month
    case year

    /// Chosen from how many civil days the chart covers. Presentation only:
    /// it decides how many bars there are, never what any bar is worth.
    static func forRange(_ range: DayRange) -> Self {
        switch max(1, range.count) {
        case ...21: return EarningsChartAxisGranularity.day
        case ...120: return EarningsChartAxisGranularity.week
        case ...730: return EarningsChartAxisGranularity.month
        default: return EarningsChartAxisGranularity.year
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .day: return Calendar.Component.day
        case .week: return Calendar.Component.weekOfYear
        case .month: return Calendar.Component.month
        case .year: return Calendar.Component.year
        }
    }

    var title: String {
        switch self {
        case .day: return "Daily earnings"
        case .week: return "Weekly earnings"
        case .month: return "Monthly earnings"
        case .year: return "Yearly earnings"
        }
    }

    var bestPeriodName: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        }
    }

    /// How many axis labels the chart can carry before they collide, as the
    /// stride for `.stride(by:count:)`: at caption3 a "Sep 13" is ~34pt and
    /// the plot is ~120pt tall on a phone-width card, so about six labels is
    /// the budget and the stride widens past it. Measured the hard way —
    /// every week of a ten-week range printed its dates as one continuous
    /// smear (Tyler, 2026-09-20). `.day` never calls this: a narrow weekday
    /// letter is ~8pt and already fits at every stride.
    static func axisLabelStride(pointCount: Int) -> Int {
        max(1, Int(ceil(Double(pointCount) / 6)))
    }

    /// The civil-day ranges this granularity divides `range` into: a
    /// PARTITION, so no day is in two buckets and none is left out.
    ///
    /// That is what makes `Σ bars == snapshot.range(theWholeRange)` true by
    /// construction rather than by luck. Edge buckets are intersected with
    /// `range`, so the first and last bar cover only the days actually asked
    /// for; a month bar for a pay period that starts on the 14th is worth
    /// the 14th onward and nothing before it.
    func buckets(of range: DayRange, timeZone: TimeZone) -> [DayRange] {
        guard !range.isEmpty else { return [] }
        if self == .day { return range.days.map { DayRange(day: $0) } }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var buckets: [DayRange] = []
        var cursor = range.start
        while cursor <= range.end {
            let anchor = cursor.date(in: timeZone)
            guard let interval = calendar.dateInterval(of: calendarComponent, for: anchor) else {
                // No interval for this component: fall back to one bucket
                // for the rest of the range rather than looping forever.
                buckets.append(DayRange(start: cursor, end: range.end))
                break
            }
            // `interval.end` is the first instant of the NEXT bucket, so the
            // last civil day of this one is the day before it.
            let nextStart = CivilDay(interval.end, in: timeZone)
            let bucketEnd = min(nextStart.adding(days: -1), range.end)
            buckets.append(DayRange(start: cursor, end: bucketEnd))
            guard bucketEnd < range.end else { break }
            cursor = bucketEnd.adding(days: 1)
        }
        return buckets
    }
}

/// Which metric a bar is worth — the basis the CALLER declared.
///
/// Two cases and no third, because a chart's bar may only be one of the two
/// metrics a range query answers in whole cents. It exists so the choice is
/// an ARGUMENT rather than a constant baked into `EarningsChartPoint`: wave 2
/// measured Insights printing `EarningsFigure.earnedIncome` bars under its
/// own note reading "Every figure below is tips only", so one day was
/// $265.00 on the chart and $105.00 in the tiles, the typical range, the plan
/// and the day totals beside it — and the bar's own label said "Total", which
/// by Tyler's rule means wage-inclusive.
///
/// A caller that has no basis decision to make (a pay period hero and its
/// chart, which are both `earnedIncome` by construction) passes nothing and
/// gets `.earnedIncome`, which is what every wave-0 and wave-1 consumer did
/// before this parameter existed.
enum EarningsChartMetric: Equatable {
    case earnedIncome
    case nonWageEarnings

    /// The registry identity, for a test that wants to name it.
    var metricID: MetricID {
        switch self {
        case .earnedIncome: return MetricID.earnedIncome
        case .nonWageEarnings: return MetricID.nonWageEarnings
        }
    }

    /// The one place a bar's figure is built, so the metric the caller
    /// declared is the metric the bar's cents, label, peak callout and scrub
    /// readout all come from.
    ///
    /// `.earnedIncome` still collapses to `nonWageEarnings` on a `.off`
    /// result, which is `EarningsFigure.earnedIncome`'s own rule: with wages
    /// off the two are the same cents and only the second is an honest name
    /// for them.
    func figure(_ result: EarningsResult) -> EarningsFigure {
        switch self {
        case .earnedIncome: return EarningsFigure.earnedIncome(result)
        case .nonWageEarnings: return EarningsFigure.nonWageEarnings(result)
        }
    }
}

/// One bar.
///
/// The bar's figure is not a number that happens to agree with the engine:
/// it IS an `EarningsResult` the engine answered, kept whole. At `.day`
/// granularity `result` is exactly what `snapshot.day(thatDay)` returns —
/// same components, same completeness, same `manifestDigest` — which is the
/// M1 fixture's contract ("chart point == day total") stated as an identity
/// instead of an equality.
///
/// Keeping the whole result is also what lets a bar know it is incomplete.
/// The previous `(date, cents)` tuple could not: it carried `ShiftFacts
/// .netCents`, which is `nonWageEarnings`, so a chart under a wage-inclusive
/// headline drew bars that summed to less than it and had no way to say so.
struct EarningsChartPoint: Equatable, Identifiable {
    var id: Date { date }
    /// The bucket's first day, as a `Date`, for the x-axis only.
    let date: Date
    /// The civil days this bar covers.
    let range: DayRange
    /// The engine's answer for `range`, verbatim.
    let result: EarningsResult
    /// What the bar is worth, labelled by its own completeness.
    let figure: EarningsFigure
    /// The bar's height. A point only exists because a query answered, so
    /// this is never a substitute for a missing figure; `EarningsChartFacts`
    /// yields no points at all when there is no snapshot.
    let cents: Int

    init(
        date: Date,
        range: DayRange,
        result: EarningsResult,
        metric: EarningsChartMetric = .earnedIncome
    ) {
        self.date = date
        self.range = range
        self.result = result
        let figure = metric.figure(result)
        self.figure = figure
        self.cents = figure.cents ?? 0
    }

    /// True when some shift in this bucket has no wage, so the bar is drawn
    /// hollow: "this is what is known so far" rather than "this is the
    /// night" (Design 2, presentation rules for `.partial`).
    ///
    /// Read off the FIGURE's metric and not the result's completeness alone.
    /// A `nonWageEarnings` bar has nothing missing from it — every shift has
    /// tips, which is that metric's stated missing-data rule — so a tips bar
    /// on a page that fell back BECAUSE some shift has no hours is complete
    /// as the number it actually is. Its page said why, once, above it.
    var isPartial: Bool {
        guard figure.metric == MetricID.earnedIncome else { return false }
        if case .partial = result.completeness.state { return true }
        return false
    }
}

/// Stable inputs for one chart render.
///
/// Two jobs. The obvious one: stop the bucketing and sorting from being
/// repeated by every mark, annotation, header and accessibility query Swift
/// Charts evaluates during a drag.
///
/// The one PR 5 added: be the only place the chart's money comes from, and
/// get it by ASKING. One `EarningsSnapshot` query per bar means the bars and
/// any headline above them are the same engine answering the same question
/// at two scopes, so `Σ bars == snapshot.range(wholeRange)` holds by
/// construction. The old path summed `StatsEngine.nightlyTotals` per day
/// and let the caller sum them again into weeks — two independent
/// additions, neither of which the headline used.
struct EarningsChartFacts: SnapshotFacts {
    let points: [EarningsChartPoint]
    let maxCents: Int
    let granularity: EarningsChartAxisGranularity
    let xDomain: ClosedRange<Date>
    /// The engine's answer for the WHOLE range, which `Σ points` equals.
    /// Carries the chart's completeness for the header and the axis.
    let whole: EarningsResult?
    let stamp: SnapshotStamp?
    /// What every bar on this chart is worth, as the caller declared it.
    /// Exposed so a screen's parity test can assert the chart is on the same
    /// metric as the sentence printed above it.
    let metric: EarningsChartMetric

    /// - Parameters:
    ///   - snapshot: nil while `EarningsStore` is loading or unavailable.
    ///     Yields no points, so the caller renders its own empty state
    ///     rather than a flat row of zero-height bars.
    ///   - range: the civil days to chart. Presentation's choice: a pay
    ///     period, a rolling window, all of history.
    ///   - timeZone: the FROZEN payroll zone, for bucket boundaries and for
    ///     the `CivilDay` → `Date` round trip the x-axis needs. Not
    ///     `TimeZone.current`: a device that travels must not re-bucket a
    ///     bar into a different week.
    ///   - asOf: the cutoff. Defaults to the snapshot's own
    ///     (`stamp.asOf`), which is what makes the last bar of the current
    ///     period stop at today instead of drawing an empty future.
    ///   - metric: the basis the CALLER declared. Defaults to
    ///     `.earnedIncome`, which is every wave-0 and wave-1 consumer's
    ///     answer (a pay period's chart sits under that period's
    ///     wage-inclusive hero). Insights passes its page basis, because a
    ///     page that has fallen back to tips must not draw wage-inclusive
    ///     bars under the sentence saying so — see `EarningsChartMetric`.
    init(
        snapshot: EarningsSnapshot?,
        range: DayRange,
        timeZone: TimeZone,
        asOf: CivilDay? = nil,
        metric: EarningsChartMetric = .earnedIncome
    ) {
        let cutoff = asOf ?? snapshot?.stamp.asOf
        let charted = cutoff.map { range.clamped(to: $0) } ?? range
        granularity = .forRange(charted)
        stamp = snapshot?.stamp
        self.metric = metric

        guard let snapshot, !charted.isEmpty else {
            points = []
            maxCents = 0
            whole = nil
            // An empty domain still has to be a valid closed range for
            // `.chartXScale`.
            let anchor = range.start.date(in: timeZone)
            xDomain = anchor...anchor.addingTimeInterval(86_400)
            return
        }

        // The whole-range answer first, so the invariant the bars have to
        // satisfy is in hand before any bar exists.
        // `.distantFuture` opts out of a SECOND clamp: `charted` already had
        // the cutoff applied, and clamping again is either a no-op or, if the
        // two ever disagreed, a silent difference between the whole-range
        // answer and the bars that are supposed to sum to it.
        whole = snapshot.range(charted, asOf: CivilDay.distantFuture)

        points = granularity.buckets(of: charted, timeZone: timeZone).map { bucket in
            EarningsChartPoint(
                date: bucket.start.date(in: timeZone),
                range: bucket,
                // A one-day bucket goes through `day(_:)` so a daily bar IS
                // the day result a DayDetail sheet opens, not a one-day
                // range that merely equals it. `day(_:)` is deliberately
                // unclamped in the engine; the bucket it was built from was
                // already clamped above, so nothing slips past the cutoff.
                result: bucket.count == 1
                    ? snapshot.day(bucket.start)
                    : snapshot.range(bucket, asOf: CivilDay.distantFuture),
                metric: metric
            )
        }
        maxCents = points.map(\.cents).max() ?? 0

        let start = charted.start.date(in: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let lastBucketStart = points.last?.date ?? start
        let end = calendar.date(
            byAdding: granularity.calendarComponent,
            value: 1,
            to: lastBucketStart
        ) ?? charted.end.date(in: timeZone)
        xDomain = start...max(end, start.addingTimeInterval(86_400))
    }

    /// The snapshot's WHOLE span, first shift's work day through last, for a
    /// chart with no period to anchor to (Insights' all-history card).
    ///
    /// `asOf` defaults to `.distantFuture` here rather than to the
    /// snapshot's cutoff: an all-history chart has always shown every row it
    /// has, including future-dated ones, and silently dropping them would be
    /// an Insights behaviour change rather than a shared-component one
    /// (group 2.6, wave 2).
    init(
        wholeOf snapshot: EarningsSnapshot?,
        timeZone: TimeZone,
        asOf: CivilDay = .distantFuture,
        metric: EarningsChartMetric = .earnedIncome
    ) {
        guard
            let snapshot,
            let first = snapshot.shifts.first?.workDay,
            let last = snapshot.shifts.last?.workDay
        else {
            self.init(
                snapshot: nil,
                range: DayRange(day: CivilDay(Date(), in: timeZone)),
                timeZone: timeZone,
                asOf: asOf,
                metric: metric
            )
            return
        }
        self.init(
            snapshot: snapshot,
            range: DayRange(start: first, end: last),
            timeZone: timeZone,
            asOf: asOf,
            metric: metric
        )
    }
}

/// Earnings, Health-app style: drag across bars to inspect an exact total,
/// with a selection haptic on every change. A short pay period stays daily;
/// longer histories combine those same days into weeks, months, and years so
/// the chart gets calmer as the data grows instead of squeezing an endless
/// row of weekday initials into the same width. Bars fade through a
/// single-green opacity ramp — relative size only, never a second hue.
///
/// Every figure on it comes from `EarningsChartFacts`, which got it from
/// `EarningsSnapshot`. The view holds no money arithmetic at all.
struct NightlyEarningsChart: View {
    private let facts: EarningsChartFacts

    @State private var selectedDate: Date?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(facts: EarningsChartFacts) {
        self.facts = facts
    }

    private var selectedPoint: EarningsChartPoint? {
        guard let selectedDate else { return nil }
        let calendar = Calendar.current
        return facts.points.min { lhs, rhs in
            let lhsDistance = abs(calendar.dateComponents([.day], from: lhs.date, to: selectedDate).day ?? .max)
            let rhsDistance = abs(calendar.dateComponents([.day], from: rhs.date, to: selectedDate).day ?? .max)
            return lhsDistance < rhsDistance
        }
    }

    private var peak: EarningsChartPoint? {
        guard facts.maxCents > 0 else { return nil }
        return facts.points.first { $0.cents == facts.maxCents }
    }

    /// Axis labels thin out as bars multiply — see
    /// `EarningsChartAxisGranularity.axisLabelStride`, which owns the budget.
    private var axisLabelStride: Int {
        EarningsChartAxisGranularity.axisLabelStride(pointCount: facts.points.count)
    }

    var body: some View {
        let selected = selectedPoint
        VStack(alignment: .leading, spacing: 8) {
            headerText(selected: selected)

            Chart(facts.points) { point in
                BarMark(
                    x: .value("Date", point.date, unit: facts.granularity.calendarComponent),
                    y: .value("Earnings", point.cents)
                )
                .foregroundStyle(PaydayColor.primary.opacity(
                    barOpacity(for: point, selectedDate: selected?.date)
                ))
                // NOT re-shaded for `.partial` here, deliberately. Design 2
                // asks for a hollow bar on an incomplete bucket, and
                // `point.isPartial` is exposed so a screen can draw one — but
                // the fill opacity is ALREADY a magnitude encoding whose
                // floor constants (0.8 light / 0.6 dark, see `barOpacity`)
                // are a stated 3:1 accessibility contract, and a second
                // opacity term stacked on top of it breaks that contract
                // while making the two encodings unreadable against each
                // other. A real hollow bar is a stroked mark, which is a
                // visual decision belonging to the screens that own this
                // chart (Insights, group 2.6/2.7, wave 2). The `.partial`
                // COPY rules are enforced here already: the header, the peak
                // annotation and the VoiceOver summary all read through
                // `EarningsFigure`.
                .cornerRadius(3)
                .annotation(position: .top, spacing: 2) {
                    if selectedDate == nil, point.id == peak?.id, let text = point.figure.wholeDollarText {
                        Text(text)
                            .font(PaydayFont.caption3)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartXScale(domain: facts.xDomain)
            .chartXAxis {
                switch facts.granularity {
                case .day:
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                            .font(PaydayFont.caption3)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                case .week:
                    AxisMarks(values: .stride(by: .weekOfYear, count: axisLabelStride)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                            }
                            .font(PaydayFont.caption3)
                            .foregroundStyle(PaydayColor.textSecondary)
                        }
                    }
                case .month:
                    AxisMarks(values: .stride(by: .month, count: axisLabelStride)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date.formatted(.dateTime.month(.abbreviated)))
                            }
                            .font(PaydayFont.caption3)
                            .foregroundStyle(PaydayColor.textSecondary)
                        }
                    }
                case .year:
                    AxisMarks(values: .stride(by: .year, count: axisLabelStride)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date.formatted(.dateTime.year()))
                            }
                            .font(PaydayFont.caption3)
                            .foregroundStyle(PaydayColor.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 120)
            // One summary is enough for VoiceOver here (per-bar audio graphs
            // aren't worth the complexity for a chart this small); combined
            // with .ignore, this replaces Swift Charts' automatic per-mark
            // accessibility elements with a single readout.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chartAccessibilityLabel)
        }
        .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: selectedDate)
        .onChange(of: selectedDate) { oldValue, newValue in
            guard oldValue != newValue else { return }
            PaydayHaptics.selection()
        }
    }

    private func headerText(selected: EarningsChartPoint?) -> some View {
        Group {
            if let selected, let amount = selected.figure.text {
                Text("\(amount) \(selectionPeriodText(for: selected.date, granularity: facts.granularity))")
            } else {
                Text(facts.granularity.title)
            }
        }
        .font(PaydayFont.subheadline)
        .foregroundStyle(PaydayColor.textSecondary)
        .monospacedDigit()
    }

    /// The best bucket, named by the label its own completeness allows: a
    /// partial best night is "Best day known so far", never a flat claim.
    private var chartAccessibilityLabel: String {
        guard let peak, let amount = peak.figure.text else {
            return "\(facts.granularity.title) chart. No earnings logged."
        }
        let qualifier = peak.isPartial ? " known so far" : ""
        return "\(facts.granularity.title) chart. Best \(facts.granularity.bestPeriodName)\(qualifier) \(amount)."
    }

    private func barOpacity(for point: EarningsChartPoint, selectedDate: Date?) -> Double {
        // Maintain at least 3:1 against every app surface. Selection still
        // reads clearly, but neighboring bars never fade into inaccessible
        // decoration while the user scrubs.
        let floor = colorScheme == .light ? 0.8 : 0.6
        let base = facts.maxCents > 0
            ? floor + (1 - floor) * (Double(point.cents) / Double(facts.maxCents))
            : floor
        guard let selectedDate else { return base }
        return Calendar.current.isDate(point.date, inSameDayAs: selectedDate)
            ? 1.0
            : max(floor, base * 0.85)
    }

    private func selectionPeriodText(for date: Date, granularity: EarningsChartAxisGranularity) -> String {
        switch granularity {
        case .day:
            return "on \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
        case .week:
            return "for the week of \(date.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return "in \(date.formatted(.dateTime.month(.wide).year()))"
        case .year:
            return "in \(date.formatted(.dateTime.year()))"
        }
    }
}
