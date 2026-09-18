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
    @Environment(PolicyStore.self) private var policyStore
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
    /// The shift's own figure as the ledger valued it, which is what the
    /// reveal HEADLINE renders (row [LS-13]).
    ///
    /// It is the same `EarningsFigure` the header showed a beat earlier and
    /// the same one `ShiftDayRow` will show on Dashboard, so "one shift speaks
    /// one number" holds across the save.
    ///
    /// `RevealResult.cents` is not rendered, but it is no longer a DIFFERENT
    /// number: `saveNew` hands `reveal(...)` this figure's own cents and seeds
    /// the engine's history with `valuedShiftCents`, so the sentence under the
    /// headline is computed on the same ledger basis the headline prints. The
    /// two used to differ, and `RevealCopy.comparison` says its figure out
    /// loud, so the card could print "$250.00 this shift." over "topping your
    /// previous record of $260.00."
    @State private var revealFigure: EarningsFigure?
    /// Whether the reveal figure contains any non-tip employee income —
    /// wages or Toast mandatory gratuity. Set alongside revealFigure so an
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
    /// A save that did not happen must not look like one that did.
    @State private var saveFailed = false
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

    /// The id the draft is substituted into the preview snapshot under
    /// (`ShiftDraftPreview`). For an edit it is the id the HISTORY snapshot
    /// keys that shift under — the stored `shiftID`, or
    /// `ShiftDays.deterministicShiftID(for:)` for a legacy row that never got
    /// one — so the draft REPLACES the stored shift in its own workweek
    /// instead of doubling it; for a new shift it is a stable id minted once,
    /// so the draft is appended and the header does not change answer between
    /// two body passes.
    @State private var draftShiftID: UUID
    /// The recording time the save will stamp. It is a tiebreaker in the
    /// ledger's within-workweek ordering, so the preview has to use the same
    /// one the save will or the cumulative rounding could land differently on
    /// the two sides of a save. An edit keeps the stored shift's own time.
    @State private var draftRecordedAt: Date

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
            _draftShiftID = State(initialValue: UUID())
            _draftRecordedAt = State(initialValue: .now)
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
            // A legacy row logged before shift grouping existed has no
            // shiftID, and substituting the draft under the wrong id APPENDS a
            // duplicate of the shift being edited into its own workweek: the
            // week's hours double and the draft is handed overtime it did not
            // earn while the person was only changing a tip amount. MEASURED
            // on a Wednesday 10-hour legacy shift inside a 36-hour Sunday-start
            // week: 5 shifts instead of 4, header $230.00 / "10h · $150.00
            // wages" against the correct $180.00 / "10h · $100.00 wages".
            //
            // So the id is seeded to the one the history snapshot actually
            // keys that group under, SYNCHRONOUSLY, on the first body pass:
            // `ShiftDays.groupedByShift`'s nil-shiftID fallback is
            // `deterministicShiftID(for: date)`, a pure function of the
            // calendar day (`ShiftDays.swift`), which `LegacySnapshotBridge`
            // and `MigrationRunner.backfillShiftIDs` already agree on. It is
            // not "a content hash the sheet cannot reproduce" — that is
            // `LegacyLedgerBridge.shiftInput`'s id, which
            // `LegacySnapshotBridge.shiftInput` overwrites with the group's.
            //
            // `seedShiftDetailDefaults` still assigns the group's id in
            // onAppear, but it can no longer be load-bearing, and that matters
            // twice: the first body pass renders BEFORE onAppear, and its own
            // guard early-returns while the @Query-backed `allEntries` is
            // momentarily empty — onAppear fires once, so a wrong id seeded
            // here could otherwise survive for the sheet's whole lifetime.
            _draftShiftID = State(initialValue: ShiftDraftPreview.editDraftShiftID(for: entry))
            _draftRecordedAt = State(initialValue: entry.recordedAt ?? .now)
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var canSave: Bool {
        cashCents > 0 || creditCents > 0
    }

    /// The draft written as the `TipEntry` rows the save will write, so the
    /// header is valued off exactly what is about to be persisted. See
    /// `ShiftDraftPreview`.
    private var draftRows: [TipEntry] {
        ShiftDraftPreview.rows(
            date: date,
            cashCents: cashCents,
            creditCents: creditCents,
            note: note.isEmpty ? nil : note,
            recordedAt: draftRecordedAt,
            shiftID: draftShiftID,
            hoursWorked: hoursWorked,
            tipOutCents: tipOutCents,
            salesCents: salesCents,
            shiftPeriod: shiftPeriod,
            clockIn: clockIn,
            clockOut: clockOut,
            serverCount: serverCount,
            receiptMetrics: receiptMetrics
        )
    }

    /// The app's real history with this draft substituted in, valued by the
    /// one ledger under the user's own effective-dated policies.
    ///
    /// `policyStore.policies` whole, never a scalar rate or a scalar weekday:
    /// wave 0 MEASURED a synthesized `.distantPast` `.confirmed` policy
    /// repricing every pre-raise shift at today's rate ($520.00 against the
    /// correct $440.00) and making `.estimated` unreachable.
    private var previewSnapshot: EarningsSnapshot? {
        ShiftDraftPreview.snapshot(
            draft: ShiftDraftPreview.draftInput(
                rows: draftRows,
                shiftID: draftShiftID,
                payrollTimeZone: policyStore.payrollTimeZone
            ),
            entries: allEntries,
            policies: policyStore.policies,
            payrollTimeZone: policyStore.payrollTimeZone
        )
    }

    /// The WHOLE history with this draft substituted in, unwindowed — the
    /// reveal comparison's dataset.
    ///
    /// `previewSnapshot` above is deliberately windowed to the draft's own
    /// workweek, because it runs on every keystroke. That window is correct
    /// for the draft's own figure (`LogShiftPreviewWindowTests` proves the
    /// windowed and whole-history previews produce the identical figure) but
    /// it is useless for the reveal, whose whole job is to compare tonight
    /// against every prior shift — an all-time record lives outside this week
    /// almost by definition. A window here would have left most of the history
    /// on `StatsEngine`'s scalar fallback, which is the defect, mixed into one
    /// comparison set rather than removed from it.
    ///
    /// So this is built ONCE PER SAVE rather than per keystroke. MEASURED at
    /// **0.2335s over a 10,000-row history** (the same order as the 0.245s the
    /// windowed header used to cost before its window), which is exactly why
    /// the header does not use it and the save does. Bounded by *"the reveal's
    /// whole-history snapshot stays inside a per-save budget"* in
    /// `LogShiftPreviewPerformanceTests`, so a future change cannot quietly
    /// move this cost onto a keystroke.
    private func revealHistorySnapshot() -> EarningsSnapshot? {
        ShiftDraftPreview.snapshot(
            draft: ShiftDraftPreview.draftInput(
                rows: draftRows,
                shiftID: draftShiftID,
                payrollTimeZone: policyStore.payrollTimeZone
            ),
            entries: allEntries,
            policies: policyStore.policies,
            payrollTimeZone: policyStore.payrollTimeZone,
            windowed: false
        )
    }

    /// Every shift's `earnedIncome`, for `StatsEngine`'s reveal comparison.
    /// Nil without a snapshot, which leaves the engine on its own fallback
    /// rather than on a dictionary of zeros.
    ///
    /// Deliberately the same construction Dashboard's `valuedCents(in:)` uses,
    /// over the same `LegacySnapshotBridge`-shaped dataset, because the two
    /// have to produce the same comparison sentence for the same shift.
    private static func valuedCents(in snapshot: EarningsSnapshot?) -> [UUID: Int]? {
        guard let snapshot else { return nil }
        return Dictionary(
            snapshot.shifts.map { ($0.id, $0.components.earnedIncomeCents) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The screen adapter. Expensive enough that `body` binds it ONCE and
    /// hands it down: every read runs the ledger over the draft's workweek.
    private var facts: LogShiftFacts {
        LogShiftFacts(
            snapshot: previewSnapshot,
            draftID: draftShiftID,
            date: date,
            shiftPeriod: shiftPeriod,
            clockIn: clockIn,
            clockOut: clockOut,
            hoursWorked: hoursWorked
        )
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
            // The id the HISTORY snapshot keys this shift under, read off the
            // same grouping `LegacySnapshotBridge` performs. `init` already
            // seeded the identical id from `entry.shiftID ??
            // ShiftDays.deterministicShiftID(for: entry.date)` — which is
            // exactly this grouping's own fallback — so this is a
            // CONFIRMATION, not the repair it used to be. It stays because it
            // is the grouping's answer rather than a restatement of its rule,
            // so a future change to the grouping is caught here.
            if let group = ShiftDays.groupedByShift(
                allEntries,
                shiftID: \.shiftID,
                date: \.date,
                period: \.shiftPeriod
            ).first(where: { $0.items.contains(where: { $0.id == entry.id }) }) {
                draftShiftID = group.shiftID
            }
            draftRecordedAt = shift.compactMap(\.recordedAt).min() ?? draftRecordedAt
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
        // Bound ONCE per body pass. Every figure on this sheet comes off this
        // one value, which is both why they cannot disagree with each other
        // and why it must not be re-read per subview: each read builds a
        // preview snapshot and runs the ledger.
        let facts = facts
        return NavigationStack {
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
                        RevealCardView(result: revealResult, figure: revealFigure ?? .unavailable(), period: shiftPeriod, includesNonTipIncome: revealIncludesNonTipIncome, onDismiss: { dismiss() })
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
                                shiftAmountContent(facts)

                                shiftDetailsGroup(facts)
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
                .alert(
                    ShiftCommands.Failure.saveFailed.message,
                    isPresented: $saveFailed
                ) {
                    Button("OK", role: .cancel) {}
                }
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

    private func shiftAmountContent(_ facts: LogShiftFacts) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                // The label is the engine's, not a constant. "Shift total" was
                // never one of `MetricID.earnedIncome.allowedLabels`, and it
                // said "total" over a figure that silently excluded the wage
                // of a shift whose hours were not logged yet. Now a draft with
                // no hours reads "Known so far", a draft with a tip-out reads
                // "You kept", and wages-off reads "Tips" — one vocabulary with
                // Dashboard, Period detail and the day sheet.
                Text(facts.total.label)
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(facts.total.text ?? ShiftDayRow.unavailablePlaceholder)
                    .font(PaydayFont.displayXL)
                    .monospacedDigit()
                    .foregroundStyle(facts.total.cents == 0 || facts.total.isUnavailable ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: facts.total.cents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                // "Wages estimated from your current rate" when the rate
                // history was never confirmed, or what is missing and for how
                // many shifts when the draft is partial. The sheet showed
                // neither before, so an estimate read exactly like a fact.
                if let caption = facts.total.caption {
                    Text(caption)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .multilineTextAlignment(.center)
                }

                receiptScanSlot
                // The hero total and the fields below it ARE the
                // decomposition (Tyler's money-language law, 2026-07-27): no
                // restated amount in another dialect sits under the headline.
                // Live $/hr, off the ENGINE's `MetricID.hourlyRate` rather
                // than the view's own `Double(total) / hours` — same
                // wage-inclusive, net-of-tip-out basis, asked of the one thing
                // allowed to answer it. This is the sheet's one secondary
                // line. Only appears once the shift has a length (times set,
                // or legacy hours) and the engine has a figure to rate.
                if let hourlyRateText = facts.hourlyRateText {
                    Text(hourlyRateText)
                        .font(PaydayFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(PaydayColor.textSecondary)
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
    private func shiftDetailsGroup(_ facts: LogShiftFacts) -> some View {
        if isEditing || isDetailsExpanded {
            shiftDetailsCard(facts)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                beliefRow(facts)
            }
            .padding(.horizontal)
        }
    }

    /// The collapsed details group's single row: one sentence of what's
    /// already known (ShiftBeliefLine), tap to expand into the full card.
    private func beliefRow(_ facts: LogShiftFacts) -> some View {
        Button {
            toggleDetailsExpanded()
        } label: {
            HStack {
                Text(facts.beliefLine)
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
    private func shiftDetailsCard(_ facts: LogShiftFacts) -> some View {
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
                // "6h 23m · $18.06 wages", or the hours alone when the engine
                // priced no wage for this shift. The wages term is the
                // ledger's slice of the WORKWEEK allocation, so it carries
                // this shift's own overtime and sums to the header — the old
                // caption was base rate only and carried a comment saying
                // overtime "can't be attributed to a single shift". The ledger
                // attributes it, per shift, and the slices telescope to the
                // week total.
                if let hoursCaption = facts.hoursCaption {
                    Text(hoursCaption)
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .padding(.top, 8)
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
        let effectiveTipOutCents = tipOutCents > 0 ? tipOutCents : nil
        let effectiveSalesCents = salesCents > 0 ? salesCents : nil
        // A shift speaks ONE number (Tyler's ruling, 2026-07-27), and since
        // wave 0 that number is the LEDGER's: the reveal headline is the same
        // `EarningsFigure` the header above it just showed and the same one
        // `ShiftDayRow` renders on Dashboard a second later. Captured before
        // the insert so it is the draft's valuation, not a re-read that would
        // depend on @Query having refreshed.
        let draftFigure = facts.total
        let draftIncludesNonTipIncome = facts.includesNonTipIncome

        let calculator = PayPeriodCalculator(payrollTimeZone: policyStore.payrollTimeZone, schedule: scheduleStore.schedule ?? .fallback)
        let period = calculator.period(containing: normalizedDate)
        // ONE basis for the whole reveal card, both lines of it.
        //
        // The headline is the ledger's figure ([LS-13]) and until now the
        // COMPARISON underneath it was still `netTotal + WageEstimate.cents`
        // over a `StatsEngine` pricing every prior shift the same scalar way.
        // Two bases, and `RevealCopy.comparison` prints its own cents out loud
        // ("topping your previous record of $X", "$Y above your Friday
        // average"), so both were on screen at once. MEASURED: a 10-hour March
        // shift with $150 of credit backfilled under a $10/hr -> $30/hr raise,
        // against a $260.00 previous best, rendered "$250.00 this shift."
        // directly above "Best dinner ever, topping your previous record of
        // $260.00." — a number BELOW the record it claimed to beat, because the
        // record was decided on $450.00: today's rate applied to a pre-raise
        // shift. The rate-history direction has the opposite sign from the
        // overtime one, so it is a visible self-contradiction and not a skew.
        //
        // The fix is not to re-price the headline. It is to let the engine read
        // the LEDGER's per-shift `earnedIncome` for its history too, which is
        // what `valuedShiftCents` is for and what [DB-25] asks for. Dashboard's
        // tonight echo seeds the identical parameter from its own snapshot, so
        // the two surfaces now produce byte-identical comparison copy for one
        // shift — pinned by `RevealComparisonParityTests`. Before this they
        // disagreed about both the delta and the rank one screen apart.
        let revealSnapshot = revealHistorySnapshot()
        let statsEngine = StatsEngine(
            payrollTimeZone: policyStore.payrollTimeZone,
            records: allEntries.map(TipRecord.init),
            valuedShiftCents: Self.valuedCents(in: revealSnapshot)
        )
        // The draft's own id, not a stand-in UUID: it is the id the draft was
        // valued under and the key it holds in the dictionary above, and for a
        // `.new` sheet it appears nowhere in `allEntries`, so it still excludes
        // nothing from the history. Passing an id at all (rather than nil) is
        // what lets the reveal compare this shift against the day's OTHER
        // shift instead of excluding the whole day.
        //
        // `draftFigure.cents` is the number the header showed a beat earlier,
        // by construction the same `EarningsFigure`. Nil only when the engine
        // could not value the draft at all, and rule 4 says that renders no
        // currency — so there is no comparison to make either, and the card
        // shows the headline's completeness label alone.
        let reveal = draftFigure.cents.map { cents in
            statsEngine.reveal(
                forNightAt: normalizedDate,
                cents: cents,
                period: period,
                shiftID: draftShiftID
            )
        }

        // Explicit and atomic. This is the path a user takes every night, and
        // it persisted only through autosave: with autosave off and no save
        // here, a logged shift is gone on relaunch. Everything after it --
        // the reveal, the nudge reschedule, the dismissal -- is a claim that
        // the shift was saved, so none of it may run if it was not.
        let newEntries: [TipEntry]
        do {
            newEntries = try ShiftCommands.commit(in: modelContext) {
                ShiftWriter.insertShift(
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
            }
        } catch {
            // Rolled back, so the form still holds the night's figures and
            // the sheet stays open to try again. No reveal, because there is
            // nothing to celebrate.
            saveFailed = true
            return
        }

        revealResult = reveal
        revealFigure = draftFigure
        revealIncludesNonTipIncome = draftIncludesNonTipIncome
        // The reveal is the only thing holding this sheet open after a save.
        // With no figure there is no card to show — the shift is written
        // either way, so close rather than sit on a form that looks unsaved.
        if reveal == nil { dismiss() }
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
        // One transaction for the whole reconciliation. Every live edit used
        // to persist through autosave alone, so with autosave off nothing
        // here would survive a relaunch. The debounce above means this runs
        // once after the user pauses, not per keystroke, so a save per call
        // is exactly what the coalescing was for.
        do {
            try ShiftCommands.commit(in: modelContext) {
                for kind in [TipKind.cash, .credit] {
                    let cents = kind == .cash ? cashCents : creditCents
                    if let row = rows.first(where: { $0.kind == kind }) {
                        if cents > 0 || row.id == anchor.id || rows.count == 1 || isDeferringReceiptScanRowDeletion {
                            row.amountCents = cents          // never delete the anchor mid-edit
                            row.touch()
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
                for row in rows { row.date = normalizedDate; row.note = trimmedNote; row.touch() }

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
            }
        } catch {
            // Rolled back, so the shift is left exactly as it was rather than
            // half-edited.
            //
            // Known gap, tracked in issue #26 rather than living only here:
            // this also runs as the flush on `.onDisappear`, and a failure
            // there has nowhere to go -- the sheet is already leaving, so the
            // alert cannot be seen and the user's last edit is silently
            // reverted. Reverting whole is still better than persisting half,
            // which would leave a shift whose cash, credit and shift-level
            // details disagree, and the alert does work for the debounced case
            // while the sheet is open.
            saveFailed = true
        }
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

        // Migrating the facts and deleting the rows must be ONE transaction.
        // Split across two, a failure between them discards the hours,
        // tip-out, sales, times and receipt metrics while leaving the rows
        // that were supposed to receive them -- which is the exact loss the
        // migration above exists to prevent.
        let survivingIDs = Set(survivingRows.map(\.id))
        let deletedRows = rows.filter { !survivingIDs.contains($0.id) }
        try? ShiftCommands.commit(in: modelContext) {
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
            PaydaySyncState.recordTipDeletions(deletedRows.map(\.id))
            for row in deletedRows {
                modelContext.delete(row)
            }
        }
        // `try?` deliberately: this only ever runs during dismissal, where an
        // alert cannot be seen. A rollback leaves the zero rows in place,
        // which is untidy but loses nothing, and the next edit sweeps them.
        // The cheaper sibling of issue #26.
    }

    private func delete() {
        if case .edit(let entry) = target {
            let rows = sameShiftEntries(around: entry)
            do {
                try ShiftCommands.commit(in: modelContext) {
                    // Queued and deleted together, so the server cannot be
                    // told about a deletion the device then fails to make,
                    // or the reverse.
                    PaydaySyncState.recordTipDeletions(rows.map(\.id))
                    for row in rows {
                        modelContext.delete(row)
                    }
                }
            } catch {
                // Rolled back: the shift is still there, so do NOT dismiss on
                // a deletion that did not happen.
                saveFailed = true
                return
            }
        }
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
    /// The comparison clause and the record flag. Its own `cents` is not
    /// rendered — `figure` below is — but it is the same ledger cents `figure`
    /// carries, and the history it was compared against is ledger-valued too.
    /// See `LogTipSheet.revealFigure`.
    let result: RevealResult
    /// The shift's earnings as the LEDGER valued it (row [LS-13]). The same
    /// figure the sheet's header showed and the same one `ShiftDayRow` will
    /// show, so the save does not change the number.
    let figure: EarningsFigure
    /// The shift's lunch/dinner, when captured — lets the comparison below
    /// name it instead of falling back to the generic "shift".
    let period: ShiftPeriod?
    /// Whether the figure includes wages or mandatory gratuity — picks an
    /// honest headline unit for the all-in shift amount.
    let includesNonTipIncome: Bool
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 12) {
            Text(headline)
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
            UIAccessibility.post(notification: .announcement, argument: "\(headline) \(comparison)")
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

    /// The reveal's one sentence about the amount, or the shift's completeness
    /// label when the engine could not value it. Rule 4: an unavailable read
    /// renders NO currency, so this never becomes "$0.00 this shift."
    private var headline: String {
        guard let cents = figure.cents else { return figure.label }
        return RevealCopy.headline(cents: cents, includesNonTipIncome: includesNonTipIncome)
    }
}
