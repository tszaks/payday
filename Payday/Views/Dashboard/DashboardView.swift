import Combine
import SwiftUI
import SwiftData
import TipKit

/// The latest wall-clock a shift was logged, for ordering today's shifts —
/// falls back to the shift's date when no recordedAt was captured.
private func shiftRecordedAt(_ items: [TipEntry]) -> Date {
    items.compactMap(\.recordedAt).max() ?? items.map(\.date).max() ?? .distantPast
}

/// Every number the Dashboard shows, computed exactly once per render from
/// allEntries — StatsEngine construction and workRhythm() (which walks
/// every calendar day since the first entry) are real costs that used to
/// happen 4-5 times per body evaluation, once per scattered computed
/// property that each rebuilt its own StatsEngine from scratch. This
/// bundles them into one pass; the engine itself is untouched and stays
/// pure — this is a call-site fix, not an engine rewrite.
private struct DashboardFacts {
    let calculator: PayPeriodCalculator
    let currentPeriod: PayPeriod
    let periodEntries: [TipEntry]
    let breakdown: TipBreakdown
    let totalCents: Int
    let daysRemaining: Int
    /// The period the hero number represents — usually the current one, but
    /// the just-finished one on the morning after a close, while the new
    /// period is still empty, so a $0.00 hero never sits above a "complete"
    /// card.
    let heroPeriod: PayPeriod
    let heroLabel: String
    let heroTotalCents: Int
    /// Gross voluntary cash/credit tips plus employee-paid Toast gratuity for
    /// the hero period, for the one-glance split under the total. Tip-out is
    /// deliberately not shown here.
    let heroCashCents: Int
    let heroCreditCents: Int
    let heroGratuityFeesCents: Int
    let heroPayDate: Date
    let heroIsCurrent: Bool
    /// Base wage + overtime for the hero period, folded into heroTotalCents
    /// and broken back out for the drawer's reconciliation rows. nil when no
    /// rate is set — the wage feature is off.
    let heroWages: PeriodIncome.Wages?
    /// The `end` of the period the payday moment is showing, so the dismiss
    /// button can remember which one was closed.
    let paydayPeriodEnd: Date?
    /// Which of the card's two moments this is: the day or two after the period
    /// closed, or the day the check actually lands. nil when the card is not
    /// showing at all.
    let paydayPhase: PaydayMoment.Phase?
    let shiftCount: Int
    let shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])]
    /// Calendar days that hold 2+ shifts — a "double" — so a row can label
    /// itself "Today · Lunch" / "Today · Dinner" only when it needs to.
    let multiShiftDays: Set<Date>
    let paceDeltaCents: Int?
    /// How many prior periods back the pace line. 1 means it's still a
    /// single-period comparison and the copy says "last period" instead of
    /// "your usual pace."
    let pacePeriodCount: Int
    let isPaydayMoment: Bool
    let isBestPeriodEver: Bool
    /// The whole pre-tax check for the payday-moment period: the stub's tips
    /// line plus wages, in ONE number (PredictedPaycheck). Never split into
    /// "$X, plus $Y in wages" on screen — that left the person adding it up.
    let predictedPaycheckCents: Int
    let predictedPayDate: Date
    /// Cash tips in the payday-moment period — the ENTIRE gap between "You
    /// kept" and the check, since cash is the one thing that never runs through
    /// payroll. Named on the card so nobody has to subtract two big numbers to
    /// find out why their check is smaller than what they made (Tyler, on his
    /// own real period: "if i kept 3100 why would my check be 2600?? cash?").
    let paydayCashCents: Int
    let tonightLine: String?

    init(allEntries: [TipEntry], schedule: PaySchedule?, now: Date, forcedPaydayPhase: PaydayMoment.Phase?, dismissedClosedEnd: Date?, dismissedCheckEnd: Date?, wageCentsPerHour: Int?) {
        let calendar = Calendar.current
        calculator = PayPeriodCalculator(schedule: schedule ?? .fallback)
        let period = calculator.period(containing: now)
        currentPeriod = period
        periodEntries = allEntries.filter { $0.date >= period.start && $0.date <= period.end }
        breakdown = TipBreakdown.total(of: periodEntries)
        daysRemaining = calculator.daysRemaining(from: now)
        shiftDays = ShiftDays.groupedByShift(periodEntries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        // A "shift" now counts closeouts, not calendar days.
        shiftCount = shiftDays.count
        // Days that hold more than one shift — the emergent doubles.
        var dayCounts: [Date: Int] = [:]
        for shift in shiftDays { dayCounts[shift.day, default: 0] += 1 }
        multiShiftDays = Set(dayCounts.filter { $0.value >= 2 }.keys)
        let tipRecords = allEntries.map(TipRecord.init)
        let statsEngine = StatsEngine(records: tipRecords)
        // Net of any tip-out, same rule as every other analytical total —
        // breakdown above stays gross, purely for the cash/credit subtitle.
        totalCents = statsEngine.periodToDateTotal(period: period, asOf: now)

        // Measured against the MEDIAN of the last several periods at this
        // same point, not against whichever single period happened to come
        // before this one — one period is a sample size of one, and a single
        // big Saturday in it would read as a real trend. Hidden entirely
        // until some prior period has a record; a brand-new user has no
        // "usual" to be ahead of. See StatsEngine.usualPaceBaseline.
        let comparison = statsEngine.paceComparison(
            currentPeriod: period,
            priorPeriods: calculator.priorPeriods(before: period, count: StatsEngine.paceLookbackPeriods),
            asOf: now
        )
        paceDeltaCents = comparison?.deltaCents
        pacePeriodCount = comparison?.periodCount ?? 0
        // The payday card belongs to a FINISHED period, and shows twice: the
        // day or two after its last shift, then again the day the check lands
        // (see PaydayMoment). Never on a day still workable.
        // forcedPaydayPhase is the DEBUG screenshot hook and pins it to the
        // current period regardless.
        let moment: PaydayMoment.Moment?
        if let forcedPaydayPhase {
            moment = PaydayMoment.Moment(period: period, phase: forcedPaydayPhase)
        } else {
            moment = PaydayMoment.moment(now: now, calculator: calculator, dismissedClosedEnd: dismissedClosedEnd, dismissedCheckEnd: dismissedCheckEnd)
        }
        // Nothing to show if that period had no earnings.
        let paydayMoment = moment.flatMap { statsEngine.periodToDateTotal(period: $0.period, asOf: $0.period.end) > 0 ? $0 : nil }
        let paydayPeriod = paydayMoment?.period
        isPaydayMoment = paydayPeriod != nil
        paydayPeriodEnd = paydayPeriod?.end
        paydayPhase = paydayMoment?.phase

        // Tips-only net for whichever period becomes the hero — wages fold
        // in below, after heroPeriod is settled.
        let heroTipsNetCents: Int
        if let pay = paydayPeriod {
            let payEntries = allEntries.filter { $0.date >= pay.start && $0.date <= pay.end }
            let payBreakdown = TipBreakdown.total(of: payEntries)
            let payNetCents = statsEngine.periodToDateTotal(period: pay, asOf: pay.end)
            // The whole pre-tax check in one number: credit tips minus
            // tip-out (what payroll prints) plus wages. Wages come from
            // PeriodIncome — the same function the hero total uses — so the
            // check figure and the hero can never disagree about a week that
            // crossed 40 hours, which is what WageEstimate used to do here.
            let payWages = PeriodIncome.wages(entries: payEntries, wageCentsPerHour: wageCentsPerHour, firstWeekday: schedule?.firstWeekday)
            predictedPaycheckCents = PredictedPaycheck.cents(from: payBreakdown, wagesCents: payWages?.totalCents ?? 0)
            predictedPayDate = calculator.payDate(for: pay)
            paydayCashCents = payBreakdown.cashCents

            // Only claims "best period yet" when there's at least one completed
            // period in history to actually beat.
            if let earliestEntryDate = allEntries.map(\.date).min() {
                var cursor = pay
                var comparedAny = false
                var isBest = true
                for _ in 0..<24 {
                    guard let previousEnd = calendar.date(byAdding: .day, value: -1, to: cursor.start),
                          previousEnd >= earliestEntryDate
                    else { break }
                    cursor = calculator.period(containing: previousEnd)
                    comparedAny = true
                    if statsEngine.periodToDateTotal(period: cursor, asOf: cursor.end) >= payNetCents {
                        isBest = false
                        break
                    }
                }
                isBestPeriodEver = comparedAny && isBest
            } else {
                isBestPeriodEver = false
            }

            // On the morning after a close the new period is still empty; lead
            // with the period that just finished so a $0.00 hero never sits
            // above its own "complete" card. Once the new period has earnings,
            // the hero follows it and the completed card rides along below.
            if totalCents == 0 && pay != period {
                heroPeriod = pay
                heroLabel = "Last pay period"
                heroTipsNetCents = payNetCents
                heroCashCents = payBreakdown.cashCents
                heroCreditCents = payBreakdown.creditCents
                heroGratuityFeesCents = payBreakdown.gratuityFeesCents
                heroPayDate = predictedPayDate
                heroIsCurrent = false
            } else {
                heroPeriod = period
                heroLabel = "This pay period"
                heroTipsNetCents = totalCents
                heroCashCents = breakdown.cashCents
                heroCreditCents = breakdown.creditCents
                heroGratuityFeesCents = breakdown.gratuityFeesCents
                heroPayDate = calculator.payDate(for: period)
                heroIsCurrent = true
            }
        } else {
            isBestPeriodEver = false
            let currentWages = PeriodIncome.wages(entries: periodEntries, wageCentsPerHour: wageCentsPerHour, firstWeekday: schedule?.firstWeekday)
            predictedPaycheckCents = PredictedPaycheck.cents(from: breakdown, wagesCents: currentWages?.totalCents ?? 0)
            predictedPayDate = calculator.payDate(for: period)
            paydayCashCents = breakdown.cashCents
            heroPeriod = period
            heroLabel = "This pay period"
            heroTipsNetCents = totalCents
            heroCashCents = breakdown.cashCents
            heroCreditCents = breakdown.creditCents
            heroGratuityFeesCents = breakdown.gratuityFeesCents
            heroPayDate = calculator.payDate(for: period)
            heroIsCurrent = true
        }

        // Wages fold into the hero total (and get broken back out for the
        // drawer) but never touch totalCents/breakdown/statsEngine above.
        // totalCents already includes employee gratuity because it is earned
        // compensation; tip-specific analytics use StatsEngine's gross tips.
        // heroPeriod's bounds are captured into locals first — referencing a
        // stored property from inside a closure here, before every stored
        // property is initialized, is a definite-initialization error.
        let heroPeriodStart = heroPeriod.start
        let heroPeriodEnd = heroPeriod.end
        let heroEntries = allEntries.filter { $0.date >= heroPeriodStart && $0.date <= heroPeriodEnd }
        heroWages = PeriodIncome.wages(entries: heroEntries, wageCentsPerHour: wageCentsPerHour, firstWeekday: schedule?.firstWeekday)
        heroTotalCents = heroTipsNetCents + (heroWages?.totalCents ?? 0)

        // Echo of tonight's reveal verdict, for the most recently logged
        // shift today — consistent with the per-shift reveal shown at log
        // time, rather than summing a double day into one number.
        let todayShifts = ShiftDays.groupedByShift(
            periodEntries.filter { calendar.isDateInToday($0.date) },
            shiftID: \.shiftID, date: \.date, period: \.shiftPeriod
        )
        var tonightRevealText: String?
        if let latest = todayShifts.max(by: { shiftRecordedAt($0.items) < shiftRecordedAt($1.items) }) {
            let netCents = TipBreakdown.total(of: latest.items).netTotalCents
            let today = calendar.startOfDay(for: now)
            let details = ShiftDetails.resolve(from: latest.items)
            // The same wage math the shift's own row uses — the echo and
            // the row must reconcile on sight. A shift speaks ONE number
            // (Tyler's ruling, 2026-07-27): the reveal pipeline moves to
            // that same wage-inclusive basis via its own StatsEngine. The
            // main engine remains wage-exclusive; its earnings totals already
            // include any employee gratuity captured for the shift.
            let shiftWageCents = details.hoursWorked.flatMap { WageEstimate.cents(wageCentsPerHour: wageCentsPerHour, hours: $0) }
            let revealCents = netCents + (shiftWageCents ?? 0)
            let revealEngine = StatsEngine(records: tipRecords, wageCentsPerHour: wageCentsPerHour)
            let result = revealEngine.reveal(forNightAt: today, cents: revealCents, period: period, shiftID: latest.shiftID)
            tonightRevealText = "\(RevealCopy.headline(cents: revealCents, includesNonTipIncome: shiftWageCents != nil || TipBreakdown.total(of: latest.items).gratuityFeesCents > 0)) \(RevealCopy.comparison(for: result.comparison, period: details.shiftPeriod))"
        }
        tonightLine = TonightLine.compose(
            tonightRevealText: tonightRevealText,
            isPaydayMoment: isPaydayMoment
        )
    }
}

