import SwiftUI
import SwiftData

private struct DaySelection: Identifiable {
    let date: Date
    var id: Date { date }
}

/// The ONE snapshot both Calendar surfaces read, built the same way from the
/// same rows.
///
/// ## Why it is the WHOLE dataset and not the month
///
/// This is the fix for the audit's original confirmed bug. `CalendarView`
/// used to hand `WageEstimate.centsSummedPerShift` one `Dictionary(grouping:
/// by: \.day)` bucket at a time (CalendarView.swift:49 on `production`) while
/// the month headline went through `PeriodIncome.wages` over the month's
/// entries. The overtime threshold belongs to a WORKWEEK, so a day handed to
/// the ledger alone can never carry the week's overtime and a month made of
/// month-fragment weeks carries a different amount of it than the days do.
/// MEASURED on W2's 48-hour week: headline 19716, tiles 18585, 1131c apart on
/// one screen.
///
/// A whole-dataset snapshot removes the premise. Every week is allocated once,
/// as a week, and then `range(_:)` and `days(in:)` only SELECT out of the same
/// valuations — so `Σ tiles == headline` is arithmetic rather than hope, and a
/// week that straddles the month edge keeps the overtime it earned.
///
/// ## Why the bridge and not `earningsStore`
///
/// Nothing writes `ShiftRecord` on a device yet (PR 2 slices S6-S13 are open),
/// so `earningsStore.snapshot` is EMPTY in production and a screen switched
/// onto it today would show a person with years of shifts a blank grid. See
/// `LegacySnapshotBridge`'s header. When the shift sync leg lands this enum is
/// the one place either Calendar surface has to change.
enum CalendarEarnings {
    /// The grouping calendar, which is NOT the grid's calendar: the grid needs
    /// the user's week start for its layout, and a shift grouping must not.
    /// The payroll zone is frozen here for the same reason the engine freezes
    /// it — a device that travels must not re-date a shift.
    static func groupingCalendar(payrollTimeZone: TimeZone) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = payrollTimeZone
        return calendar
    }

    /// Every shift in the dataset, grouped by the app's one grouping rule.
    static func shiftGroups(
        entries: [TipEntry],
        payrollTimeZone: TimeZone
    ) -> [(day: Date, shiftID: UUID, items: [TipEntry])] {
        ShiftDays.groupedByShift(
            entries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: groupingCalendar(payrollTimeZone: payrollTimeZone)
        )
    }

    /// One snapshot over every shift, valued with the user's OWN rate and
    /// workweek history, effective dates intact.
    ///
    /// `asOf` is `.distantFuture` deliberately, and it is the only cutoff
    /// decision this screen makes. The calendar has never applied a to-date
    /// clamp ([CA-01], [CA-04]: "no asOf — future-dated days render"), and it
    /// must not start: a person who logs tomorrow's shift expects to see it on
    /// tomorrow's tile. Opting out in the STAMP rather than per query is what
    /// keeps `range(_:)` and `days(in:)` clamping identically, which is the
    /// whole `Σ tiles == headline` guarantee — `day(_:)` is unclamped in the
    /// engine and a half-clamped screen would disagree with itself.
    static func snapshot(
        shifts: [(day: Date, shiftID: UUID, items: [TipEntry])],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone
    ) -> EarningsSnapshot? {
        LegacySnapshotBridge.snapshot(
            shifts: shifts,
            policies: policies,
            payrollTimeZone: payrollTimeZone,
            asOf: .distantFuture
        )
    }

    /// The same snapshot from the new representation. Main actor because
    /// `ShiftRecord` is a `@Model`, the same reason `ShiftInputAdapter` is.
    @MainActor
    static func snapshot(
        records: [ShiftRecord],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone
    ) -> EarningsSnapshot? {
        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        return try? EarningsSnapshot.build(EarningsInputs(
            shifts: adapted.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            // `.distantFuture` for the reason the legacy overload above
            // records at length: the calendar has never clamped to today and
            // must not start, and opting out in the STAMP rather than per
            // query is what keeps `day(_:)`, `range(_:)` and `days(in:)`
            // clamping identically. That agreement is the whole
            // `sum of tiles == headline` guarantee.
            asOf: CivilDay(.distantFuture, in: payrollTimeZone),
            unreadableReceiptShiftIDs: adapted.unreadableReceiptShiftIDs
        ))
    }

    /// **The one entry point for this screen's snapshot.**
    ///
    /// Takes BOTH representations and resolves which to read itself. The
    /// month grid was the last whole-screen reader still on a legacy-only
    /// path: `makeFacts` called `shiftGroups(entries:)` with no switch, so
    /// after the flip the tiles would have rendered only the shifts logged
    /// BEFORE conversion and silently dropped every one since. It survived
    /// the earlier sweep because the per-screen audit that cleared it counted
    /// edit and delete TARGETS -- of which this screen has none -- and that
    /// zero was carried forward as though it were a statement about reads.
    @MainActor
    static func snapshot(
        entries: [TipEntry],
        records: [ShiftRecord],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        representation: ShiftRepresentation = .automatic
    ) -> EarningsSnapshot? {
        representation.usesRecords
            ? snapshot(records: records, policies: policies, payrollTimeZone: payrollTimeZone)
            : snapshot(
                shifts: shiftGroups(entries: entries, payrollTimeZone: payrollTimeZone),
                policies: policies,
                payrollTimeZone: payrollTimeZone
            )
    }
}

