import SwiftUI
import SwiftData

struct PaycheckEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let period: PayPeriod
    let existing: PaycheckRecord?

    @State private var amountCents: Int
    @State private var note: String

    init(period: PayPeriod, existing: PaycheckRecord?) {
        self.period = period
        self.existing = existing
        _amountCents = State(initialValue: existing?.paidTipsCents ?? 0)
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Enter the tips amount from the pay stub — not the check total.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                CurrencyAmountField(cents: $amountCents)
                    .padding(.top, 8)

                HStack {
                    Text("Note")
                    Spacer()
                    TextField("Optional", text: $note)
                        .multilineTextAlignment(.trailing)
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 16)
            .background(Color(.systemBackground))
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
        .presentationDetents([.medium])
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
        Haptics.success()
        dismiss()
    }
}
