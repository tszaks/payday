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
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    let target: TipEntrySheetTarget

    // New-log state (dual amount)
    @State private var cashCents: Int = 0
    @State private var creditCents: Int = 0
    @FocusState private var focusedCurrencyField: CurrencyRowField?

    // Edit state (single amount + kind)
    @State private var amountCents: Int = 0
    @State private var kind: TipKind = .cash

    // Shared
    @State private var date: Date
    @State private var note: String
    @State private var isDouble: Bool
    @State private var isDoubleManuallySet = false
    @State private var showDeleteConfirmation = false
    @State private var revealResult: RevealResult?
    /// Set alongside revealResult only when a tip-out was logged tonight —
    /// lets the reveal show gross + tip-out one glance under the net
    /// headline, never hiding what net was computed from.
    @State private var revealGrossAndTipOut: (grossCents: Int, tipOutCents: Int)?

    // Optional shift details — skippable, never nagged. hoursWorked and
    // tipOutCents only ever land on ONE entry when a night has both cash
    // and credit (see saveNew); StatsEngine sums a day's values across its
    // records, so a duplicate value on both would silently double them.
    @State private var showMoreDetails = false
    @State private var hoursWorked: Double?
    @State private var tipOutCents: Int = 0
    @State private var salesCents: Int = 0

    init(target: TipEntrySheetTarget) {
        self.target = target
        switch target {
        case .new(let defaultDate):
            _date = State(initialValue: defaultDate)
            _note = State(initialValue: "")
            _isDouble = State(initialValue: false)
        case .edit(let entry):
            _amountCents = State(initialValue: entry.amountCents)
            _kind = State(initialValue: entry.kind)
            _date = State(initialValue: entry.date)
            _note = State(initialValue: entry.note ?? "")
            _isDouble = State(initialValue: entry.isDouble)
            _hoursWorked = State(initialValue: entry.hoursWorked)
            _tipOutCents = State(initialValue: entry.tipOutCents ?? 0)
            _salesCents = State(initialValue: entry.salesCents ?? 0)
            _showMoreDetails = State(initialValue: entry.hoursWorked != nil || entry.tipOutCents != nil || entry.salesCents != nil)
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var canSave: Bool {
        cashCents > 0 || creditCents > 0
    }

    /// A server who's never once logged cash and has enough credit history
    /// to call it a pattern gets the credit field focused first instead of
    /// the usual cash-first default.
    private var prefersCreditFirst: Bool {
        let hasCash = allEntries.contains { $0.kind == .cash }
        let creditCount = allEntries.filter { $0.kind == .credit }.count
        return !hasCash && creditCount >= 3
    }

    private var averagePerShiftCents: Int? {
        let nights = StatsEngine(records: allEntries.map(TipRecord.init)).nightlyTotals()
        guard !nights.isEmpty else { return nil }
        return nights.reduce(0) { $0 + $1.cents } / nights.count
    }

    /// The most recently logged hours for this same weekday — lets a
    /// regular Friday bartender see their usual number already sitting
    /// there instead of having to remember and re-enter it every time.
    private func suggestedHours(for date: Date) -> Double? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        return allEntries
            .filter { $0.hoursWorked != nil && calendar.component(.weekday, from: $0.date) == weekday }
            .sorted { $0.date > $1.date }
            .first?.hoursWorked
    }

    /// Same per-weekday memory as hours, for tip-out.
    private func suggestedTipOutCents(for date: Date) -> Int? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        return allEntries
            .filter { $0.tipOutCents != nil && calendar.component(.weekday, from: $0.date) == weekday }
            .sorted { $0.date > $1.date }
            .first?.tipOutCents
    }

    /// Same per-weekday memory as hours and tip-out, for sales.
    private func suggestedSalesCents(for date: Date) -> Int? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        return allEntries
            .filter { $0.salesCents != nil && calendar.component(.weekday, from: $0.date) == weekday }
            .sorted { $0.date > $1.date }
            .first?.salesCents
    }

    /// Pulled out of the view body's onAppear closure — inlining this much
    /// logic directly in a chained-modifier closure was slow enough to trip
    /// the type checker's time budget.
    private func seedShiftDetailDefaults() {
        guard case .new = target else { return }
        if hoursWorked == nil { hoursWorked = suggestedHours(for: date) }
        if tipOutCents == 0 { tipOutCents = suggestedTipOutCents(for: date) ?? 0 }
        if salesCents == 0 { salesCents = suggestedSalesCents(for: date) ?? 0 }
        // A remembered default is still a value about to be saved — show
        // it rather than attach it silently.
        if hoursWorked != nil || tipOutCents > 0 || salesCents > 0 { showMoreDetails = true }
    }

    /// A default, not a lock: only suggests the toggle until the user has
    /// touched it themselves, at which point their choice always wins.
    private func maybeSuggestDouble() {
        guard !isDoubleManuallySet, let average = averagePerShiftCents, average > 0 else { return }
        if cashCents + creditCents >= average * 2 {
            isDouble = true
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let revealResult {
                    RevealCardView(result: revealResult, grossAndTipOut: revealGrossAndTipOut, onDismiss: { dismiss() })
                } else {
                    VStack(spacing: 24) {
                        if isEditing {
                            editContent
                        } else {
                            logContent
                        }

                        detailsCard
                        moreDetailsCard

                        if isEditing {
                            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                                Text("Delete Tip")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(PaydayColor.error)
                            .padding(.horizontal)
                            .padding(.top, 4)
                            .confirmationDialog("Delete this tip?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                                Button("Delete Tip", role: .destructive) { delete() }
                            }
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .background(PaydayColor.background)
            .navigationTitle(revealResult != nil ? "" : (isEditing ? "Edit Tips" : "Log Tips"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if revealResult == nil {
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
            }
            .onChange(of: amountCents) { _, _ in liveSaveEdit() }
            .onChange(of: kind) { _, _ in liveSaveEdit() }
            .onChange(of: date) { _, _ in liveSaveEdit() }
            .onChange(of: note) { _, _ in liveSaveEdit() }
            .onChange(of: isDouble) { _, _ in liveSaveEdit() }
            .onChange(of: cashCents) { _, _ in maybeSuggestDouble() }
            .onChange(of: creditCents) { _, _ in maybeSuggestDouble() }
            .onChange(of: hoursWorked) { _, _ in liveSaveEdit() }
            .onChange(of: tipOutCents) { _, _ in liveSaveEdit() }
            .onChange(of: salesCents) { _, _ in liveSaveEdit() }
            .onAppear { seedShiftDetailDefaults() }
        }
        // Fixed height for the common case, plus .large as an escape hatch so
        // content is never clipped on smaller iPhones with the keypad up.
        .presentationDetents([.height(isEditing ? 480 : 520), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(PaydayColor.background)
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if !isEditing, let index = args.firstIndex(of: "-DebugTriggerReveal"), args.count > index + 1,
               let cents = Int(args[index + 1]) {
                cashCents = cents
                saveNew()
            }
        }
        #endif
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
                CurrencyAmountRow(label: "Cash", cents: $cashCents, field: .cash, focusedField: $focusedCurrencyField, autoFocus: !prefersCreditFirst)
                CurrencyAmountRow(label: "Credit", cents: $creditCents, field: .credit, focusedField: $focusedCurrencyField, autoFocus: prefersCreditFirst)
            }
            .padding(.horizontal)
        }
        .toolbar {
            if let focusedCurrencyField {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Next") {
                        self.focusedCurrencyField = focusedCurrencyField == .cash ? .credit : .cash
                    }
                }
            }
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
            Divider()
            Toggle("Double shift", isOn: Binding(
                get: { isDouble },
                set: { isDouble = $0; isDoubleManuallySet = true }
            ))
            .padding()
        }
    }

    /// Optional shift details, collapsed by default unless already set —
    /// hours today, tip-out and sales to follow. Never required: leaving
    /// this closed logs exactly what the app always logged.
    private var moreDetailsCard: some View {
        card {
            DisclosureGroup("Hours, tip-out, sales", isExpanded: $showMoreDetails) {
                VStack(spacing: 12) {
                    HStack {
                        Text("Hours")
                        Spacer()
                        Stepper(value: hoursStepperBinding, in: 0...16, step: 0.25) {
                            Text(hoursWorked.map(Self.hoursLabel) ?? "Not logged")
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                    }
                    HStack {
                        Text("Tip-out")
                        Spacer()
                        CompactCurrencyField(cents: $tipOutCents)
                    }
                    HStack {
                        Text("Sales")
                        Spacer()
                        CompactCurrencyField(cents: $salesCents)
                    }
                }
                .padding(.top, 12)
            }
            .padding()
            .tint(PaydayColor.textPrimary)
        }
    }

    private var hoursStepperBinding: Binding<Double> {
        Binding(
            get: { hoursWorked ?? 0 },
            set: { hoursWorked = $0 > 0 ? $0 : nil }
        )
    }

    private static func hoursLabel(_ hours: Double) -> String {
        var formatted = String(format: "%.2f", (hours * 4).rounded() / 4)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return "\(formatted) hrs"
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(PaydayColor.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: PaydayRadius.lg))
            .padding(.horizontal)
    }

    // MARK: Actions

    /// Creation flow only: writes the entries, then shows the post-log
    /// reveal instead of dismissing immediately. Stats are computed from
    /// history BEFORE the insert (the engine's `excluding` parameters exist
    /// exactly so callers can pass tonight's history and total separately).
    private func saveNew() {
        guard case .new = target else { return }
        // Clamp to today: the picker already blocks future dates, but never
        // trust the initial/bound value to enforce it.
        let normalizedDate = Calendar.current.startOfDay(for: min(date, .now))
        let trimmedNote = note.isEmpty ? nil : note
        let recordedAt = Date.now
        let totalCents = cashCents + creditCents
        let effectiveTipOutCents = tipOutCents > 0 ? tipOutCents : nil
        let effectiveSalesCents = salesCents > 0 ? salesCents : nil
        let netTotalCents = totalCents - (effectiveTipOutCents ?? 0)

        let statsEngine = StatsEngine(records: allEntries.map(TipRecord.init))
        let calculator = PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
        let period = calculator.period(containing: normalizedDate)
        // Reveal always speaks in net — the same rule StatsEngine applies to
        // every other analytical total.
        let reveal = statsEngine.reveal(forNightAt: normalizedDate, cents: netTotalCents, period: period, hoursWorked: hoursWorked)

        // Shift-level details (hours, tip-out) go on exactly one of
        // tonight's entries — putting them on both would double-count when
        // StatsEngine sums a night's values across its records.
        let creditIsPrimary = creditCents > 0
        var newEntries: [TipEntry] = []
        if cashCents > 0 {
            let entry = TipEntry(date: normalizedDate, amountCents: cashCents, kind: .cash, note: trimmedNote, recordedAt: recordedAt, isDouble: isDouble, hoursWorked: creditIsPrimary ? nil : hoursWorked, tipOutCents: creditIsPrimary ? nil : effectiveTipOutCents, salesCents: creditIsPrimary ? nil : effectiveSalesCents)
            modelContext.insert(entry)
            newEntries.append(entry)
        }
        if creditCents > 0 {
            let entry = TipEntry(date: normalizedDate, amountCents: creditCents, kind: .credit, note: trimmedNote, recordedAt: recordedAt, isDouble: isDouble, hoursWorked: hoursWorked, tipOutCents: effectiveTipOutCents, salesCents: effectiveSalesCents)
            modelContext.insert(entry)
            newEntries.append(entry)
        }
        revealResult = reveal
        revealGrossAndTipOut = effectiveTipOutCents.map { (grossCents: totalCents, tipOutCents: $0) }
        // Tonight is logged — cancel tonight's nudge and queue the next
        // usual night's instead. allEntries' @Query hasn't necessarily
        // refreshed within this same call, so the just-inserted entries
        // are appended explicitly rather than relied on to already be in it.
        SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries + newEntries)
        PaydayWidgetRefresh.request()
    }

    /// Edit flow: every field change writes straight through to the entry.
    /// Routine, reversible edits stay silent — no haptic on every keystroke.
    private func liveSaveEdit() {
        guard case .edit(let entry) = target else { return }
        entry.date = Calendar.current.startOfDay(for: min(date, .now))
        entry.amountCents = amountCents
        entry.kind = kind
        entry.note = note.isEmpty ? nil : note
        entry.isDouble = isDouble
        entry.hoursWorked = hoursWorked
        entry.tipOutCents = tipOutCents > 0 ? tipOutCents : nil
        entry.salesCents = salesCents > 0 ? salesCents : nil
        PaydayWidgetRefresh.request()
    }

    private func delete() {
        if case .edit(let entry) = target {
            modelContext.delete(entry)
        }
        PaydayWidgetRefresh.request()
        dismiss()
    }
}

