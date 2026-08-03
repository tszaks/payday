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

    /// Everything that adds, then the subtotal, then everything that
    /// subtracts, then what's left — the same one-direction-change ledger the
    /// Dashboard hero uses, so the two screens read identically.
    private var grossEarnedCents: Int {
        breakdown.cashCents + breakdown.creditCents + (wages?.totalCents ?? 0)
    }

    private var breakdownRows: [BreakdownRow] {
        var rows: [BreakdownRow] = [
            BreakdownRow("Cash tips", cents: breakdown.cashCents),
            BreakdownRow("Credit tips", cents: breakdown.creditCents),
        ]
        if let wages {
            // Regular hours only, not wages.hours (the total) — see the
            // Dashboard's identical row.
            rows.append(BreakdownRow("Wages · \(WageEstimate.hoursLabel(wages.hours - wages.overtimeHours))", cents: wages.regularCents))
            if wages.overtimeCents > 0 {
                rows.append(BreakdownRow("Overtime · \(WageEstimate.hoursLabel(wages.overtimeHours))", cents: wages.overtimeCents))
            }
        }
        if tipOutCents > 0 {
            rows.append(BreakdownRow("Earned", cents: grossEarnedCents, dividerAbove: true))
            rows.append(BreakdownRow("Tipped out", cents: -tipOutCents))
        }
        return rows
    }

    private var predictedPaycheckCents: Int {
        PredictedPaycheck.cents(from: breakdown, wagesCents: wages?.totalCents ?? 0)
    }

    /// Logged hours for this period's shifts, for the wages estimate below —
    /// tip analytics (breakdown, tipsNetCents) never touch this; it exists
    /// only to feed WageEstimate/PeriodIncome.
    private var loggedHours: Double {
        WageEstimate.loggedHours(shiftGroups: shiftDays.map(\.items))
    }

    /// One number and one sentence. The old copy read "Payday expects $2,960.28
    /// in card tips around Aug 7, plus $206.21 in wages for the 72h 52m you
    /// logged (before taxes). Enter the tips line from your stub to check it."
    /// That is two totals to add up, the hours the drawer already itemizes, and
    /// an instruction the button immediately below it already gives.
    private var noPaycheckCaption: String {
        let predicted = Money.string(fromCents: predictedPaycheckCents)
        let dateText = payDate.formatted(.dateTime.month(.abbreviated).day())
        let verb = isPayDateUpcoming ? "should show" : "should have shown"
        return "Your check \(verb) \(predicted) around \(dateText). Card tips minus tip-out, plus wages, before taxes."
    }

    private var paycheck: PaycheckRecord? {
        // Match by the paycheck's end date landing inside this period rather
        // than exact boundary equality, so paychecks re-home to the right
        // period after a schedule change instead of silently orphaning.
        paycheckRecords.first { $0.periodEnd >= period.start && $0.periodEnd <= period.end }
    }

    var body: some View {
        // A ScrollView, deliberately NOT a List — same fix as the Dashboard
        // (2026-07-19): a List animates row resize on UIKit's own clock,
        // which fights the hero drawer's spring and makes everything below
        // visibly stutter as it opens and closes. Pure SwiftUI layout keeps
        // the whole column on one animation.
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                HeroBreakdownDrawer(
                    // Must reconcile to the hero directly above it — gross
                    // cash + credit did not (see the Dashboard's lip).
                    lipText: tipOutCents > 0
                        ? "Earned \(Money.string(fromCents: grossEarnedCents)) · Tipped out \(Money.string(fromCents: tipOutCents))"
                        : "Cash \(Money.string(fromCents: breakdown.cashCents)) · Credit \(Money.string(fromCents: breakdown.creditCents))",
                    rows: breakdownRows,
                    total: BreakdownRow(tipOutCents > 0 ? "You kept" : "Total", cents: heroTotalCents, emphasized: true),
                    hasBreakdown: hasBreakdown,
                    isExpanded: $breakdownExpanded
                ) {
                    heroCard
                }

                // The chart keeps its own "Daily tips" label (it doubles as
                // the scrub readout), so no separate flat header goes above
                // it — this is this screen's only other flat section without
                // a kicker.
                if !nightsInPeriod.isEmpty {
                    NightlyEarningsChart(nights: nightsInPeriod, period: period)
                }

                paycheckSection

                shiftsSection
            }
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
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
        #if DEBUG
        .onAppear {
            // Screenshot-only, same flag as the Dashboard hero: opens the
            // drawer immediately so QA can inspect the expanded layout
            // without tapping through simctl.
            if ProcessInfo.processInfo.arguments.contains("-DebugExpandBreakdown") {
                breakdownExpanded = true
            }
        }
        #endif
    }

    /// Flat, in the Insights section grammar: a tracked caption2 kicker,
    /// content beneath, no card. One raised object on this screen is the
    /// hero; the paycheck comparison sits on the surface like every other
    /// non-hero section.
    @ViewBuilder
    private var paycheckSection: some View {
        let paycheck = self.paycheck
        VStack(alignment: .leading, spacing: 6) {
            Text("PAYCHECK")
                .font(PaydayFont.caption2)
                .tracking(0.8)
                .foregroundStyle(PaydayColor.primary)

            if let paycheck {
                PaycheckComparisonView(breakdown: breakdown, paycheck: paycheck)
            } else {
                Text(noPaycheckCaption)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
            }

            Button(paycheck == nil ? "Enter paycheck amount" : "Edit paycheck amount") {
                showPaycheckSheet = true
            }
            .font(PaydayFont.subheadline)
            .foregroundStyle(PaydayColor.primary)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }

    @ViewBuilder
    private var shiftsSection: some View {
        if shiftDays.isEmpty {
            Text("No shifts in this period.")
                .font(PaydayFont.bodyRegular)
                .foregroundStyle(PaydayColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Shifts")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .padding(.bottom, PaydaySpacing.p8)

                ForEach(Array(shiftDays.enumerated()), id: \.element.shiftID) { index, group in
                    if index > 0 { Divider() }
                    shiftRow(for: group)
                }
            }
        }
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
                    .padding(.vertical, PaydaySpacing.p12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Swipe-to-delete was List-only and went with the List
            // conversion — delete stays one long-press away via the context
            // menu, with the same undo toast, matching the Dashboard.
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
    // The stub's tips line — credit tips NET OF TIP-OUT, the one shared
    // formula (PredictedPaycheck). This used to compare against gross credit,
    // which made every period with a tip-out read as short by exactly the
    // tip-out, in red, accusing payroll of a shortfall that never happened.
    private var comparedCents: Int { PredictedPaycheck.tipsLineCents(from: breakdown) }

    private var deltaCents: Int { paycheck.paidTipsCents - comparedCents }
    private var isShort: Bool { deltaCents < 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verdictLine)
                .font(PaydayFont.headline)
                .monospacedDigit()
                .foregroundStyle(isShort ? PaydayColor.error : PaydayColor.primary)

            Text(comparisonCaption)
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
                .monospacedDigit()

            if let note = paycheck.note, !note.isEmpty {
                Text(note)
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
            }

            ForEach(stubDetailLines, id: \.label) { line in
                Text(line.text)
                    .font(PaydayFont.caption2)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Capture-only stub facts (see PaycheckRecord's optional detail
    /// fields) — quiet caption lines under the comparison, nothing shown
    /// for whichever weren't entered, no layout change when none exist.
    /// hourlyRateCents/owedTipsCents are retired from the entry sheet
    /// (2026-07-27) but still shown here when present — legacy records that
    /// only ever had those two must stay legible.
    private var stubDetailLines: [(label: String, text: String)] {
        var lines: [(label: String, text: String)] = []
        if let regularWagesCents = paycheck.regularWagesCents {
            lines.append((label: "Regular wages", text: "Regular wages \(Money.string(fromCents: regularWagesCents))"))
        }
        if let overtimeWagesCents = paycheck.overtimeWagesCents {
            lines.append((label: "Overtime wages", text: "Overtime wages \(Money.string(fromCents: overtimeWagesCents))"))
        }
        if let grossPayCents = paycheck.grossPayCents {
            lines.append((label: "Gross", text: "Gross \(Money.string(fromCents: grossPayCents))"))
        }
        if let taxesCents = paycheck.taxesCents {
            lines.append((label: "Taxes", text: "Taxes \(Money.string(fromCents: taxesCents))"))
        }
        if let netPayCents = paycheck.netPayCents {
            lines.append((label: "Net", text: "Net \(Money.string(fromCents: netPayCents))"))
        }
        if let hourlyRateCents = paycheck.hourlyRateCents {
            lines.append((label: "Hourly rate", text: "Hourly rate \(Money.string(fromCents: hourlyRateCents))"))
        }
        if let owedTipsCents = paycheck.owedTipsCents {
            lines.append((label: "Tips owed", text: "Tips owed \(Money.string(fromCents: owedTipsCents))"))
        }
        return lines
    }

    /// The whole verdict in one sentence — exact dollar gap, no exclamation
    /// marks. The explanatory paragraph that used to sit under this (cash
    /// tips aren't on the stub) is gone: true of every server everywhere,
    /// it doesn't need repeating on every period forever (Tyler's
    /// obviousness law, 2026-07-27).
    private var verdictLine: String {
        guard deltaCents != 0 else { return "Matched exactly." }
        let amount = Money.string(fromCents: abs(deltaCents))
        return isShort ? "\(amount) short." : "\(amount) over."
    }

    private var comparisonCaption: String {
        let logged = Money.string(fromCents: comparedCents)
        let paid = Money.string(fromCents: paycheck.paidTipsCents)
        if usesCreditOnly {
            return "Logged \(logged) in credit tips · check paid \(paid)"
        }
        return "Logged \(logged) · check paid \(paid)"
    }
}
