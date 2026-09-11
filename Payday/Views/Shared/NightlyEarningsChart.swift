import SwiftUI
import Charts

enum EarningsChartAxisGranularity: Equatable {
    case day
    case week
    case month
    case year

    static func forDomain(_ domain: ClosedRange<Date>, calendar: Calendar = .current) -> Self {
        let days = max(1, calendar.dateComponents([.day], from: domain.lowerBound, to: domain.upperBound).day ?? 1)
        switch days {
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

    func bucketStart(for date: Date, calendar: Calendar = .current) -> Date {
        if self == .day { return calendar.startOfDay(for: date) }
        return calendar.dateInterval(of: calendarComponent, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    func aggregate(
        _ nights: [(date: Date, cents: Int)],
        calendar: Calendar = .current
    ) -> [(date: Date, cents: Int)] {
        Dictionary(grouping: nights) { bucketStart(for: $0.date, calendar: calendar) }
            .map { date, rows in (date: date, cents: rows.reduce(0) { $0 + $1.cents }) }
            .sorted { $0.date < $1.date }
    }
}

/// Stable inputs for one chart render. This prevents the aggregation/sort
/// from being repeated by every mark, annotation, header, and accessibility
/// query Swift Charts evaluates during a drag.
struct EarningsChartFacts {
    let points: [(date: Date, cents: Int)]
    let maxCents: Int
    let granularity: EarningsChartAxisGranularity
    let xDomain: ClosedRange<Date>

    init(nights: [(date: Date, cents: Int)], period: PayPeriod?, calendar: Calendar = .current) {
        let sourceBounds: (start: Date, end: Date)
        if let period {
            sourceBounds = (period.start, period.end)
        } else {
            let dates = nights.map(\.date)
            let start = dates.min() ?? Date()
            sourceBounds = (start, dates.max() ?? start)
        }

        let sourceDomain = sourceBounds.start...sourceBounds.end
        granularity = .forDomain(sourceDomain, calendar: calendar)
        points = granularity.aggregate(nights, calendar: calendar)
        maxCents = points.map(\.cents).max() ?? 0

        let start = granularity.bucketStart(for: sourceBounds.start, calendar: calendar)
        let lastBucket = granularity.bucketStart(for: sourceBounds.end, calendar: calendar)
        let end = calendar.date(
            byAdding: granularity.calendarComponent,
            value: 1,
            to: lastBucket
        ) ?? sourceBounds.end
        xDomain = start...end
    }
}

/// Earnings, Health-app style: drag across bars to inspect an exact total,
/// with a selection haptic on every change. A short pay period stays daily;
/// longer histories combine those same daily totals into weeks, months, and
/// years so the chart gets calmer as the data grows instead of squeezing an
/// endless row of weekday initials into the same width. Bars fade through a
/// single-green opacity ramp — relative size only, never a second hue.
struct NightlyEarningsChart: View {
    /// Anchors the x-axis to the whole period so days off render as labeled
    /// empty slots instead of ambiguous gaps. Optional because InsightsView's
    /// rolling recent-nights window crosses period boundaries and has no
    /// single period to anchor to — falls back to the nights' own date range.
    private let facts: EarningsChartFacts

    @State private var selectedDate: Date?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(nights: [(date: Date, cents: Int)], period: PayPeriod? = nil) {
        self.facts = EarningsChartFacts(nights: nights, period: period)
    }

    private func selectedNight(in facts: EarningsChartFacts) -> (date: Date, cents: Int)? {
        guard let selectedDate else { return nil }
        let calendar = Calendar.current
        return facts.points.min { lhs, rhs in
            let lhsDistance = abs(calendar.dateComponents([.day], from: lhs.date, to: selectedDate).day ?? .max)
            let rhsDistance = abs(calendar.dateComponents([.day], from: rhs.date, to: selectedDate).day ?? .max)
            return lhsDistance < rhsDistance
        }
    }

    var body: some View {
        let selectedNight = selectedNight(in: facts)
        VStack(alignment: .leading, spacing: 8) {
            headerText(facts, selectedNight: selectedNight)

            Chart(facts.points, id: \.date) { night in
                BarMark(
                    x: .value("Date", night.date, unit: facts.granularity.calendarComponent),
                    y: .value("Earnings", night.cents)
                )
                .foregroundStyle(PaydayColor.primary.opacity(
                    barOpacity(for: night, facts: facts, selectedDate: selectedNight?.date)
                ))
                .cornerRadius(3)
                .annotation(position: .top, spacing: 2) {
                    if selectedDate == nil, facts.maxCents > 0, night.cents == facts.maxCents {
                        Text(Money.wholeDollarString(fromCents: night.cents))
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
                    AxisMarks(values: .stride(by: .weekOfYear)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                            }
                            .font(PaydayFont.caption3)
                            .foregroundStyle(PaydayColor.textSecondary)
                        }
                    }
                case .month:
                    AxisMarks(values: .stride(by: .month)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date.formatted(.dateTime.month(.abbreviated)))
                            }
                            .font(PaydayFont.caption3)
                            .foregroundStyle(PaydayColor.textSecondary)
                        }
                    }
                case .year:
                    AxisMarks(values: .stride(by: .year)) { value in
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
            .accessibilityLabel(chartAccessibilityLabel(facts))
        }
        .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: selectedDate)
        .onChange(of: selectedDate) { oldValue, newValue in
            guard oldValue != newValue else { return }
            PaydayHaptics.selection()
        }
    }

    private func headerText(
        _ facts: EarningsChartFacts,
        selectedNight: (date: Date, cents: Int)?
    ) -> some View {
        Group {
            if let selectedNight {
                Text("\(Money.string(fromCents: selectedNight.cents)) \(selectionPeriodText(for: selectedNight.date, granularity: facts.granularity))")
            } else {
                Text(facts.granularity.title)
            }
        }
        .font(PaydayFont.subheadline)
        .foregroundStyle(PaydayColor.textSecondary)
        .monospacedDigit()
    }

    private func chartAccessibilityLabel(_ facts: EarningsChartFacts) -> String {
        guard facts.maxCents > 0 else { return "\(facts.granularity.title) chart. No earnings logged." }
        return "\(facts.granularity.title) chart. Best \(facts.granularity.bestPeriodName) \(Money.string(fromCents: facts.maxCents))."
    }

    private func barOpacity(
        for night: (date: Date, cents: Int),
        facts: EarningsChartFacts,
        selectedDate: Date?
    ) -> Double {
        // Maintain at least 3:1 against every app surface. Selection still
        // reads clearly, but neighboring bars never fade into inaccessible
        // decoration while the user scrubs.
        let floor = colorScheme == .light ? 0.8 : 0.6
        let base = facts.maxCents > 0
            ? floor + (1 - floor) * (Double(night.cents) / Double(facts.maxCents))
            : floor
        guard let selectedDate else { return base }
        return Calendar.current.isDate(night.date, inSameDayAs: selectedDate)
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
