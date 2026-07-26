import SwiftUI
import Charts

/// Daily earnings, Health-app style: drag across bars to inspect a day's
/// exact total, with a selection haptic on every change. This is a DAILY
/// chart — a double (two shifts, same day) sums into one bar, not two. Bars
/// fade through a single-green opacity ramp — relative size only, never a
/// second hue, per design law.
struct NightlyEarningsChart: View {
    let nights: [(date: Date, cents: Int)]
    /// Anchors the x-axis to the whole period so days off render as labeled
    /// empty slots instead of ambiguous gaps. Optional because InsightsView's
    /// rolling recent-nights window crosses period boundaries and has no
    /// single period to anchor to — falls back to the nights' own date range.
    let period: PayPeriod?

    @State private var selectedDate: Date?

    init(nights: [(date: Date, cents: Int)], period: PayPeriod? = nil) {
        self.nights = nights
        self.period = period
    }

    private var maxCents: Int {
        nights.map(\.cents).max() ?? 0
    }

    private var selectedNight: (date: Date, cents: Int)? {
        guard let selectedDate else { return nil }
        let calendar = Calendar.current
        return nights.min { lhs, rhs in
            let lhsDistance = abs(calendar.dateComponents([.day], from: lhs.date, to: selectedDate).day ?? .max)
            let rhsDistance = abs(calendar.dateComponents([.day], from: rhs.date, to: selectedDate).day ?? .max)
            return lhsDistance < rhsDistance
        }
    }

    private var xDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        guard let period else {
            let dates = nights.map(\.date)
            let start = dates.min() ?? Date()
            let end = calendar.date(byAdding: .day, value: 1, to: dates.max() ?? start) ?? start
            return start...end
        }
        return period.start...(calendar.date(byAdding: .day, value: 1, to: period.end) ?? period.end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerText

            Chart(nights, id: \.date) { night in
                BarMark(
                    x: .value("Date", night.date, unit: .day),
                    y: .value("Tips", night.cents)
                )
                .foregroundStyle(PaydayColor.primary.opacity(barOpacity(for: night)))
                .cornerRadius(3)
                .annotation(position: .top, spacing: 2) {
                    if selectedDate == nil, maxCents > 0, night.cents == maxCents {
                        Text(Money.wholeDollarString(fromCents: night.cents))
                            .font(PaydayFont.caption3)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    // centered: true aligns each letter under the middle of
                    // its day band — bars are band-centered, so without this
                    // every label sits a half-step left of its bar.
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .font(PaydayFont.caption3)
                        .foregroundStyle(PaydayColor.textSecondary)
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
        .animation(PaydayAnimation.premiumSpring, value: selectedDate)
        .onChange(of: selectedDate) { oldValue, newValue in
            guard oldValue != newValue else { return }
            PaydayHaptics.selection()
        }
    }

    private var headerText: some View {
        Group {
            if let selectedNight {
                Text("\(Money.string(fromCents: selectedNight.cents)) on \(selectedNight.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
            } else {
                Text("Daily earnings")
            }
        }
        .font(PaydayFont.subheadline)
        .foregroundStyle(PaydayColor.textSecondary)
        .monospacedDigit()
    }

    private var chartAccessibilityLabel: String {
        guard maxCents > 0 else { return "Daily earnings chart. No earnings logged." }
        return "Daily earnings chart. Best day \(Money.string(fromCents: maxCents))."
    }

    private func barOpacity(for night: (date: Date, cents: Int)) -> Double {
        let base = maxCents > 0 ? 0.35 + 0.65 * (Double(night.cents) / Double(maxCents)) : 0.5
        guard let selectedNight else { return base }
        return Calendar.current.isDate(night.date, inSameDayAs: selectedNight.date) ? 1.0 : base * 0.5
    }
}