/// A small, non-auto-focusing cents field for the optional shift-details
/// group — same digit-shift-from-the-right technique as CurrencyAmountRow,
/// just compact and self-contained since these are secondary, skippable
/// fields, not the sheet's primary input.
private struct CompactCurrencyField: View {
    @Binding var cents: Int
    @FocusState private var isFocused: Bool
    @State private var digitsText: String = ""

    private static let maxDigits = 7

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(Money.string(fromCents: cents))
                .font(PaydayFont.body)
                .monospacedDigit()
                .foregroundStyle(cents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                .contentTransition(.numericText())
            TextField("", text: $digitsText)
                .keyboardType(.numberPad)
                .focused($isFocused)
                .opacity(0.01)
                .frame(maxWidth: 100, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { digitsText = cents == 0 ? "" : String(cents) }
        .onChange(of: digitsText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(Self.maxDigits))
            if filtered != newValue { digitsText = filtered }
            cents = Int(filtered) ?? 0
        }
    }
}

/// The post-log reveal: one beat (~2s, tappable to skip) showing tonight's
/// total and the one most interesting true thing about it. Record nights
/// get the single earned flourish — the amount sweeps to green, once, paired
/// with the save's success haptic. No confetti, no looping animation.
private struct RevealCardView: View {
    let result: RevealResult
    /// Non-nil only when a tip-out was logged — the headline above is
    /// already net; this makes the gross it came from one glance away.
    let grossAndTipOut: (grossCents: Int, tipOutCents: Int)?
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 12) {
            Text(RevealCopy.headline(cents: result.cents))
                .font(PaydayFont.displayXL)
                .monospacedDigit()
                .foregroundStyle(result.isRecord && isRevealed ? PaydayColor.primary : PaydayColor.textPrimary)
            Text(RevealCopy.comparison(for: result.comparison))
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let rateClause = result.rateClause {
                Text(RevealCopy.rateClause(for: rateClause))
                    .font(PaydayFont.footnote)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            if let grossAndTipOut {
                Text("\(Money.string(fromCents: grossAndTipOut.grossCents)) gross, \(Money.string(fromCents: grossAndTipOut.tipOutCents)) tipped out.")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .task {
            PaydayHaptics.success()
            if result.isRecord {
                if reduceMotion {
                    isRevealed = true
                } else {
                    withAnimation(PaydayAnimation.premiumSpring) { isRevealed = true }
                }
            }
            try? await Task.sleep(for: .seconds(2))
            onDismiss()
        }
    }
}
