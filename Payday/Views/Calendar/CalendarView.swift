import SwiftUI
import SwiftData
import UIKit

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
        let shiftsByDay = Dictionary(grouping: shifts, by: \.day)
        let wagesByDay = shiftsByDay.mapValues { WageEstimate.centsSummedPerShift(shiftGroups: $0.map(\.items), wageCentsPerHour: wageCentsPerHour) }
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
        monthDailyTotals.map(\.cents).max() ?? 0
    }

    /// This month's per-day all-in totals — the same figures the grid tiles
    /// show — feeding both the heat normalization and the summary block
    /// below, so "Best day" always agrees with the hottest tile on screen.
    private var monthDailyTotals: [(day: Date, cents: Int)] {
        dailyTotals
            .filter { calendar.isDate($0.key, equalTo: displayedMonth, toGranularity: .month) }
            .map { (day: $0.key, cents: $0.value) }
    }

    private var monthShiftGroups: [(day: Date, shiftID: UUID, items: [TipEntry])] {
        let monthEntries = allEntries.filter { calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month) }
        return ShiftDays.groupedByShift(monthEntries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod, calendar: calendar)
    }

    private var daysWorkedCount: Int { monthDailyTotals.count }

    /// Exact punch hours (never rounded to the quarter) for every shift this
    /// month, via the same canonical-hours rule WageEstimate reads for the
    /// wage figures folded into monthDailyTotals.
    private var monthLoggedHours: Double {
        WageEstimate.loggedHours(shiftGroups: monthShiftGroups.map(\.items))
    }

    private var bestDay: (day: Date, cents: Int)? {
        monthDailyTotals.max { $0.cents < $1.cents }
    }

    /// Cents summed by weekday across every week in the displayed month —
    /// the mini bar row's data, aligned to orderedWeekdaySymbols below via
    /// the same firstWeekday rotation.
    private var weekdayTotals: [Int: Int] {
        var totals: [Int: Int] = [:]
        for entry in monthDailyTotals {
            let weekday = calendar.component(.weekday, from: entry.day)
            totals[weekday, default: 0] += entry.cents
        }
        return totals
    }

    private var orderedWeekdayTotals: [Int] {
        let totals = weekdayTotals
        let start = calendar.firstWeekday
        return (0..<7).map { offset in
            let weekday = ((start - 1 + offset) % 7) + 1
            return totals[weekday] ?? 0
        }
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

    private var monthTitle: String {
        displayedMonth.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PaydaySpacing.p16) {
                    VStack(spacing: PaydaySpacing.p16) {
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
                                        isToday: calendar.isDateInToday(day)
                                    )
                                }
                                .buttonStyle(PressableButtonStyle())
                            }
                        }
                        .id(displayedMonth)
                        .transition(.opacity)
                        .gesture(monthSwipeGesture)

                        monthSummarySection
                    }
                    .paydayCard(padding: PaydaySpacing.p20)
                }
                .padding(.horizontal, PaydaySpacing.p16)
                .padding(.top, PaydaySpacing.p8)
            }
            .contentMargins(.bottom, 88, for: .scrollContent)
            .background(PaydayColor.background)
            .navigationTitle(monthTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeOut(duration: PaydayAnimation.standardDuration)) { shiftMonth(by: -1) }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeOut(duration: PaydayAnimation.standardDuration)) { shiftMonth(by: 1) }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                }
            }
            .tint(PaydayColor.primary)
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

    /// Horizontal drag on the grid pages the month, same as the chevrons —
    /// only fires when the drag is dominantly horizontal so it never steals
    /// the ScrollView's vertical scroll.
    private var monthSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), abs(horizontal) > 50 else { return }
                withAnimation(.easeOut(duration: PaydayAnimation.standardDuration)) {
                    shiftMonth(by: horizontal < 0 ? 1 : -1)
                }
            }
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

    /// The month's second surface: exact hours worked, its best day (all-in,
    /// matching the tiles above), and a quiet weekday shape. Collapses to a
    /// single line when nothing's logged yet so an empty month never shows
    /// zeroed-out stats.
    @ViewBuilder
    private var monthSummarySection: some View {
        if monthDailyTotals.isEmpty {
            Text("Nothing logged this month yet.")
                .font(PaydayFont.footnote)
                .foregroundStyle(PaydayColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, PaydaySpacing.p4)
        } else {
            VStack(spacing: PaydaySpacing.p12) {
                Divider()

                VStack(spacing: 4) {
                    Text("\(daysWorkedCount) day\(daysWorkedCount == 1 ? "" : "s") worked · \(WageEstimate.hoursLabel(monthLoggedHours))")
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.textPrimary)
                        .monospacedDigit()
                    if let bestDay {
                        Text("Best day: \(bestDay.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(Money.string(fromCents: bestDay.cents))")
                            .font(PaydayFont.footnote)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .monospacedDigit()
                    }
                }

                weekdayBars
            }
        }
    }

    /// A sparkline, not a bar chart: fixed hairline-thin bars so the shape
    /// reads quietly rather than blobby capsules competing with the grid
    /// above. Zero-total weekdays get no fill at all — just the baseline
    /// track — instead of a faint capsule pretending to be a bar.
    private var weekdayBars: some View {
        let totals = orderedWeekdayTotals
        let maxTotal = max(totals.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(zip(orderedWeekdaySymbols, totals).enumerated()), id: \.offset) { _, pair in
                let (symbol, cents) = pair
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(PaydayColor.textTertiary.opacity(0.15))
                            .frame(width: 4, height: 1)
                        if cents > 0 {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(PaydayColor.primary)
                                .frame(width: 4, height: max(2, 28 * Double(cents) / Double(maxTotal)))
                        }
                    }
                    .frame(height: 28, alignment: .bottom)
                    Text(symbol)
                        .font(PaydayFont.caption3)
                        .foregroundStyle(PaydayColor.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 40, alignment: .bottom)
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

    private var dayNumber: Int {
        Calendar.current.component(.day, from: day)
    }

    private var hasTips: Bool {
        (totalCents ?? 0) > 0
    }

    private var heatFraction: Double {
        guard hasTips, let totalCents else { return 0 }
        return monthMaxCents > 0 ? min(1.0, Double(totalCents) / Double(monthMaxCents)) : 1.0
    }

    var body: some View {
        VStack(spacing: 2) {
            dayNumberLabel
            if hasTips, let totalCents {
                Text(Money.wholeDollarString(fromCents: totalCents))
                    .font(PaydayFont.caption3)
                    .monospacedDigit()
                    .foregroundStyle(Self.heatTextColor(fraction: heatFraction))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(hasTips ? Self.heat(fraction: heatFraction) : Color.clear, in: RoundedRectangle(cornerRadius: PaydayRadius.sm))
        .overlay {
            if isToday && hasTips {
                RoundedRectangle(cornerRadius: PaydayRadius.sm)
                    .strokeBorder(PaydayColor.primary, lineWidth: 2)
            }
        }
        .opacity(isCurrentMonth ? 1 : 0.3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The numeral, with a bare ring for "today" when the day has no tile to
    /// carry it — the ring rides the day itself, not a background it doesn't
    /// have.
    private var dayNumberLabel: some View {
        ZStack {
            if isToday && !hasTips {
                Circle()
                    .strokeBorder(PaydayColor.primary, lineWidth: 2)
                    .frame(width: 26, height: 26)
            }
            Text("\(dayNumber)")
                .font(.system(.callout, design: .rounded))
                .fontWeight(hasTips || isToday ? .bold : .regular)
                .foregroundStyle(hasTips ? Self.heatTextColor(fraction: heatFraction) : PaydayColor.textSecondary)
        }
    }

    private var accessibilityLabel: String {
        let dateText = day.formatted(.dateTime.month(.wide).day())
        guard hasTips, let totalCents else { return dateText }
        return "\(dateText), \(Money.string(fromCents: totalCents)) logged"
    }

    /// Temperature scale, Tyler's pick over a single-hue green ramp (2026-07-19):
    /// a hue walk from red (slow) through yellow (mid) to Vero green (best).
    /// Committed color (2026-07-20): opacity is no longer how heat shows —
    /// every worked tile is fully opaque, and saturation/brightness deepen
    /// with heat instead, so light mode never washes out to pastel. A
    /// deliberate, contained exception to the one-green design law — the
    /// calendar is the app's one at-a-glance pattern surface, and on a
    /// tightly clustered month hue separates days that a green ramp leaves
    /// looking identical. True red only appears when a day lands far below
    /// the month's best, so it reads as information, not judgment.
    private static func heatComponents(fraction f: Double) -> (hue: Double, saturation: Double, brightness: Double) {
        let hue = f < 0.5
            ? 0.02 + (0.13 - 0.02) * (f / 0.5)
            : 0.13 + (0.40 - 0.13) * ((f - 0.5) / 0.5)
        let saturation = 0.62 + 0.18 * f
        let brightness = 0.70 - 0.30 * f
        return (hue, saturation, brightness)
    }

    private static func heat(fraction f: Double) -> Color {
        let c = heatComponents(fraction: f)
        return Color(hue: c.hue, saturation: c.saturation, brightness: c.brightness)
    }

    /// White reads on most of the ramp, but the hue walk crosses yellow —
    /// bright enough on its own that white can fail there even after the
    /// darkening above. Computed from the same HSB the tile actually paints
    /// (relative luminance, ITU-R BT.601 weights) rather than a fixed
    /// "white unless near yellow" guess, so the choice is correct at every
    /// point on the ramp, not just the one this was checked at.
    private static func heatTextColor(fraction f: Double) -> Color {
        let c = heatComponents(fraction: f)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(hue: c.hue, saturation: c.saturation, brightness: c.brightness, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.55 ? .black : .white
    }
}
