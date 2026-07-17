import SwiftUI
import SwiftData

/// Owns its own dismissal and save logic.
///
/// A shift is one closeout — cash and credit walked out with the same
/// night, one Started/Ended pair, one tip-out, one Sales, one Note. Both
/// logging a new shift and editing an existing one use the exact same form:
/// the "entry" layer never surfaces in the UI, so there's nothing to ask
/// twice and nothing per-tip-type to juggle. Creation stays Cancel +
/// explicit Save; editing live-saves every field straight through, same as
/// the Vero sheet standard, with the toolbar reduced to a single Done.
struct LogTipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    let target: TipEntrySheetTarget

    // Cash + credit together — the two numbers a server actually walks out
    // with, whether this is a brand-new shift or an existing one being edited.
    @State private var cashCents: Int = 0
    @State private var creditCents: Int = 0
    @FocusState private var focusedCurrencyField: CurrencyRowField?

    // Shared
    @State private var date: Date
    @State private var note: String
    @State private var showDeleteConfirmation = false
    @State private var revealResult: RevealResult?
    /// Set alongside revealResult only when a tip-out was logged tonight —
    /// lets the reveal show gross + tip-out one glance under the net
    /// headline, never hiding what net was computed from.
    @State private var revealGrossAndTipOut: (grossCents: Int, tipOutCents: Int)?

    // Optional shift details — skippable, never nagged. hoursWorked,
    // tipOutCents, salesCents, shiftPeriod, clockIn, and clockOut are all
    // facts about the SHIFT (one closeout), never one entry or tip type —
    // ShiftDetails is the one place read/write for these six fields is
    // allowed to happen.
    @State private var hoursWorked: Double?
    @State private var tipOutCents: Int = 0
    @State private var salesCents: Int = 0
    @State private var shiftPeriod: ShiftPeriod?
    @State private var clockIn: Date?
    @State private var clockOut: Date?
    /// How many servers were on the floor — capture-only for now (see
    /// TipEntry.serverCount), same optional/shift-level treatment as
    /// everything else in this group.
    @State private var serverCount: Int?

    init(target: TipEntrySheetTarget) {
        self.target = target
        switch target {
        case .new(let defaultDate):
            _date = State(initialValue: defaultDate)
            _note = State(initialValue: "")
            // The clock is only a trustworthy proxy for "which shift is
            // this" when the shift being logged is actually today — a
            // backfilled past day has no clock to read, so it starts
            // unset rather than guessed at.
            if Calendar.current.isDateInToday(defaultDate) {
                let hour = Calendar.current.component(.hour, from: .now)
                _shiftPeriod = State(initialValue: hour < 16 ? .lunch : .dinner)
            }
        case .edit(let entry):
            // A synchronous fallback seeded from the anchor entry alone —
            // always available immediately, unlike the @Query-backed
            // allEntries seedShiftDetailDefaults needs for the full shift.
            // onAppear upgrades this to the true shift-level values (looking
            // at every sibling entry too) the moment allEntries has caught
            // up; until then, this is still correct for a single-entry
            // shift and a reasonable placeholder otherwise.
            if entry.kind == .cash {
                _cashCents = State(initialValue: entry.amountCents)
            } else {
                _creditCents = State(initialValue: entry.amountCents)
            }
            _date = State(initialValue: entry.date)
            _note = State(initialValue: entry.note ?? "")
            _hoursWorked = State(initialValue: entry.hoursWorked)
            _tipOutCents = State(initialValue: entry.tipOutCents ?? 0)
            _salesCents = State(initialValue: entry.salesCents ?? 0)
            _shiftPeriod = State(initialValue: entry.shiftPeriod)
            _clockIn = State(initialValue: entry.clockIn)
            _clockOut = State(initialValue: entry.clockOut)
            _serverCount = State(initialValue: entry.serverCount)
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

    /// The most recent same-weekday shift with both clock times logged —
    /// lets a regular Friday bartender see their usual Started/Ended already
    /// sitting there instead of having to remember and re-enter it every
    /// time. Re-anchored onto the shift being logged in seedShiftDetailDefaults,
    /// so only the hour/minute of the suggestion is actually used.
    private func suggestedClockTimes(for date: Date) -> (`in`: Date, out: Date)? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let match = allEntries
            .filter { $0.clockIn != nil && $0.clockOut != nil && calendar.component(.weekday, from: $0.date) == weekday }
            .sorted { $0.date > $1.date }
            .first
        guard let matchIn = match?.clockIn, let matchOut = match?.clockOut else { return nil }
        return (in: matchIn, out: matchOut)
    }

    /// Same per-weekday memory as clock times, for tip-out.
    private func suggestedTipOutCents(for date: Date) -> Int? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        return allEntries
            .filter { $0.tipOutCents != nil && calendar.component(.weekday, from: $0.date) == weekday }
            .sorted { $0.date > $1.date }
            .first?.tipOutCents
    }

    /// Same per-weekday memory as clock times and tip-out, for sales.
    private func suggestedSalesCents(for date: Date) -> Int? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        return allEntries
            .filter { $0.salesCents != nil && calendar.component(.weekday, from: $0.date) == weekday }
            .sorted { $0.date > $1.date }
            .first?.salesCents
    }

    /// Same-weekday tip-out, shown only as a CompactCurrencyField
    /// placeholder (see the type's own doc) — never pre-filled as a real
    /// value. New-log only: an existing shift already has its own honest
    /// number, not a guess to overlay. Recomputes as `date` changes, so
    /// backdating to a different weekday updates the hint too.
    private var tipOutPlaceholderCents: Int? {
        guard case .new = target else { return nil }
        return suggestedTipOutCents(for: date)
    }

    /// Same reasoning as tipOutPlaceholderCents, for sales.
    private var salesPlaceholderCents: Int? {
        guard case .new = target else { return nil }
        return suggestedSalesCents(for: date)
    }

    /// Same per-weekday memory as tip-out and sales, for server count.
    private func suggestedServerCount(for date: Date) -> Int? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        return allEntries
            .filter { $0.serverCount != nil && calendar.component(.weekday, from: $0.date) == weekday }
            .sorted { $0.date > $1.date }
            .first?.serverCount
    }

    /// Same reasoning as tipOutPlaceholderCents/salesPlaceholderCents, for
    /// server count.
    private var serversPlaceholderCount: Int? {
        guard case .new = target else { return nil }
        return suggestedServerCount(for: date)
    }

    /// Pulled out of the view body's onAppear closure — inlining this much
    /// logic directly in a chained-modifier closure was slow enough to trip
    /// the type checker's time budget.
    private func seedShiftDetailDefaults() {
        switch target {
        case .new:
            if clockIn == nil, clockOut == nil, let suggestion = suggestedClockTimes(for: date) {
                let calendar = Calendar.current
                let inComponents = calendar.dateComponents([.hour, .minute], from: suggestion.`in`)
                let outComponents = calendar.dateComponents([.hour, .minute], from: suggestion.out)
                clockIn = calendar.date(bySettingHour: inComponents.hour ?? 0, minute: inComponents.minute ?? 0, second: 0, of: date)
                clockOut = calendar.date(bySettingHour: outComponents.hour ?? 0, minute: outComponents.minute ?? 0, second: 0, of: date)
                hoursWorked = ShiftTimes.hours(clockIn: clockIn, clockOut: clockOut)
            }
            // Times pre-fill as real values because they're stable per
            // weekday — a genuine fact worth attaching automatically.
            // Tip-out and sales are NOT: they used to pre-fill tipOutCents/
            // salesCents directly here, which meant a rushed Save could
            // silently attach last Friday's tip-out to tonight. They only
            // ever surface as a CompactCurrencyField placeholder
            // (tipOutPlaceholderCents/salesPlaceholderCents, read by
            // shiftDetailsCard below) — a hint to tap into, never a
            // committed value.
        case .edit(let entry):
            // A fact about the whole shift, not this one entry — resolve
            // across every entry in the shift, same convention liveSaveEdit
            // writes back through. Guarded on the shift list actually
            // containing `entry` itself: allEntries is @Query-backed and can
            // momentarily be empty right as the sheet mounts, which would
            // otherwise resolve against an empty array and wipe out the
            // correct value init already seeded from `entry` directly.
            let shift = sameShiftEntries(around: entry)
            guard shift.contains(where: { $0.id == entry.id }) else { return }
            cashCents = shift.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amountCents }
            creditCents = shift.filter { $0.kind == .credit }.reduce(0) { $0 + $1.amountCents }
            let resolved = ShiftDetails.resolve(from: shift)
            hoursWorked = resolved.hoursWorked
            tipOutCents = resolved.tipOutCents ?? 0
            salesCents = resolved.salesCents ?? 0
            shiftPeriod = resolved.shiftPeriod
            clockIn = resolved.clockIn
            clockOut = resolved.clockOut
            serverCount = resolved.serverCount
        }
    }

    /// Every entry belonging to the same shift (closeout) as `entry` — the
    /// rows sharing its shiftID — used to treat hours/tip-out/sales/times as
    /// one shift-level fact instead of a per-entry one, even though
    /// ShiftDetails physically stores them on a single TipEntry. Falls back
    /// to same-day for a legacy entry with no shiftID yet (pre-migration).
    private func sameShiftEntries(around entry: TipEntry) -> [TipEntry] {
        if let shiftID = entry.shiftID {
            return allEntries.filter { $0.shiftID == shiftID }
        }
        return allEntries.filter { $0.shiftID == nil && Calendar.current.isDate($0.date, inSameDayAs: entry.date) }
    }

    /// Top to bottom, this sheet is ordered by a deliberate hierarchy:
    /// MONEY first (shiftAmountContent — the reason the sheet exists at
    /// all), then the shift's own defining facts and economics
    /// (shiftDetailsCard — when, which shift, what times, what tip-out and
    /// sales), then bookkeeping (noteCard — the least important input on
    /// the whole sheet), and destructive last (Delete Shift, edit only).
    /// Every row below money is optional; nothing here is ever nagged for.
    var body: some View {
        NavigationStack {
            // The system's own keyboard avoidance keeps the LAST-focused
            // field roughly on screen, but Next can hop straight from Cash
            // to Tip-out/Sales/Servers — rows that were never near the
            // keyboard's edge to begin with, so avoidance alone doesn't
            // reliably surface them. ScrollViewReader + an explicit
            // scrollTo on every focus change is the one mechanism that
            // covers the whole Cash→Servers chain, not just whichever
            // field happened to be closest.
            ScrollViewReader { proxy in
                Group {
                    if let revealResult {
                        RevealCardView(result: revealResult, grossAndTipOut: revealGrossAndTipOut, onDismiss: { dismiss() })
                    } else {
                        // Scrollable rather than a fixed VStack: expanding the
                        // details group used to compress every row toward zero
                        // height once the keyboard was up, badly enough that
                        // the amount could render overlapping the nav title.
                        // A ScrollView absorbs that extra height by scrolling
                        // instead of squeezing, keeps the header stable in
                        // every state, and (with the system's own keyboard
                        // avoidance) keeps a focused field visible above the
                        // keyboard automatically.
                        ScrollView {
                            VStack(spacing: 24) {
                                shiftAmountContent

                                shiftDetailsCard
                                noteCard

                                if isEditing {
                                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                                        Text("Delete Shift")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.glassProminent)
                                    .tint(PaydayColor.error)
                                    .padding(.horizontal)
                                    .padding(.top, 4)
                                    .confirmationDialog("Delete this shift?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                                        Button("Delete Shift", role: .destructive) { delete() }
                                    }
                                }
                            }
                            .padding(.top, 20)
                            .padding(.bottom, 32)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
                .background(PaydayColor.background)
                .navigationTitle(revealResult != nil ? "" : (isEditing ? "Edit Shift" : "Log Shift"))
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
                        // The whole flow — Cash through Servers — is reachable
                        // without a hand ever leaving the bottom of the screen:
                        // Next cycles every numberPad field in the sheet, and
                        // Save/Done sits right beside it so a rushed one-handed
                        // log never has to reach up to the nav bar.
                        if let focusedCurrencyField {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Next") {
                                    self.focusedCurrencyField = nextFocusField(after: focusedCurrencyField)
                                }
                                Button(isEditing ? "Done" : "Save") {
                                    if isEditing {
                                        dismiss()
                                    } else {
                                        saveNew()
                                    }
                                }
                                .disabled(!isEditing && !canSave)
                            }
                        }
                    }
                }
                .onChange(of: cashCents) { _, _ in liveSaveEdit() }
                .onChange(of: creditCents) { _, _ in liveSaveEdit() }
                .onChange(of: date) { _, _ in liveSaveEdit() }
                .onChange(of: note) { _, _ in liveSaveEdit() }
                .onChange(of: hoursWorked) { _, _ in liveSaveEdit() }
                .onChange(of: tipOutCents) { _, _ in liveSaveEdit() }
                .onChange(of: salesCents) { _, _ in liveSaveEdit() }
                .onChange(of: shiftPeriod) { _, _ in liveSaveEdit() }
                .onChange(of: clockIn) { _, _ in
                    if clockIn != nil, clockOut != nil { hoursWorked = ShiftTimes.hours(clockIn: clockIn, clockOut: clockOut) }
                    liveSaveEdit()
                }
                .onChange(of: clockOut) { _, _ in
                    if clockIn != nil, clockOut != nil { hoursWorked = ShiftTimes.hours(clockIn: clockIn, clockOut: clockOut) }
                    liveSaveEdit()
                }
                .onChange(of: serverCount) { _, _ in liveSaveEdit() }
                .onChange(of: focusedCurrencyField) { _, newField in
                    guard let newField else { return }
                    withAnimation(PaydayAnimation.premiumSpring) {
                        proxy.scrollTo(newField, anchor: .center)
                    }
                }
                .onAppear { seedShiftDetailDefaults() }
                .onDisappear { pruneZeroedRows() }
            }
        }
        // Fixed height for the common case, plus .large as an escape hatch so
        // content is never clipped on smaller iPhones with the keypad up.
        // Taller than before now that shiftDetailsCard is always expanded —
        // Shift/Started/Ended/Tip-out need to be visible without a scroll.
        // Screenshot/QA hook: -DebugNoAutoFocus also opens straight to the
        // .large detent, so the full scrollable sheet is visible without
        // needing a drag gesture to expand it.
        .presentationDetents(debugSuppressAutoFocus ? [.large] : [.height(isEditing ? 560 : 600), .large])
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

    // MARK: Shift total — cash + credit together, new or edit alike

    private var shiftAmountContent: some View {
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
                // Live $/hr, computed as the fields change — and NET of any
                // tip-out, by product ruling: a tip-out is recorded because
                // it's an important fact, but it is never income. Not in
                // your total, not in your hourly, not in anything that
                // means you keep the money. Only appears once the shift has
                // a length (times set, or legacy hours).
                if let hoursWorked, hoursWorked > 0 {
                    let netCents = cashCents + creditCents - tipOutCents
                    if netCents > 0 {
                        let rateCentsPerHour = Int((Double(netCents) / hoursWorked).rounded())
                        Text(tipOutCents > 0
                             ? "\(Money.wholeDollarString(fromCents: rateCentsPerHour))/hr after tip-out"
                             : "\(Money.wholeDollarString(fromCents: rateCentsPerHour))/hr")
                            .font(PaydayFont.caption)
                            .monospacedDigit()
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                }
            }

            VStack(spacing: 12) {
                // The debug hooks below (-DebugFocusTipOut/-DebugFocusServers)
                // exist to screenshot ONE specific field focused above the
                // keyboard — Cash's own default autofocus would otherwise
                // race it, since both fire from an onAppear and whichever
                // view happens to mount last wins. Deferring to the debug
                // hooks here makes that deterministic instead of luck.
                CurrencyAmountRow(label: "Cash", cents: $cashCents, field: .cash, focusedField: $focusedCurrencyField, autoFocus: !isEditing && !prefersCreditFirst && !debugAutoFocusTipOut && !debugAutoFocusServers)
                    .id(CurrencyRowField.cash)
                CurrencyAmountRow(label: "Credit", cents: $creditCents, field: .credit, focusedField: $focusedCurrencyField, autoFocus: !isEditing && prefersCreditFirst && !debugAutoFocusTipOut && !debugAutoFocusServers)
                    .id(CurrencyRowField.credit)
            }
            .padding(.horizontal)
        }
    }

    /// Next always cycles Cash -> Credit -> Tip-out -> Sales -> Servers ->
    /// back to Cash. The shift-details card is always visible now (no
    /// disclosure to open first), so every field is reachable every time.
    private func nextFocusField(after field: CurrencyRowField) -> CurrencyRowField {
        switch field {
        case .cash: return .credit
        case .credit: return .tipOut
        case .tipOut: return .sales
        case .sales: return .servers
        case .servers: return .cash
        }
    }

    // MARK: Shift details — the facts that define this closeout

    /// The shift's own identity and economics — date, period, times,
    /// tip-out, sales, headcount — sit closest to the money and are always
    /// visible now: no disclosure to tap through, no toggle to remember
    /// whether a row is holding a real value. Never required: leaving
    /// every row at its default logs exactly what the app always logged.
    /// Date answers "which day"; Shift period drives the Started/Ended
    /// "Set" buttons' time defaults right below it.
    private var shiftDetailsCard: some View {
        card {
            VStack(spacing: 0) {
                HStack {
                    Text("Date")
                    Spacer()
                    DatePicker("", selection: $date, in: ...Date.now, displayedComponents: .date)
                        .labelsHidden()
                }
                .padding(.vertical, 14)
                Divider()
                // Lunch or dinner — the defining period of this one
                // closeout. A "double" isn't a toggle anymore: you just log
                // a second shift for the day, and the two closeouts make
                // the double.
                HStack {
                    Text("Shift")
                    Spacer()
                    Picker("", selection: $shiftPeriod) {
                        Text("Lunch").tag(ShiftPeriod?.some(.lunch))
                        Text("Dinner").tag(ShiftPeriod?.some(.dinner))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .labelsHidden()
                }
                .padding(.vertical, 14)
                Divider()
                HStack {
                    Text("Started")
                    Spacer()
                    if clockIn != nil {
                        DatePicker("", selection: clockInBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    } else {
                        Button("Set") { clockIn = defaultClockIn }
                    }
                }
                .padding(.vertical, 14)
                Divider()
                HStack {
                    Text("Ended")
                    Spacer()
                    if clockOut != nil {
                        DatePicker("", selection: clockOutBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    } else {
                        Button("Set") { clockOut = defaultClockOut }
                    }
                }
                .padding(.vertical, 14)
                if let hoursWorked {
                    Text("That's \(Self.hoursLabel(hoursWorked)).")
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .padding(.top, 8)
                }
                Divider().padding(.top, 14)
                HStack {
                    Text("Tip-out")
                    Spacer()
                    CompactCurrencyField(cents: $tipOutCents, field: .tipOut, focusedField: $focusedCurrencyField, autoFocus: debugAutoFocusTipOut, placeholderCents: tipOutPlaceholderCents)
                }
                .padding(.vertical, 14)
                .id(CurrencyRowField.tipOut)
                Divider()
                HStack {
                    Text("Sales")
                    Spacer()
                    CompactCurrencyField(cents: $salesCents, field: .sales, focusedField: $focusedCurrencyField, placeholderCents: salesPlaceholderCents)
                }
                .padding(.vertical, 14)
                .id(CurrencyRowField.sales)
                Divider()
                // Capture-only, no engine analysis yet — how many servers
                // were on the floor changes section size and split
                // economics, worth having on record before there's enough
                // history to actually say something about it. A count is a
                // number, so it uses the same typed-field language as
                // Tip-out and Sales right above it, not a different kind
                // of control for what's really the same kind of fact.
                HStack {
                    Text("Servers")
                    Spacer()
                    CompactCountField(count: serverCountBinding, field: .servers, focusedField: $focusedCurrencyField, autoFocus: debugAutoFocusServers, placeholderCount: serversPlaceholderCount)
                }
                .padding(.vertical, 14)
                .id(CurrencyRowField.servers)
            }
            .padding()
            .tint(PaydayColor.textPrimary)
        }
    }

    // MARK: Note — bookkeeping, not a shift-defining fact

    /// The least important input on the whole sheet, by design: a place to
    /// remember something in a sentence, nothing more. Everything that
    /// actually defines the shift lives in shiftDetailsCard above, closer
    /// to the money.
    private var noteCard: some View {
        card {
            HStack {
                Text("Note")
                Spacer()
                TextField("Optional", text: $note)
                    .multilineTextAlignment(.trailing)
            }
            .padding()
        }
    }

    /// Lunch defaults to an 11am start; dinner (or no period set yet)
    /// defaults to 5pm — a sensible first guess rather than "now," which
    /// would be wrong for a backfilled past day.
    private var defaultClockIn: Date {
        let hour = shiftPeriod == .lunch ? 11 : 17
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
    }

    /// Lunch defaults to a 4pm end; dinner (or nil) defaults to 11pm.
    private var defaultClockOut: Date {
        let hour = shiftPeriod == .lunch ? 16 : 23
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
    }

    private var clockInBinding: Binding<Date> {
        Binding(get: { clockIn ?? defaultClockIn }, set: { clockIn = $0 })
    }

    private var clockOutBinding: Binding<Date> {
        Binding(get: { clockOut ?? defaultClockOut }, set: { clockOut = $0 })
    }

    /// Same zero-means-nil sentinel used elsewhere in this file (see
    /// clockInBinding/clockOutBinding): typing back down to 0 — or an
    /// empty field, which CompactCountField reads as 0 — clears the fact
    /// instead of committing "zero servers."
    private var serverCountBinding: Binding<Int> {
        Binding(
            get: { serverCount ?? 0 },
            set: { serverCount = $0 > 0 ? $0 : nil }
        )
    }

    /// Screenshot/QA hook only: lets a launch argument force the keyboard
    /// up over the Tip-out field so the expanded+keyboard layout state can
    /// be verified without a UI automation tool to tap into it.
    private var debugAutoFocusTipOut: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-DebugFocusTipOut")
        #else
        false
        #endif
    }

    /// Same reasoning as debugAutoFocusTipOut, for the Servers field.
    private var debugAutoFocusServers: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-DebugFocusServers")
        #else
        false
        #endif
    }

    /// Screenshot/QA hook only: lets a launch argument suppress the edit
    /// flow's default amount-field autofocus, so the full sheet — details
    /// group included — can be screenshotted without the keyboard covering
    /// whatever's below the fold.
    private var debugSuppressAutoFocus: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-DebugNoAutoFocus")
        #else
        false
        #endif
    }

    private static func hoursLabel(_ hours: Double) -> String {
        // Quarter-hour precision, matching what ShiftTimes computes from the
        // Started/Ended pair — a 9:30-5:15 shift must caption as 7.75, not
        // round itself up to 8 while the times right above say otherwise.
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
        // Apple's own guidance: ask for notification permission at a moment
        // of actual relevant value, not on launch before anyone's seen
        // anything worth being reminded about. The first shift ever logged
        // is that moment. `allEntries` still reflects state from before
        // this save's inserts land below (SwiftData's @Query hasn't
        // refreshed mid-call), so isEmpty here means genuinely the first.
        let isFirstShiftEver = allEntries.isEmpty
        // Clamp to today: the picker already blocks future dates, but never
        // trust the initial/bound value to enforce it.
        let normalizedDate = Calendar.current.startOfDay(for: min(date, .now))
        let trimmedNote = note.isEmpty ? nil : note
        let recordedAt = Date.now
        let totalCents = cashCents + creditCents
        let effectiveTipOutCents = tipOutCents > 0 ? tipOutCents : nil
        let effectiveSalesCents = salesCents > 0 ? salesCents : nil
        let netTotalCents = totalCents - (effectiveTipOutCents ?? 0)

        // One id ties this closeout's cash and credit rows into one shift.
        // Logging again the same day mints a fresh id — that's how a double
        // (two closeouts) emerges, with no toggle.
        let shiftID = UUID()

        let statsEngine = StatsEngine(records: allEntries.map(TipRecord.init))
        let calculator = PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
        let period = calculator.period(containing: normalizedDate)
        // Reveal always speaks in net — the same rule StatsEngine applies to
        // every other analytical total. Passing this shift's id lets the
        // reveal compare it against the day's other shift (if any) rather
        // than excluding the whole day.
        let reveal = statsEngine.reveal(forNightAt: normalizedDate, cents: netTotalCents, period: period, hoursWorked: hoursWorked, shiftID: shiftID)

        var newEntries: [TipEntry] = []
        if cashCents > 0 {
            let entry = TipEntry(date: normalizedDate, amountCents: cashCents, kind: .cash, note: trimmedNote, recordedAt: recordedAt, shiftID: shiftID)
            modelContext.insert(entry)
            newEntries.append(entry)
        }
        if creditCents > 0 {
            let entry = TipEntry(date: normalizedDate, amountCents: creditCents, kind: .credit, note: trimmedNote, recordedAt: recordedAt, shiftID: shiftID)
            modelContext.insert(entry)
            newEntries.append(entry)
        }
        // Shift-level details land on one canonical entry (credit
        // preferred), never split across both — see ShiftDetails.
        ShiftDetails.write(hoursWorked: hoursWorked, tipOutCents: effectiveTipOutCents, salesCents: effectiveSalesCents, shiftPeriod: shiftPeriod, clockIn: clockIn, clockOut: clockOut, serverCount: serverCount, into: newEntries)

        revealResult = reveal
        revealGrossAndTipOut = effectiveTipOutCents.map { (grossCents: totalCents, tipOutCents: $0) }
        // Tonight is logged — cancel tonight's nudge and queue the next
        // usual night's instead. allEntries' @Query hasn't necessarily
        // refreshed within this same call, so the just-inserted entries
        // are appended explicitly rather than relied on to already be in it.
        SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries + newEntries)
        if isFirstShiftEver {
            Task { await SmartNudgeScheduler.requestAuthorizationIfNeeded() }
        }
        PaydayWidgetRefresh.request()
    }

    /// Edit flow: every field change writes straight through to the shift.
    /// Routine, reversible edits stay silent — no haptic on every keystroke.
    /// Cash and credit are now each their own row across the whole shift
    /// (not one entry's amount+kind), so this reconciles the shift's actual
    /// rows against the two on-screen totals: an existing row gets its
    /// amount updated (or zeroed, or deleted if it's not the anchor), and a
    /// kind with no existing row yet gets a fresh one inserted.
    private func liveSaveEdit() {
        guard case .edit(let anchor) = target else { return }
        var rows = sameShiftEntries(around: anchor)
        guard rows.contains(where: { $0.id == anchor.id }) else { return }
        let normalizedDate = Calendar.current.startOfDay(for: min(date, .now))
        let trimmedNote = note.isEmpty ? nil : note
        for kind in [TipKind.cash, .credit] {
            let cents = kind == .cash ? cashCents : creditCents
            if let row = rows.first(where: { $0.kind == kind }) {
                if cents > 0 || row.id == anchor.id || rows.count == 1 {
                    row.amountCents = cents          // never delete the anchor mid-edit
                } else {
                    modelContext.delete(row)          // non-anchor row zeroed out
                    rows.removeAll { $0.id == row.id }
                }
            } else if cents > 0 {
                let newRow = TipEntry(date: normalizedDate, amountCents: cents, kind: kind, note: trimmedNote, recordedAt: .now, shiftID: anchor.shiftID)
                modelContext.insert(newRow)
                rows.append(newRow)
            }
        }
        for row in rows { row.date = normalizedDate; row.note = trimmedNote }

        // Shift-level details land on the shift's one canonical entry
        // (credit preferred, same convention as saveNew) and get cleared
        // from every other entry in the shift — self-healing any shift
        // that ended up with a value split across both entries.
        ShiftDetails.write(
            hoursWorked: hoursWorked,
            tipOutCents: tipOutCents > 0 ? tipOutCents : nil,
            salesCents: salesCents > 0 ? salesCents : nil,
            shiftPeriod: shiftPeriod,
            clockIn: clockIn,
            clockOut: clockOut,
            serverCount: serverCount,
            into: rows
        )

        PaydayWidgetRefresh.request()
    }

    /// A row that got zeroed out mid-edit (cash typed down to 0 while
    /// credit carries the shift, say) is deleted immediately by
    /// liveSaveEdit's reconciliation above — but the anchor itself is
    /// deliberately never deleted while its sheet is still open, so this
    /// sweeps it up too if it's the one left holding a zero when the sheet
    /// closes. Always leaves at least one row behind.
    private func pruneZeroedRows() {
        guard case .edit(let anchor) = target else { return }
        let rows = sameShiftEntries(around: anchor)
        guard rows.count > 1 else { return }
        let zeroed = rows.filter { $0.amountCents == 0 }
        guard zeroed.count < rows.count else {
            // Every row is zero — keep the first so the shift isn't silently
            // erased out from under the person who just closed the sheet.
            for row in zeroed.dropFirst() { modelContext.delete(row) }
            return
        }
        for row in zeroed { modelContext.delete(row) }
    }

    private func delete() {
        if case .edit(let entry) = target {
            for row in sameShiftEntries(around: entry) {
                modelContext.delete(row)
            }
        }
        PaydayWidgetRefresh.request()
        dismiss()
    }
}

