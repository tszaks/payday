import SwiftUI
import SwiftData

struct PeriodDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    let period: PayPeriod
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showPaycheckSheet = false
    @State private var pendingDeleteEntry: TipEntry?

    private var payDate: Date {
        PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback).payDate(for: period)
    }

    private var entries: [TipEntry] {
        allEntries
            .filter { $0.date >= period.start && $0.date <= period.end }
            .sorted { $0.date > $1.date }
    }

    private var breakdown: TipBreakdown {
        TipBreakdown.total(of: entries)
    }

    private var loggedCents: Int {
        breakdown.totalCents
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
                VStack(spacing: 10) {
                    Text(dateRangeString)
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.textSecondary)
                    Text(Money.string(fromCents: loggedCents))
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
                    Text("Paid \(payDate.formatted(.dateTime.month(.wide).day()))")
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section("Paycheck") {
                if let paycheck {
                    PaycheckComparisonView(breakdown: breakdown, paycheck: paycheck)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    Button("Edit paycheck amount") { showPaycheckSheet = true }
                } else {
                    Button {
                        showPaycheckSheet = true
                    } label: {
                        Label("Enter paycheck amount", systemImage: "banknote")
                    }
                }
            }
            .listRowBackground(PaydayColor.background)

            if entries.isEmpty {
                Section {
                    Text("No entries in this period.")
                        .foregroundStyle(PaydayColor.textSecondary)
                }
                .listRowBackground(PaydayColor.background)
            } else {
                Section("Entries") {
                    ForEach(entries) { entry in
                        Button {
                            sheetTarget = .edit(entry)
                        } label: {
                            EntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeleteEntry = entry
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(PaydayColor.background)
            }
        }
        .confirmationDialog(
            "Delete this tip?",
            isPresented: Binding(get: { pendingDeleteEntry != nil }, set: { if !$0 { pendingDeleteEntry = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDeleteEntry { modelContext.delete(entry) }
                pendingDeleteEntry = nil
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
        .sheet(isPresented: $showPaycheckSheet) {
            PaycheckEntrySheet(period: period, existing: paycheck)
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
    private var comparedCents: Int { usesCreditOnly ? breakdown.creditCents : breakdown.totalCents }

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
        .padding()
        .background(PaydayColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: PaydayRadius.lg, style: .continuous))
        .paydayPremiumShadow()
        .padding(.horizontal)
        .padding(.vertical, 4)
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
