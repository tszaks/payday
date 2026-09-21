import SwiftUI
import SwiftData
import Combine

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
    @Query private var paycheckRecords: [PaycheckRecord]
    /// The other representation. SmartNudgeScheduler picks between this and
    /// `allEntries` on `shiftsAreAuthoritative`; it must never read both, or a
    /// converted shift counts twice.
    @Query private var shiftRecords: [ShiftRecord]

    @State private var selectedDate: Date
    @State private var cashCents: Int = 0
    @State private var creditCents: Int = 0
    @State private var tipOutCents: Int = 0
    @FocusState private var focusedField: CurrencyRowField?

    @State private var shiftsAddedCount = 0
    @State private var saveFailed = false
    @State private var datesWithExistingShifts: Set<Date> = []
    /// Entries saved this session, appended to allEntries when rescheduling
    /// the nudge at dismiss — same defensive concatenation LogTipSheet.saveNew
    /// uses, since allEntries' @Query isn't guaranteed to have refreshed by
    /// the time onDisappear fires for the very last save.
    /// The same, in the shift representation. Backfill enters a whole history
    /// in one sitting, so `@Query` lags badly here -- this is why the session
    /// list exists at all, and the record path needs its own for the same
    /// reason. Exactly one of the two ever fills.
    @State private var sessionRecords: [ShiftRecord] = []

    init() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        _selectedDate = State(initialValue: Calendar.current.startOfDay(for: yesterday))
    }

    /// "Did the person type an amount", not a money figure. Spelled as two
    /// comparisons rather than `cash + credit > 0` so there is no cents
    /// addition in this view at all — the PR 5 contract's rule 1 bans `a + b`
    /// on cents outside the engine, and a gate that happens to be true today
    /// is exactly how the next `+` gets written. Same spelling LogTipSheet's
    /// own `canSave` already used.
    private var canSave: Bool {
        cashCents > 0 || creditCents > 0
    }

    /// Informational only, never blocking — two shifts a day is a
    /// legitimate double, not a mistake to prevent.
    private var selectedDayAlreadyHasShift: Bool {
        datesWithExistingShifts.contains(Calendar.current.startOfDay(for: selectedDate))
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
                                .foregroundStyle(PaydayColor.textSecondary)
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
                // FLIP GATE 1's other call site. Backfill writes many nights in one
                // sitting, so the session list is the only thing that knows what
                // was just entered -- appending it on the correct representation
                // is what stops the nudge firing for a night the user just typed in.
                SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, shiftRecords: shiftRecords + sessionRecords)
                PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, shiftRecords: shiftRecords + sessionRecords, paycheckRecords: paycheckRecords)
                PaydayWidgetRefresh.request()
            }
            .task {
                refreshExistingShiftDates()
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
                refreshExistingShiftDates()
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(PaydayColor.background)
        .alert(
            ShiftCommands.Failure.saveFailed.message,
            isPresented: $saveFailed
        ) {
            Button("OK", role: .cancel) {}
        }
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
                        .foregroundStyle(PaydayColor.textSecondary)
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
        case .tipOut, .gratuityFees, .receiptTotal, .sales, .servers, .guests, .tables: return .cash
        }
    }

    /// The one place a shift actually gets written — shared by "Save & Add
    /// Another" and both Done buttons so there's exactly one save path.
    private func performSave() {
        // Explicit and atomic. This path persisted only through autosave, so
        // with autosave off a backfilled shift would vanish on relaunch --
        // and backfill is used to enter a whole history at once, so the loss
        // would be many nights rather than one.
        // `create` owns its own save and rollback, so it is not wrapped in
        // `commit`.
        let records: [ShiftRecord]
        do {
            records = [try ShiftCommands.create(
                in: modelContext,
                workDate: selectedDate,
                cashTipsCents: cashCents,
                creditTipsCents: creditCents,
                tipOutCents: tipOutCents > 0 ? tipOutCents : nil
            )]
        } catch {
            // Rolled back. The amounts stay on screen so the night can be
            // re-entered rather than silently lost, and the counter does not
            // advance on a save that did not happen.
            saveFailed = true
            return
        }
        sessionRecords.append(contentsOf: records)
        datesWithExistingShifts.insert(Calendar.current.startOfDay(for: selectedDate))
        PaydayHaptics.success()
        shiftsAddedCount += 1
    }

    private func refreshExistingShiftDates() {
        // This set is what stops backfill offering a night the user has
        // already entered.
        let recordDays = (shiftRecords + sessionRecords).map {
            Calendar.current.startOfDay(for: $0.workDate)
        }
        datesWithExistingShifts = Set(recordDays)
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