/// A small cents field for the optional shift-details group — same
/// digit-shift-from-the-right technique as CurrencyAmountRow, including its
/// focused-ring treatment (scaled down to fit inline in a row) and the same
/// externally-driven FocusState (so the keyboard toolbar's Next button can
/// cycle through Tip-out and Sales too, not just Cash/Credit). See
/// CompactCountField just below for the plain-integer sibling this powers
/// (Servers).
private struct CompactCurrencyField: View {
    @Binding var cents: Int
    let field: CurrencyRowField
    var focusedField: FocusState<CurrencyRowField?>.Binding
    var autoFocus: Bool = false
    /// A same-weekday suggestion, shown only while cents == 0 — a hint to
    /// tap into, never a value that saves on its own. See LogTipSheet's
    /// seedShiftDetailDefaults: pre-filling this straight into `cents` used
    /// to let a rushed Save silently attach last Friday's tip-out to
    /// tonight.
    var placeholderCents: Int? = nil
    @State private var digitsText: String = ""

    private static let maxDigits = 7
    private var isFocused: Bool { focusedField.wrappedValue == field }

    var body: some View {
        ZStack(alignment: .trailing) {
            if cents == 0, let placeholderCents {
                // Tertiary, not secondary — a hint reads visibly softer than
                // an honest zero, so it's never mistaken for a real number.
                Text(Money.string(fromCents: placeholderCents))
                    .font(PaydayFont.body)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textTertiary)
                    .accessibilityHidden(true)
            } else {
                Text(Money.string(fromCents: cents))
                    .font(PaydayFont.body)
                    .monospacedDigit()
                    .foregroundStyle(cents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
            }
            TextField("", text: $digitsText)
                .keyboardType(.numberPad)
                .focused(focusedField, equals: field)
                .opacity(0.01)
                .multilineTextAlignment(.trailing)
                .accessibilityValue(Money.string(fromCents: cents))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 92, alignment: .trailing)
        .overlay(
            RoundedRectangle(cornerRadius: PaydayRadius.sm)
                .strokeBorder(isFocused ? PaydayColor.primary : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusedField.wrappedValue = field }
        .onAppear {
            digitsText = cents == 0 ? "" : String(cents)
            if autoFocus { focusedField.wrappedValue = field }
        }
        .onChange(of: digitsText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(Self.maxDigits))
            if filtered != newValue { digitsText = filtered }
            cents = Int(filtered) ?? 0
        }
    }
}

