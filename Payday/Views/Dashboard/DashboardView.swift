import SwiftUI
import SwiftData
import TipKit

struct DashboardView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(TabRouter.self) private var tabRouter
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showSettings = false
    @State private var undoState = UndoDeleteToastState()

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

    /// A shift is a day worked, not a row: logging one night now writes up to
    /// two entries (cash + credit), so count distinct days, not entries.
    private var shiftCount: Int {
        Set(periodEntries.map { Calendar.current.startOfDay(for: $0.date) }).count
    }

    private var priorPeriod: PayPeriod {
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: currentPeriod.start) ?? currentPeriod.start
        return calculator.period(containing: previousDay)
    }

    /// Hidden until there's real history to compare against — a brand-new
    /// user's first period has no "last period" worth being ahead of.
    private var paceLineText: String? {
        guard allEntries.contains(where: { $0.date >= priorPeriod.start && $0.date <= priorPeriod.end }) else { return nil }
        let delta = statsEngine.paceDelta(currentPeriod: currentPeriod, priorPeriod: priorPeriod, asOf: .now) ?? 0
        return RevealCopy.paceLine(deltaCents: delta)
    }

    private var statsEngine: StatsEngine {
        StatsEngine(records: allEntries.map(TipRecord.init))
    }

    /// The app is named after this moment: the last day of a pay period,
    /// when there's a verdict to deliver and a paycheck to predict. Not the
    /// same day money actually lands (see PayPeriodCalculator.payDate) -
    /// this is "your work here is done," not "you got paid today."
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
    /// period in history to actually beat — a brand-new user's first
    /// period has nothing to be the best of.
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

    private let paydayVerificationTip = PaydayVerificationTip()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    heroCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if periodEntries.isEmpty {
                    Section {
                        emptyState
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section("Recent entries") {
                        ForEach(periodEntries) { entry in
                            Button {
                                sheetTarget = .edit(entry)
                            } label: {
                                EntryRow(entry: entry)
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
                        }
                    }
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

    private var heroCard: some View {
        VStack(spacing: 24) {
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
                if let paceLineText {
                    Text(paceLineText)
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 0) {
                MoneyTile(label: "Cash", cents: breakdown.cashCents)
                Divider().frame(height: 36)
                MoneyTile(label: "Credit", cents: breakdown.creditCents)
            }

            Divider()

            HStack(spacing: 0) {
                Button {
                    tabRouter.selected = .calendar
                } label: {
                    StatChip(
                        value: daysRemaining == 0 ? "Today" : "\(daysRemaining)",
                        label: daysRemaining == 0 ? "Last day" : (daysRemaining == 1 ? "day left" : "days left")
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Calendar")

                Divider().frame(height: 36)

                StatChip(
                    value: "\(shiftCount)",
                    label: shiftCount == 1 ? "shift logged" : "shifts logged"
                )
            }

            if isPaydayMoment {
                Divider()
                paydayMomentSection
            }
        }
        .padding(.horizontal, PaydaySpacing.p20)
        .padding(.top, 8)
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

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing logged yet this period",
            systemImage: "tray",
            description: Text("Log tonight's tips and watch the total build toward payday.")
        )
        .padding(.vertical, 16)
    }
}

private struct MoneyTile: View {
    let label: String
    let cents: Int

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(Money.string(fromCents: cents))
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(cents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .animation(PaydayAnimation.premiumSpring, value: cents)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct StatChip: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
            Text(label)
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
