import SwiftUI
import SwiftData

/// Owns its own dismissal and save logic. Handles both logging a brand new
/// tip and editing an existing one, selected by `target`.
struct LogTipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let target: TipEntrySheetTarget

    @State private var amountCents: Int
    @State private var date: Date
    @State private var note: String

    init(target: TipEntrySheetTarget) {
        self.target = target
        switch target {
        case .new(let defaultDate):
            _amountCents = State(initialValue: 0)
            _date = State(initialValue: defaultDate)
            _note = State(initialValue: "")
        case .edit(let entry):
            _amountCents = State(initialValue: entry.amountCents)
            _date = State(initialValue: entry.date)
            _note = State(initialValue: entry.note ?? "")
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                CurrencyAmountField(cents: $amountCents)
                    .padding(.top, 24)

                VStack(spacing: 0) {
                    HStack {
                        Text("Date")
                        Spacer()
                        DatePicker("", selection: $date, in: ...Date.now, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .padding()
                    Divider()
                    HStack {
                        Text("Note")
                        Spacer()
                        TextField("Optional", text: $note)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding()
                }
                .background(Color.paydaySurface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.horizontal)
            }
            .padding(.bottom, 32)
            .background(Color.paydaySurface)
            .navigationTitle(isEditing ? "Edit Tips" : "Log Tips")
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
                if isEditing {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", role: .destructive) { delete() }
                    }
                }
            }
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.paydaySurface)
    }

    private func save() {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        switch target {
        case .new:
            let entry = TipEntry(date: normalizedDate, amountCents: amountCents, note: note.isEmpty ? nil : note)
            modelContext.insert(entry)
        case .edit(let entry):
            entry.date = normalizedDate
            entry.amountCents = amountCents
            entry.note = note.isEmpty ? nil : note
        }
        Haptics.success()
        dismiss()
    }

    private func delete() {
        if case .edit(let entry) = target {
            modelContext.delete(entry)
        }
        dismiss()
    }
}