/// One tile of the month grid.
///
/// The tile holds an `EarningsFigure`, never cents: a day the engine could not
/// answer renders no currency instead of `$0.00`, and `hasShifts` is what
/// separates "nothing was worked" from "nothing is known".
struct CalendarDayTile: Identifiable, Equatable {
    /// The civil day this tile is, in the payroll zone.
    let civilDay: CivilDay
    /// The same day as a `Date`, for the grid's own lookups and labels.
    let day: Date
    /// That day's earnings as the engine answered, labelled by its own
    /// completeness.
    let figure: EarningsFigure
    /// Whether any shift at all falls on this day. A day with a logged shift
    /// worth $0 is a different fact from a day nobody worked, and only this
    /// flag keeps them apart (the [CA-03] VoiceOver lie).
    let hasShifts: Bool

    var id: Int { civilDay.dayNumber }
}

/// One immutable render pass for Calendar: the grid's geometry, one figure per
/// day of the displayed month, and the month's own figure.
///
/// The PR 5 adapter contract (`Payday/Earnings/SnapshotFacts.swift`), rule for
/// rule:
///
/// 1. **Presentation only.** Grid days, which day a tile is, the month title's
///    inputs, the heat normalizer, the counts. Every cents figure arrived from
///    an `EarningsSnapshot` query and nothing here adds, subtracts, scales or
///    rounds one.
/// 2. **It takes a snapshot plus its own presentational inputs.** Not
///    `[TipEntry]`, not `wageCentsPerHour`, not `firstWeekday`. The `Calendar`
///    it does take is the grid's own geometry — the user's week start decides
///    the column order and nothing else — and its `timeZone` is the frozen
///    payroll zone the snapshot was built in, so a cell and the shift on it
///    cannot disagree about which day it was.
/// 3. **No `Key`, no `dataRevision`.** It carries the snapshot's `stamp`.
/// 4. **`EarningsFigure`, never cents.** A `.partial` month reads "Known so
///    far" and never "Total"; an unbacked read renders no currency at all.
struct CalendarMonthFacts: SnapshotFacts {
    // MARK: Presentation

    /// Every cell the grid draws, including the leading and trailing days of
    /// the neighbouring months.
    let gridDays: [Date]
    /// The displayed month's days, in order, one per tile.
    let tiles: [CalendarDayTile]
    /// Days with at least one shift on them.
    let daysWorkedCount: Int
    /// "Xh Ym" over the month's covered minutes, straight off the engine's
    /// own minute count rather than a second pass over the rows.
    let monthHoursLabel: String
    /// The month's best day, which is the heat ramp's normalizer. A `max` is a
    /// selection, not arithmetic: it is one of the tiles' own figures, the
    /// same shape as `EarningsChartFacts.maxCents`.
    let brightestTileCents: Int