private struct DashboardFactsKey: Hashable {
    let entriesRevision: Int
    let frequency: PayFrequency?
    let anchorPeriodEnd: Date?
    let payDelayDays: Int?
    let firstWeekday: Int?
    let day: Date
    let forcedPhase: String?
    let dismissedClosedEndRaw: Double
    let dismissedCheckEndRaw: Double
    let wageCentsPerHour: Int?
}

private struct DashboardFactsCache {
    let key: DashboardFactsKey
    let facts: DashboardFacts
}

struct DashboardView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(TabRouter.self) private var tabRouter
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showSettings = false
    @State private var undoState = UndoDeleteToastState()
    @State private var progressTrackDrawn = false
    /// Observed, not mirrored into local state: a quick action or Control
    /// Center intent can start a session while this view is already on
    /// screen and foregrounded, which no scenePhase change would announce.
    private var shiftSession = ShiftSessionState.shared
    /// Whether the cash/credit breakdown drawer tucked under the hero is open.
    @State private var breakdownExpanded = false
    @State private var factsCache: DashboardFactsCache?
    @State private var dataRevision = 0
    /// The `end` (as a reference-date interval) of the period whose completion
    /// card the person dismissed; 0 means none. Kept so the card stays gone
    /// once closed, without reappearing on the next launch.
    @AppStorage("dismissedPaydayPeriodEnd") private var dismissedClosedEndRaw: Double = 0
    /// The same, for the PAYDAY appearance of that card. Separate on purpose:
    /// closing the "period complete" summary on Monday says nothing about
    /// whether you want the check-verification prompt on Friday.
    @AppStorage("dismissedCheckDayPeriodEnd") private var dismissedCheckEndRaw: Double = 0

    private static let maxShiftRows = 5

    private var greeting: String {
        let timeOfDay = switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        guard let firstName = preferencesStore.firstName, !firstName.isEmpty else { return timeOfDay }
        return "\(timeOfDay), \(firstName)"
    }

    /// Screenshot/QA hook: pins the payday card to the current period in one of
    /// its two moments, so both can be inspected without waiting for a real
    /// payroll calendar. `-DebugForcePaydayMoment` is the close summary,
    /// `-DebugForceCheckDay` the payday appearance.
    private var forcedPaydayPhase: PaydayMoment.Phase? {
        #if DEBUG || targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-DebugForceCheckDay") { return .checkDay }
        if arguments.contains("-DebugForcePaydayMoment") { return .periodClosed }
        return nil
        #else
        return nil
        #endif
    }

    private let paydayVerificationTip = PaydayVerificationTip()

    var body: some View {
        let now = Date.now
        let dismissedClosedEnd = dismissedClosedEndRaw == 0 ? nil : Date(timeIntervalSinceReferenceDate: dismissedClosedEndRaw)
        let dismissedCheckEnd = dismissedCheckEndRaw == 0 ? nil : Date(timeIntervalSinceReferenceDate: dismissedCheckEndRaw)
        let key = DashboardFactsKey(
            entriesRevision: dataRevision,
            frequency: scheduleStore.schedule?.frequency,
            anchorPeriodEnd: scheduleStore.schedule?.anchorPeriodEnd,
            payDelayDays: scheduleStore.schedule?.payDelayDays,
            firstWeekday: scheduleStore.schedule?.firstWeekday,
            day: Calendar.current.startOfDay(for: now),
            forcedPhase: forcedPaydayPhase?.rawValue,
            dismissedClosedEndRaw: dismissedClosedEndRaw,
            dismissedCheckEndRaw: dismissedCheckEndRaw,
            wageCentsPerHour: preferencesStore.baseHourlyWageCents
        )
        let facts = factsCache?.key == key
            ? factsCache!.facts
            : DashboardFacts(
                allEntries: allEntries,
                schedule: scheduleStore.schedule,
                now: now,
                forcedPaydayPhase: forcedPaydayPhase,
                dismissedClosedEnd: dismissedClosedEnd,
                dismissedCheckEnd: dismissedCheckEnd,
                wageCentsPerHour: preferencesStore.baseHourlyWageCents
            )
        NavigationStack {
            // A ScrollView, deliberately NOT a List: the hero's drawer changes
            // height when it opens, and a List (UIKit-backed) animates the row
            // resize on its own clock while the drawer's spring runs on
            // another — everything below visibly stutters. Pure SwiftUI layout
            // keeps the whole column on one animation, which is exactly how
            // Vero's budget drawer stays smooth.
            ScrollView {
                VStack(spacing: PaydaySpacing.p8) {
                    heroWithDrawer(facts)
                        .padding(.horizontal, PaydaySpacing.p16)
                        .padding(.top, 8)

                    tonightLineRow(facts)

                    if facts.periodEntries.isEmpty {
                        emptyState(facts)
                    } else {
                        shiftsSection(facts)
                            .padding(.horizontal, PaydaySpacing.p16)
                    }
                }
            }
            .background(PaydayColor.background)
            .contentMargins(.bottom, 88, for: .scrollContent) // clear the floating + button
            .navigationTitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(item: $sheetTarget) { target in
                LogTipSheet(target: target).paydayAppearance()
            }
            #if DEBUG || targetEnvironment(simulator)
            .onAppear {
                // Screenshot/QA hook only — opens the most recent period
                // entry, no kind argument. Named distinctly from
                // MainTabView's "-OpenEditSheetKind <kind>" hook so passing
                // one can never accidentally also satisfy the other and
                // double-present a sheet.
                if ProcessInfo.processInfo.arguments.contains("-OpenEditSheet"), let first = facts.periodEntries.first {
                    sheetTarget = .edit(first)
                }
                if ProcessInfo.processInfo.arguments.contains("-OpenSettings") {
                    showSettings = true
                }
                if ProcessInfo.processInfo.arguments.contains("-DebugExpandBreakdown") {
                    breakdownExpanded = true
                }
                // Screenshot-only: opens the drawer in slow motion so a
                // frame-capture pass can inspect mid-animation layout for
                // jumps — a real tap animates too fast to catch over simctl.
                if ProcessInfo.processInfo.arguments.contains("-DebugDrawerSlowMotion") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.linear(duration: 4)) {
                            breakdownExpanded = true
                        }
                    }
                }
            }
            #endif
            .sheet(isPresented: $showSettings) {
                SettingsView(schedule: scheduleStore.schedule ?? .fallback).paydayAppearance()
            }
        }
        .undoDeleteToast(undoState, context: modelContext)
        .onAppear { shiftSession.sync() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            shiftSession.sync()
        }
        .task(id: key) {
            factsCache = DashboardFactsCache(key: key, facts: facts)
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            dataRevision &+= 1
        }
    }

    // MARK: Tonight line

    /// The historical "you usually work Fridays" line — hero card's own
    /// footer band (shiftBand) owns the live-shift slot now, so this only
    /// ever renders while no session is active.
    @ViewBuilder
    private func tonightLineRow(_ facts: DashboardFacts) -> some View {
        if shiftSession.activeStart == nil, let tonightLine = facts.tonightLine {
            Text(tonightLine)
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.horizontal, PaydaySpacing.p24)
                .padding(.vertical, PaydaySpacing.p4)
        }
    }

    // MARK: Hero card + breakdown drawer

    /// The hero card with a cash/credit drawer tucked behind it, via the
    /// shared HeroBreakdownDrawer (same peek + slide treatment as Vero's
    /// coverage drawer, now also used by PeriodDetailView's hero). The
    /// drawer's collapsed lip shows the earnings split at rest; tapping the
    /// hero slides it open to the full reconciliation (cash tips + credit
    /// tips + employee gratuity − tip-out = take-home), which is where the
    /// tip-out lives now instead of cluttering the card face.
    private func heroWithDrawer(_ facts: DashboardFacts) -> some View {
        let hasBreakdown = facts.heroCashCents > 0 || facts.heroCreditCents > 0 || facts.heroGratuityFeesCents > 0
        // The figure that makes the split reconcile to Total, derived so it
        // always adds up regardless of how tip-out was logged across a
        // shift. Wages sit outside cash/credit/gratuity entirely, so tip-out
        // is measured against non-wage earnings, not the combined Total.
        let wagesTotalCents = facts.heroWages?.totalCents ?? 0
        let nonWageNetCents = facts.heroTotalCents - wagesTotalCents
        let tipOutCents = max(0, facts.heroCashCents + facts.heroCreditCents + facts.heroGratuityFeesCents - nonWageNetCents)
        // Everything that ADDS, then the subtotal, then everything that
        // SUBTRACTS, then what's left. The old order ran cash, credit, tipped
        // out, wages, overtime — plus, plus, minus, plus, plus — so the eye had
        // to track a sign that flipped twice on the way down a five-row column.
        var rows: [BreakdownRow] = [
            BreakdownRow("Cash tips", cents: facts.heroCashCents),
            BreakdownRow("Credit tips", cents: facts.heroCreditCents),
        ]
        if facts.heroGratuityFeesCents > 0 {
            rows.append(BreakdownRow("Gratuity & fees", cents: facts.heroGratuityFeesCents))
        }
        if let wages = facts.heroWages {
            // Regular hours only — `wages.hours` is the TOTAL, so labeling this
            // row with it claims the base-rate line covers hours that are
            // actually priced at 1.5x on the Overtime row below it. Identical
            // when there's no overtime.
            rows.append(BreakdownRow("Wages · \(WageEstimate.hoursLabel(wages.hours - wages.overtimeHours))", cents: wages.regularCents))
            if wages.overtimeCents > 0 {
                rows.append(BreakdownRow("Overtime · \(WageEstimate.hoursLabel(wages.overtimeHours))", cents: wages.overtimeCents))
            }
        }
        // The subtotal only earns its rule when something is subtracted below
        // it; with no tip-out logged, "Earned" and "You kept" would be the same
        // number printed twice.
        if tipOutCents > 0 {
            rows.append(BreakdownRow("Earned", cents: facts.heroCashCents + facts.heroCreditCents + facts.heroGratuityFeesCents + wagesTotalCents, dividerAbove: true))
            rows.append(BreakdownRow("Tipped out", cents: -tipOutCents))
        }

        return HeroBreakdownDrawer(
            // The lip has to reconcile to the number directly above it. It used
            // to show gross cash + credit, which sum to MORE than the hero
            // (tip-out is already out of the hero, wages are already in), so
            // the closed card presented two figures that could not be squared.
            lipText: tipOutCents > 0
                ? "Earned \(Money.string(fromCents: facts.heroCashCents + facts.heroCreditCents + facts.heroGratuityFeesCents + wagesTotalCents)) · Tipped out \(Money.string(fromCents: tipOutCents))"
                : facts.heroGratuityFeesCents > 0
                    ? "Tips \(Money.string(fromCents: facts.heroCashCents + facts.heroCreditCents)) · Gratuity \(Money.string(fromCents: facts.heroGratuityFeesCents))"
                    : "Cash \(Money.string(fromCents: facts.heroCashCents)) · Credit \(Money.string(fromCents: facts.heroCreditCents))",
            rows: rows,
            total: BreakdownRow(tipOutCents > 0 ? "You kept" : "Total", cents: facts.heroTotalCents, emphasized: true),
            hasBreakdown: hasBreakdown,
            isExpanded: $breakdownExpanded
        ) {
            heroCard(facts)
        }
    }

    /// Shared by the hero's tap gesture (inside HeroBreakdownDrawer) and its
    /// VoiceOver accessibility action (heroSummary below) so both paths
    /// toggle identically.
    private func toggleBreakdown() {
        HeroBreakdownToggle.fire($breakdownExpanded, reduceMotion: reduceMotion)
    }

    // MARK: Hero card

    private func heroCard(_ facts: DashboardFacts) -> some View {
        VStack(spacing: PaydaySpacing.p20) {
            heroSummary(facts)

            if facts.isPaydayMoment {
                Divider()
                paydayMomentSection(facts)
            }

            Divider()
            shiftBand
        }
        .paydayCard(padding: PaydaySpacing.p24)
    }

    /// The hero card's own footer band — this is where a shift lives or
    /// dies now, not a separate row below the card (Tyler's call: Start
    /// Shift felt tacked on before). Idle offers Start Shift; live shows the
    /// running timer and hands off to End Shift, which does nothing but
    /// open the same log sheet every other creation path uses — the
    /// session itself only ends once that sheet is SAVED (see
    /// LiveShiftEndModeResolver), so cancelling leaves the shift running
    /// exactly as it was before the tap.
    @ViewBuilder
    private var shiftBand: some View {
        Group {
            if let activeStart = shiftSession.activeStart {
                HStack(spacing: PaydaySpacing.p8) {
                    HStack(spacing: PaydaySpacing.p8) {
                        LiveShiftDot()
                        Text("On shift · ")
                            .foregroundStyle(PaydayColor.textSecondary)
                            .font(PaydayFont.subheadline)
                        LiveShiftClock(startedAt: activeStart)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(onShiftAccessibilityLabel(activeStart))

                    Spacer(minLength: PaydaySpacing.p8)

                    Button("End Shift") {
                        sheetTarget = .new(defaultDate: .now)
                    }
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.primary)
                    .buttonStyle(PressableButtonStyle())
                }
                // The live row arrives with real presence — leading-edge
                // slide + slight scale, the app's own spring — and leaves
                // fast (exits are always quicker than entrances). Never
                // from nothing: opacity + 0.97, not scale-from-zero.
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: -8)).combined(with: .scale(scale: 0.97, anchor: .leading)),
                    removal: .opacity
                ))
            } else {
                Button("Start Shift") {
                    PaydayHaptics.lightTap()
                    ShiftSessionManager.start()
                }
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.primary)
                .buttonStyle(PressableButtonStyle())
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : PaydayAnimation.drawerSpring, value: shiftSession.activeStart != nil)
    }

    /// "On shift, 47 minutes" — a spoken fact, not the literal ticking
    /// digits the clock renders visually.
    private func onShiftAccessibilityLabel(_ start: Date) -> String {
        let minutes = max(0, Int(Date.now.timeIntervalSince(start) / 60))
        return "On shift, \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// The always-tappable part of the hero: label, amount, pace line, and
    /// the period progress bar. Combined into one VoiceOver element carrying
    /// a button trait and the toggle action — the tap gesture that expands
    /// the breakdown drawer lives on the outer heroCard container, which
    /// (being several separately-readable Texts) has no single element for
    /// VoiceOver to activate otherwise. The payday moment section stays
    /// outside this combined region so its own Dismiss button and TipKit
    /// popover keep their individual accessibility.
    private func heroSummary(_ facts: DashboardFacts) -> some View {
        let hasBreakdown = facts.heroCashCents > 0 || facts.heroCreditCents > 0 || facts.heroGratuityFeesCents > 0
        return VStack(spacing: PaydaySpacing.p20) {
            VStack(spacing: 6) {
                Text(facts.heroLabel)
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: facts.heroTotalCents))
                    .font(PaydayFont.displayXXL)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: facts.heroTotalCents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                // Pace only makes sense for the period still in progress —
                // a finished period isn't racing anything.
                if facts.heroIsCurrent, let paceDeltaCents = facts.paceDeltaCents {
                    // The screen's one color moment: ahead is green because
                    // being ahead is the act. Behind stays quiet gray — red
                    // is reserved for a shorted paycheck, never for pace.
                    Text(RevealCopy.paceLine(deltaCents: paceDeltaCents, periodCount: facts.pacePeriodCount))
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(paceDeltaCents > 0 ? PaydayColor.primary : PaydayColor.textSecondary)
                        .monospacedDigit()
                        .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: paceDeltaCents > 0)
                }
                // Projection line removed: it overlapped the pace line above
                // (two framings of the same trajectory). Pace stays — it's
                // grounded in real logged history on both sides and it's the
                // screen's one green moment; projection was the softer of the
                // two. (Still computed for the widget/Insights.)
            }

            progressTrack(facts)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(hasBreakdown ? .isButton : [])
        .accessibilityHint(hasBreakdown ? (breakdownExpanded ? "Hide breakdown" : "Show breakdown") : "")
        .accessibilityAction {
            guard hasBreakdown else { return }
            toggleBreakdown()
        }
    }

    private func progressAccessibilityValue(_ facts: DashboardFacts) -> String {
        guard facts.heroIsCurrent else { return "Period complete" }
        return facts.daysRemaining == 0 ? "Last day" : "\(facts.daysRemaining) days left"
    }

    /// The period itself, drawn: fills as days pass, ends at payday. This
    /// carries "days left" without a number — a glance shows where you are.
    private func progressTrack(_ facts: DashboardFacts) -> some View {
        let fraction = facts.calculator.progress(through: .now, in: facts.heroPeriod)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PaydayColor.primary.opacity(0.15))
                    Capsule()
                        .fill(PaydayColor.primary)
                        .frame(width: geo.size.width * (progressTrackDrawn ? fraction : 0))
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Pay period progress")
            .accessibilityValue(progressAccessibilityValue(facts))

            // The bar already shows how far through the period you are, so
            // "N days left" was the same fact twice — only the payday date
            // remains, labeling where the bar ends.
            HStack {
                Spacer()
                Text("Payday · \(facts.heroPayDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .onAppear {
            guard !progressTrackDrawn else { return }
            if reduceMotion {
                progressTrackDrawn = true
            } else {
                withAnimation(PaydayAnimation.premiumSpring.delay(0.15)) {
                    progressTrackDrawn = true
                }
            }
        }
    }

    private func paydayMomentSection(_ facts: DashboardFacts) -> some View {
        let isCheckDay = facts.paydayPhase == .checkDay
        return VStack(spacing: 16) {
            // No header on payday: a green "Payday" here collided with the
            // progress bar's own "Payday · Thu, Aug 13" a few lines above,
            // which labels the CURRENT period's payday — two different dates
            // under one word reads as "payday is Aug 13" on the very day the
            // money arrives. "Today" moves into the caption below instead, where
            // it belongs, and the card keeps one line rather than two.
            //
            // Otherwise the header names the state the card is reporting, and
            // then only when the hero above isn't already saying it — once the
            // hero reads "Last pay period" over a full progress bar, "the period
            // ended" is on screen twice and this made it three times (Tyler,
            // 2026-08-03: say it once).
            //
            // Best day is gone entirely — nobody opens the app for it, and it
            // was the one figure on this card measured tips-only, so it never
            // matched the wage-inclusive shift rows below it anyway.
            VStack(spacing: 4) {
                Text(isCheckDay ? "Today's check should show" : "Your check should show")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: facts.predictedPaycheckCents))
                    .font(PaydayFont.displayLarge)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                // The arithmetic, stated out loud. This number used to be
                // gross credit tips with the tip-out silently left in and the
                // wages added back in a second sentence, which is exactly how
                // a card ends up with two totals nobody can reconcile. The
                // payday date is NOT repeated here — the progress bar above
                // already labels where the period ends.
                Text("Card tips + gratuity + wages − tip-out · before tax")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .multilineTextAlignment(.center)
                // Closes the last gap on this card. The hero says what you kept
                // and this says what the check carries, and the difference
                // between them is ALWAYS exactly the cash — the only money that
                // never runs through payroll. Without this line the reader has
                // to subtract two four-figure numbers to learn that, and Tyler
                // did exactly that on his own real period before asking "cash?".
                // Not a repeat under rule 11: it does arithmetic for the reader
                // rather than restating something already on screen.
                if facts.paydayCashCents > 0 {
                    Text("Cash already paid · \(Money.string(fromCents: facts.paydayCashCents))")
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .popoverTip(paydayVerificationTip)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            // The card clears on its own, but let the person close it the moment
            // they've seen it. Each of the two moments is dismissed on its own
            // key, so closing the period summary does not also cancel the
            // check-verification prompt days later.
            if let end = facts.paydayPeriodEnd {
                Button {
                    let dismiss = {
                        if isCheckDay {
                            dismissedCheckEndRaw = end.timeIntervalSinceReferenceDate
                        } else {
                            dismissedClosedEndRaw = end.timeIntervalSinceReferenceDate
                        }
                    }
                    if reduceMotion {
                        dismiss()
                    } else {
                        withAnimation(PaydayAnimation.premiumSpring) { dismiss() }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PaydayColor.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCheckDay ? "Dismiss payday card" : "Dismiss period summary")
            }
        }
    }

    // MARK: Shifts

    private func shiftsSection(_ facts: DashboardFacts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Shifts")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Spacer()
                Text(facts.shiftCount == 1 ? "1 this period" : "\(facts.shiftCount) this period")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            .padding(.top, PaydaySpacing.p16)
            .padding(.bottom, PaydaySpacing.p8)

            ForEach(Array(facts.shiftDays.prefix(Self.maxShiftRows).enumerated()), id: \.element.shiftID) { index, group in
                if index > 0 { Divider() }
                shiftRow(for: group, multiShiftDays: facts.multiShiftDays)
            }
            if facts.shiftDays.count > Self.maxShiftRows {
                Divider()
                Button {
                    // "See all" used to just switch tabs and leave the
                    // person staring at the periods LIST — the shifts they
                    // were looking at live inside the CURRENT period's
                    // detail, so land there directly.
                    tabRouter.pendingCurrentPeriodDetail = true
                    HistoryLens.periods.select()
                    tabRouter.selected = .history
                } label: {
                    Text("See all")
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.primary)
                        .padding(.vertical, PaydaySpacing.p12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func shiftRow(for group: (day: Date, shiftID: UUID, items: [TipEntry]), multiShiftDays: Set<Date>) -> some View {
        let period = ShiftDetails.resolve(from: group.items).shiftPeriod
        let dayHasMultiple = multiShiftDays.contains(group.day)
        // A shift, single-entry or merged cash+credit, is one row now — the
        // edit sheet is shaped like a shift regardless of how many TipEntry
        // rows it took to log it, so there's no separate "open this shift's
        // entries" destination anymore.
        // Swipe-to-delete went with the List conversion (swipeActions is
        // List-only); delete stays one long-press away via the context menu,
        // with the same undo toast, and PeriodDetailView still swipes.
        if let anchor = group.items.first {
            Button {
                sheetTarget = .edit(anchor)
            } label: {
                ShiftDayRow(day: group.day, period: period, dayHasMultipleShifts: dayHasMultiple, entries: group.items, wageCentsPerHour: preferencesStore.baseHourlyWageCents)
                    .padding(.vertical, PaydaySpacing.p12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shiftContextMenu(group.items, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
        }
    }

    /// Deliberately NOT ContentUnavailableView any more: its intrinsic height
    /// wants most of a screen, so inside this ScrollView it sat down behind the
    /// floating glass tab bar, which refracted the text into an unreadable
    /// double image. Its description line ("Log your tips and watch the total
    /// build toward payday") also only restated the title.
    ///
    /// The wording follows the hero: when the hero reads "Last pay period", the
    /// empty list belongs to the NEW period, and "Nothing logged yet this
    /// period" directly under a completed period's total reads like a
    /// contradiction rather than a new start.
    private func emptyState(_ facts: DashboardFacts) -> some View {
        Text("No shifts this period.")
            .font(PaydayFont.subheadline)
            .foregroundStyle(PaydayColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, PaydaySpacing.p24)
    }
}

/// One-time education, shown the first time the payday moment appears:
/// TipKit tracks "seen" state itself, so this never repeats once dismissed.
private struct PaydayVerificationTip: Tip {
    var title: Text {
        Text("Verify your paycheck")
    }

    var message: Text? {
        Text("Compare this with the tips line on your stub.")
    }

    var image: Image? {
        Image(systemName: "checkmark.seal")
    }
}


/// The live band's recording light: a quiet breathing pulse (opacity only,
/// never size) says "this is recording right now" the way a REC dot does —
/// the one piece of ongoing motion the band earns while a shift runs.
/// Static under Reduce Motion.
private struct LiveShiftDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(PaydayColor.primary)
            .frame(width: 8, height: 8)
            .opacity(dimmed ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// The elapsed clock, digit-rolling: Text(timerInterval:) self-updates
/// outside SwiftUI's animation system, so its digits SWAP every second.
/// Driving the same string from a per-second TimelineView lets
/// contentTransition(.numericText) roll each changing digit instead —
/// the system's own timer language (Dynamic Island, Clock). Plain swaps
/// under Reduce Motion.
private struct LiveShiftClock: View {
    let startedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let label = ElapsedClock.string(from: startedAt, to: context.date)
            Text(label)
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textPrimary)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: false))
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: label)
        }
    }
}
