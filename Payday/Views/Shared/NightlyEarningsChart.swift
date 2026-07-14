import SwiftUI
import Charts

/// Nightly earnings, Health-app style: drag across bars to inspect a
/// night's exact total, with a selection haptic on every change. Bars fade
/// through a single-green opacity ramp — relative size only, never a second
/// hue, per design law.
struct NightlyEarningsChart: View {
    let nights: [(date: Date, cents: Int)]

    @State private var selectedDate: Date?

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
            }
            .chartXSelection(value: $selectedDate)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 120)
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
                Text("\(Money.string(fromCents: selectedNight.cents)) on \(selectedNight.date.formatted(.dateTime.month(.abbreviated).day()))")
            } else {
                Text("Nightly earnings")
            }
        }
        .font(PaydayFont.subheadline)
        .foregroundStyle(PaydayColor.textSecondary)
        .monospacedDigit()
    }

    private func barOpacity(for night: (date: Date, cents: Int)) -> Double {
        let base = maxCents > 0 ? 0.35 + 0.65 * (Double(night.cents) / Double(maxCents)) : 0.5
        guard let selectedNight else { return base }
        return Calendar.current.isDate(night.date, inSameDayAs: selectedNight.date) ? 1.0 : base * 0.5
    }
}
