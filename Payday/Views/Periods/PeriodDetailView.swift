import SwiftUI
import SwiftData

struct PeriodDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    let period: PayPeriod
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showPaycheckSheet = false

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
        paycheckRecords.first { $0.periodStart == period.start && $0.periodEnd == period.end }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Text(dateRangeString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(Money.string(fromCents: loggedCents))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Text("Cash \(Money.string(fromCents: breakdown.cashCents))")
                        Text("·").foregroundStyle(.secondary)
                        Text("Credit \(Money.string(fromCents: breakdown.creditCents))")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    Button("Edit paycheck amount") { showPaycheckSheet = true }
                } else {
                    Button {
                        showPaycheckSheet = true
                    } label: {
                        Label("Enter paycheck amount", systemImage: "banknote")
                    }
                }
            }

            if entries.isEmpty {
                Section {
                    Text("No entries in this period.")
                        .foregroundStyle(.secondary)
                }
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
                                modelContext.delete(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
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
                .font(.subheadline)

            HStack(spacing: 6) {
                Image(systemName: isShort ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isShort ? Color.red : Color.accentColor)
                Text(deltaString)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(isShort ? Color.red : Color.accentColor)
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let note = paycheck.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
