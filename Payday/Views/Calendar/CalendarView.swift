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
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                monthNavRow
                    // The lens selector sits directly above this screen;
                    // the month needs air to read as its own thing rather
                    // than a second row of that control (Tyler, 2026-07-28).
                    .padding(.top, PaydaySpacing.p20)

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
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .background(PaydayColor.background)
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

    /// Month navigation lives in the content, not the nav bar — the nav
    /// bar's title is the fixed "History" chrome shared with the Periods
    /// lens now, so paging the month can't live there. A compact quiet row,
    /// not big floating nav buttons: chevrons small enough to read as an
    /// in-page control, not a second navigation bar.
    /// No chevrons (Tyler, 2026-07-28): the month title alone, with a
    /// horizontal swipe over the grid moving months — the gesture every
    /// calendar already teaches. The buttons were a second navigation bar
    /// stacked under the real one.
    private var monthNavRow: some View {
        Text(monthTitle)
            .font(PaydayFont.headline)
            .foregroundStyle(PaydayColor.textPrimary)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Swipe left or right to change month")
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

    /// The screen's hero moved here (Tyler, 2026-07-28): the grid is what a
    /// glance at this screen is for, so the month total no longer sits above
    /// it demanding first read. This cluster is the second surface: the
    /// total leads, then exact hours worked, its best day (all-in, matching
    /// the tiles above), and a quiet weekday shape. Collapses to a single
    /// line when nothing's logged yet so an empty month never shows
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

                VStack(spacing: 2) {
                    Text(Money.string(fromCents: monthTotalCents))
                        .font(PaydayFont.displayMedium)
                        .monospacedDigit()
                        .foregroundStyle(PaydayColor.textPrimary)
                        .contentTransition(.numericText())
                        .animation(PaydayAnimation.premiumSpring, value: monthTotalCents)
                    Text("this month")
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                }

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

                // Weekday mini-bars deleted (Tyler, 2026-07-20): the heatmap
                // grid directly above already tells the which-days story —
                // re-encoding it smaller looked goofy at any styling. The two
                // text lines are the summary.
            }
        }
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

    @Environment(\.colorScheme) private var colorScheme

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
                    .font(PaydayFont.caption2)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(Self.heatTextColor(fraction: heatFraction, colorScheme: colorScheme))
                    .opacity(0.85)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        // Every cell — worked or not, in-month or not — gets the same fixed
        // footprint so the grid reads as one surface with heat in it, never
        // a field of raised chips (Tyler, 2026-07-28).
        .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
        .background(hasTips ? PaydayColor.primary.opacity(Self.fillOpacity(fraction: heatFraction)) : Color.clear, in: RoundedRectangle(cornerRadius: PaydayRadius.sm))
        // Today always rings the full cell in the same rounded-square
        // geometry as the tiles — a tight circle around the numeral read as
        // a stray dot, not a state (Tyler, 2026-07-20).
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: PaydayRadius.sm)
                    .strokeBorder(PaydayColor.primary, lineWidth: 2)
            }
        }
        .opacity(isCurrentMonth ? 1 : 0.3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dayNumberLabel: some View {
        Text("\(dayNumber)")
            .font(.system(.callout, design: .rounded))
            .fontWeight(hasTips || isToday ? .bold : .regular)
            .foregroundStyle(hasTips ? Self.heatTextColor(fraction: heatFraction, colorScheme: colorScheme) : PaydayColor.textSecondary)
    }

    private var accessibilityLabel: String {
        let dateText = day.formatted(.dateTime.month(.wide).day())
        guard hasTips, let totalCents else { return "\(dateText), no shifts" }
        return "\(dateText), \(Money.string(fromCents: totalCents)) logged"
    }

    /// One-hue green ramp (Tyler, 2026-07-28), reversing the temperature-walk
    /// exception picked on 2026-07-19: a hue walk from red through yellow to
    /// green was meant to separate a tightly clustered month at a glance, but
    /// on real renders it came out as muddy browns and olives on black — not
    /// one cell actually read as the app's green — so the "deliberate,
    /// contained exception to the one-green law" it was sold as never earned
    /// its keep. The calendar rejoins that law: every worked day is
    /// PaydayColor.primary, full stop, and heat is carried by opacity alone,
    /// floored so the faintest worked day still reads as green rather than
    /// fading toward grey — the mistake made in the prior opacity attempt
    /// (2026-07-20) that led to the (now also reversed) fully-opaque commit.
    /// That prior miss came from tuning against dark-mode renders only; the
    /// floor here is picked by looking at both modes.
    private static let fillOpacityFloor = 0.22

    /// A linear ramp off a high floor made every worked day look alike on a
    /// tightly clustered month. Squaring the fraction spends more of the
    /// range on the differences that actually exist between ordinary days,
    /// while the floor keeps the quietest one unmistakably green.
    private static func fillOpacity(fraction: Double) -> Double {
        let curved = fraction * fraction
        return fillOpacityFloor + (1 - fillOpacityFloor) * curved
    }

    private static func backgroundComponents(for colorScheme: ColorScheme) -> (r: Double, g: Double, b: Double) {
        if colorScheme == .dark {
            return (0.0196, 0.0196, 0.0196) // #050505
        }
        return (0.9804, 0.9804, 0.9804) // #FAFAFA
    }

    /// Contrast is computed against the fill as it actually composites —
    /// PaydayColor.primary at `fillOpacity`, blended over this mode's page
    /// background (PaydayColor.background) — rather than assumed, since the
    /// same opacity reads very differently over alabaster than over
    /// obsidian. Same relative-luminance approximation (ITU-R BT.601
    /// weights) the calendar has used since the temperature-walk days.
    private static func heatTextColor(fraction: Double, colorScheme: ColorScheme) -> Color {
        let alpha = fillOpacity(fraction: fraction)
        let bg = backgroundComponents(for: colorScheme)
        let fgR = 0.0
        let fgG = 0.7216 // 184/255
        let fgB = 0.2471 // 63/255
        let r = fgR * alpha + bg.r * (1 - alpha)
        let g = fgG * alpha + bg.g * (1 - alpha)
        let b = fgB * alpha + bg.b * (1 - alpha)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.55 ? PaydayColor.textPrimary : .white
    }
}
