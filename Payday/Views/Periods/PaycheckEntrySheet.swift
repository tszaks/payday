import SwiftUI
import SwiftData

struct PaycheckEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query private var allEntries: [TipEntry]

    let period: PayPeriod
    let existing: PaycheckRecord?

    @State private var amountCents: Int
    @State private var note: String
    @State private var showDeleteConfirmation = false

    init(period: PayPeriod, existing: PaycheckRecord?) {
        self.period = period
        self.existing = existing
        _amountCents = State(initialValue: existing?.paidTipsCents ?? 0)
        _note = State(initialValue: existing?.note ?? "")
    }

    /// Hours logged for this period, for the wages footnote only — never fed
    /// into the tips amount this sheet records.
    private var loggedHours: Double {
        let periodEntries = allEntries.filter { $0.date >= period.start && $0.date <= period.end }
        let shiftGroups = ShiftDays.groupedByShift(periodEntries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod).map(\.items)
        return WageEstimate.loggedHours(shiftGroups: shiftGroups)
    }

    private var explainerText: String {
        let base = "Enter the tips amount from the pay stub — not the check total."
        guard let wageEstimateCents = WageEstimate.cents(wageCentsPerHour: preferencesStore.baseHourlyWageCents, hours: loggedHours) else {
            return base
        }
        let wages = Money.string(fromCents: wageEstimateCents)
        let hours = WageEstimate.hoursLabel(loggedHours)
        return "\(base) Your stub should also show \(wages) in wages for \(hours); don't include that here."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text(explainerText)
                        .font(PaydayFont.footnote)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    CurrencyAmountField(cents: $amountCents)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Note")
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.textSecondary)
                        TextField("Optional", text: $note, axis: .vertical)
                            .lineLimit(2...6)
                    }
                    .padding()
                    .background(PaydayColor.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: PaydayRadius.lg))
                    .padding(.horizontal)

                    if existing != nil {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: {
                            Text("Remove Paycheck")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(PaydayColor.error)
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .confirmationDialog("Remove this paycheck?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                            Button("Remove Paycheck", role: .destructive) { delete() }
                        }
                    }

                    Spacer()
                }
                .padding(.top, 16)
            }
            .background(PaydayColor.background)
            .navigationTitle("Paycheck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                        .disabled(amountCents == 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(PaydayColor.background)
    }

    private func save() {
        if let existing {
            existing.paidTipsCents = amountCents
            existing.note = note.isEmpty ? nil : note
        } else {
            let record = PaycheckRecord(
                periodStart: period.start,
                periodEnd: period.end,
                paidTipsCents: amountCents,
                note: note.isEmpty ? nil : note
            )
            modelContext.insert(record)
        }
        PaydayHaptics.success()
        PaydayWidgetRefresh.request()
        dismiss()
    }

    private func delete() {
        if let existing {
            modelContext.delete(existing)
        }
        PaydayWidgetRefresh.request()
        dismiss()
    }
}
