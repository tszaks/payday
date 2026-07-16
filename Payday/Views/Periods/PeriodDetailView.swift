import SwiftUI
import SwiftData

private struct ShiftSelection: Identifiable {
    let day: Date
    let shiftID: UUID
    var id: UUID { shiftID }
}

struct PeriodDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    let period: PayPeriod
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var shiftSelection: ShiftSelection?
    @State private var showPaycheckSheet = false
    @State private var undoState = UndoDeleteToastState()

    private var payDate: Date {
        PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback).payDate(for: period)
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
    /// against any logged tip-out — the headline this hero shows.
    private var netCents: Int {
        nightsInPeriod.reduce(0) { $0 + $1.cents }
    }

    /// Only this period's own entries feed the rate — a different period's
    /// $/hr belongs on that period's detail screen, not this one.
    private var averageDollarsPerHour: Double? {
        StatsEngine(records: entries.map(TipRecord.init)).averageDollarsPerHour()
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
                heroCard
            }
            .listRowInsets(EdgeInsets(top: 8, leading: PaydaySpacing.p16, bottom: 8, trailing: PaydaySpacing.p16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !nightsInPeriod.isEmpty {
                Section {
                    NightlyEarningsChart(nights: nightsInPeriod)
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
                }
            }

            if shiftDays.isEmpty {
                Section {
                    Text("No entries in this period.")
                        .foregroundStyle(PaydayColor.textSecondary)
                }
                .listRowBackground(PaydayColor.background)
            } else {
                Section("Entries") {
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
        .navigationTitle("Period")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetTarget) { target in
            LogTipSheet(target: target)
        }
        .sheet(item: $shiftSelection) { selection in
            DayDetailSheet(date: selection.day, shiftID: selection.shiftID)
        }
        .sheet(isPresented: $showPaycheckSheet) {
            PaycheckEntrySheet(period: period, existing: paycheck)
        }
        .undoDeleteToast(undoState, context: modelContext)
    }

    private var heroCard: some View {
        VStack(spacing: 10) {
            Text(dateRangeString)
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(Money.string(fromCents: netCents))
                .font(PaydayFont.displayXL)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
            HStack(spacing: 6) {
                Text("Cash \(Money.string(fromCents: breakdown.cashCents))")
                Text("·").foregroundStyle(PaydayColor.textSecondary)
                Text("Credit \(Money.string(fromCents: breakdown.creditCents))")
            }
            .font(PaydayFont.footnote)
            .monospacedDigit()
            .foregroundStyle(PaydayColor.textSecondary)
            if let averageDollarsPerHour {
                Text("Averaging \(Money.wholeDollarString(fromCents: Int((averageDollarsPerHour * 100).rounded())))/hr")
                    .font(PaydayFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            Text("Paid \(payDate.formatted(.dateTime.month(.wide).day()))")
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .paydayCard(padding: PaydaySpacing.p24)
    }

    @ViewBuilder
    private func shiftRow(for group: (day: Date, shiftID: UUID, items: [TipEntry])) -> some View {
        let period = ShiftDetails.resolve(from: group.items).shiftPeriod
        let dayHasMultiple = multiShiftDays.contains(group.day)
        if group.items.count == 1, let entry = group.items.first {
            Button {
                sheetTarget = .edit(entry)
            } label: {
                ShiftDayRow(day: group.day, period: period, dayHasMultipleShifts: dayHasMultiple, entries: group.items)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    undoState.delete(entry, in: modelContext)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .entryContextMenu(entry, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
        } else {
            Button {
                shiftSelection = ShiftSelection(day: group.day, shiftID: group.shiftID)
            } label: {
                ShiftDayRow(day: group.day, period: period, dayHasMultipleShifts: dayHasMultiple, entries: group.items)
            }
            .buttonStyle(.plain)
        }
    }

    private var dateRangeString: String {
        "\(period.start.formatted(.dateTime.month(.wide).day())) – \(period.end.formatted(.dateTime.month(.wide).day().year()))"
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paydayCard()
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