    // MARK: Money, from the engine

    /// The displayed month, as `snapshot.range(month)` answered it.
    ///
    /// `Σ tiles == this`, by construction: both come from the same valuations
    /// under the same cutoff, and the engine's `days(in:)` is documented to
    /// partition exactly what `range(_:)` selects.
    let monthFigure: EarningsFigure

    /// The month hero's drawer, from the SAME `EarningsResult` the face
    /// figure came from.
    ///
    /// The Calendar was the one hero without one. Dashboard and
    /// PeriodDetail have had `HeroBreakdownDrawer` since wave 0, so a
    /// person could see what a period was made of everywhere except the
    /// month they were looking at -- and this screen is where the
    /// "wages missing for 1 shift" caption appears, which is exactly the
    /// figure most worth opening up.
    ///
    /// Rows come from `BreakdownRow.ledgerRows`, which reads
    /// `knownComponents`, so a partial month shows the tips it has and the
    /// wages it has and does not silently imply the missing one.
    let monthBreakdownRows: [BreakdownRow]
    /// The emphasized bottom line. Its LABEL is the face figure's, so the
    /// card and the drawer cannot say two different things about one number.
    let monthBreakdownTotal: BreakdownRow
    let monthHasBreakdown: Bool

    /// The wages caption, NAMING the day when it can.
    ///
    /// "wages missing for 1 shift" made Tyler scan a whole month by hand to
    /// find which one. The engine already knew: every `ShiftValuation`
    /// carries its `workDay` and a `wage` that is `.unavailable` when it
    /// could not be priced, so this is a filter over
    /// `EarningsSnapshot.valuations(in:)` rather than new engine API or a
    /// second derivation of the same fact.
    let monthWagesCaption: String?

    let stamp: SnapshotStamp?

    /// The payroll zone the snapshot was built in, for the grid's day lookup.
    private let payrollTimeZone: TimeZone
    private let tilesByDay: [Int: CalendarDayTile]

    init(snapshot: EarningsSnapshot?, displayedMonth: Date, calendar: Calendar) {
        let zone = calendar.timeZone
        payrollTimeZone = zone
        stamp = snapshot?.stamp

        let month = YearMonth(CivilDay(displayedMonth, in: zone))
        if let snapshot {
            let monthResult = snapshot.range(month.range)
            monthFigure = .earnedIncome(monthResult)
            monthHoursLabel = WorkedMinutes.hoursLabel(minutes: monthResult.minutes)
            monthBreakdownRows = BreakdownRow.ledgerRows(monthResult)
            monthBreakdownTotal = BreakdownRow.total(monthResult)
            monthHasBreakdown = BreakdownRow.hasBreakdown(monthResult)
            // Sorted so the named day is stable run to run; a caption that
            // reorders itself reads like the data changed.
            let unpriced = snapshot.valuations(in: month.range)
                .filter { !$0.wage.isValued }
                .map(\.workDay)
                .sorted { $0.iso < $1.iso }
            monthWagesCaption = CompletenessCopy.caption(
                monthResult.completeness.state, unpricedDays: unpriced)
            // One result per civil day of the month, from the query whose
            // contract is that it partitions the range above. Paired by each
            // result's OWN range rather than by index, so a cutoff that
            // shortened the series can never shift a figure onto the wrong
            // tile.
            tiles = snapshot.days(in: month.range).compactMap { result in
                guard let civilDay = result.range?.start else { return nil }
                return CalendarDayTile(
                    civilDay: civilDay,
                    day: civilDay.date(in: zone),
                    figure: .earnedIncome(result),
                    hasShifts: !result.shiftIDs.isEmpty
                )
            }
        } else {
            // Rule 4: no snapshot is a failed read, not an empty month. Every
            // figure on the screen renders a placeholder and the grid draws no
            // amounts at all.
            monthFigure = .unavailable()
            monthHoursLabel = WorkedMinutes.hoursLabel(minutes: 0)
            // A failed read has no breakdown to show. The label still comes
            // from the figure so VoiceOver reads something next to the
            // placeholder, matching Dashboard's unavailable branch.
            let unavailable = EarningsFigure.unavailable()
            monthBreakdownRows = []
            monthBreakdownTotal = BreakdownRow(unavailable.label, cents: nil, emphasized: true)
            monthHasBreakdown = false
            monthWagesCaption = nil
            tiles = []
        }

        tilesByDay = Dictionary(tiles.map { ($0.civilDay.dayNumber, $0) }, uniquingKeysWith: { first, _ in first })
        daysWorkedCount = tiles.filter(\.hasShifts).count
        brightestTileCents = tiles.compactMap(\.figure.cents).max() ?? 0

        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else {
            gridDays = []
            return
        }
        let weekday = calendar.component(.weekday, from: monthInterval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthInterval.start),
              let daysInMonth = calendar.range(of: .day, in: .month, for: displayedMonth)?.count
        else {
            gridDays = []
            return
        }
        let totalCells = leading + daysInMonth
        let totalDays = totalCells + (7 - totalCells % 7) % 7
        gridDays = (0..<totalDays).compactMap {
            calendar.date(byAdding: .day, value: $0, to: gridStart)
        }
    }

