import Combine
import SwiftUI
import SwiftData

/// One immutable period-detail render. This view has several consumers of
/// the same filtered entries; collecting them here prevents each section,
/// label, and accessibility query from rebuilding the same history facts.
struct PeriodDetailFacts {
    let payDate: Date
    let entries: [TipEntry]
    let shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])]
    let multiShiftDays: Set<Date>
    let breakdown: TipBreakdown
    let nightsInPeriod: [(date: Date, cents: Int)]
    let wages: PeriodIncome.Wages?
    let heroTotalCents: Int
    let heroRateCaption: String?
    let hasBreakdown: Bool
    let tipOutCents: Int
    let grossEarnedCents: Int
    let breakdownRows: [BreakdownRow]
    let noPaycheckCaption: String
    let paycheck: PaycheckRecord?

    init(
        allEntries: [TipEntry],
        paycheckRecords: [PaycheckRecord],
        period: PayPeriod,
        schedule: PaySchedule?,
        wageCentsPerHour: Int?,
        calendar: Calendar = .current
    ) {
        let calculator = PayPeriodCalculator(schedule: schedule ?? .fallback, calendar: calendar)
        let resolvedPayDate = calculator.payDate(for: period)
        let resolvedEntries = allEntries
            .filter { $0.date >= period.start && $0.date <= period.end }
            .sorted { $0.date > $1.date }
        let resolvedShiftDays = ShiftDays.groupedByShift(
            resolvedEntries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: calendar
        )

        var shiftCounts: [Date: Int] = [:]
        for shift in resolvedShiftDays { shiftCounts[shift.day, default: 0] += 1 }
        let resolvedMultiShiftDays = Set(shiftCounts.filter { $0.value >= 2 }.keys)

        let resolvedBreakdown = TipBreakdown.total(of: resolvedEntries)
        let resolvedNights = StatsEngine(
            records: resolvedEntries.map(TipRecord.init),
            calendar: calendar
        ).nightlyTotals()
        let nonWageEarningsCents = resolvedNights.reduce(0) { $0 + $1.cents }
        let resolvedWages = PeriodIncome.wages(
            entries: resolvedEntries,
            wageCentsPerHour: wageCentsPerHour,
            firstWeekday: schedule?.firstWeekday,
            calendar: calendar
        )
        let resolvedHeroTotalCents = nonWageEarningsCents + (resolvedWages?.totalCents ?? 0)

        let loggedHours = WageEstimate.loggedHours(shiftGroups: resolvedShiftDays.map(\.items))
        let resolvedHeroRateCaption: String?
        if loggedHours > 0 {
            let dollarsPerHour = Double(resolvedHeroTotalCents) / 100 / loggedHours
            let rate = Money.wholeDollarString(fromCents: Int((dollarsPerHour * 100).rounded()))
            resolvedHeroRateCaption = "Averaging \(rate)/hr"
        } else {
            resolvedHeroRateCaption = nil
        }

        let resolvedHasBreakdown = resolvedBreakdown.cashCents > 0
            || resolvedBreakdown.creditCents > 0
            || resolvedBreakdown.gratuityFeesCents > 0
        let resolvedTipOutCents = max(
            0,
            resolvedBreakdown.cashCents
                + resolvedBreakdown.creditCents
                + resolvedBreakdown.gratuityFeesCents
                - nonWageEarningsCents
        )
        let resolvedGrossEarnedCents = resolvedBreakdown.cashCents
            + resolvedBreakdown.creditCents
            + resolvedBreakdown.gratuityFeesCents
            + (resolvedWages?.totalCents ?? 0)

        var rows = [
            BreakdownRow("Cash tips", cents: resolvedBreakdown.cashCents),
            BreakdownRow("Credit tips", cents: resolvedBreakdown.creditCents),
        ]
        if resolvedBreakdown.gratuityFeesCents > 0 {
            rows.append(BreakdownRow("Gratuity & fees", cents: resolvedBreakdown.gratuityFeesCents))
        }
        if let resolvedWages {
            rows.append(BreakdownRow(
                "Wages · \(WageEstimate.hoursLabel(resolvedWages.hours - resolvedWages.overtimeHours))",
                cents: resolvedWages.regularCents
            ))
            if resolvedWages.overtimeCents > 0 {
                rows.append(BreakdownRow(
                    "Overtime · \(WageEstimate.hoursLabel(resolvedWages.overtimeHours))",
                    cents: resolvedWages.overtimeCents
                ))
            }
        }
        if resolvedTipOutCents > 0 {
            rows.append(BreakdownRow("Earned", cents: resolvedGrossEarnedCents, dividerAbove: true))
            rows.append(BreakdownRow("Tipped out", cents: -resolvedTipOutCents))
        }

        let predictedPaycheckCents = PredictedPaycheck.cents(
            from: resolvedBreakdown,
            wagesCents: resolvedWages?.totalCents ?? 0
        )
        let resolvedNoPaycheckCaption = "Expected \(Money.string(fromCents: predictedPaycheckCents)) · \(resolvedPayDate.formatted(.dateTime.month(.abbreviated).day()))"
        let resolvedPaycheck = paycheckRecords.first {
            $0.periodEnd >= period.start && $0.periodEnd <= period.end
        }

        payDate = resolvedPayDate
        entries = resolvedEntries
        shiftDays = resolvedShiftDays
        multiShiftDays = resolvedMultiShiftDays
        breakdown = resolvedBreakdown
        nightsInPeriod = resolvedNights
        wages = resolvedWages
        heroTotalCents = resolvedHeroTotalCents
        heroRateCaption = resolvedHeroRateCaption
        hasBreakdown = resolvedHasBreakdown
        tipOutCents = resolvedTipOutCents
        grossEarnedCents = resolvedGrossEarnedCents
        breakdownRows = rows
        noPaycheckCaption = resolvedNoPaycheckCaption
        paycheck = resolvedPaycheck
    }
}

