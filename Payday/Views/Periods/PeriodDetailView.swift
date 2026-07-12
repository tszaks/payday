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

    private var loggedCents: Int {
        entries.reduce(0) { $0 + $1.amountCents }
    }

    private var paycheck: PaycheckRecord? {
        paycheckRecords.first { $0.periodStart == period.start && $0.periodEnd == period.end }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text(dateRangeString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(Money.string(fromCents: loggedCents))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section("Paycheck") {
                if let paycheck {
                    PaycheckComparisonView(loggedCents: loggedCents, paycheck: paycheck)
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
                        EntryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { sheetTarget = .edit(entry) }
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
    let loggedCents: Int
    let paycheck: PaycheckRecord

    private var deltaCents: Int { paycheck.paidTipsCents - loggedCents }
    private var isShort: Bool { deltaCents < 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You logged \(Money.string(fromCents: loggedCents)) / Check paid \(Money.string(fromCents: paycheck.paidTipsCents))")
                .font(.subheadline)

            HStack(spacing: 6) {
                Image(systemName: isShort ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isShort ? Color.red : Color.accentColor)
                Text(deltaString)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(isShort ? Color.red : Color.accentColor)
            }

            Text("Compare against the tips line on your stub, not the check total.")
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

    private var deltaString: String {
        if deltaCents == 0 { return "Matched exactly" }
        let sign = deltaCents > 0 ? "+" : "-"
        return "\(sign)\(Money.string(fromCents: abs(deltaCents)))"
    }
}
