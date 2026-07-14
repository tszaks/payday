import SwiftUI
import SwiftData

/// Owns its own dismissal and save logic.
///
/// Logging a new shift captures cash AND credit together (the two numbers a
/// server actually walks out with), saving one TipEntry per non-zero amount.
/// This is a creation flow, so it stays Cancel + explicit Save.
///
/// Editing an existing entry stays single-amount with a kind toggle, since an
/// entry is one specific cash-or-credit record — but per the Vero sheet
/// standard, edit flows live-save: every field change writes straight to the
/// entry, and the toolbar is a single Done.
struct LogTipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let target: TipEntrySheetTarget

    // New-log state (dual amount)
    @State private var cashCents: Int = 0
    @State private var creditCents: Int = 0

    // Edit state (single amount + kind)
    @State private var amountCents: Int = 0
    @State private var kind: TipKind = .cash

    // Shared
    @State private var date: Date
    @State private var note: String

    init(target: TipEntrySheetTarget) {
        self.target = target
        switch target {
        case .new(let defaultDate):
            _date = State(initialValue: defaultDate)
            _note = State(initialValue: "")
        case .edit(let entry):
            _amountCents = State(initialValue: entry.amountCents)
            _kind = State(initialValue: entry.kind)
            _date = State(initialValue: entry.date)
            _note = State(initialValue: entry.note ?? "")
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var canSave: Bool {
        cashCents > 0 || creditCents > 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isEditing {
                    editContent
                } else {
                    logContent
                }

                detailsCard

                if isEditing {
                    Button("Delete Entry", role: .destructive) { delete() }
                        .padding(.top, 4)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 32)
            .background(PaydayColor.background)
            .navigationTitle(isEditing ? "Edit Tips" : "Log Tips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveNew() }
                            .buttonStyle(.glassProminent)
                            .disabled(!canSave)
                    }
                }
            }
            .onChange(of: amountCents) { _, _ in liveSaveEdit() }
            .onChange(of: kind) { _, _ in liveSaveEdit() }
            .onChange(of: date) { _, _ in liveSaveEdit() }
            .onChange(of: note) { _, _ in liveSaveEdit() }
        }
        // Fixed height for the common case, plus .large as an escape hatch so
        // content is never clipped on smaller iPhones with the keypad up.
        .presentationDetents([.height(isEditing ? 480 : 520), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(PaydayColor.background)
    }

    // MARK: New log — cash + credit together

    private var logContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Shift total")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: cashCents + creditCents))
                    .font(PaydayFont.displayXL)
                    .monospacedDigit()
                    .foregroundStyle(cashCents + creditCents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(PaydayAnimation.premiumSpring, value: cashCents + creditCents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            VStack(spacing: 12) {
                CurrencyAmountRow(label: "Cash", cents: $cashCents, autoFocus: true)
                CurrencyAmountRow(label: "Credit", cents: $creditCents)
            }
            .padding(.horizontal)
        }
    }

    // MARK: Edit — single amount + kind

    private var editContent: some View {
        VStack(spacing: 16) {
            CurrencyAmountField(cents: $amountCents)

            Picker("Tip type", selection: $kind) {
                ForEach(TipKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
    }

    // MARK: Shared date + note

    private var detailsCard: some View {
        card {
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
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(PaydayColor.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
    }

    // MARK: Actions

    /// Creation flow only: writes the entries and haptics-confirms once, on
    /// explicit Save.
    private func saveNew() {
        guard case .new = target else { return }
        // Clamp to today: the picker already blocks future dates, but never
        // trust the initial/bound value to enforce it.
        let normalizedDate = Calendar.current.startOfDay(for: min(date, .now))
        let trimmedNote = note.isEmpty ? nil : note
        let recordedAt = Date.now

        if cashCents > 0 {
            modelContext.insert(TipEntry(date: normalizedDate, amountCents: cashCents, kind: .cash, note: trimmedNote, recordedAt: recordedAt))
        }
        if creditCents > 0 {
            modelContext.insert(TipEntry(date: normalizedDate, amountCents: creditCents, kind: .credit, note: trimmedNote, recordedAt: recordedAt))
        }
        PaydayHaptics.success()
        dismiss()
    }

    /// Edit flow: every field change writes straight through to the entry.
    /// Routine, reversible edits stay silent — no haptic on every keystroke.
    private func liveSaveEdit() {
        guard case .edit(let entry) = target else { return }
        entry.date = Calendar.current.startOfDay(for: min(date, .now))
        entry.amountCents = amountCents
        entry.kind = kind
        entry.note = note.isEmpty ? nil : note
    }

    private func delete() {
        if case .edit(let entry) = target {
            modelContext.delete(entry)
        }
        dismiss()
    }
}