private struct PeriodDetailFactsKey: Equatable {
    let entriesRevision: Int
    let paychecksRevision: Int
    let period: PayPeriod
    let frequency: PayFrequency?
    let anchorPeriodEnd: Date?
    let payDelayDays: Int?
    let firstWeekday: Int?
    let wageCentsPerHour: Int?
}

private struct PeriodDetailFactsCache {
    let key: PeriodDetailFactsKey
    let facts: PeriodDetailFacts
}

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
    @State private var factsCache: PeriodDetailFactsCache?
    @State private var dataRevision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let schedule = scheduleStore.schedule
        let key = PeriodDetailFactsKey(
            entriesRevision: dataRevision,
            paychecksRevision: dataRevision,
            period: period,
            frequency: schedule?.frequency,
            anchorPeriodEnd: schedule?.anchorPeriodEnd,
            payDelayDays: schedule?.payDelayDays,
            firstWeekday: schedule?.firstWeekday,
            wageCentsPerHour: preferencesStore.baseHourlyWageCents
        )
        let facts = factsCache?.key == key
            ? factsCache!.facts
            : makeFacts()
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
                    lipText: facts.tipOutCents > 0
                        ? "Earned \(Money.string(fromCents: facts.grossEarnedCents)) · Tipped out \(Money.string(fromCents: facts.tipOutCents))"
                        : facts.breakdown.gratuityFeesCents > 0
                            ? "Tips \(Money.string(fromCents: facts.breakdown.grossTotalCents)) · Gratuity \(Money.string(fromCents: facts.breakdown.gratuityFeesCents))"
                            : "Cash \(Money.string(fromCents: facts.breakdown.cashCents)) · Credit \(Money.string(fromCents: facts.breakdown.creditCents))",
                    rows: facts.breakdownRows,
                    total: BreakdownRow(facts.tipOutCents > 0 ? "You kept" : "Total", cents: facts.heroTotalCents, emphasized: true),
                    hasBreakdown: facts.hasBreakdown,
                    isExpanded: $breakdownExpanded
                ) {
                    heroCard(facts)
                }

                // The chart keeps its own time-scaled earnings label (it doubles as
                // the scrub readout), so no separate flat header goes above
                // it — this is this screen's only other flat section without
                // a kicker.
                if !facts.nightsInPeriod.isEmpty {
                    NightlyEarningsChart(nights: facts.nightsInPeriod, period: period)
                }

                paycheckSection(facts)

                shiftsSection(facts)
            }
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .background(PaydayColor.background)
        .navigationTitle(periodTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetTarget) { target in
            LogTipSheet(target: target).paydayAppearance()
        }
        .sheet(isPresented: $showPaycheckSheet) {
            PaycheckEntrySheet(period: period, existing: facts.paycheck).paydayAppearance()
        }
        .undoDeleteToast(undoState, context: modelContext)
        .task(id: key) {
            guard factsCache?.key != key else { return }
            factsCache = PeriodDetailFactsCache(key: key, facts: facts)
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            dataRevision &+= 1
        }
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

    private func makeFacts() -> PeriodDetailFacts {
        PeriodDetailFacts(
            allEntries: allEntries,
            paycheckRecords: paycheckRecords,
            period: period,
            schedule: scheduleStore.schedule,
            wageCentsPerHour: preferencesStore.baseHourlyWageCents
        )
    }

    /// Flat, in the Insights section grammar: a tracked caption2 kicker,
    /// content beneath, no card. One raised object on this screen is the
    /// hero; the paycheck comparison sits on the surface like every other
    /// non-hero section.
    @ViewBuilder
    private func paycheckSection(_ facts: PeriodDetailFacts) -> some View {
        let paycheck = facts.paycheck
        VStack(alignment: .leading, spacing: 6) {
            Text("PAYCHECK")
                .font(PaydayFont.caption2)
                .tracking(0.8)
                .foregroundStyle(PaydayColor.primary)

            if let paycheck {
                PaycheckComparisonView(breakdown: facts.breakdown, paycheck: paycheck)
            } else {
                Text(facts.noPaycheckCaption)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
            }

            Button(paycheck == nil ? "Add paycheck" : "Edit paycheck") {
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
    private func shiftsSection(_ facts: PeriodDetailFacts) -> some View {
        if facts.shiftDays.isEmpty {
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

                ForEach(Array(facts.shiftDays.enumerated()), id: \.element.shiftID) { index, group in
                    if index > 0 { Divider() }
                    shiftRow(for: group, multiShiftDays: facts.multiShiftDays)
                }
            }
        }
    }

    /// The face goes minimal: the total, plus at most one quiet caption (the
    /// true $/hr rate, only when there's one to show). Cash/Credit, Wages,
    /// and the payday date all moved to the tucked drawer / paycheck section
    /// below, rather than stacking four caption lines of differently-weighted
    /// information on the card face.
    private func heroCard(_ facts: PeriodDetailFacts) -> some View {
        VStack(spacing: 10) {
            Text(Money.string(fromCents: facts.heroTotalCents))
                .font(PaydayFont.displayXL)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
            if let heroRateCaption = facts.heroRateCaption {
                Text(heroRateCaption)
                    .font(PaydayFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(facts.hasBreakdown ? .isButton : [])
        .accessibilityHint(facts.hasBreakdown ? (breakdownExpanded ? "Hide breakdown" : "Show breakdown") : "")
        .accessibilityAction {
            guard facts.hasBreakdown else { return }
            HeroBreakdownToggle.fire($breakdownExpanded, reduceMotion: reduceMotion)
        }
        .paydayCard(padding: PaydaySpacing.p24)
    }

    @ViewBuilder
    private func shiftRow(
        for group: (day: Date, shiftID: UUID, items: [TipEntry]),
        multiShiftDays: Set<Date>
    ) -> some View {
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
    private var comparedCents: Int {
        PredictedPaycheck.tipsLineCents(from: breakdown) + breakdown.gratuityFeesCents
    }

    private var paidTipEarningsCents: Int {
        PredictedPaycheck.paidTipEarningsCents(
            tipsCents: paycheck.reconciledPaidTipsCents,
            gratuityCents: paycheck.gratuityCents
        )
    }
    private var deltaCents: Int { paidTipEarningsCents - comparedCents }
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
        if let gratuityCents = paycheck.gratuityCents {
            lines.append((label: "Gratuity", text: "Gratuity \(Money.string(fromCents: gratuityCents))"))
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
        let paid = Money.string(fromCents: paidTipEarningsCents)
        if usesCreditOnly {
            return "Logged \(logged) in card tips and gratuity · check paid \(paid)"
        }
        return "Logged \(logged) · check paid \(paid)"
    }
}
