import SwiftUI
import SwiftData
import PhotosUI
import OSLog
import UIKit

enum ScanInputSlotState: Equatable {
    case rest
    case analyzing
    case scanned
    case error(String)
}

struct ScanInputLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.viewfinder")
            Text(title)
        }
            .font(PaydayFont.subheadline)
            .foregroundStyle(PaydayColor.primary)
    }
}

struct ScanInputSlot: View {
    let title: String
    let state: ScanInputSlotState
    let onScan: () -> Void
    let onUndo: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Button(action: onScan) {
                ScanInputLabel(title: title)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(state == .rest ? 1 : 0)
            .allowsHitTesting(state == .rest)
            .accessibilityHidden(state != .rest)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Analyzing…")
            }
            .font(PaydayFont.subheadline)
            .foregroundStyle(PaydayColor.textSecondary)
            .opacity(state == .analyzing ? 1 : 0)
            .accessibilityHidden(state != .analyzing)

            HStack(spacing: 4) {
                Text("Scanned ·")
                    .foregroundStyle(PaydayColor.textSecondary)
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain)
                    .foregroundStyle(PaydayColor.primary)
            }
            .font(PaydayFont.subheadline)
            .opacity(state == .scanned ? 1 : 0)
            .allowsHitTesting(state == .scanned)
            .accessibilityHidden(state != .scanned)

            Text(errorMessage)
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.error)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .opacity(isShowingError ? 1 : 0)
                .accessibilityHidden(!isShowingError)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
    }

    private var errorMessage: String {
        if case .error(let message) = state { return message }
        return ""
    }

    private var isShowingError: Bool {
        if case .error = state { return true }
        return false
    }
}

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
    private enum ReceiptScannedField: Hashable {
        case cash
        case credit
        case tipOut
        case sales
        case serverCount
        case receiptMetrics
        case date
        case clockIn
        case clockOut
        case hoursWorked
        case detailsExpanded
    }

    private struct ReceiptScanSnapshot {
        let touched: Set<ReceiptScannedField>
        let cashCents: Int
        let creditCents: Int
        let tipOutCents: Int
        let salesCents: Int
        let serverCount: Int?
        let receiptMetrics: ShiftReceiptMetrics?
        let date: Date
        let clockIn: Date?
        let clockOut: Date?
        let hoursWorked: Double?
        let isDetailsExpanded: Bool
    }

    private static let receiptLogger = Logger(
        subsystem: "com.szakacsmedia.payday",
        category: "ReceiptScanUI"
    )

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
    @State private var showReceiptScanOptions = false
    @State private var showReceiptPhotoPicker = false
    @State private var selectedReceiptPhotoItem: PhotosPickerItem?
    @State private var receiptPhotoSource: ReceiptPhotoSource?
    @State private var isScanningReceipt = false
    @State private var receiptScanSlotState: ScanInputSlotState = .rest
    @State private var receiptScanSnapshot: ReceiptScanSnapshot?
    @State private var receiptScanResetTask: Task<Void, Never>?
    @State private var receiptScanTask: Task<Void, Never>?
    @State private var liveSaveTask: Task<Void, Never>?
    @State private var receiptScanScrollRequest = 0
    // A scanned zero may temporarily zero an existing cash/credit row. Keep
    // that exact row alive while Undo is offered so restoring the scan also
    // restores its identity and recordedAt metadata, not a replacement row.
    @State private var isDeferringReceiptScanRowDeletion = false
    @State private var prefersCreditFirstCache: Bool?
    @FocusState private var focusedCurrencyField: CurrencyRowField?

    // Shared
    @State private var date: Date
    @State private var note: String
    @State private var showDeleteConfirmation = false
    @State private var revealResult: RevealResult?
    /// Whether revealResult.cents contains any non-tip employee income —
    /// wages or Toast mandatory gratuity. Set alongside revealResult so an
    /// all-in number is never mislabeled as "tips."
    @State private var revealIncludesNonTipIncome = false
    /// Set once, at appearance, when LiveShiftEndModeResolver decides this
    /// blank `.new` sheet exists to close out the shift already running —
    /// every creation path (the + tab, the widget, quick actions, deep
    /// links) funnels through here rather than each knowing about live
    /// sessions itself. Saving in this state ends the session; cancelling
    /// leaves it running untouched.
    @State private var isEndingLiveShift = false
    /// Cancel-while-ending disambiguation — see the Cancel button.
    @State private var isShowingEndShiftCancelDialog = false
    /// New-entry only: the details group opens collapsed behind a one-line
    /// belief sentence (ShiftBeliefLine) instead of every row at full volume.
    /// Editing never touches this — that flow keeps the card always open.
    @State private var isDetailsExpanded = false

    // Optional shift details — skippable, never nagged. hoursWorked,
    // tipOutCents, salesCents, shiftPeriod, clockIn, and clockOut are all
    // facts about the SHIFT (one closeout), never one entry or tip type —
    // ShiftDetails is the one place read/write for these six fields is
    // allowed to happen.
    @State private var hoursWorked: Double?
    @State private var tipOutCents: Int = 0
    @State private var salesCents: Int = 0
    @State private var shiftPeriod: ShiftPeriod?
    /// Automatic period inference follows the start time until the person
    /// taps Lunch or Dinner. That tap becomes the explicit override.
    @State private var hasManuallySelectedShiftPeriod = false
    @State private var clockIn: Date?
    @State private var clockOut: Date?
    /// How many servers were on the floor — capture-only for now (see
    /// TipEntry.serverCount), same optional/shift-level treatment as
    /// everything else in this group.
    @State private var serverCount: Int?
    /// Rich facts captured from the end-of-shift printout. Employee
    /// gratuity/fees, Guests, Tables, and the report-wide Total amount are
    /// reviewable/editable here; the remaining facts stay attached for
    /// analysis without turning closeout into a long questionnaire.
    @State private var receiptMetrics: ShiftReceiptMetrics?

    init(target: TipEntrySheetTarget) {
        self.target = target
        switch target {
        case .new(let defaultDate, let seedClockIn, let seedClockOut):
            _date = State(initialValue: defaultDate)
            _note = State(initialValue: "")
            if let start = seedClockIn ?? seedClockOut {
                _shiftPeriod = State(initialValue: ShiftTimes.period(for: start))
            } else if Calendar.current.isDateInToday(defaultDate) {
                _shiftPeriod = State(initialValue: ShiftTimes.period(for: .now))
            }
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
            _hasManuallySelectedShiftPeriod = State(initialValue: entry.shiftPeriod != nil)
            _clockIn = State(initialValue: entry.clockIn)
            _clockOut = State(initialValue: entry.clockOut)
            _serverCount = State(initialValue: entry.serverCount)
            _receiptMetrics = State(initialValue: entry.receiptMetrics)
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var canSave: Bool {
        cashCents > 0 || creditCents > 0
    }

    /// The header figure: voluntary cash + credit tips, plus Toast employee
    /// gratuity/fees, net of tip-out, plus this shift's base-rate wages. The
    /// gratuity line is non-tip income, but it is still money earned on this
    /// shift and therefore belongs in the all-in total.
    private var shiftTotalCents: Int {
        WageEstimate.shiftTotalCents(cashCents: cashCents, creditCents: creditCents, tipOutCents: tipOutCents, wageCentsPerHour: preferencesStore.baseHourlyWageCents, hoursWorked: hoursWorked)
            + (receiptMetrics?.separatedGratuityFeesCents ?? 0)
    }

    /// A server who's never once logged cash and has enough credit history
    /// to call it a pattern gets the credit field focused first instead of
    /// the usual cash-first default.
    private var prefersCreditFirst: Bool {
        if let prefersCreditFirstCache { return prefersCreditFirstCache }
        return computePrefersCreditFirst()
    }

    private func computePrefersCreditFirst() -> Bool {
        var creditCount = 0
        for entry in allEntries {
            if entry.kind == .cash { return false }
            if entry.kind == .credit { creditCount += 1 }
        }
        return creditCount >= 3
    }

    /// Runs once at appearance, before seedShiftDetailDefaults — a resolved
    /// live-shift punch pair pre-empts the weekday-suggestion fill-in below
    /// (which only fires when clockIn/clockOut are still nil) rather than
    /// competing with it.
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
        inferShiftPeriod(from: mode.clockIn)
        isEndingLiveShift = true
    }

    /// Pulled out of the view body's onAppear closure — inlining this much
    /// logic directly in a chained-modifier closure was slow enough to trip
    /// the type checker's time budget.
    private func seedShiftDetailDefaults() {
        switch target {
        case .new:
            // Nothing is seeded from history — Tyler's no-assumptions law
            // (2026-07-27): every shift is different, patterns never
            // pre-populate a field. Only facts prefill: a live session's
            // exact punches (init) and today's date.
            break
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
            receiptMetrics = resolved.receiptMetrics
        }
    }

    private func handleSheetAppear() {
        prefersCreditFirstCache = computePrefersCreditFirst()
        applyLiveShiftEndModeIfNeeded()
        seedShiftDetailDefaults()
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
                        RevealCardView(result: revealResult, period: shiftPeriod, includesNonTipIncome: revealIncludesNonTipIncome, onDismiss: { dismiss() })
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

                                shiftDetailsGroup
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
                        .onChange(of: receiptScanScrollRequest) { _, _ in
                            if reduceMotion {
                                proxy.scrollTo("receipt-scan-slot", anchor: .center)
                            } else {
                                withAnimation(PaydayAnimation.premiumSpring) {
                                    proxy.scrollTo("receipt-scan-slot", anchor: .center)
                                }
                            }
                        }
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
                        ToolbarItemGroup(placement: .keyboard) {
                            Button(action: presentReceiptScanOptions) {
                                ScanInputLabel(title: "Scan receipt")
                            }
                            .accessibilityHint("Take a receipt photo or choose one from Photos")
                            Spacer()
                            if let focusedCurrencyField {
                                if let next = nextFocusField(after: focusedCurrencyField) {
                                    Button("Next") {
                                        PaydayHaptics.selection()
                                        self.focusedCurrencyField = next
                                    }
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
                    // Each label names where it leaves you — "Continue Shift" next
                    // to "Keep Logging" read as the same thing (Tyler,
                    // 2026-07-27): one must say EXIT, the other BACK.
                    Button("Exit and Continue Shift") { dismiss() }
                    Button("Back to Logging", role: .cancel) {}
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
                    inferShiftPeriod(from: clockIn)
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
                    if reduceMotion {
                        proxy.scrollTo(newField, anchor: .center)
                    } else {
                        withAnimation(PaydayAnimation.premiumSpring) {
                            proxy.scrollTo(newField, anchor: .center)
                        }
                    }
                }
                .onAppear(perform: handleSheetAppear)
                .onDisappear {
                    receiptScanResetTask?.cancel()
                    receiptScanTask?.cancel()
                    liveSaveTask?.cancel()
                    commitLiveEdit()
                    receiptScanSnapshot = nil
                    isDeferringReceiptScanRowDeletion = false
                    pruneZeroedRows()
                }
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
        .confirmationDialog("Scan receipt", isPresented: $showReceiptScanOptions, titleVisibility: .visible) {
            if PaydayCameraView.isCameraAvailable {
                Button("Take Photo", systemImage: "camera") {
                    receiptPhotoSource = .camera
                }
            }
            Button("Choose from Photos", systemImage: "photo") {
                showReceiptPhotoPicker = true
            }
        } message: {
            if ReceiptAIParser.isConfigured {
                Text("Receipt photos are sent to OpenAI for scanning.")
            }
        }
        .photosPicker(isPresented: $showReceiptPhotoPicker, selection: $selectedReceiptPhotoItem, matching: .images)
        .sheet(item: $receiptPhotoSource) { source in
            PaydayCameraView(title: "Scan receipt") { image in
                receiptScanTask?.cancel()
                receiptScanTask = Task { await scanReceipt(image) }
            }
            .ignoresSafeArea()
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: selectedReceiptPhotoItem) { _, item in
            guard let item else { return }
            receiptScanTask?.cancel()
            receiptScanTask = Task { await scanReceipt(photoItem: item) }
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-DebugScanSlot"), args.count > index + 1 {
                switch args[index + 1] {
                case "analyzing": receiptScanSlotState = .analyzing
                case "scanned": receiptScanSlotState = .scanned
                case "error": receiptScanSlotState = .error("Couldn’t analyze receipt.")
                default: receiptScanSlotState = .rest
                }
            }
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

                receiptScanSlot
                // The hero total and the fields below it ARE the
                // decomposition (Tyler's money-language law, 2026-07-27): no
                // restated amount in another dialect sits under the headline.
                // Live $/hr, computed as the fields change, off the same
                // all-in numerator as the total above (net of tip-out, plus
                // wages) — a tip-out is recorded because it's an important
                // fact, but it is never income; wages are income, so they
                // belong in the rate same as they belong in the total. This
                // is the sheet's one secondary line. Only appears once the
                // shift has a length (times set, or legacy hours).
                if let hoursWorked, hoursWorked > 0 {
                    if shiftTotalCents > 0 {
                        let rateCentsPerHour = Int((Double(shiftTotalCents) / hoursWorked).rounded())
                        Text("\(Money.wholeDollarString(fromCents: rateCentsPerHour))/hr")
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
                CurrencyAmountRow(label: "Cash", cents: $cashCents, field: .cash, focusedField: $focusedCurrencyField, autoFocus: !isEditing && !prefersCreditFirst && !debugAutoFocusTipOut && !debugAutoFocusServers && !debugSuppressAutoFocus)
                    .id(CurrencyRowField.cash)
                CurrencyAmountRow(label: "Credit", cents: $creditCents, field: .credit, focusedField: $focusedCurrencyField, autoFocus: !isEditing && prefersCreditFirst && !debugAutoFocusTipOut && !debugAutoFocusServers && !debugSuppressAutoFocus)
                    .id(CurrencyRowField.credit)
            }
            .padding(.horizontal)
        }
    }

    private var receiptScanSlot: some View {
        ScanInputSlot(
            title: "Scan receipt",
            state: receiptScanSlotState,
            onScan: presentReceiptScanOptions,
            onUndo: undoReceiptScan
        )
        .padding(.horizontal)
        .id("receipt-scan-slot")
        .accessibilityHint("Take a receipt photo or choose one from Photos to fill the shift fields")
    }

    /// While the details group is expanded (always true when editing), Next
    /// cycles Cash -> Credit -> Tip-out -> Gratuity & fees -> Total amount ->
    /// Gross sales -> Servers, then through
    /// receipt-only Guests/Tables when those rows are present.
    /// Collapsed, only Cash and Credit are on screen, so the chain shortens
    /// to Cash -> Credit -> nil (Save sits right beside Next at that point,
    /// nothing left to advance into).
    private func nextFocusField(after field: CurrencyRowField) -> CurrencyRowField? {
        guard isEditing || isDetailsExpanded else {
            return field == .cash ? .credit : nil
        }
        switch field {
        case .cash: return .credit
        case .credit: return .tipOut
        case .tipOut:
            if receiptMetrics?.gratuityFeesCents != nil { return .gratuityFees }
            return receiptMetrics?.totalAmountCents == nil ? .sales : .receiptTotal
        case .gratuityFees: return receiptMetrics?.totalAmountCents == nil ? .sales : .receiptTotal
        case .receiptTotal: return .sales
        case .sales: return .servers
        case .servers: return receiptMetrics == nil ? .cash : .guests
        case .guests: return .tables
        case .tables: return .cash
        }
    }

    // MARK: Shift details — the facts that define this closeout

    /// New-entry only: the belief row (collapsed) or the full card
    /// (expanded). Editing bypasses this entirely — the card is always
    /// visible, exactly as it always was, no belief row to speak of.
    @ViewBuilder
    private var shiftDetailsGroup: some View {
        if isEditing || isDetailsExpanded {
            shiftDetailsCard
        } else {
            VStack(alignment: .leading, spacing: 4) {
                beliefRow
            }
            .padding(.horizontal)
        }
    }

    /// The collapsed details group's single row: one sentence of what's
    /// already known (ShiftBeliefLine), tap to expand into the full card.
    private var beliefRow: some View {
        Button {
            toggleDetailsExpanded()
        } label: {
            HStack {
                Text(ShiftBeliefLine.compose(date: date, shiftPeriod: shiftPeriod, clockIn: clockIn, clockOut: clockOut, tipOutCents: tipOutCents))
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
                    // Rotate rather than swap symbols — same convention as
                    // the Dashboard's breakdown drawer chevron.
                    .rotationEffect(.degrees(isDetailsExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isDetailsExpanded ? "Hide details" : "Show details")
    }

    private func toggleDetailsExpanded() {
        if reduceMotion {
            isDetailsExpanded.toggle()
        } else {
            withAnimation(PaydayAnimation.drawerSpring) {
                isDetailsExpanded.toggle()
            }
        }
    }

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
                    Picker("", selection: shiftPeriodBinding) {
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
                    // Base rate only — overtime is a weekly calculation that
                    // can't be attributed to a single shift, so this caption
                    // never claims OT.
                    if let wageCents = WageEstimate.cents(wageCentsPerHour: preferencesStore.baseHourlyWageCents, hours: hoursWorked) {
                        Text("\(WageEstimate.hoursLabel(hoursWorked)) · \(Money.string(fromCents: wageCents)) wages")
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .padding(.top, 8)
                    } else {
                        Text(WageEstimate.hoursLabel(hoursWorked))
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
                if receiptMetrics?.gratuityFeesCents != nil {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gratuity & fees")
                            Text("Non-tip income")
                                .font(PaydayFont.caption2)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                        Spacer()
                        CompactCurrencyField(cents: gratuityFeesBinding, field: .gratuityFees, focusedField: $focusedCurrencyField)
                    }
                    .padding(.vertical, 14)
                    .id(CurrencyRowField.gratuityFees)
                    Divider()
                }
                if receiptMetrics?.totalAmountCents != nil {
                    HStack {
                        Text("Total amount")
                        Spacer()
                        CompactCurrencyField(cents: totalAmountBinding, field: .receiptTotal, focusedField: $focusedCurrencyField)
                    }
                    .padding(.vertical, 14)
                    .id(CurrencyRowField.receiptTotal)
                    Divider()
                }
                HStack {
                    Text(receiptMetrics?.totalAmountCents == nil ? "Sales" : "Gross sales")
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
                receiptDetailRows
            }
            .padding()
            .tint(PaydayColor.textPrimary)
        }
    }

    /// Receipt-only rows stay in their own builder so adding them does not
    /// push the parent sheet body's generic type past Swift's checking limit.
    @ViewBuilder
    private var receiptDetailRows: some View {
        if receiptMetrics != nil {
            Divider()
            HStack {
                Text("Guests")
                Spacer()
                CompactCountField(count: guestCountBinding, field: .guests, focusedField: $focusedCurrencyField, maxDigits: 3)
            }
            .padding(.vertical, 14)
            .id(CurrencyRowField.guests)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tables")
                    if receiptMetrics?.tableCountSource?.isEstimated == true {
                        Text("Estimated from checks")
                            .font(PaydayFont.caption2)
                            .foregroundStyle(PaydayColor.textSecondary)
                    } else if receiptMetrics?.tableCountSource == .confirmed {
                        Text("Confirmed")
                            .font(PaydayFont.caption2)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                }
                Spacer()
                CompactCountField(count: tableCountBinding, field: .tables, focusedField: $focusedCurrencyField, maxDigits: 3)
            }
            .padding(.vertical, 14)
            .id(CurrencyRowField.tables)

            if let receiptMetricsSummary {
                Text(receiptMetricsSummary)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
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

    private var shiftPeriodBinding: Binding<ShiftPeriod?> {
        Binding(
            get: { shiftPeriod },
            set: { newValue in
                hasManuallySelectedShiftPeriod = true
                shiftPeriod = newValue
            }
        )
    }

    private func inferShiftPeriod(from start: Date?) {
        guard !hasManuallySelectedShiftPeriod, let start else { return }
        shiftPeriod = ShiftTimes.period(for: start)
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

    private var guestCountBinding: Binding<Int> {
        Binding(
            get: { receiptMetrics?.guestCount ?? 0 },
            set: { newValue in
                var metrics = receiptMetrics ?? ShiftReceiptMetrics()
                metrics.guestCount = newValue > 0 ? newValue : nil
                receiptMetrics = metrics.isEmpty ? nil : metrics
                liveSaveEdit()
            }
        )
    }

    /// A receipt's report-wide total is not the same fact as the pre-tip
    /// Gross sales amount used by tip-percentage analytics. Keep it editable
    /// in the scanned details without overloading TipEntry.salesCents.
    private var totalAmountBinding: Binding<Int> {
        Binding(
            get: { receiptMetrics?.totalAmountCents ?? 0 },
            set: { newValue in
                var metrics = receiptMetrics ?? ShiftReceiptMetrics()
                metrics.totalAmountCents = newValue > 0 ? newValue : nil
                receiptMetrics = metrics.isEmpty ? nil : metrics
                liveSaveEdit()
            }
        )
    }

    /// Toast prints employee-paid mandatory gratuity separately from both
    /// voluntary tips and sales. Keep that category visible and editable;
    /// folding it into Credit would corrupt tip-percent and paycheck audits.
    private var gratuityFeesBinding: Binding<Int> {
        Binding(
            get: { receiptMetrics?.gratuityFeesCents ?? 0 },
            set: { newValue in
                var metrics = receiptMetrics ?? ShiftReceiptMetrics()
                if (metrics.earningsSchemaVersion ?? 1) < 2 {
                    let foldedGratuity = metrics.employeeGratuityFeesCents
                    if creditCents >= foldedGratuity {
                        creditCents -= foldedGratuity
                    } else {
                        cashCents = max(0, cashCents - foldedGratuity)
                    }
                }
                metrics.earningsSchemaVersion = 2
                metrics.gratuityFeesCents = newValue > 0 ? newValue : nil
                receiptMetrics = metrics.isEmpty ? nil : metrics
                liveSaveEdit()
            }
        )
    }

    private var tableCountBinding: Binding<Int> {
        Binding(
            get: { receiptMetrics?.tableCount ?? 0 },
            set: { newValue in
                var metrics = receiptMetrics ?? ShiftReceiptMetrics()
                metrics.tableCount = newValue > 0 ? newValue : nil
                metrics.tableCountSource = newValue > 0 ? .confirmed : nil
                receiptMetrics = metrics.isEmpty ? nil : metrics
                liveSaveEdit()
            }
        )
    }

    /// One compact proof that the scan captured more than the visible form.
    /// Average spend follows the restaurant receipt convention and therefore
    /// uses pre-tax net sales, unlike the editable post-tax Sales field.
    private var receiptMetricsSummary: String? {
        guard let metrics = receiptMetrics else { return nil }
        var parts: [String] = []
        if let average = metrics.averageSpendPerGuestCents {
            parts.append("\(Money.string(fromCents: average))/guest")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    // MARK: Actions

    @MainActor
    private func presentReceiptScanOptions() {
        guard !isScanningReceipt else { return }
        receiptScanResetTask?.cancel()
        receiptScanSnapshot = nil
        setReceiptScanSlotState(.rest)
        focusedCurrencyField = nil
        receiptScanScrollRequest += 1
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        Task { @MainActor in
            await Task.yield()
            showReceiptScanOptions = true
        }
    }

    @MainActor
    private func setReceiptScanSlotState(_ state: ScanInputSlotState, resetAfter seconds: Int? = nil) {
        receiptScanResetTask?.cancel()
        if case .error = state {
            isDeferringReceiptScanRowDeletion = false
            receiptScanScrollRequest += 1
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            receiptScanSlotState = state
        }

        guard let seconds else { return }
        receiptScanResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let shouldReconcileDeferredRow = isDeferringReceiptScanRowDeletion
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                receiptScanSlotState = .rest
            }
            receiptScanSnapshot = nil
            isDeferringReceiptScanRowDeletion = false
            // The Undo window has closed. Apply any explicit scanned zero
            // through the normal edit reconciliation only now.
            if shouldReconcileDeferredRow {
                liveSaveEdit()
            }
        }
    }

    @MainActor
    private func undoReceiptScan() {
        guard let snapshot = receiptScanSnapshot else {
            setReceiptScanSlotState(.rest)
            return
        }

        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            if snapshot.touched.contains(.cash) { cashCents = snapshot.cashCents }
            if snapshot.touched.contains(.credit) { creditCents = snapshot.creditCents }
            if snapshot.touched.contains(.tipOut) { tipOutCents = snapshot.tipOutCents }
            if snapshot.touched.contains(.sales) { salesCents = snapshot.salesCents }
            if snapshot.touched.contains(.serverCount) { serverCount = snapshot.serverCount }
            if snapshot.touched.contains(.receiptMetrics) { receiptMetrics = snapshot.receiptMetrics }
            if snapshot.touched.contains(.date) { date = snapshot.date }
            if snapshot.touched.contains(.clockIn) { clockIn = snapshot.clockIn }
            if snapshot.touched.contains(.clockOut) { clockOut = snapshot.clockOut }
            if snapshot.touched.contains(.hoursWorked) { hoursWorked = snapshot.hoursWorked }
            if snapshot.touched.contains(.detailsExpanded) { isDetailsExpanded = snapshot.isDetailsExpanded }
        }
        receiptScanSnapshot = nil
        isDeferringReceiptScanRowDeletion = false
        setReceiptScanSlotState(.rest)
        liveSaveEdit()
        PaydayHaptics.selection()
    }

    @MainActor
    private func scanReceipt(_ image: UIImage) async {
        let scanStartedAt = Date()
        Self.receiptLogger.notice(
            "Receipt scan UI started. source=camera pixels=\(Int(image.size.width))x\(Int(image.size.height))"
        )
        isScanningReceipt = true
        receiptScanSnapshot = nil
        setReceiptScanSlotState(.analyzing)
        defer {
            isScanningReceipt = false
            let elapsedMilliseconds = Int(Date().timeIntervalSince(scanStartedAt) * 1_000)
            Self.receiptLogger.notice(
                "Receipt scan UI ended. source=camera elapsedMs=\(elapsedMilliseconds)"
            )
        }

        do {
            let parsed = try await ReceiptAIParser.parse(image: image)
            try Task.checkCancellation()
            let snapshotCashCents = cashCents
            let snapshotCreditCents = creditCents
            let snapshotTipOutCents = tipOutCents
            let snapshotSalesCents = salesCents
            let snapshotServerCount = serverCount
            let snapshotReceiptMetrics = receiptMetrics
            let snapshotDate = date
            let snapshotClockIn = clockIn
            let snapshotClockOut = clockOut
            let snapshotHoursWorked = hoursWorked
            let snapshotDetailsExpanded = isDetailsExpanded
            var touched: Set<ReceiptScannedField> = []

            // State-driven live saves fire as the bindings below change.
            // Defer destructive row reconciliation until Undo expires.
            isDeferringReceiptScanRowDeletion = true

            let parsedReceiptDate: Date?
            if let shiftDate = parsed.shiftDate {
                parsedReceiptDate = receiptDate(from: shiftDate)
            } else {
                parsedReceiptDate = nil
            }
            let clockDate = parsedReceiptDate ?? date
            let shouldExpandDetails = parsed.tipOutCents != nil
                || parsed.salesCents != nil
                || parsed.serverCount != nil
                || parsed.receiptMetrics != nil
                || parsed.shiftDate != nil
                || parsed.clockIn != nil
                || parsed.clockOut != nil

            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                if let cashTipsCents = parsed.cashTipsCents {
                    touched.insert(.cash)
                    cashCents = cashTipsCents
                }
                if let creditTipsCents = parsed.creditTipsCents {
                    touched.insert(.credit)
                    creditCents = creditTipsCents
                }
                if let parsedTipOutCents = parsed.tipOutCents {
                    touched.insert(.tipOut)
                    tipOutCents = parsedTipOutCents
                }
                if let parsedSalesCents = parsed.salesCents {
                    touched.insert(.sales)
                    salesCents = parsedSalesCents
                }
                if let parsedServerCount = parsed.serverCount {
                    touched.insert(.serverCount)
                    serverCount = parsedServerCount
                }
                if let metrics = parsed.receiptMetrics {
                    touched.insert(.receiptMetrics)
                    receiptMetrics = receiptMetrics?.merging(metrics) ?? metrics
                }
                if let parsedReceiptDate {
                    touched.insert(.date)
                    date = min(parsedReceiptDate, .now)
                }
                if let parsedClockIn = parsed.clockIn {
                    touched.insert(.clockIn)
                    clockIn = receiptDate(on: clockDate, at: parsedClockIn)
                }
                if let parsedClockOut = parsed.clockOut {
                    touched.insert(.clockOut)
                    var parsedEnd = receiptDate(on: clockDate, at: parsedClockOut)
                    if let parsedStart = clockIn, let end = parsedEnd, end <= parsedStart {
                        parsedEnd = Calendar.current.date(byAdding: .day, value: 1, to: end)
                    }
                    clockOut = parsedEnd
                }
                if let clockIn, let clockOut {
                    touched.insert(.hoursWorked)
                    hoursWorked = ShiftTimes.hours(clockIn: clockIn, clockOut: clockOut)
                }
                if shouldExpandDetails, !isDetailsExpanded {
                    touched.insert(.detailsExpanded)
                    isDetailsExpanded = true
                }
            }

            receiptScanSnapshot = ReceiptScanSnapshot(
                touched: touched,
                cashCents: snapshotCashCents,
                creditCents: snapshotCreditCents,
                tipOutCents: snapshotTipOutCents,
                salesCents: snapshotSalesCents,
                serverCount: snapshotServerCount,
                receiptMetrics: snapshotReceiptMetrics,
                date: snapshotDate,
                clockIn: snapshotClockIn,
                clockOut: snapshotClockOut,
                hoursWorked: snapshotHoursWorked,
                isDetailsExpanded: snapshotDetailsExpanded
            )
            setReceiptScanSlotState(.scanned, resetAfter: 6)
            Self.receiptLogger.notice(
                "Receipt scan UI applied result. filledFields=\(parsed.filledFieldCount)"
            )
            liveSaveEdit()
            PaydayHaptics.success()
        } catch is CancellationError {
            return
        } catch {
            let errorType = String(describing: type(of: error))
            Self.receiptLogger.error(
                "Receipt scan UI received failure. type=\(errorType, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
            )
            receiptScanSnapshot = nil
            isDeferringReceiptScanRowDeletion = false
            setReceiptScanSlotState(.error(error.localizedDescription), resetAfter: 4)
        }
    }

    @MainActor
    private func scanReceipt(photoItem: PhotosPickerItem) async {
        guard !isScanningReceipt else {
            Self.receiptLogger.notice("Receipt photo-library import ignored because a scan is already active")
            selectedReceiptPhotoItem = nil
            return
        }
        let importStartedAt = Date()
        Self.receiptLogger.notice("Receipt photo-library import started")
        isScanningReceipt = true
        receiptScanSnapshot = nil
        setReceiptScanSlotState(.analyzing)
        defer {
            isScanningReceipt = false
            selectedReceiptPhotoItem = nil
        }
        do {
            guard let data = try await photoItem.loadTransferable(type: Data.self),
                  let image = await PaydayImageDecoder.decode(data) else {
                throw ReceiptAIParser.ParseError.imageUnavailable
            }
            try Task.checkCancellation()
            let importMilliseconds = Int(Date().timeIntervalSince(importStartedAt) * 1_000)
            Self.receiptLogger.notice(
                "Receipt photo-library import completed. bytes=\(data.count) elapsedMs=\(importMilliseconds)"
            )
            await scanReceipt(image)
        } catch is CancellationError {
            return
        } catch {
            let errorType = String(describing: type(of: error))
            Self.receiptLogger.error(
                "Receipt photo-library import failed. type=\(errorType, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
            )
            receiptScanSnapshot = nil
            isDeferringReceiptScanRowDeletion = false
            setReceiptScanSlotState(.error(error.localizedDescription), resetAfter: 4)
        }
    }

    private func receiptDate(from shiftDate: ReceiptAIParser.ParsedReceipt.ShiftDate) -> Date? {
        Calendar.current.date(from: DateComponents(
            year: shiftDate.year,
            month: shiftDate.month,
            day: shiftDate.day
        ))
    }

    private func receiptDate(on day: Date, at time: ReceiptAIParser.ParsedReceipt.ClockTime) -> Date? {
        Calendar.current.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: day
        )
    }

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
        let tipsCents = cashCents + creditCents
        let gratuityFeesCents = receiptMetrics?.separatedGratuityFeesCents ?? 0
        let effectiveTipOutCents = tipOutCents > 0 ? tipOutCents : nil
        let effectiveSalesCents = salesCents > 0 ? salesCents : nil
        let netTotalCents = tipsCents + gratuityFeesCents - (effectiveTipOutCents ?? 0)
        // A shift speaks ONE number (Tyler's ruling, 2026-07-27): the
        // reveal's total is non-wage earnings plus this shift's own wages, the same
        // figure the Shifts row already shows — never a tips-only number
        // shown next to a wage-aware history.
        let wageCentsPerHour = preferencesStore.baseHourlyWageCents
        let wageCents = hoursWorked.flatMap { WageEstimate.cents(wageCentsPerHour: wageCentsPerHour, hours: $0) }
        let revealCents = netTotalCents + (wageCents ?? 0)

        // A stand-in id for the reveal's own exclusion check below — the
        // freshly-inserted rows get their own id from ShiftWriter, but since
        // neither id exists among allEntries yet, either one excludes
        // nothing and the comparison comes out identical.
        let shiftID = UUID()

        let statsEngine = StatsEngine(records: allEntries.map(TipRecord.init), wageCentsPerHour: wageCentsPerHour)
        let calculator = PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
        let period = calculator.period(containing: normalizedDate)
        // The engine and the cents passed here share one basis — see
        // StatsEngine.reveal's doc. Passing this shift's id lets the
        // reveal compare it against the day's other shift (if any) rather
        // than excluding the whole day.
        let reveal = statsEngine.reveal(forNightAt: normalizedDate, cents: revealCents, period: period, hoursWorked: hoursWorked, shiftID: shiftID)

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
            serverCount: serverCount,
            receiptMetrics: receiptMetrics
        )

        revealResult = reveal
        revealIncludesNonTipIncome = wageCents != nil || gratuityFeesCents > 0
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
        guard isEditing else { return }
        liveSaveTask?.cancel()
        liveSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commitLiveEdit()
        }
    }

    /// Coalesce keypad and text-field edits into one SwiftData mutation and
    /// one WidgetKit refresh after the user pauses, then flush on dismissal.
    private func commitLiveEdit() {
        guard case .edit(let anchor) = target else { return }
        var rows = sameShiftEntries(around: anchor)
        guard rows.contains(where: { $0.id == anchor.id }) else { return }
        let normalizedDate = Calendar.current.startOfDay(for: min(date, .now))
        let trimmedNote = note.isEmpty ? nil : note
        for kind in [TipKind.cash, .credit] {
            let cents = kind == .cash ? cashCents : creditCents
            if let row = rows.first(where: { $0.kind == kind }) {
                if cents > 0 || row.id == anchor.id || rows.count == 1 || isDeferringReceiptScanRowDeletion {
                    row.amountCents = cents          // never delete the anchor mid-edit
                } else {
                    PaydaySyncState.recordTipDeletions([row.id])
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
            receiptMetrics: receiptMetrics,
            into: rows
        )

        PaydayWidgetRefresh.request()
    }

    /// A row that got zeroed out mid-edit (cash typed down to 0 while
    /// credit carries the shift, say) is deleted immediately by
    /// liveSaveEdit's reconciliation above — but the anchor itself is
    /// deliberately never deleted while its sheet is still open, so this
    /// sweeps it up too if it's the one left holding a zero when the sheet
    /// closes. Before deleting any zero row, migrate the shift-level facts to
    /// the rows that will survive so removing the canonical credit row cannot
    /// discard hours, tip-out, sales, times, or receipt metrics. Always leaves
    /// at least one row behind.
    private func pruneZeroedRows() {
        guard case .edit(let anchor) = target else { return }
        let rows = sameShiftEntries(around: anchor)
        guard rows.count > 1 else { return }
        let zeroed = rows.filter { $0.amountCents == 0 }
        guard !zeroed.isEmpty else { return }

        let resolved = ShiftDetails.resolve(from: rows)
        let nonzeroRows = rows.filter { $0.amountCents > 0 }
        // Every row is zero: keep the anchor if possible so the edit target is
        // not erased out from under the sheet during dismissal.
        let survivingRows = nonzeroRows.isEmpty
            ? [rows.first(where: { $0.id == anchor.id }) ?? rows[0]]
            : nonzeroRows

        ShiftDetails.write(
            hoursWorked: resolved.hoursWorked,
            tipOutCents: resolved.tipOutCents,
            salesCents: resolved.salesCents,
            shiftPeriod: resolved.shiftPeriod,
            clockIn: resolved.clockIn,
            clockOut: resolved.clockOut,
            serverCount: resolved.serverCount,
            receiptMetrics: resolved.receiptMetrics,
            into: survivingRows
        )

        let survivingIDs = Set(survivingRows.map(\.id))
        let deletedRows = rows.filter { !survivingIDs.contains($0.id) }
        PaydaySyncState.recordTipDeletions(deletedRows.map(\.id))
        for row in deletedRows {
            modelContext.delete(row)
        }
    }

    private func delete() {
        if case .edit(let entry) = target {
            let rows = sameShiftEntries(around: entry)
            PaydaySyncState.recordTipDeletions(rows.map(\.id))
            for row in rows {
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
                // Secondary, not tertiary: textTertiary falls short of
                // 4.5:1 contrast against fieldBackground in both modes, and
                // a placeholder hint still has to be legible to read at all.
                Text(Money.string(fromCents: placeholderCents))
                    .font(PaydayFont.body)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
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
        // Keeps the hidden text field in sync when cents changes from
        // outside typing (the suggestion chip's one-tap commit) — without
        // this, digitsText would silently keep its stale "" and the next
        // keystroke would stomp the committed value back toward zero.
        .onChange(of: cents) { _, newValue in
            guard Int(digitsText) ?? 0 != newValue else { return }
            digitsText = newValue == 0 ? "" : String(newValue)
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
    var maxDigits: Int = 2
    @State private var digitsText: String = ""

    private var isFocused: Bool { focusedField.wrappedValue == field }

    var body: some View {
        ZStack(alignment: .trailing) {
            if count == 0, let placeholderCount {
                // textSecondary, not textTertiary — see CompactCurrencyField's
                // same contrast note above.
                Text("\(placeholderCount)")
                    .font(PaydayFont.body)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
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
            let filtered = String(newValue.filter(\.isNumber).prefix(maxDigits))
            if filtered != newValue { digitsText = filtered }
            count = Int(filtered) ?? 0
        }
        .onChange(of: count) { _, newValue in
            guard Int(digitsText) ?? 0 != newValue else { return }
            digitsText = newValue == 0 ? "" : String(newValue)
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
    /// Whether result.cents includes wages or mandatory gratuity — picks an
    /// honest headline unit for the all-in shift amount.
    let includesNonTipIncome: Bool
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 12) {
            Text(RevealCopy.headline(cents: result.cents, includesNonTipIncome: includesNonTipIncome))
                .font(PaydayFont.displayXL)
                .monospacedDigit()
                .foregroundStyle(result.isRecord && isRevealed ? PaydayColor.primary : PaydayColor.textPrimary)
            Text(RevealCopy.comparison(for: result.comparison, period: period))
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            let comparison = RevealCopy.comparison(for: result.comparison, period: period)
            UIAccessibility.post(notification: .announcement, argument: "\(RevealCopy.headline(cents: result.cents, includesNonTipIncome: includesNonTipIncome)) \(comparison)")
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
