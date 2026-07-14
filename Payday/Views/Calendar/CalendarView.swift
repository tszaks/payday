import SwiftUI
import SwiftData

private struct DaySelection: Identifiable {
    let date: Date
    var id: Date { date }
}

struct CalendarView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Query private var allEntries: [TipEntry]

    @State private var displayedMonth: Date = Calendar.current.startOfDay(for: .now)
    @State private var daySelection: DaySelection?

    /// Honors the user's chosen week-start; the grid layout and weekday header
    /// both key off calendar.firstWeekday, so setting it here is enough.
    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = scheduleStore.schedule?.resolvedFirstWeekday ?? c.firstWeekday
        return c
    }

    private var calculator: PayPeriodCalculator {
        PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
    }

    private var currentPeriod: PayPeriod {
        calculator.period(containing: .now)
    }

    private var dailyTotals: [Date: Int] {
        Dictionary(grouping: allEntries, by: { calendar.startOfDay(for: $0.date) })
            .mapValues { entries in entries.reduce(0) { $0 + $1.amountCents } }
    }

    private var gridDays: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthInterval.start),
              let daysInMonth = calendar.range(of: .day, in: .month, for: displayedMonth)?.count
        else { return [] }
        let totalCells = leading + daysInMonth
        let trailing = (7 - totalCells % 7) % 7
        let totalDays = totalCells + trailing
        return (0..<totalDays).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                monthHeader

                weekdayHeader

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(gridDays, id: \.self) { day in
                        Button {
                            daySelection = DaySelection(date: day)
                        } label: {
                            DayCell(
                                day: day,
                                totalCents: dailyTotals[day],
                                isCurrentMonth: calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month),
                                isToday: calendar.isDateInToday(day),
                                isInCurrentPeriod: day >= currentPeriod.start && day <= currentPeriod.end
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.horizontal)
                .id(displayedMonth)
                .transition(.opacity)

                Spacer()
            }
            .padding(.top, 8)
            .navigationTitle("Calendar")
            .sheet(item: $daySelection) { selection in
                DayDetailSheet(date: selection.date)
            }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.22)) { shiftMonth(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.22)) { shiftMonth(by: 1) }
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal, 24)
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private func shiftMonth(by delta: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = newMonth
        }
    }
}

private struct DayCell: View {
    let day: Date
    let totalCents: Int?
    let isCurrentMonth: Bool
    let isToday: Bool
    let isInCurrentPeriod: Bool

    private var dayNumber: Int {
        Calendar.current.component(.day, from: day)
    }

    private var hasTips: Bool {
        (totalCents ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(dayNumber)")
                .font(.system(.callout, design: .rounded))
                .fontWeight(isToday ? .bold : .regular)
            if hasTips, let totalCents {
                Text(Money.string(fromCents: totalCents))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(cellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isToday ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .opacity(isCurrentMonth ? 1 : 0.3)
        .contentShape(Rectangle())
    }

    /// Days with tips read strongest; the rest of the current pay period gets
    /// a soft wash so the range shows as a continuous band of tinted tiles
    /// instead of disconnected underlines.
    private var cellFill: Color {
        if hasTips { return Color.accentColor.opacity(0.18) }
        if isInCurrentPeriod { return Color.accentColor.opacity(0.07) }
        return .clear
    }
}
