import SwiftUI
import SwiftData

private struct DaySelection: Identifiable {
    let date: Date
    var id: Date { date }
}

struct CalendarView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
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
    // Period detail totals for the same days. Wages (base rate x each
    // shift's canonical hours, never OT — that's a weekly figure) are added
    // per day so the tiles and the heat normalization below both agree with
    // the row/sheet totals for the same day.
    private var dailyTotals: [Date: Int] {
        let tipsByDay = Dictionary(grouping: allEntries, by: { calendar.startOfDay(for: $0.date) })
            .mapValues { entries in entries.reduce(0) { $0 + $1.netCents } }
        guard let wageCentsPerHour = preferencesStore.baseHourlyWageCents else { return tipsByDay }
        let shifts = ShiftDays.groupedByShift(allEntries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod, calendar: calendar)
        var wagesByDay: [Date: Int] = [:]
        for shift in shifts {
            let hours = ShiftDetails.resolve(from: shift.items).hoursWorked ?? 0
            guard hours > 0 else { continue }
            wagesByDay[shift.day, default: 0] += WageEstimate.cents(wageCentsPerHour: wageCentsPerHour, hours: hours) ?? 0
        }
        return tipsByDay.merging(wagesByDay, uniquingKeysWith: +)
    }

    // Wage-inclusive, matching the Dashboard/Period-detail/Periods-list
    // totals: net tips + base wage + overtime. Overtime is computed per
    // calendar workweek (see PeriodIncome), so a week straddling this
    // month's boundary attributes its whole overtime to whichever month
    // the filter below happens to include — an acceptable imprecision,
    // not worth splitting a week's OT across two months for.
    private var monthTotalCents: Int {
        let monthEntries = allEntries.filter { calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month) }
        let tipsCents = monthEntries.reduce(0) { $0 + $1.netCents }
        let wages = PeriodIncome.wages(entries: monthEntries, wageCentsPerHour: preferencesStore.baseHourlyWageCents, firstWeekday: scheduleStore.schedule?.firstWeekday)
        return tipsCents + (wages?.totalCents ?? 0)
    }

    /// The displayed month's best day — the heatmap's full-intensity anchor,
    /// so every month self-normalizes and always shows its own hottest day
    /// at full heat.
    private var displayedMonthMaxCents: Int {
        dailyTotals
            .filter { calendar.isDate($0.key, equalTo: displayedMonth, toGranularity: .month) }
            .values.max() ?? 0
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
                                        monthMaxCents: displayedMonthMaxCents,
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
    /// The best day of the displayed month — full heat. Each month
    /// self-normalizes so its own hottest day always reads at full intensity.
    let monthMaxCents: Int
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

    /// Worked days are a heatmap — intensity scales with the day's take
    /// relative to the month's best day, so hot and slow days separate at a
    /// glance. The rest of the current pay period keeps its soft wash so the
    /// range still shows as a continuous band.
    private var cellFill: Color {
        if hasTips, let totalCents {
            let fraction = monthMaxCents > 0 ? min(1.0, Double(totalCents) / Double(monthMaxCents)) : 1.0
            return Self.heat(fraction: fraction)
        }
        if isInCurrentPeriod { return Color.accentColor.opacity(0.07) }
        return .clear
    }

    /// Temperature scale, Tyler's pick over a single-hue green ramp (2026-07-19):
    /// a hue walk from red (slow) through yellow (mid) to Vero green (best),
    /// opacity rising with heat for shade depth within each hue. A deliberate,
    /// contained exception to the one-green design law — the calendar is the
    /// app's one at-a-glance pattern surface, and on a tightly clustered month
    /// hue separates days that a green ramp leaves looking identical. True red
    /// only appears when a day lands far below the month's best, so it reads
    /// as information, not judgment.
    private static func heat(fraction f: Double) -> Color {
        // Hue walk: red (0.02) through yellow (0.13) to Vero green (0.40).
        let hue = f < 0.5
            ? 0.02 + (0.13 - 0.02) * (f / 0.5)
            : 0.13 + (0.40 - 0.13) * ((f - 0.5) / 0.5)
        return Color(hue: hue, saturation: 0.72, brightness: 0.88).opacity(0.35 + 0.25 * f)
    }
}
