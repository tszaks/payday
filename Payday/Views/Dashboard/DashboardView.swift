import SwiftUI
import SwiftData
import TipKit

private struct DaySelection: Identifiable {
    let date: Date
    var id: Date { date }
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
    let totalTipOutCents: Int
    let daysRemaining: Int
    let shiftCount: Int
    let shiftDays: [(day: Date, items: [TipEntry])]
    let paceDeltaCents: Int?
    let projectedTotalCents: Int?
    let isPaydayMoment: Bool
    let bestNightThisPeriod: (date: Date, cents: Int)?
    let isBestPeriodEver: Bool
    let predictedPaycheckCents: Int
    let predictedPayDate: Date
    let tonightLine: String?

    init(allEntries: [TipEntry], schedule: PaySchedule?, now: Date, forcePaydayMoment: Bool) {
        let calendar = Calendar.current
        calculator = PayPeriodCalculator(schedule: schedule ?? .fallback)
        let period = calculator.period(containing: now)
        currentPeriod = period
        let previousDay = calendar.date(byAdding: .day, value: -1, to: period.start) ?? period.start
        let priorPeriod = calculator.period(containing: previousDay)

        periodEntries = allEntries.filter { $0.date >= period.start && $0.date <= period.end }
        breakdown = TipBreakdown.total(of: periodEntries)
        daysRemaining = calculator.daysRemaining(from: now)
        shiftCount = Set(periodEntries.map { calendar.startOfDay(for: $0.date) }).count
        shiftDays = ShiftDays.groupedByDay(periodEntries, date: \.date)
        // One canonical tip-out per night (never a per-entry sum — see
        // ShiftDetails), summed across the period — the gross/net gap the
        // caption below has to explain.
        totalTipOutCents = shiftDays.reduce(0) { $0 + (ShiftDetails.resolve(from: $1.items).tipOutCents ?? 0) }

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

        isPaydayMoment = forcePaydayMoment || (daysRemaining == 0 && totalCents > 0)
        bestNightThisPeriod = statsEngine.bestNight(in: period)

        // Only claims "best period yet" when there's at least one completed
        // period in history to actually beat.
        if let earliestEntryDate = allEntries.map(\.date).min() {
            var cursor = period
            var comparedAny = false
            var isBest = true
            for _ in 0..<24 {
                guard let previousEnd = calendar.date(byAdding: .day, value: -1, to: cursor.start),
                      previousEnd >= earliestEntryDate
                else { break }
                cursor = calculator.period(containing: previousEnd)
                comparedAny = true
                if statsEngine.periodToDateTotal(period: cursor, asOf: cursor.end) >= totalCents {
                    isBest = false
                    break
                }
            }
            isBestPeriodEver = comparedAny && isBest
        } else {
            isBestPeriodEver = false
        }

        // Credit tips are what land on a stub; cash never does. Gross, like
        // PaycheckComparisonView — a stub reports gross, not net income.
        predictedPaycheckCents = breakdown.creditCents > 0 ? breakdown.creditCents : breakdown.grossTotalCents
        predictedPayDate = calculator.payDate(for: period)

        // Echo of tonight's reveal verdict, if something was logged today.
        let tonightEntries = periodEntries.filter { calendar.isDateInToday($0.date) }
        var tonightRevealText: String?
        if !tonightEntries.isEmpty {
            let cents = tonightEntries.reduce(0) { $0 + $1.netCents }
            let today = calendar.startOfDay(for: now)
            let result = statsEngine.reveal(forNightAt: today, cents: cents, period: period)
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
    @State private var daySelection: DaySelection?
    @State private var showSettings = false
    @State private var undoState = UndoDeleteToastState()
    @State private var progressTrackDrawn = false

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
        let facts = DashboardFacts(allEntries: allEntries, schedule: scheduleStore.schedule, now: .now, forcePaydayMoment: forcePaydayMoment)
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
            .sheet(item: $daySelection) { selection in
                DayDetailSheet(date: selection.date)
            }
            #if DEBUG
            .onAppear {
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
                Text("This pay period")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: facts.totalCents))
                    .font(PaydayFont.displayXXL)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(PaydayAnimation.premiumSpring, value: facts.totalCents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let paceDeltaCents = facts.paceDeltaCents {
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

            if facts.totalCents > 0 {
                Text(captionLine(for: facts))
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .monospacedDigit()
            }

            progressTrack(facts)

            if facts.isPaydayMoment {
                Divider()
                paydayMomentSection(facts)
            }
        }
        .paydayCard(padding: PaydaySpacing.p24)
    }

    /// The hero total above is net; this is gross's one-glance-away
    /// explanation whenever a tip-out actually moved the two apart — never
    /// silently letting cash+credit stop equaling the big number with no
    /// cue why.
    private func captionLine(for facts: DashboardFacts) -> String {
        let base = "Cash \(Money.string(fromCents: facts.breakdown.cashCents)) · Credit \(Money.string(fromCents: facts.breakdown.creditCents))"
        guard facts.totalTipOutCents > 0 else { return base }
        return "\(base) · Tipped out \(Money.string(fromCents: facts.totalTipOutCents))"
    }

    /// The period itself, drawn: fills as days pass, ends at payday. This
    /// carries "days left" without a number — a glance shows where you are.
    private func progressTrack(_ facts: DashboardFacts) -> some View {
        let fraction = facts.calculator.progress(through: .now, in: facts.currentPeriod)
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
            .accessibilityValue(facts.daysRemaining == 0 ? "Last day" : "\(facts.daysRemaining) days left")

            // The bar already shows how far through the period you are, so
            // "N days left" was the same fact twice — only the payday date
            // remains, labeling where the bar ends.
            HStack {
                Spacer()
                Text("Payday · \(facts.predictedPayDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
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
    }

    // MARK: Shifts

    private func shiftsSection(_ facts: DashboardFacts) -> some View {
        Section {
            ForEach(facts.shiftDays.prefix(Self.maxShiftRows), id: \.day) { group in
                shiftRow(for: group)
            }
            if facts.shiftDays.count > Self.maxShiftRows {
                Button {
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
    private func shiftRow(for group: (day: Date, items: [TipEntry])) -> some View {
        if group.items.count == 1, let entry = group.items.first {
            Button {
                sheetTarget = .edit(entry)
            } label: {
                ShiftDayRow(day: group.day, entries: group.items)
            }
            .buttonStyle(.plain)
            .listRowBackground(PaydayColor.background)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    undoState.delete(entry, in: modelContext)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .entryContextMenu(entry, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
        } else {
            // A merged night (cash + credit rows): one tap opens the day's
            // entries for editing — per-entry actions live there.
            Button {
                daySelection = DaySelection(date: group.day)
            } label: {
                ShiftDayRow(day: group.day, entries: group.items)
            }
            .buttonStyle(.plain)
            .listRowBackground(PaydayColor.background)
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

struct EntryRow: View {
    let entry: TipEntry

    private var subtitle: String {
        let calendar = Calendar.current
        let recordedSameDay = entry.recordedAt.map { calendar.isDate($0, inSameDayAs: entry.date) } ?? false

        var parts = [entry.kind.displayName]
        // Only show the clock time when the tip was recorded the same day it
        // was earned — then it reads as roughly when you worked. For backfills
        // the recorded time isn't the shift time, so we don't imply it is.
        if recordedSameDay, let recordedAt = entry.recordedAt {
            parts.append(recordedAt.formatted(date: .omitted, time: .shortened))
        }
        if entry.isDouble {
            parts.append("double")
        }
        if let note = entry.note, !note.isEmpty {
            parts.append(note)
        }
        if !recordedSameDay, let recordedAt = entry.recordedAt {
            parts.append("logged \(recordedAt.formatted(.dateTime.month(.abbreviated).day()))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                Text(subtitle)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .monospacedDigit()
            }
            Spacer()
            Text(Money.string(fromCents: entry.amountCents))
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
        }
        .padding(.vertical, 4)
    }
}
