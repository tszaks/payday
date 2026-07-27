import SwiftUI
import SwiftData
import UIKit

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

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
    /// Set once, at appearance, when LiveShiftEndModeResolver decides this
    /// blank `.new` sheet exists to close out the shift already running —
    /// every creation path (the + tab, the widget, quick actions, deep
    /// links) funnels through here rather than each knowing about live
    /// sessions itself. Saving in this state ends the session; cancelling
    /// leaves it running untouched.
    @State private var isEndingLiveShift = false
    /// Cancel-while-ending disambiguation — see the Cancel button.
    @State private var isShowingEndShiftCancelDialog = false
    /// Captured alongside isEndingLiveShift, independent of the editable
    /// `clockIn` field below — the caption always names the shift's real
    /// start even if Started gets hand-edited before Save.
    @State private var liveShiftStartedAt: Date?
    /// Creation-mode only: which card of the deck is centered. nil never
    /// happens in practice — it's Optional only because that's what
    /// `.scrollPosition(id:)` requires — so `?? .tips` is the only place
    /// that needs to unwrap it. Editing never touches this; the classic
    /// form has no deck.
    @State private var currentCardStep: CardFlowStep? = .tips
    /// The TIPS card's date pill starts collapsed — creation defaults to
    /// today and never asks, so the DatePicker underneath is a rare,
    /// deliberate reveal for backdating, not a default-open control.
    @State private var isBackdatePickerExpanded = false

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
        case .new(let defaultDate, let seedClockIn, let seedClockOut):
            _date = State(initialValue: defaultDate)
            _note = State(initialValue: "")
            // Every shift is different — lunch/dinner is never guessed from
            // the clock. It stays unset until the SHIFT card is tapped.
            // A just-ended live shift session already knows its exact
            // punches — seed Started/Ended from them directly, same as if
            // the pickers had been set by hand.
            _clockIn = State(initialValue: seedClockIn)
            _clockOut = State(initialValue: seedClockOut)
            if let seedClockIn, let seedClockOut {
                _hoursWorked = State(initialValue: ShiftTimes.hours(clockIn: seedClockIn, clockOut: seedClockOut))
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

    /// The header figure: cash + credit, net of tip-out, plus this shift's
    /// base-rate wages — the same "total = cash + credit - tip-out + wages"
    /// law every other shift/day surface in the app now follows. Live as
    /// every field changes, same as the header always was. Math lives in
    /// WageEstimate.shiftTotalCents so it's testable independent of this view.
    private var shiftTotalCents: Int {
        WageEstimate.shiftTotalCents(cashCents: cashCents, creditCents: creditCents, tipOutCents: tipOutCents, wageCentsPerHour: preferencesStore.baseHourlyWageCents, hoursWorked: hoursWorked)
    }

    /// A server who's never once logged cash and has enough credit history
    /// to call it a pattern gets the credit field focused first instead of
    /// the usual cash-first default.
    private var prefersCreditFirst: Bool {
        let hasCash = allEntries.contains { $0.kind == .cash }
        let creditCount = allEntries.filter { $0.kind == .credit }.count
        return !hasCash && creditCount >= 3
    }

    /// Runs once at appearance, before seedShiftDetailDefaults — resolves
    /// the live session's exact punches into clockIn/clockOut/hoursWorked
    /// when this blank `.new` sheet exists to close out a running shift.
    private func applyLiveShiftEndModeIfNeeded() {
        guard case .new(_, let providedClockIn, let providedClockOut) = target else { return }
        guard let mode = LiveShiftEndModeResolver.resolve(
            isEditing: isEditing,
            providedClockIn: providedClockIn,
            providedClockOut: providedClockOut,
            activeStart: ShiftSessionState.shared.activeStart
        ) else { return }
        clockIn = mode.clockIn
        clockOut = mode.clockOut
        hoursWorked = ShiftTimes.hours(clockIn: mode.clockIn, clockOut: mode.clockOut)
        liveShiftStartedAt = mode.clockIn
        isEndingLiveShift = true
    }

    /// Pulled out of the view body's onAppear closure — inlining this much
    /// logic directly in a chained-modifier closure was slow enough to trip
    /// the type checker's time budget. Edit only: a new shift starts from a
    /// genuinely blank slate now (no weekday-typical seeding — every shift
    /// is different).
    private func seedShiftDetailDefaults() {
        guard case .edit(let entry) = target else { return }
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

    /// Edit mode keeps the classic full form, top to bottom by a deliberate
    /// hierarchy: MONEY first (shiftAmountContent — the reason the sheet
    /// exists at all), then the shift's own defining facts and economics
    /// (shiftDetailsCard — when, which shift, what times, what tip-out and
    /// sales), then bookkeeping (noteCard — the least important input on
    /// the whole sheet), and destructive last (Delete Shift). Every row
    /// below money is optional; nothing here is ever nagged for. Creation
    /// mode replaces all of that with creationCardDeck — one question per
    /// card instead of every field at once.
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
                        RevealCardView(result: revealResult, period: shiftPeriod, grossAndTipOut: revealGrossAndTipOut, onDismiss: { dismiss() })
                    } else if isEditing {
                        // Scrollable rather than a fixed VStack: the keypad
                        // coming up used to compress every row toward zero
                        // height badly enough that the amount could render
                        // overlapping the nav title. A ScrollView absorbs
                        // that extra height by scrolling instead of
                        // squeezing, keeps the header stable in every state,
                        // and (with the system's own keyboard avoidance)
                        // keeps a focused field visible above the keyboard
                        // automatically.
                        ScrollView {
                            VStack(spacing: 24) {
                                shiftAmountContent
                                shiftDetailsCard
                                noteCard

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
                            .padding(.top, 20)
                            .padding(.bottom, 32)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    } else {
                        creationCardDeck
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
                                // Cancel while closing out a LIVE shift is
                                // ambiguous — three intents hide behind one
                                // button (Mail's discard-draft problem), so it
                                // asks. A normal log sheet's Cancel stays
                                // instant: no timer at stake, no dialog.
                                Button("Cancel") {
                                    if isEndingLiveShift {
                                        isShowingEndShiftCancelDialog = true
                                    } else {
                                        dismiss()
                                    }
                                }
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
                                if isEditing {
                                    if let next = nextFocusField(after: focusedCurrencyField) {
                                        Button("Next") {
                                            PaydayHaptics.selection()
                                            self.focusedCurrencyField = next
                                        }
                                    }
                                    Button("Done") { dismiss() }
                                } else {
                                    Button("Next") { advanceFromCreationKeyboard(focusedCurrencyField) }
                                    Button("Save") { saveNew() }
                                        .disabled(!canSave)
                                }
                            }
                        }
                    }
                }
                // An alert, deliberately not a confirmationDialog: anchored
                // to a toolbar button, a confirmation dialog presents as a
                // popover that hides the cancel option behind tap-outside.
                // The centered box shows all three intents explicitly.
                .alert("End shift?", isPresented: $isShowingEndShiftCancelDialog) {
                    Button("End Shift Without Saving", role: .destructive) {
                        Task {
                            await ShiftSessionManager.end(stashPendingEnd: false)
                            dismiss()
                        }
                    }
                    Button("Continue Shift") { dismiss() }
                    Button("Keep Logging", role: .cancel) {}
                } message: {
                    Text("You're still on the clock.")
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
                .onAppear {
                    applyLiveShiftEndModeIfNeeded()
                    seedShiftDetailDefaults()
                }
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
                Text(Money.string(fromCents: shiftTotalCents))
                    .font(PaydayFont.displayXL)
                    .monospacedDigit()
                    .foregroundStyle(shiftTotalCents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: shiftTotalCents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                // Take-home is pure mechanics — cash + credit, net of
                // tip-out, before wages — and needs no hours logged to say
                // something true, unlike the $/hr clause right below it.
                if tipOutCents > 0 {
                    Text("\(Money.string(fromCents: cashCents + creditCents - tipOutCents)) take-home after tip-out")
                        .font(PaydayFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(PaydayColor.textSecondary)
                }
                // Live $/hr, computed as the fields change, off the same
                // all-in numerator as the total above (net of tip-out, plus
                // wages) — a tip-out is recorded because it's an important
                // fact, but it is never income; wages are income, so they
                // belong in the rate same as they belong in the total.
                // Only appears once the shift has a length (times set, or
                // legacy hours).
                if let hoursWorked, hoursWorked > 0 {
                    if shiftTotalCents > 0 {
                        let rateCentsPerHour = Int((Double(shiftTotalCents) / hoursWorked).rounded())
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

    /// Edit mode's classic form only: Next cycles Cash -> Credit -> Tip-out
    /// -> Sales -> Servers -> back to Cash, since every field is on screen
    /// at once. Creation mode's fields are split one-per-card, so its Next
    /// advances the card instead — see advanceFromCreationKeyboard below.
    private func nextFocusField(after field: CurrencyRowField) -> CurrencyRowField? {
        switch field {
        case .cash: return .credit
        case .credit: return .tipOut
        case .tipOut: return .sales
        case .sales: return .servers
        case .servers: return .cash
        }
    }

    /// Creation mode's keyboard-toolbar Next. Cash -> Credit stays a
    /// same-card focus hop (both live on the TIPS card). Tip-out -> Sales
    /// and Sales -> Servers advance the card AND carry focus to the next
    /// card's own field, so the numberPad never has to be dismissed and
    /// re-summoned crossing a card boundary — same "hand never leaves the
    /// bottom" reachability the rest of the sheet already has. Credit and
    /// Servers are each the last currency field before a card with no
    /// keypad (SHIFT, NOTE), so those just advance and let focus clear.
    private func advanceFromCreationKeyboard(_ field: CurrencyRowField) {
        switch field {
        case .cash:
            PaydayHaptics.selection()
            focusedCurrencyField = .credit
        case .credit, .servers:
            focusedCurrencyField = nil
            advanceCard()
        case .tipOut:
            advanceCard()
            focusedCurrencyField = .sales
        case .sales:
            advanceCard()
            focusedCurrencyField = .servers
        }
    }

    // MARK: Shift details — the facts that define this closeout (edit mode)

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
                if isEndingLiveShift, let liveShiftStartedAt {
                    Text("Ending the shift you started at \(liveShiftStartedAt.formatted(.dateTime.hour().minute())).")
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textTertiary)
                        .padding(.top, 4)
                }
                if let hoursWorked {
                    // Base rate only — overtime is a weekly calculation that
                    // can't be attributed to a single shift, so this caption
                    // never claims OT.
                    if let wageCents = WageEstimate.cents(wageCentsPerHour: preferencesStore.baseHourlyWageCents, hours: hoursWorked) {
                        Text("That's \(WageEstimate.hoursLabel(hoursWorked)). \(Money.string(fromCents: wageCents)) in wages.")
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .padding(.top, 8)
                    } else {
                        Text("That's \(WageEstimate.hoursLabel(hoursWorked)).")
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .padding(.top, 8)
                    }
                }
                Divider().padding(.top, 14)
                HStack {
                    Text("Tip-out")
                    Spacer()
                    CompactCurrencyField(cents: $tipOutCents, field: .tipOut, focusedField: $focusedCurrencyField, autoFocus: debugAutoFocusTipOut)
                }
                .padding(.vertical, 14)
                .id(CurrencyRowField.tipOut)
                Divider()
                HStack {
                    Text("Sales")
                    Spacer()
                    CompactCurrencyField(cents: $salesCents, field: .sales, focusedField: $focusedCurrencyField)
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
                    CompactCountField(count: serverCountBinding, field: .servers, focusedField: $focusedCurrencyField, autoFocus: debugAutoFocusServers)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Note")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                TextField("Optional", text: $note, axis: .vertical)
                    .lineLimit(2...6)
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

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(PaydayColor.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: PaydayRadius.lg))
            .padding(.horizontal)
    }

    // MARK: Creation-mode card deck
    //
    // SANCTIONED EXCEPTION to docs/DESIGN.md's "card-in-sheet is always
    // wrong" elevation rule: Tyler (the design law's author) ordered a
    // card-based entry flow for creation specifically, and the override is
    // scoped to exactly the seven cards below (deckCard's chrome). Every
    // other sheet in the app still follows the no-card-in-sheet rule.

    /// The lifted, focused surface every deck card sits on — fieldBackground
    /// rather than a true elevated card, generous padding, one question at a
    /// time. See the SANCTIONED EXCEPTION note above.
    private func deckCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) { content() }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaydayColor.fieldBackground, in: RoundedRectangle(cornerRadius: PaydayRadius.xl, style: .continuous))
    }

    private func kickerLabel(_ text: String) -> some View {
        Text(text)
            .font(PaydayFont.caption)
            .foregroundStyle(PaydayColor.textSecondary)
            .tracking(0.6)
    }

    /// A horizontally paged carousel, poker-deck style: the active card
    /// centered, neighbors peeking at the edges (contentMargins plus each
    /// card leaving room on both sides). Swiping always works for review —
    /// it only ever moves which card is centered, never a value underneath.
    private var creationCardDeck: some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                let cardWidth = max(geometry.size.width - 32, 200)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(CardFlowStep.allCases) { step in
                            cardView(for: step)
                                .frame(width: cardWidth)
                                // The lift-and-slide: scale up slightly while
                                // sliding out/in — one motion driven by the
                                // scroll offset itself, whether that offset
                                // moved from a finger drag or advanceCard's
                                // animated scrollPosition change. Reduce
                                // Motion drops the scale, leaving opacity as
                                // the only cue.
                                .scrollTransition(axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(reduceMotion || phase.isIdentity ? 1 : 1.03)
                                        .opacity(phase.isIdentity ? 1 : 0.9)
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("\(step.accessibilityTitle), card \(step.rawValue + 1) of \(CardFlowStep.allCases.count)")
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $currentCardStep)
                .contentMargins(.horizontal, 16, for: .scrollContent)
            }
            .frame(height: 400)

            // Sighted-only progress cue — not independently tappable (a tap
            // gesture here would fight the page view's own drag recognizer).
            HStack(spacing: 8) {
                ForEach(CardFlowStep.allCases) { step in
                    Circle()
                        .fill((currentCardStep ?? .tips) == step ? PaydayColor.primary : PaydayColor.fieldBackground)
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func cardView(for step: CardFlowStep) -> some View {
        switch step {
        case .tips: tipsCard
        case .shift: shiftCard
        case .times: timesCard
        case .tipOut: tipOutCard
        case .sales: salesCard
        case .servers: serversCard
        case .note: noteDeckCard
        }
    }

    private var tipsCard: some View {
        deckCard {
            kickerLabel(CardFlowStep.tips.kicker)
            datePill
            VStack(spacing: 12) {
                CurrencyAmountRow(label: "Cash", cents: $cashCents, field: .cash, focusedField: $focusedCurrencyField, autoFocus: !prefersCreditFirst && !debugAutoFocusTipOut && !debugAutoFocusServers)
                CurrencyAmountRow(label: "Credit", cents: $creditCents, field: .credit, focusedField: $focusedCurrencyField, autoFocus: prefersCreditFirst && !debugAutoFocusTipOut && !debugAutoFocusServers)
            }
        }
    }

    /// Collapsed by default — creation defaults to today and never asks;
    /// this is the one deliberate, rare escape hatch for backdating.
    private var datePill: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if reduceMotion {
                    isBackdatePickerExpanded.toggle()
                } else {
                    withAnimation(PaydayAnimation.drawerSpring) {
                        isBackdatePickerExpanded.toggle()
                    }
                }
            } label: {
                Text(ShiftBeliefLine.dateLabel(for: date))
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(PaydayColor.background, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isBackdatePickerExpanded ? "Hide date picker" : "Change the date, for backdating a past shift")

            if isBackdatePickerExpanded {
                DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
        }
    }

    private var shiftCard: some View {
        deckCard {
            kickerLabel(CardFlowStep.shift.kicker)
            Text("Lunch or dinner?")
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
            HStack(spacing: 12) {
                periodButton(.lunch, label: "Lunch")
                periodButton(.dinner, label: "Dinner")
            }
            Button("Next") { advanceCard() }
                .buttonStyle(.glassProminent)
        }
    }

    private func periodButton(_ period: ShiftPeriod, label: String) -> some View {
        let isSelected = shiftPeriod == period
        return Button {
            selectShiftPeriod(period)
        } label: {
            Text(label)
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
        .buttonStyle(.plain)
        .background(PaydayColor.fieldBackground, in: RoundedRectangle(cornerRadius: PaydayRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PaydayRadius.lg)
                .strokeBorder(isSelected ? PaydayColor.primary : PaydayColor.textPrimary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Tapping a period is a real choice, so it gets its own haptic
    /// immediately. The beat before advancing (PaydayAnimation.quickDuration
    /// — the same 150ms token list-item staggers use) lets the selection
    /// ring actually register before the deck moves on; the eventual advance
    /// skips advanceCard's own haptic so this whole gesture reads as one
    /// action, not two. Swiping past this card without tapping either button
    /// never sets shiftPeriod — it stays nil, never guessed.
    private func selectShiftPeriod(_ period: ShiftPeriod) {
        PaydayHaptics.selection()
        shiftPeriod = period
        Task {
            try? await Task.sleep(for: .seconds(PaydayAnimation.quickDuration))
            advanceCard(haptic: false)
        }
    }

    private var timesCard: some View {
        deckCard {
            kickerLabel(CardFlowStep.times.kicker)
            VStack(spacing: 0) {
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
            }
            if isEndingLiveShift, let liveShiftStartedAt {
                Text("Ending the shift you started at \(liveShiftStartedAt.formatted(.dateTime.hour().minute())).")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
            }
            if let hoursWorked {
                // Base rate only — overtime is a weekly calculation that
                // can't be attributed to a single shift, so this caption
                // never claims OT.
                if let wageCents = WageEstimate.cents(wageCentsPerHour: preferencesStore.baseHourlyWageCents, hours: hoursWorked) {
                    Text("That's \(WageEstimate.hoursLabel(hoursWorked)). \(Money.string(fromCents: wageCents)) in wages.")
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                } else {
                    Text("That's \(WageEstimate.hoursLabel(hoursWorked)).")
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
            }
            Button("Next") { advanceCard() }
                .buttonStyle(.glassProminent)
        }
        .tint(PaydayColor.textPrimary)
    }

    private var tipOutCard: some View {
        deckCard {
            kickerLabel(CardFlowStep.tipOut.kicker)
            CurrencyAmountRow(label: "Tip-out", cents: $tipOutCents, field: .tipOut, focusedField: $focusedCurrencyField)
        }
    }

    private var salesCard: some View {
        deckCard {
            kickerLabel(CardFlowStep.sales.kicker)
            CurrencyAmountRow(label: "Sales", cents: $salesCents, field: .sales, focusedField: $focusedCurrencyField)
        }
    }

    private var serversCard: some View {
        deckCard {
            kickerLabel(CardFlowStep.servers.kicker)
            HStack {
                Text("Servers")
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                Spacer()
                CompactCountField(count: serverCountBinding, field: .servers, focusedField: $focusedCurrencyField)
            }
        }
    }

    private var noteDeckCard: some View {
        deckCard {
            kickerLabel(CardFlowStep.note.kicker)
            TextField("Optional", text: $note, axis: .vertical)
                .font(PaydayFont.body)
                .lineLimit(2...6)
            Text(ShiftBeliefLine.compose(date: date, shiftPeriod: shiftPeriod, clockIn: clockIn, clockOut: clockOut, tipOutCents: tipOutCents))
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
                .monospacedDigit()
            Button("Save") { saveNew() }
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
        }
    }

    /// Advances the deck one card via a scroll-position change — the same
    /// mechanism whether triggered by an on-card Next button, the keyboard
    /// toolbar's Next, or the SHIFT card's auto-advance. Deliberately does
    /// nothing to VoiceOver focus: no explicit accessibility-focus call
    /// here, so an auto-advance never steals focus out from under whatever
    /// VoiceOver is mid-announcing.
    private func advanceCard(haptic: Bool = true) {
        guard let current = currentCardStep, let next = CardFlowStep(rawValue: current.rawValue + 1) else { return }
        if haptic { PaydayHaptics.selection() }
        withAnimation(reduceMotion ? .easeInOut(duration: PaydayAnimation.standardDuration) : PaydayAnimation.drawerSpring) {
            currentCardStep = next
        }
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

        // A stand-in id for the reveal's own exclusion check below — the
        // freshly-inserted rows get their own id from ShiftWriter, but since
        // neither id exists among allEntries yet, either one excludes
        // nothing and the comparison comes out identical.
        let shiftID = UUID()

        let statsEngine = StatsEngine(records: allEntries.map(TipRecord.init))
        let calculator = PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
        let period = calculator.period(containing: normalizedDate)
        // Reveal always speaks in net — the same rule StatsEngine applies to
        // every other analytical total. Passing this shift's id lets the
        // reveal compare it against the day's other shift (if any) rather
        // than excluding the whole day.
        let reveal = statsEngine.reveal(forNightAt: normalizedDate, cents: netTotalCents, period: period, hoursWorked: hoursWorked, shiftID: shiftID)

        let newEntries = ShiftWriter.insertShift(
            into: modelContext,
            date: date,
            cashCents: cashCents,
            creditCents: creditCents,
            note: trimmedNote,
            recordedAt: recordedAt,
            hoursWorked: hoursWorked,
            tipOutCents: effectiveTipOutCents,
            salesCents: effectiveSalesCents,
            shiftPeriod: shiftPeriod,
            clockIn: clockIn,
            clockOut: clockOut,
            serverCount: serverCount
        )

        revealResult = reveal
        revealGrossAndTipOut = effectiveTipOutCents.map { (grossCents: totalCents, tipOutCents: $0) }
        // Tonight is logged — cancel tonight's nudge and queue the next
        // usual night's instead. allEntries' @Query hasn't necessarily
        // refreshed within this same call, so the just-inserted entries
        // are appended explicitly rather than relied on to already be in it.
        SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries + newEntries)
        PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, allEntries: allEntries + newEntries, paycheckRecords: paycheckRecords)
        if isFirstShiftEver {
            Task { await SmartNudgeScheduler.requestAuthorizationIfNeeded() }
        }
        PaydayWidgetRefresh.request()

        // This sheet just consumed the live session's exact punches — end it
        // without stashing pendingEnd, or MainTabView's next-foreground pop
        // would present a second, duplicate sheet for the same shift.
        if isEndingLiveShift {
            Task { await ShiftSessionManager.end(stashPendingEnd: false) }
        }
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

/// A small cents field for the optional shift-details group (edit mode's
/// classic form) — same digit-shift-from-the-right technique as
/// CurrencyAmountRow, including its focused-ring treatment (scaled down to
/// fit inline in a row) and the same externally-driven FocusState (so the
/// keyboard toolbar's Next button can cycle through Tip-out and Sales too,
/// not just Cash/Credit). No placeholder of any kind: every shift is
/// different, so an unset amount just shows $0.00, nothing suggested. See
/// CompactCountField just below for the plain-integer sibling this powers
/// (Servers).
private struct CompactCurrencyField: View {
    @Binding var cents: Int
    let field: CurrencyRowField
    var focusedField: FocusState<CurrencyRowField?>.Binding
    var autoFocus: Bool = false
    @State private var digitsText: String = ""

    private static let maxDigits = 7
    private var isFocused: Bool { focusedField.wrappedValue == field }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(Money.string(fromCents: cents))
                .font(PaydayFont.body)
                .monospacedDigit()
                .foregroundStyle(cents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .accessibilityHidden(true)
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
        // Keeps the hidden text field in sync when cents changes from
        // outside typing (edit mode's seedShiftDetailDefaults resolving the
        // shift's real value on appear) — without this, digitsText would
        // silently keep its stale "" and the next keystroke would stomp the
        // resolved value back toward zero.
        .onChange(of: cents) { _, newValue in
            guard Int(digitsText) ?? 0 != newValue else { return }
            digitsText = newValue == 0 ? "" : String(newValue)
        }
    }
}

/// CompactCurrencyField's plain-integer sibling — same digit-shift field,
/// same focus-ring and externally-driven FocusState, but for a count rather
/// than money: no currency formatting, no unit suffix (the row's own label
/// already says "Servers"), capped at 2 digits. A count reads as a fact
/// worth stating plainly or not at all — unlike an amount, which always
/// shows $0.00 even unset, an unset count shows nothing rather than a
/// misleading "0" (a real "worked with zero servers" fact this app has no
/// way to distinguish from "never asked" if it rendered the same as unset).
private struct CompactCountField: View {
    @Binding var count: Int
    let field: CurrencyRowField
    var focusedField: FocusState<CurrencyRowField?>.Binding
    var autoFocus: Bool = false
    @State private var digitsText: String = ""

    private static let maxDigits = 2
    private var isFocused: Bool { focusedField.wrappedValue == field }

    var body: some View {
        ZStack(alignment: .trailing) {
            if count > 0 {
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
    /// The shift's lunch/dinner, when captured — lets the comparison below
    /// name it instead of falling back to the generic "shift".
    let period: ShiftPeriod?
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
            Text(RevealCopy.comparison(for: result.comparison, period: period))
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
        .onAppear {
            let comparison = RevealCopy.comparison(for: result.comparison, period: period)
            UIAccessibility.post(notification: .announcement, argument: "\(RevealCopy.headline(cents: result.cents)) \(comparison)")
        }
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
