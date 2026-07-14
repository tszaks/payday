import SwiftUI
import SwiftData
import TipKit

private struct DaySelection: Identifiable {
    let date: Date
    var id: Date { date }
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

    private var calculator: PayPeriodCalculator {
        // Fallback keeps a transient render safe if the schedule is cleared
        // while this view is still mounted; RootView swaps to setup next tick.
        PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
    }

    private var currentPeriod: PayPeriod {
        calculator.period(containing: .now)
    }

    private var periodEntries: [TipEntry] {
        allEntries.filter { $0.date >= currentPeriod.start && $0.date <= currentPeriod.end }
    }

    private var breakdown: TipBreakdown {
        TipBreakdown.total(of: periodEntries)
    }

    private var totalCents: Int {
        breakdown.totalCents
    }

    private var daysRemaining: Int {
        calculator.daysRemaining(from: .now)
    }

    /// A shift is a day worked, not a row: logging one night writes up to
    /// two entries (cash + credit), so count distinct days, not entries.
    private var shiftCount: Int {
        Set(periodEntries.map { Calendar.current.startOfDay(for: $0.date) }).count
    }

    private var shiftDays: [(day: Date, items: [TipEntry])] {
        ShiftDays.groupedByDay(periodEntries, date: \.date)
    }

    private var priorPeriod: PayPeriod {
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: currentPeriod.start) ?? currentPeriod.start
        return calculator.period(containing: previousDay)
    }

    /// Hidden until there's real history to compare against — a brand-new
    /// user's first period has no "last period" worth being ahead of.
    private var paceDeltaCents: Int? {
        guard allEntries.contains(where: { $0.date >= priorPeriod.start && $0.date <= priorPeriod.end }) else { return nil }
        return statsEngine.paceDelta(currentPeriod: currentPeriod, priorPeriod: priorPeriod, asOf: .now)
    }

    private var statsEngine: StatsEngine {
        StatsEngine(records: allEntries.map(TipRecord.init))
    }

    /// The app is named after this moment: the last day of a pay period,
    /// when there's a verdict to deliver and a paycheck to predict.
    private var isPaydayMoment: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DebugForcePaydayMoment") { return true }
        #endif
        return daysRemaining == 0 && totalCents > 0
    }

    private var bestNightThisPeriod: (date: Date, cents: Int)? {
        statsEngine.bestNight(in: currentPeriod)
    }

    /// Only claims "best period yet" when there's at least one completed
    /// period in history to actually beat.
    private var isBestPeriodEver: Bool {
        guard let earliestEntryDate = allEntries.map(\.date).min() else { return false }
        var cursor = currentPeriod
        var comparedAny = false
        for _ in 0..<24 {
            guard let previousEnd = Calendar.current.date(byAdding: .day, value: -1, to: cursor.start),
                  previousEnd >= earliestEntryDate
            else { break }
            cursor = calculator.period(containing: previousEnd)
            comparedAny = true
            if statsEngine.periodToDateTotal(period: cursor, asOf: cursor.end) >= totalCents {
                return false
            }
        }
        return comparedAny
    }

    /// Credit tips are what land on a stub; cash never does. Same fallback
    /// PaycheckComparisonView uses for legacy all-cash periods.
    private var predictedPaycheckCents: Int {
        breakdown.creditCents > 0 ? breakdown.creditCents : totalCents
    }

    private var predictedPayDate: Date {
        calculator.payDate(for: currentPeriod)
    }

    /// Echo of tonight's reveal verdict, if something was logged today —
    /// "$118.00 tonight. $34.00 above your Friday average."
    private var tonightRevealText: String? {
        let calendar = Calendar.current
        let tonightEntries = periodEntries.filter { calendar.isDateInToday($0.date) }
        guard !tonightEntries.isEmpty else { return nil }
        let cents = tonightEntries.reduce(0) { $0 + $1.amountCents }
        let today = calendar.startOfDay(for: .now)
        let result = statsEngine.reveal(forNightAt: today, cents: cents, period: currentPeriod)
        return "\(RevealCopy.headline(cents: cents)) \(RevealCopy.comparison(for: result.comparison))"
    }

    private var tonightLine: String? {
        TonightLine.compose(
            rhythm: statsEngine.workRhythm(),
            tonightRevealText: tonightRevealText,
            isPaydayMoment: isPaydayMoment
        )
    }

    private let paydayVerificationTip = PaydayVerificationTip()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    heroCard
                }
                .listRowInsets(EdgeInsets(top: 8, leading: PaydaySpacing.p16, bottom: 8, trailing: PaydaySpacing.p16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let tonightLine {
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

                if periodEntries.isEmpty {
                    Section {
                        emptyState
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    shiftsSection
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
                if ProcessInfo.processInfo.arguments.contains("-OpenEditSheet"), let first = periodEntries.first {
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

    private var heroCard: some View {
        VStack(spacing: PaydaySpacing.p20) {
            VStack(spacing: 6) {
                Text("This pay period")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: totalCents))
                    .font(PaydayFont.displayXXL)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(PaydayAnimation.premiumSpring, value: totalCents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let paceDeltaCents {
                    // The screen's one color moment: ahead is green because
                    // being ahead is the act. Behind stays quiet gray — red
                    // is reserved for a shorted paycheck, never for pace.
                    Text(RevealCopy.paceLine(deltaCents: paceDeltaCents))
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(paceDeltaCents > 0 ? PaydayColor.primary : PaydayColor.textSecondary)
                        .monospacedDigit()
                        .animation(PaydayAnimation.premiumSpring, value: paceDeltaCents > 0)
                }
            }

            if totalCents > 0 {
                Text("Cash \(Money.string(fromCents: breakdown.cashCents)) · Credit \(Money.string(fromCents: breakdown.creditCents))")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .monospacedDigit()
            }

            progressTrack

            if isPaydayMoment {
                Divider()
                paydayMomentSection
            }
        }
        .paydayCard(padding: PaydaySpacing.p24)
    }

    /// The period itself, drawn: fills as days pass, ends at payday. This
    /// carries "days left" without a number — a glance shows where you are.
    private var progressTrack: some View {
        let fraction = calculator.progress(through: .now, in: currentPeriod)
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
            .accessibilityValue(daysRemaining == 0 ? "Last day" : "\(daysRemaining) days left")

            HStack {
                if daysRemaining > 0 {
                    Text(daysRemaining == 1 ? "1 day left" : "\(daysRemaining) days left")
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textTertiary)
                }
                Spacer()
                Text("Payday · \(predictedPayDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
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

    private var paydayMomentSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Period complete")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                if let bestNightThisPeriod {
                    Text("Best night: \(Money.string(fromCents: bestNightThisPeriod.cents)) on \(bestNightThisPeriod.date.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(PaydayFont.footnote)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .monospacedDigit()
                }
                if isBestPeriodEver {
                    Text("Your best period yet")
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.primary)
                }
            }

            VStack(spacing: 4) {
                Text("Predicted paycheck")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: predictedPaycheckCents))
                    .font(PaydayFont.displayLarge)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                Text("Expect it around \(predictedPayDate.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            .popoverTip(paydayVerificationTip)
        }
    }

    // MARK: Shifts

    private var shiftsSection: some View {
        Section {
            ForEach(shiftDays.prefix(Self.maxShiftRows), id: \.day) { group in
                shiftRow(for: group)
            }
            if shiftDays.count > Self.maxShiftRows {
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
                Text(shiftCount == 1 ? "1 this period" : "\(shiftCount) this period")
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

/// One shift (one day), however many rows it took to log it.
private struct ShiftDayRow: View {
    let day: Date
    let entries: [TipEntry]

    private var totalCents: Int {
        entries.reduce(0) { $0 + $1.amountCents }
    }

    private var subtitle: String {
        var parts: [String] = []
        let breakdown = TipBreakdown.total(of: entries)
        if breakdown.cashCents > 0, breakdown.creditCents > 0 {
            parts.append("Cash \(Money.string(fromCents: breakdown.cashCents)) · Credit \(Money.string(fromCents: breakdown.creditCents))")
        } else {
            parts.append(entries.first?.kind.displayName ?? "")
        }
        if entries.contains(where: \.isDouble) {
            parts.append("double")
        }
        if let note = entries.compactMap(\.note).first(where: { !$0.isEmpty }) {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ShiftDays.humanLabel(for: day))
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                Text(subtitle)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer()
            Text(Money.string(fromCents: totalCents))
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
        }
        .padding(.vertical, 4)
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
