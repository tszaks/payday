import SwiftUI
import SwiftData

/// Fast batch entry for shifts that happened before someone started using
/// Payday — the whole point is letting the cold start (5+ shifts before the
/// intelligence says anything) get skipped in one sitting. Deliberately
/// minimal: date, cash, credit, optional tip-out. Hours, sales, and notes
/// are NOT here by design — that detail can be added later by editing the
/// shift, same as any other. Never shows the post-log reveal (a backfill
/// isn't "tonight"), and never dismisses on its own — Save & Add Another
/// keeps the sheet open so a whole notebook's worth of history can go in
/// without reopening this sheet once per shift.
struct BackfillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    @State private var selectedDate: Date
    @State private var cashCents: Int = 0
    @State private var creditCents: Int = 0
    @State private var tipOutCents: Int = 0
    @FocusState private var focusedField: CurrencyRowField?

    @State private var shiftsAddedCount = 0
    /// Entries saved this session, appended to allEntries when rescheduling
    /// the nudge at dismiss — same defensive concatenation LogTipSheet.saveNew
    /// uses, since allEntries' @Query isn't guaranteed to have refreshed by
    /// the time onDisappear fires for the very last save.
    @State private var sessionEntries: [TipEntry] = []

    init() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        _selectedDate = State(initialValue: Calendar.current.startOfDay(for: yesterday))
    }

    private var canSave: Bool {
        cashCents + creditCents > 0
    }

    /// Informational only, never blocking — two shifts a day is a
    /// legitimate double, not a mistake to prevent.
    private var selectedDayAlreadyHasShift: Bool {
        let calendar = Calendar.current
        let sameDay = allEntries.filter { calendar.isDate($0.date, inSameDayAs: selectedDate) }
        return Set(sameDay.compactMap(\.shiftID)).count >= 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    dateCard

                    VStack(spacing: 12) {
                        CurrencyAmountRow(label: "Cash", cents: $cashCents, field: .cash, focusedField: $focusedField, autoFocus: true)
                            .id("cash-\(shiftsAddedCount)")
                        CurrencyAmountRow(label: "Credit", cents: $creditCents, field: .credit, focusedField: $focusedField)
                            .id("credit-\(shiftsAddedCount)")
                        CurrencyAmountRow(label: "Tip-out", cents: $tipOutCents, field: .tipOut, focusedField: $focusedField)
                            .id("tipOut-\(shiftsAddedCount)")
                    }
                    .padding(.horizontal)

                    VStack(spacing: 8) {
                        // Hidden while a money field is focused: the keyboard
                        // toolbar's own Save carries the loop then, and the
                        // floating pill would collide with this button anyway.
                        if focusedField == nil {
                            Button("Save & Add Another") { saveAndAddAnother() }
                                .buttonStyle(.glassProminent)
                                .disabled(!canSave)
                                .frame(maxWidth: .infinity)
                        }

                        if shiftsAddedCount > 0 {
                            Text(shiftsAddedCount == 1 ? "1 shift added" : "\(shiftsAddedCount) shifts added")
                                .font(PaydayFont.caption2)
                                .foregroundStyle(PaydayColor.textTertiary)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PaydayColor.background)
            .navigationTitle("Add Past Shifts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finishAndDismiss() }
                        .buttonStyle(.glassProminent)
                }
                // Same bottom-thumb-reachable Next/Save chain LogTipSheet
                // gives its own currency fields — here Save means "save and
                // keep going," since the batch loop is this sheet's whole
                // point. Only the nav-bar Done ends the session.
                if let focusedField {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Next") { self.focusedField = nextFocusField(after: focusedField) }
                        Button("Save") { saveAndAddAnother() }
                            .disabled(!canSave)
                    }
                }
            }
            .onDisappear {
                guard shiftsAddedCount > 0 else { return }
                SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries + sessionEntries)
                PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, allEntries: allEntries + sessionEntries, paycheckRecords: paycheckRecords)
                PaydayWidgetRefresh.request()
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(PaydayColor.background)
    }

    private var dateCard: some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Date")
                        .font(PaydayFont.body)
                        .foregroundStyle(PaydayColor.textPrimary)
                    Spacer()
                    DatePicker("", selection: $selectedDate, in: ...Date.now, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                }
                .padding()
                if selectedDayAlreadyHasShift {
                    Text("This day already has a shift. Saving adds a second.")
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textTertiary)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
            }
            .tint(PaydayColor.textPrimary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(PaydayColor.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: PaydayRadius.lg))
            .padding(.horizontal)
    }

    private func nextFocusField(after field: CurrencyRowField) -> CurrencyRowField {
        switch field {
        case .cash: return .credit
        case .credit: return .tipOut
        case .tipOut, .sales, .servers: return .cash
        }
    }

    /// The one place a shift actually gets written — shared by "Save & Add
    /// Another" and both Done buttons so there's exactly one save path.
    private func performSave() {
        let entries = ShiftWriter.insertShift(
            into: modelContext,
            date: selectedDate,
            cashCents: cashCents,
            creditCents: creditCents,
            tipOutCents: tipOutCents > 0 ? tipOutCents : nil
        )
        sessionEntries.append(contentsOf: entries)
        PaydayHaptics.success()
        shiftsAddedCount += 1
    }

    /// Saves, then resets for the next entry: clears the three amounts,
    /// steps the date back a day (the natural direction when working
    /// backward through a notebook), and bumps the session counter.
    private func saveAndAddAnother() {
        performSave()
        cashCents = 0
        creditCents = 0
        tipOutCents = 0
        selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
    }

    /// Never silently discards entered amounts: whatever's on screen gets
    /// saved first if it adds up to a valid shift, then the sheet closes.
    private func finishAndDismiss() {
        if canSave { performSave() }
        dismiss()
    }
}
