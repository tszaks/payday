import SwiftUI
import SwiftData

struct PeriodsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    private var calculator: PayPeriodCalculator {
        PayPeriodCalculator(schedule: scheduleStore.schedule!)
    }

    /// Current period plus history, walking backward until we run out of
    /// entries/paychecks to show, capped so the list stays bounded.
    private var periods: [PayPeriod] {
        var result: [PayPeriod] = []
        var cursor = calculator.period(containing: .now)
        result.append(cursor)

        let earliestEntryDate = allEntries.map(\.date).min()
        let earliestPaycheckDate = paycheckRecords.map(\.periodStart).min()
        let earliestRelevantDate = [earliestEntryDate, earliestPaycheckDate].compactMap { $0 }.min()

        guard let earliestRelevantDate else { return result }

        while result.count < 24, cursor.start > earliestRelevantDate {
            let previousEnd = Calendar.current.date(byAdding: .day, value: -1, to: cursor.start) ?? cursor.start
            cursor = calculator.period(containing: previousEnd)
            result.append(cursor)
        }
        return result
    }

    private func total(for period: PayPeriod) -> Int {
        allEntries
            .filter { $0.date >= period.start && $0.date <= period.end }
            .reduce(0) { $0 + $1.amountCents }
    }

    private func paycheck(for period: PayPeriod) -> PaycheckRecord? {
        paycheckRecords.first { $0.periodStart == period.start && $0.periodEnd == period.end }
    }

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List(periods.indices, id: \.self) { index in
                let period = periods[index]
                NavigationLink(value: period) {
                    PeriodRow(
                        period: period,
                        isCurrent: index == 0,
                        loggedCents: total(for: period),
                        paycheck: paycheck(for: period)
                    )
                }
            }
            .listStyle(.plain)
            .navigationTitle("Periods")
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenPeriodWithPaycheck"), path.isEmpty,
                   let periodWithPaycheck = periods.first(where: { paycheck(for: $0) != nil }) {
                    path.append(periodWithPaycheck)
                }
            }
            #endif
            .navigationDestination(for: PayPeriod.self) { period in
                PeriodDetailView(period: period)
            }
        }
    }
}

private struct PeriodRow: View {
    let period: PayPeriod
    let isCurrent: Bool
    let loggedCents: Int
    let paycheck: PaycheckRecord?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dateRangeString)
                        .font(.body)
                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(Money.string(fromCents: loggedCents))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let paycheck {
                let delta = paycheck.paidTipsCents - loggedCents
                VStack(alignment: .trailing, spacing: 2) {
                    Text(deltaString(delta))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(delta < 0 ? Color.red : Color.accentColor)
                    Text("checked")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var dateRangeString: String {
        "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(period.end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func deltaString(_ deltaCents: Int) -> String {
        let sign = deltaCents > 0 ? "+" : (deltaCents < 0 ? "-" : "")
        return sign + Money.string(fromCents: abs(deltaCents))
    }
}