    /// The tile for one grid cell, or nil when that cell is a neighbouring
    /// month's day (or when there is no dataset behind the grid at all).
    ///
    /// Keyed by civil day rather than by `Date` so a DST boundary, where a
    /// day's midnight is not 86,400 seconds after the previous one, cannot
    /// miss.
    func tile(on day: Date) -> CalendarDayTile? {
        tilesByDay[CivilDay(day, in: payrollTimeZone).dayNumber]
    }

    /// Whether the month has anything to summarize. False for a month nobody
    /// worked AND for a read that failed — the two render different things,
    /// which is why `isUnbacked` is checked separately.
    var hasAnythingLogged: Bool { !tiles.isEmpty && daysWorkedCount > 0 }

    /// The line under the month's number.
    ///
    /// `"this month"` alone whenever the figure may be called a total. When it
    /// may not, the figure's own label leads: a month holding a shift with no
    /// hours logged reads "known so far this month", never a bare total that
    /// quietly excludes it. The rule is `EarningsFigure`'s, not this screen's.
    var monthCaption: String {
        // An unavailable figure is not "known so far" about anything; it is
        // the absence of an answer, and the placeholder next to it already
        // says that.
        if monthFigure.isUnavailable || monthFigure.mayBeCalledATotal { return "this month" }
        return "\(monthFigure.label.lowercased()) this month"
    }
}