/// CompactCurrencyField's plain-integer sibling — same digit-shift field,
/// same focus-ring and externally-driven FocusState, same placeholder
/// treatment, but for a count rather than money: no currency formatting,
/// no unit suffix (the row's own label already says "Servers"), capped at
/// 2 digits. A count reads as a fact worth stating plainly or not at all —
/// unlike an amount, which always shows $0.00 even unset, a count with
/// neither a real value nor a placeholder shows nothing rather than a
/// misleading "0" (a real "worked with zero servers" fact this app has no
/// way to distinguish from "never asked" if it rendered the same as unset).
private struct CompactCountField: View {
    @Binding var count: Int
    let field: CurrencyRowField
    var focusedField: FocusState<CurrencyRowField?>.Binding
    var autoFocus: Bool = false
    var placeholderCount: Int? = nil
    @State private var digitsText: String = ""

    private static let maxDigits = 2
    private var isFocused: Bool { focusedField.wrappedValue == field }

    var body: some View {
        ZStack(alignment: .trailing) {
            if count == 0, let placeholderCount {
                Text("\(placeholderCount)")
                    .font(PaydayFont.body)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textTertiary)
                    .accessibilityHidden(true)
            } else if count > 0 {
                Text("\(count)")
                    .font(PaydayFont.body)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
            }
            TextField("", text: $digitsText)
                .keyboardType(.numberPad)
                .focused(focusedField, equals: field)
                .opacity(0.01)
                .multilineTextAlignment(.trailing)
                .accessibilityValue(count == 0 ? "Not logged" : "\(count)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 92, alignment: .trailing)
        .overlay(
            RoundedRectangle(cornerRadius: PaydayRadius.sm)
                .strokeBorder(isFocused ? PaydayColor.primary : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusedField.wrappedValue = field }
        .onAppear {
            digitsText = count == 0 ? "" : String(count)
            if autoFocus { focusedField.wrappedValue = field }
        }
        .onChange(of: digitsText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(Self.maxDigits))
            if filtered != newValue { digitsText = filtered }
            count = Int(filtered) ?? 0
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
