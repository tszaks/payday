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
    let heroPayDate: Date
    let heroIsCurrent: Bool
    /// The `end` of the period the payday moment is showing, so the dismiss
    /// button can remember which one was closed.
    let paydayPeriodEnd: Date?
    let shiftCount: Int
    let shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])]
    /// Calendar days that hold 2+ shifts — a "double" — so a row can label
    /// itself "Today · Lunch" / "Today · Dinner" only when it needs to.
    let multiShiftDays: Set<Date>
    let paceDeltaCents: Int?
    let projectedTotalCents: Int?
    let isPaydayMoment: Bool
    let bestNightThisPeriod: (date: Date, cents: Int)?
    let isBestPeriodEver: Bool
    let predictedPaycheckCents: Int
    let predictedPayDate: Date
    let tonightLine: String?

    init(allEntries: [TipEntry], schedule: PaySchedule?, now: Date, forcePaydayMoment: Bool, dismissedPaydayEnd: Date?) {
        let calendar = Calendar.current
        calculator = PayPeriodCalculator(schedule: schedule ?? .fallback)
        let period = calculator.period(containing: now)
        currentPeriod = period
        let previousDay = calendar.date(byAdding: .day, value: -1, to: period.start) ?? period.start
        let priorPeriod = calculator.period(containing: previousDay)

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
        let statsEngine = StatsEngine(records: allEntries.map(TipRecord.init))
        // Net of any tip-out, same rule as every other analytical total —
        // breakdown above stays gross, purely for the cash/credit subtitle.
        totalCents = statsEngine.periodToDateTotal(period: period, asOf: now)

        // Hidden until there's real history to compare against — a
        // brand-new user's first period has no "last period" to be ahead of.
        if allEntries.contains(where: { $0.date >= priorPeriod.start && $0.date <= priorPeriod.end }) {
            paceDeltaCents = statsEngine.paceDelta(currentPeriod: period, priorPeriod: priorPeriod, asOf: now)
        } else {
            paceDeltaCents = nil
        }
        projectedTotalCents = statsEngine.projectedPeriodTotal(period: period, asOf: now, rhythm: statsEngine.workRhythm(referenceDate: now))

        // The "period complete" moment belongs to a FINISHED period whose
        // check is still pending — the day after its last shift, never a day
        // still workable (see PaydayMoment). forcePaydayMoment is the DEBUG
        // screenshot hook and pins it to the current period regardless.
        let finished: PayPeriod?
        if forcePaydayMoment {
            finished = period
        } else {
            finished = PaydayMoment.finishedPeriod(now: now, calculator: calculator, dismissedEnd: dismissedPaydayEnd)
        }
        // Nothing to celebrate if that period had no earnings.
        let paydayPeriod = finished.flatMap { statsEngine.periodToDateTotal(period: $0, asOf: $0.end) > 0 ? $0 : nil }
        isPaydayMoment = paydayPeriod != nil
        paydayPeriodEnd = paydayPeriod?.end

        if let pay = paydayPeriod {
            let payEntries = allEntries.filter { $0.date >= pay.start && $0.date <= pay.end }
            let payBreakdown = TipBreakdown.total(of: payEntries)
            let payNetCents = statsEngine.periodToDateTotal(period: pay, asOf: pay.end)
            bestNightThisPeriod = statsEngine.bestNight(in: pay)
            // Credit tips are what land on a stub; cash never does. Gross, like
            // PaycheckComparisonView — a stub reports gross, not net income.
            predictedPaycheckCents = payBreakdown.creditCents > 0 ? payBreakdown.creditCents : payBreakdown.grossTotalCents
            predictedPayDate = calculator.payDate(for: pay)

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
                heroTotalCents = payNetCents
                heroPayDate = predictedPayDate
                heroIsCurrent = false
            } else {
                heroPeriod = period
                heroLabel = "This pay period"
                heroTotalCents = totalCents
                heroPayDate = calculator.payDate(for: period)
                heroIsCurrent = true
            }
        } else {
            bestNightThisPeriod = statsEngine.bestNight(in: period)
            isBestPeriodEver = false
            predictedPaycheckCents = breakdown.creditCents > 0 ? breakdown.creditCents : breakdown.grossTotalCents
            predictedPayDate = calculator.payDate(for: period)
            heroPeriod = period
            heroLabel = "This pay period"
            heroTotalCents = totalCents
            heroPayDate = calculator.payDate(for: period)
            heroIsCurrent = true
        }

        // Echo of tonight's reveal verdict, for the most recently logged
        // shift today — consistent with the per-shift reveal shown at log
        // time, rather than summing a double day into one number.
        let todayShifts = ShiftDays.groupedByShift(
            periodEntries.filter { calendar.isDateInToday($0.date) },
            shiftID: \.shiftID, date: \.date, period: \.shiftPeriod
        )
        var tonightRevealText: String?
        if let latest = todayShifts.max(by: { shiftRecordedAt($0.items) < shiftRecordedAt($1.items) }) {
            let cents = TipBreakdown.total(of: latest.items).netTotalCents
            let today = calendar.startOfDay(for: now)
            let result = statsEngine.reveal(forNightAt: today, cents: cents, period: period, shiftID: latest.shiftID)
            tonightRevealText = "\(RevealCopy.headline(cents: cents)) \(RevealCopy.comparison(for: result.comparison))"
        }
        tonightLine = TonightLine.compose(
            rhythm: statsEngine.workRhythm(),
            tonightRevealText: tonightRevealText,
            isPaydayMoment: isPaydayMoment
        )
    }
}

