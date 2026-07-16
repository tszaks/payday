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

    // Net everywhere — every income number in the app is net of any logged
    // tip-out (see PRODUCT.md), and this grid used to be the one place still
    // summing gross amountCents, silently disagreeing with the Dashboard and
    // Period detail totals for the same days.
    private var dailyTotals: [Date: Int] {
        Dictionary(grouping: allEntries, by: { calendar.startOfDay(for: $0.date) })
            .mapValues { entries in entries.reduce(0) { $0 + $1.netCents } }
    }

    private var monthTotalCents: Int {
        allEntries
            .filter { calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month) }
            .reduce(0) { $0 + $1.netCents }
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
            ScrollView {
                VStack(spacing: PaydaySpacing.p16) {
                    VStack(spacing: PaydaySpacing.p16) {
                        monthHeader

                        VStack(spacing: 2) {
                            Text(Money.string(fromCents: monthTotalCents))
                                .font(PaydayFont.displayLarge)
                                .monospacedDigit()
                                .foregroundStyle(PaydayColor.textPrimary)
                                .contentTransition(.numericText())
                                .animation(PaydayAnimation.premiumSpring, value: monthTotalCents)
                            Text("this month")
                                .font(PaydayFont.caption)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }

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
                        .id(displayedMonth)
                        .transition(.opacity)
                    }
                    .paydayCard(padding: PaydaySpacing.p20)
                }
                .padding(.horizontal, PaydaySpacing.p16)
                .padding(.top, PaydaySpacing.p8)
            }
            .contentMargins(.bottom, 88, for: .scrollContent)
            .background(PaydayColor.background)
            .navigationTitle("Calendar")
            .sheet(item: $daySelection) { selection in
                DayDetailSheet(date: selection.date)
            }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenDaySheet") {
                    daySelection = DaySelection(date: .now)
                }
            }
            #endif
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: PaydayAnimation.standardDuration)) { shiftMonth(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
            Spacer()
            Button {
                withAnimation(.easeOut(duration: PaydayAnimation.standardDuration)) { shiftMonth(by: 1) }
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .tint(PaydayColor.primary)
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
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
                .foregroundStyle(PaydayColor.textPrimary)
            if hasTips, let totalCents {
                Text(Money.wholeDollarString(fromCents: totalCents))
                    .font(PaydayFont.caption3)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(cellFill, in: RoundedRectangle(cornerRadius: PaydayRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: PaydayRadius.sm)
                .strokeBorder(isToday ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .opacity(isCurrentMonth ? 1 : 0.3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let dateText = day.formatted(.dateTime.month(.wide).day())
        guard hasTips, let totalCents else { return dateText }
        return "\(dateText), \(Money.string(fromCents: totalCents)) logged"
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
