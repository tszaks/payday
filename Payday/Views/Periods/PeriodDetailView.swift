import SwiftUI
import SwiftData

struct PeriodDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    let period: PayPeriod
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showPaycheckSheet = false
    @State private var undoState = UndoDeleteToastState()
    /// Whether the cash/credit breakdown drawer tucked under the hero is open.
    @State private var breakdownExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var payDate: Date {
        PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback).payDate(for: period)
    }

    private var isPayDateUpcoming: Bool {
        Calendar.current.startOfDay(for: payDate) >= Calendar.current.startOfDay(for: Date())
    }

    private var entries: [TipEntry] {
        allEntries
            .filter { $0.date >= period.start && $0.date <= period.end }
            .sorted { $0.date > $1.date }
    }

    private var shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])] {
        ShiftDays.groupedByShift(entries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
    }

    private var multiShiftDays: Set<Date> {
        var counts: [Date: Int] = [:]
        for shift in shiftDays { counts[shift.day, default: 0] += 1 }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    private var breakdown: TipBreakdown {
        TipBreakdown.total(of: entries)
    }

    private var nightsInPeriod: [(date: Date, cents: Int)] {
        StatsEngine(records: entries.map(TipRecord.init)).nightlyTotals()
    }

    /// Sum of this period's nights, which nightlyTotals() already nets
    /// against any logged tip-out — tips-only, same figure every other
    /// analytic on this screen (breakdown, nightsInPeriod) reads.
    private var tipsNetCents: Int {
        nightsInPeriod.reduce(0) { $0 + $1.cents }
    }

    /// Chart-only: nightsInPeriod with each day's base-rate wages folded in
    /// (never OT — that's a weekly figure, unattributable to one day), so
    /// the bars agree with the tiles and shift rows on screen. tipsNetCents/
    /// heroTotalCents above deliberately keep reading the tips-only
    /// nightsInPeriod — period wages (incl. OT) are already added in there
    /// once, at the period level; folding wages in twice here too would
    /// double-count them.
    private var chartNightsInPeriod: [(date: Date, cents: Int)] {
        guard let wageCentsPerHour = preferencesStore.baseHourlyWageCents else { return nightsInPeriod }
        let shiftsByDay = Dictionary(grouping: shiftDays, by: \.day)
        let wagesByDay = shiftsByDay.mapValues { WageEstimate.centsSummedPerShift(shiftGroups: $0.map(\.items), wageCentsPerHour: wageCentsPerHour) }
        return nightsInPeriod.map { night in
            (date: night.date, cents: night.cents + (wagesByDay[night.date] ?? 0))
        }
    }

    /// Base wage + overtime for this period's shifts — folds into the hero
    /// total and the true $/hr rate below, but StatsEngine/TipBreakdown/
    /// nightsInPeriod above never see it.
    private var wages: PeriodIncome.Wages? {
        PeriodIncome.wages(entries: entries, wageCentsPerHour: preferencesStore.baseHourlyWageCents, firstWeekday: scheduleStore.schedule?.firstWeekday)
    }

    /// The hero figure: tips net plus wages, the same "period income"
    /// definition the dashboard hero and periods list now share.
    private var heroTotalCents: Int {
        tipsNetCents + (wages?.totalCents ?? 0)
    }

    /// TRUE hourly — (net tips + wages) / logged hours — computed locally so
    /// StatsEngine.averageDollarsPerHour (tips-only, used elsewhere) stays
    /// untouched.
    private var trueDollarsPerHour: Double? {
        guard loggedHours > 0 else { return nil }
        return Double(heroTotalCents) / 100 / loggedHours
    }

    /// The face's one quiet caption — the true $/hr rate, when there's
    /// enough to compute one. Nothing when it's absent: no filler, and the
    /// payday date now lives only in the paycheck section further down this
    /// screen (see noPaycheckCaption / PaycheckComparisonView).
    private var heroRateCaption: String? {
        guard let trueDollarsPerHour else { return nil }
        let rate = Money.wholeDollarString(fromCents: Int((trueDollarsPerHour * 100).rounded()))
        return "Averaging \(rate)/hr"
    }

    /// Whether the hero has a cash/credit split worth tucking a drawer under.
    private var hasBreakdown: Bool {
        breakdown.cashCents > 0 || breakdown.creditCents > 0
    }

    /// The figure that makes the drawer's rows reconcile to Total, same
    /// derivation as the Dashboard hero's drawer: gross cash + credit minus
    /// the tips-only net (which nightlyTotals() already nets tip-out out of).
    private var tipOutCents: Int {
        max(0, breakdown.cashCents + breakdown.creditCents - tipsNetCents)
    }

    /// Drawer rows in reconciliation order: Cash, Credit, Tipped out (only
    /// when logged), Wages (only when a rate is set; Overtime its own row
    /// only when logged) — total = cash + credit − tipout + wages.
    private var breakdownRows: [BreakdownRow] {
        var rows: [BreakdownRow] = [
            BreakdownRow("Cash", cents: breakdown.cashCents),
            BreakdownRow("Credit", cents: breakdown.creditCents),
        ]
        if tipOutCents > 0 {
            rows.append(BreakdownRow("Tipped out", cents: -tipOutCents))
        }
        if let wages {
            rows.append(BreakdownRow("Wages", cents: wages.regularCents))
            if wages.overtimeCents > 0 {
                rows.append(BreakdownRow("Overtime", cents: wages.overtimeCents))
            }
        }
        return rows
    }

    private var predictedPaycheckCents: Int {
        PredictedPaycheck.cents(from: breakdown)
    }

    /// Logged hours for this period's shifts, for the wages estimate below —
    /// tip analytics (breakdown, tipsNetCents) never touch this; it exists
    /// only to feed WageEstimate/PeriodIncome.
    private var loggedHours: Double {
        WageEstimate.loggedHours(shiftGroups: shiftDays.map(\.items))
    }

    private var wageEstimateCents: Int? {
        WageEstimate.cents(wageCentsPerHour: preferencesStore.baseHourlyWageCents, hours: loggedHours)
    }

    private var noPaycheckCaption: String {
        let predicted = Money.string(fromCents: predictedPaycheckCents)
        let dateText = payDate.formatted(.dateTime.month(.abbreviated).day())
        let verb = isPayDateUpcoming ? "expects" : "expected"
        guard let wageEstimateCents else {
            return "Payday \(verb) \(predicted) around \(dateText). Enter the tips line from your stub to check it."
        }
        let wages = Money.string(fromCents: wageEstimateCents)
        let hours = WageEstimate.hoursLabel(loggedHours)
        return "Payday \(verb) \(predicted) in card tips around \(dateText), plus \(wages) in wages for the \(hours) you logged (before taxes). Enter the tips line from your stub to check it."
    }

    private var paycheck: PaycheckRecord? {
        // Match by the paycheck's end date landing inside this period rather
        // than exact boundary equality, so paychecks re-home to the right
        // period after a schedule change instead of silently orphaning.
        paycheckRecords.first { $0.periodEnd >= period.start && $0.periodEnd <= period.end }
    }

    var body: some View {
        List {
            Section {
                HeroBreakdownDrawer(
                    lipText: "Cash \(Money.string(fromCents: breakdown.cashCents)) · Credit \(Money.string(fromCents: breakdown.creditCents))",
                    rows: breakdownRows,
                    total: BreakdownRow("Total", cents: heroTotalCents, emphasized: true),
                    hasBreakdown: hasBreakdown,
                    isExpanded: $breakdownExpanded
                ) {
                    heroCard
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: PaydaySpacing.p16, bottom: 8, trailing: PaydaySpacing.p16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !nightsInPeriod.isEmpty {
                Section {
                    NightlyEarningsChart(nights: chartNightsInPeriod, period: period)
                        .paydayCard()
                }
                .listRowInsets(EdgeInsets(top: 4, leading: PaydaySpacing.p16, bottom: 4, trailing: PaydaySpacing.p16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section("Paycheck") {
                if let paycheck {
                    PaycheckComparisonView(breakdown: breakdown, paycheck: paycheck)
                        .listRowInsets(EdgeInsets(top: 4, leading: PaydaySpacing.p16, bottom: 4, trailing: PaydaySpacing.p16))
                        .listRowBackground(Color.clear)
                    Button("Edit paycheck amount") { showPaycheckSheet = true }
                        .listRowBackground(PaydayColor.background)
                } else {
                    Button {
                        showPaycheckSheet = true
                    } label: {
                        Label("Enter paycheck amount", systemImage: "banknote")
                    }
                    .listRowBackground(PaydayColor.background)
                    Text(noPaycheckCaption)
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .listRowBackground(PaydayColor.background)
                }
            }

            if shiftDays.isEmpty {
                Section {
                    Text("No shifts in this period.")
                        .foregroundStyle(PaydayColor.textSecondary)
                }
                .listRowBackground(PaydayColor.background)
            } else {
                Section("Shifts") {
                    ForEach(shiftDays, id: \.shiftID) { group in
                        shiftRow(for: group)
                    }
                }
                .listRowBackground(PaydayColor.background)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(PaydayColor.background)
        .navigationTitle(periodTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetTarget) { target in
            LogTipSheet(target: target)
        }
        .sheet(isPresented: $showPaycheckSheet) {
            PaycheckEntrySheet(period: period, existing: paycheck)
        }
        .undoDeleteToast(undoState, context: modelContext)
    }

    /// The face goes minimal: the total, plus at most one quiet caption (the
    /// true $/hr rate, only when there's one to show). Cash/Credit, Wages,
    /// and the payday date all moved to the tucked drawer / paycheck section
    /// below, rather than stacking four caption lines of differently-weighted
    /// information on the card face.
    private var heroCard: some View {
        VStack(spacing: 10) {
            Text(Money.string(fromCents: heroTotalCents))
                .font(PaydayFont.displayXL)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
            if let heroRateCaption {
                Text(heroRateCaption)
                    .font(PaydayFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(hasBreakdown ? .isButton : [])
        .accessibilityHint(hasBreakdown ? (breakdownExpanded ? "Hide breakdown" : "Show breakdown") : "")
        .accessibilityAction {
            guard hasBreakdown else { return }
            HeroBreakdownToggle.fire($breakdownExpanded, reduceMotion: reduceMotion)
        }
        .paydayCard(padding: PaydaySpacing.p24)
    }

    @ViewBuilder
    private func shiftRow(for group: (day: Date, shiftID: UUID, items: [TipEntry])) -> some View {
        let period = ShiftDetails.resolve(from: group.items).shiftPeriod
        let dayHasMultiple = multiShiftDays.contains(group.day)
        if let anchor = group.items.first {
            Button {
                sheetTarget = .edit(anchor)
            } label: {
                ShiftDayRow(day: group.day, period: period, dayHasMultipleShifts: dayHasMultiple, entries: group.items, wageCentsPerHour: preferencesStore.baseHourlyWageCents)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    undoState.delete(group.items, in: modelContext)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .shiftContextMenu(group.items, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
        }
    }

    /// The card used to carry its own date range as a caption; folding it
    /// into the nav title instead frees that space for the payday/rate line.
    /// The year only shows when the period crosses into one other than the
    /// current one — most periods live entirely inside a single year.
    private var periodTitle: String {
        let currentYear = Calendar.current.component(.year, from: Date())
        let endYear = Calendar.current.component(.year, from: period.end)
        let start = period.start.formatted(.dateTime.month(.abbreviated).day())
        if endYear != currentYear {
            return "\(start) – \(period.end.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
        return "\(start) – \(period.end.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

struct PaycheckComparisonView: View {
    let breakdown: TipBreakdown
    let paycheck: PaycheckRecord

    /// Credit tips are what land on the stub. But entries logged before
    /// cash/credit tracking existed all read as cash, so a period with a
    /// paycheck but zero credit is almost certainly legacy data — fall back
    /// to comparing the total rather than showing a nonsense full-overpay.
    private var usesCreditOnly: Bool { breakdown.creditCents > 0 }
    // Gross, deliberately: this compares against a pay-stub's tips line,
    // which reports gross credit tips — a separate question from income,
    // which is net everywhere else in the app.
    private var comparedCents: Int { usesCreditOnly ? breakdown.creditCents : breakdown.grossTotalCents }

    private var deltaCents: Int { paycheck.paidTipsCents - comparedCents }
    private var isShort: Bool { deltaCents < 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(comparisonLine)
                .font(PaydayFont.subheadline)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)

            HStack(spacing: 6) {
                Image(systemName: isShort ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isShort ? PaydayColor.error : PaydayColor.primary)
                Text(deltaString)
                    .font(PaydayFont.displayCompact)
                    .monospacedDigit()
                    .foregroundStyle(isShort ? PaydayColor.error : PaydayColor.primary)
            }

            Text(caption)
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)

            if let note = paycheck.note, !note.isEmpty {
                Text(note)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
            }

            ForEach(stubDetailLines, id: \.label) { line in
                Text(line.text)
                    .font(PaydayFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paydayCard()
    }

    /// Capture-only stub facts (see PaycheckRecord's four optional detail
    /// fields) — quiet caption lines under the comparison, nothing shown
    /// for whichever weren't entered, no layout change when none exist.
    private var stubDetailLines: [(label: String, text: String)] {
        var lines: [(label: String, text: String)] = []
        if let hourlyRateCents = paycheck.hourlyRateCents {
            lines.append((label: "Hourly rate", text: "Hourly rate \(Money.string(fromCents: hourlyRateCents))"))
        }
        if let grossPayCents = paycheck.grossPayCents {
            lines.append((label: "Gross pay", text: "Gross pay \(Money.string(fromCents: grossPayCents))"))
        }
        if let netPayCents = paycheck.netPayCents {
            lines.append((label: "Net pay", text: "Net pay \(Money.string(fromCents: netPayCents))"))
        }
        if let owedTipsCents = paycheck.owedTipsCents {
            lines.append((label: "Tips owed", text: "Tips owed \(Money.string(fromCents: owedTipsCents))"))
        }
        return lines
    }

    private var comparisonLine: String {
        let logged = Money.string(fromCents: comparedCents)
        let paid = Money.string(fromCents: paycheck.paidTipsCents)
        if usesCreditOnly {
            return "You logged \(logged) in credit tips / Check paid \(paid)"
        }
        return "You logged \(logged) / Check paid \(paid)"
    }

    private var caption: String {
        if usesCreditOnly {
            return "Cash tips aren't on your stub, so this compares your credit tips against the tips line."
        }
        return "This period has no credit tips logged, so it compares your total against the tips line."
    }

    private var deltaString: String {
        if deltaCents == 0 { return "Matched exactly" }
        let sign = deltaCents > 0 ? "+" : "-"
        return "\(sign)\(Money.string(fromCents: abs(deltaCents)))"
    }
}