struct DashboardView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(TabRouter.self) private var tabRouter
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showSettings = false
    @State private var undoState = UndoDeleteToastState()
    @State private var progressTrackDrawn = false
    /// The `end` (as a reference-date interval) of the period whose completion
    /// card the person dismissed; 0 means none. Kept so the card stays gone
    /// once closed, without reappearing on the next launch.
    @AppStorage("dismissedPaydayPeriodEnd") private var dismissedPaydayEndRaw: Double = 0

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

    private var forcePaydayMoment: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-DebugForcePaydayMoment")
        #else
        return false
        #endif
    }

    private let paydayVerificationTip = PaydayVerificationTip()

    var body: some View {
        let dismissedPaydayEnd = dismissedPaydayEndRaw == 0 ? nil : Date(timeIntervalSinceReferenceDate: dismissedPaydayEndRaw)
        let facts = DashboardFacts(allEntries: allEntries, schedule: scheduleStore.schedule, now: .now, forcePaydayMoment: forcePaydayMoment, dismissedPaydayEnd: dismissedPaydayEnd)
        NavigationStack {
            List {
                Section {
                    heroCard(facts)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: PaydaySpacing.p16, bottom: 8, trailing: PaydaySpacing.p16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let tonightLine = facts.tonightLine {
                    Section {
                        Text(tonightLine)
                            .font(PaydayFont.subheadline)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, PaydaySpacing.p24)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if facts.periodEntries.isEmpty {
                    Section {
                        emptyState
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    shiftsSection(facts)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
                }
            }
            .sheet(item: $sheetTarget) { target in
                LogTipSheet(target: target)
            }
            #if DEBUG
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
            }
            #endif
            .sheet(isPresented: $showSettings) {
                SettingsView(schedule: scheduleStore.schedule ?? .fallback)
            }
        }
        .undoDeleteToast(undoState, context: modelContext)
    }

    // MARK: Hero card

    private func heroCard(_ facts: DashboardFacts) -> some View {
        VStack(spacing: PaydaySpacing.p20) {
            VStack(spacing: 6) {
                Text(facts.heroLabel)
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: facts.heroTotalCents))
                    .font(PaydayFont.displayXXL)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(PaydayAnimation.premiumSpring, value: facts.heroTotalCents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                // Pace only makes sense for the period still in progress —
                // a finished period isn't racing anything.
                if facts.heroIsCurrent, let paceDeltaCents = facts.paceDeltaCents {
                    // The screen's one color moment: ahead is green because
                    // being ahead is the act. Behind stays quiet gray — red
                    // is reserved for a shorted paycheck, never for pace.
                    Text(RevealCopy.paceLine(deltaCents: paceDeltaCents))
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(paceDeltaCents > 0 ? PaydayColor.primary : PaydayColor.textSecondary)
                        .monospacedDigit()
                        .animation(PaydayAnimation.premiumSpring, value: paceDeltaCents > 0)
                }
                // Projection line removed: it overlapped the pace line above
                // (two framings of the same trajectory). Pace stays — it's
                // grounded in real logged history on both sides and it's the
                // screen's one green moment; projection was the softer of the
                // two. (Still computed for the widget/Insights.)
            }

            progressTrack(facts)

            if facts.isPaydayMoment {
                Divider()
                paydayMomentSection(facts)
            }
        }
        .paydayCard(padding: PaydaySpacing.p24)
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
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Period complete")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                if let bestNightThisPeriod = facts.bestNightThisPeriod {
                    Text("Best night: \(Money.string(fromCents: bestNightThisPeriod.cents)) on \(bestNightThisPeriod.date.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(PaydayFont.footnote)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .monospacedDigit()
                }
                if facts.isBestPeriodEver {
                    Text("Your best period yet")
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.primary)
                }
            }

            VStack(spacing: 4) {
                Text("Predicted paycheck")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: facts.predictedPaycheckCents))
                    .font(PaydayFont.displayLarge)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                Text("Expect it around \(facts.predictedPayDate.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            .popoverTip(paydayVerificationTip)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            // The card clears on its own after a day or two, but let the
            // person close it the moment they've seen it — it won't return
            // for this period once dismissed.
            if let end = facts.paydayPeriodEnd {
                Button {
                    withAnimation(PaydayAnimation.premiumSpring) {
                        dismissedPaydayEndRaw = end.timeIntervalSinceReferenceDate
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PaydayColor.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss period summary")
            }
        }
    }

    // MARK: Shifts

    private func shiftsSection(_ facts: DashboardFacts) -> some View {
        Section {
            ForEach(facts.shiftDays.prefix(Self.maxShiftRows), id: \.shiftID) { group in
                shiftRow(for: group, multiShiftDays: facts.multiShiftDays)
            }
            if facts.shiftDays.count > Self.maxShiftRows {
                Button {
                    // "See all" used to just switch tabs and leave the
                    // person staring at the periods LIST — the shifts they
                    // were looking at live inside the CURRENT period's
                    // detail, so land there directly.
                    tabRouter.pendingCurrentPeriodDetail = true
                    tabRouter.selected = .periods
                } label: {
                    Text("See all")
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.primary)
                }
                .buttonStyle(.plain)
                .listRowBackground(PaydayColor.background)
            }
        } header: {
            HStack {
                Text("Shifts")
                Spacer()
                Text(facts.shiftCount == 1 ? "1 this period" : "\(facts.shiftCount) this period")
                    .textCase(nil)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textTertiary)
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
        if let anchor = group.items.first {
            Button {
                sheetTarget = .edit(anchor)
            } label: {
                ShiftDayRow(day: group.day, period: period, dayHasMultipleShifts: dayHasMultiple, entries: group.items)
            }
            .buttonStyle(.plain)
            .listRowBackground(PaydayColor.background)
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

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing logged yet this period",
            systemImage: "tray",
            description: Text("Log tonight's tips and watch the total build toward payday.")
        )
        .padding(.vertical, 16)
    }
}

/// One-time education, shown the first time the payday moment appears:
/// TipKit tracks "seen" state itself, so this never repeats once dismissed.
private struct PaydayVerificationTip: Tip {
    var title: Text {
        Text("Verify your paycheck")
    }

    var message: Text? {
        Text("When your check lands, enter the tips line from your stub and Payday will check it against this.")
    }

    var image: Image? {
        Image(systemName: "checkmark.seal")
    }
}