struct CalendarView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(PolicyStore.self) private var policyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The month hero's drawer. Collapsed by default: the grid is what a
    /// glance at this screen is for, and the breakdown is the second question.
    @State private var monthBreakdownExpanded = false
    @Query private var allEntries: [TipEntry]
    /// The other representation. `CalendarEarnings.snapshot` resolves which
    /// one this screen reads; see its header for why the choice is no longer
    /// made here.
    @Query private var shiftRecords: [ShiftRecord]

    @State private var displayedMonth: Date = Calendar.current.startOfDay(for: .now)
    @State private var daySelection: DaySelection?

    /// Honors the user's chosen week-start; the grid layout and weekday header
    /// both key off calendar.firstWeekday, so setting it here is enough.
    ///
    /// This weekday is the pay-period GRID's, and it is a LAYOUT input only.
    /// PR 3 severed it from the workweek that owns overtime, which lives on
    /// `PayrollCalendarPolicy` — and the snapshot below is handed
    /// `policyStore.policies` whole so the engine does its own effective
    /// dating. Feeding this weekday onto a money path is what made Dashboard
    /// and Insights allocate overtime across different weeks over the same
    /// days.
    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = scheduleStore.schedule?.resolvedFirstWeekday ?? c.firstWeekday
        // The grid draws civil days in the PAYROLL zone, so a tile and the
        // shift on it cannot disagree about which day it was while the phone
        // is somewhere else.
        c.timeZone = policyStore.payrollTimeZone
        return c
    }

    private var monthTitle: String {
        displayedMonth.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        // No `Key` and no `dataRevision` (contract rule 3): the snapshot's
        // `stamp` is the complete dependency list, and it is complete because
        // it is computed rather than hand-listed. Nor is there a facts cache
        // keyed on it — a cache key has to exist BEFORE the value it guards,
        // and the stamp only exists after the snapshot is built. Measured
        // instead: `RenderFactsPerformanceTests.calendarFactsStayFastForLargeHistory`
        // covers the snapshot build AND the month's queries over a 10,000-row
        // history inside the interactive budget.
        let resolvedCalendar = calendar
        let facts = makeFacts(calendar: resolvedCalendar)
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                monthNavRow
                    // The lens selector sits directly above this screen;
                    // the month needs air to read as its own thing rather
                    // than a second row of that control (Tyler, 2026-07-28).
                    .padding(.top, PaydaySpacing.p20)

                weekdayHeader

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(facts.gridDays, id: \.self) { day in
                        Button {
                            daySelection = DaySelection(date: day)
                        } label: {
                            DayCell(
                                day: day,
                                tile: facts.tile(on: day),
                                monthMaxCents: facts.brightestTileCents,
                                isCurrentMonth: resolvedCalendar.isDate(day, equalTo: displayedMonth, toGranularity: .month),
                                isToday: resolvedCalendar.isDateInToday(day)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .id(displayedMonth)
                .transition(.opacity)
                .gesture(monthSwipeGesture)

                monthSummarySection(facts)
            }
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .background(PaydayColor.background)
        .sheet(item: $daySelection) { selection in
            DayDetailSheet(date: selection.date).paydayAppearance()
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-OpenDaySheet") {
                daySelection = DaySelection(date: .now)
            }
        }
        #endif
    }

    private func makeFacts(calendar: Calendar) -> CalendarMonthFacts {
        let zone = policyStore.payrollTimeZone
        return CalendarMonthFacts(
            snapshot: CalendarEarnings.snapshot(
                entries: allEntries,
                records: shiftRecords,
                policies: policyStore.policies,
                payrollTimeZone: zone
            ),
            displayedMonth: displayedMonth,
            calendar: calendar
        )
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: PaydayAnimation.standardDuration)) {
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
            ForEach(Array(orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
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
    private func monthSummarySection(_ facts: CalendarMonthFacts) -> some View {
        if facts.isUnbacked {
            // A failed read. Not "nothing logged this month", which would be a
            // claim about the person's history, and not `$0.00`.
            VStack(spacing: PaydaySpacing.p12) {
                Divider()
                VStack(spacing: 2) {
                    Text(ShiftDayRow.unavailablePlaceholder)
                        .font(PaydayFont.displayMedium)
                        .monospacedDigit()
                        .foregroundStyle(PaydayColor.textSecondary)
                    Text(facts.monthCaption)
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Amount unavailable for this month.")
            }
        } else if !facts.hasAnythingLogged {
            Text("Nothing logged this month.")
                .font(PaydayFont.footnote)
                .foregroundStyle(PaydayColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, PaydaySpacing.p4)
        } else {
            VStack(spacing: PaydaySpacing.p12) {
                Divider()

                // The same drawer Dashboard and PeriodDetail use, over the
                // month's own `EarningsResult`. A person can now see that
                // this figure is cash + credit + gratuity + wages MINUS
                // tip-out rather than having to be told.
                HeroBreakdownDrawer(
                    rows: facts.monthBreakdownRows,
                    total: facts.monthBreakdownTotal,
                    hasBreakdown: facts.monthHasBreakdown,
                    isExpanded: $monthBreakdownExpanded
                ) {
                    VStack(spacing: 2) {
                        Text(facts.monthFigure.text ?? ShiftDayRow.unavailablePlaceholder)
                            .font(PaydayFont.displayMedium)
                            .monospacedDigit()
                            .foregroundStyle(PaydayColor.textPrimary)
                            .contentTransition(.numericText())
                            .animation(
                                reduceMotion ? nil : PaydayAnimation.premiumSpring,
                                value: facts.monthFigure.cents
                            )
                        Text(facts.monthCaption)
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.textSecondary)
                        // `.estimated` carries its caption, per the completeness
                        // presentation rules: a wage priced off an assumed rate
                        // says so on the surface that shows it.
                        if let caption = facts.monthWagesCaption ?? facts.monthFigure.caption {
                            Text(caption)
                                .font(PaydayFont.caption2)
                                .foregroundStyle(PaydayColor.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                VStack(spacing: 4) {
                    Text("\(facts.daysWorkedCount) day\(facts.daysWorkedCount == 1 ? "" : "s") worked · \(facts.monthHoursLabel)")
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.textPrimary)
                        .monospacedDigit()
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
    /// This day's tile, or nil for a neighbouring month's day.
    let tile: CalendarDayTile?
    /// The best day of the displayed month — full heat. Each month
    /// self-normalizes so its own hottest day always reads at full intensity.
    let monthMaxCents: Int
    let isCurrentMonth: Bool
    let isToday: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var dayNumber: Int {
        Calendar.current.component(.day, from: day)
    }

    /// The day's own figure, only for a day of the displayed month.
    private var figure: EarningsFigure? {
        isCurrentMonth ? tile?.figure : nil
    }

    private var hasTips: Bool {
        (figure?.cents ?? 0) > 0
    }

    /// The heat ramp's position. A magnitude encoding, not a figure: it prints
    /// no currency and it is why the tile's own `EarningsFigure` keeps its
    /// cents available. Nothing downstream of this is money.
    private var heatFraction: Double {
        guard hasTips, let cents = figure?.cents else { return 0 }
        return monthMaxCents > 0 ? min(1.0, Double(cents) / Double(monthMaxCents)) : 1.0
    }

    var body: some View {
        VStack(spacing: 2) {
            dayNumberLabel
            if hasTips, let amount = figure?.wholeDollarText {
                Text(amount)
                    .font(PaydayFont.caption2)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(Self.heatTextColor(fraction: heatFraction, colorScheme: colorScheme))
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dayNumberLabel: some View {
        Text("\(dayNumber)")
            .font(.system(.callout, design: .rounded))
            .fontWeight(hasTips || isToday ? .bold : .regular)
            .foregroundStyle(
                hasTips
                    ? Self.heatTextColor(fraction: heatFraction, colorScheme: colorScheme)
                    : (isCurrentMonth ? PaydayColor.textSecondary : PaydayColor.textTertiary)
            )
    }

    /// Three different facts, said differently, where the old label said "no
    /// shifts" for all three: a day with money on it, a day somebody worked
    /// for nothing, and a day the engine could not answer for.
    private var accessibilityLabel: String {
        let dateText = day.formatted(.dateTime.month(.wide).day())
        guard let figure, isCurrentMonth, tile?.hasShifts == true else {
            return "\(dateText), no shifts"
        }
        guard let amount = figure.text else {
            return "\(dateText), amount unavailable"
        }
        return "\(dateText), \(amount) logged"
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
    /// background (PaydayColor.background) — rather than assumed. Choose the
    /// higher-contrast black/white foreground using WCAG's gamma-correct
    /// relative luminance, so every point in the heat ramp stays legible.
    private static func heatTextColor(fraction: Double, colorScheme: ColorScheme) -> Color {
        let alpha = fillOpacity(fraction: fraction)
        let bg = backgroundComponents(for: colorScheme)
        let fgR = 0.0
        let fgG = colorScheme == .dark ? 0.7216 : 0.5216 // #00B83F / #00852F
        let fgB = colorScheme == .dark ? 0.2471 : 0.1843
        let r = fgR * alpha + bg.r * (1 - alpha)
        let g = fgG * alpha + bg.g * (1 - alpha)
        let b = fgB * alpha + bg.b * (1 - alpha)
        let luminance = 0.2126 * linearized(r) + 0.7152 * linearized(g) + 0.0722 * linearized(b)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? .black : .white
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
