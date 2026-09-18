import SwiftUI
import SwiftData

/// One day, as the engine answered it.
///
/// ## The identity this struct exists to make unbreakable
///
/// `total` is `snapshot.day(thatDay)` and `shifts` is that same result's
/// `shiftIDs`, in the engine's canonical order. So the hero is not a number
/// that agrees with the rows — it is the SUM of exactly the rows listed, by
/// construction, because both sides name the same selection. Each row then
/// renders `snapshot.valuation(id)`, that shift's own slice of the same
/// allocation.
///
/// ## Why the snapshot is the whole dataset
///
/// It used to be this day's shifts alone. The overtime threshold belongs to a
/// WORKWEEK, so a ledger handed one day can never allocate overtime: MEASURED
/// on the straddling Thursday, 3396c day-scoped against 3679c week-scoped, and
/// the tile that opened this sheet had the same hole. Both surfaces now read
/// one whole-dataset snapshot from `CalendarEarnings`, which is what makes
/// "calendar tile == this sheet's hero" an identity rather than a coincidence.
/// Internal rather than private so the parity gate can measure the REAL
/// adapter. A parity test that re-implements the screen's arithmetic in its
/// own helper proves the helper, and that is exactly how a screen came to
/// disagree with the test that was supposed to pin it.
struct DayDetailFacts: SnapshotFacts {
    /// Exactly the shifts the day result selected, in the engine's order.
    let shifts: [(day: Date, shiftID: UUID, items: [TipEntry])]
    /// The same, in the shift representation. Populated by
    /// `init(shiftRecords:...)` and empty from the legacy initializer, so the
    /// two never both hold rows and a screen cannot accidentally render both.
    ///
    /// A live `[ShiftRecord]` rather than a projection, because these rows ARE
    /// the edit and delete targets: `ProjectedShiftRow` is deliberately
    /// un-persistable, so `context.delete` and the edit sheet cannot take it.
    let shiftRecords: [ShiftRecord]
    /// The whole-dataset snapshot, so a row can ask for its own valuation.
    let snapshot: EarningsSnapshot?
    let stamp: SnapshotStamp?
    /// The day's earnings, labelled by the day's own completeness: a day
    /// holding a shift with no hours logged reads "Known so far", never
    /// "Total", and a failed read renders no currency at all.
    let total: EarningsFigure

    init(allEntries: [TipEntry], date: Date, policies: CompensationPolicies, payrollTimeZone: TimeZone) {
        // The same civil day the tile that opened this sheet drew, in the same
        // frozen payroll zone.
        let calendar = CalendarEarnings.groupingCalendar(payrollTimeZone: payrollTimeZone)
        let civilDay = CivilDay(date, in: payrollTimeZone)
        let allShifts = CalendarEarnings.shiftGroups(entries: allEntries, payrollTimeZone: payrollTimeZone)
        // The USER'S rate and workweek history, effective dates intact, whole
        // and unmodified. A scalar weekday here is what let this sheet bucket
        // overtime into a different week than the tile above it: it used to
        // read `policyStore.latestCalendarPolicy`, which is `calendars.last`
        // and therefore a QUEUED FUTURE policy.
        let resolvedSnapshot = CalendarEarnings.snapshot(
            shifts: allShifts,
            policies: policies,
            payrollTimeZone: payrollTimeZone
        )
        snapshot = resolvedSnapshot
        stamp = resolvedSnapshot?.stamp

        let groupsByID = Dictionary(
            allShifts.map { ($0.shiftID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if let dayResult = resolvedSnapshot?.day(civilDay) {
            total = .earnedIncome(dayResult)
            shifts = dayResult.shiftIDs.compactMap { groupsByID[$0] }
        } else {
            // No snapshot is a failed read, not an empty day (contract rule
            // 4). The rows are still listed, from the grouping, so the person
            // sees that the shifts exist; every amount on them renders as
            // unavailable because no valuation stands behind it.
            total = .unavailable()
            shifts = allShifts.filter { calendar.isDate($0.day, inSameDayAs: date) }
        }
        shiftRecords = []
    }

    /// The same day, from the shift representation.
    ///
    /// Additive: nothing calls this until the writer flip. It exists now so
    /// the equivalence can be asserted against the legacy initializer before
    /// anything depends on it -- `DayDetailShiftFactsTests` pins that both
    /// produce the same total, the same stamp and the same shift ids for
    /// equivalent data.
    ///
    /// Deliberately mirrors the legacy initializer's structure line for line,
    /// including the no-snapshot branch: a failed read is a failed read, not
    /// an empty day, so the rows are still listed and every amount renders
    /// unavailable rather than as `$0`.
    /// `@MainActor` because `ShiftInputAdapter.adapt` is: SwiftData models
    /// must not cross an isolation domain, and that rule does not relax for a
    /// facts initializer. Views build these on the main actor already.
    @MainActor
    init(shiftRecords records: [ShiftRecord], date: Date, policies: CompensationPolicies, payrollTimeZone: TimeZone) {
        let calendar = CalendarEarnings.groupingCalendar(payrollTimeZone: payrollTimeZone)
        let civilDay = CivilDay(date, in: payrollTimeZone)

        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        let resolvedSnapshot = try? EarningsSnapshot.build(EarningsInputs(
            shifts: adapted.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            // `.distantFuture`, the same opt-out the calendar makes: a person
            // who logs tomorrow's shift expects to see it on tomorrow's tile,
            // and opting out in the STAMP rather than per query is what keeps
            // `Σ tiles == headline` true.
            asOf: CivilDay(.distantFuture, in: payrollTimeZone),
            unreadableReceiptShiftIDs: adapted.unreadableReceiptShiftIDs
        ))
        snapshot = resolvedSnapshot
        stamp = resolvedSnapshot?.stamp

        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let dayResult = resolvedSnapshot?.day(civilDay) {
            total = .earnedIncome(dayResult)
            shiftRecords = dayResult.shiftIDs.compactMap { byID[$0] }
        } else {
            total = .unavailable()
            shiftRecords = records.filter { calendar.isDate($0.workDate, inSameDayAs: date) }
        }
        shifts = []
    }

    /// The row's facts need three scalars, not a representation.
    ///
    /// This is the decision that was generating the complexity, and naming it
    /// dissolves it. The row facts looked representation-bound because the
    /// signature took the legacy tuple, but the body only ever used
    /// `shiftID`, `day` and the shift's period. All three sit directly on a
    /// `ShiftRecord`, so no enum over the two representations and no generic
    /// over `LegacyShiftRow` is needed here at all -- each caller supplies the
    /// three from its own shape, the legacy one via `ShiftDetails.resolve` and
    /// the record one by reading its own canonical fields.
    func rowFacts(
        shiftID: UUID,
        day: Date,
        period: ShiftPeriod?,
        shiftCount: Int,
        note: String?
    ) -> ShiftDayRowFacts {
        ShiftDayRowFacts(
            valuation: snapshot?.valuation(shiftID),
            wageFeatureEnabled: snapshot?.wageFeatureEnabled ?? false,
            stamp: stamp,
            day: day,
            period: period,
            dayHasMultipleShifts: shiftCount >= 2,
            note: note
        )
    }

    /// The legacy shape, delegating, so this change moves no behaviour.
    func rowFacts(
        for group: (day: Date, shiftID: UUID, items: [TipEntry]),
        shiftCount: Int,
        note: String?
    ) -> ShiftDayRowFacts {
        rowFacts(
            shiftID: group.shiftID,
            day: group.day,
            period: ShiftDetails.resolve(from: group.items).shiftPeriod,
            shiftCount: shiftCount,
            note: note
        )
    }

    /// The record shape. One record already holds the canonical period, so
    /// there is nothing to resolve -- which is the two-row model's cost
    /// disappearing rather than being ported.
    func rowFacts(
        for record: ShiftRecord,
        shiftCount: Int,
        note: String?
    ) -> ShiftDayRowFacts {
        rowFacts(
            shiftID: record.id,
            day: record.workDate,
            period: record.shiftPeriod,
            shiftCount: shiftCount,
            note: note
        )
    }
}

struct DayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PolicyStore.self) private var policyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var allEntries: [TipEntry]

    let date: Date
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var undoState = UndoDeleteToastState()

    /// Always "Wed, Jul 15" — weekday abbrev, month, day. ShiftDays.humanLabel
    /// (which this sheet used to show) collapses recent days to "Today" /
    /// bare "Wednesday", which reads fine in a list of shifts but not as a
    /// sheet title naming one specific day.
    private var titleText: String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        // No `Key` and no `dataRevision`: the facts carry the snapshot's
        // stamp, which is the computed dependency list (contract rule 3).
        let facts = DayDetailFacts(
            allEntries: allEntries,
            date: date,
            policies: policyStore.policies,
            payrollTimeZone: policyStore.payrollTimeZone
        )
        NavigationStack {
            List {
                if facts.shifts.isEmpty {
                    Text(facts.isUnbacked ? "Payday couldn't read this day." : "No tips logged this day.")
                        .foregroundStyle(PaydayColor.textSecondary)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        heroCard(figure: facts.total)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: PaydaySpacing.p16, bottom: 4, trailing: PaydaySpacing.p16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section("Shifts") {
                        ForEach(facts.shifts, id: \.shiftID) { group in
                            shiftRow(
                                for: group,
                                rowFacts: facts.rowFacts(
                                    for: group,
                                    shiftCount: facts.shifts.count,
                                    note: Self.shiftNote(from: group.items)
                                )
                            )
                        }
                    }
                    .listRowBackground(PaydayColor.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        sheetTarget = .new(defaultDate: date)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Log shift")
                }
            }
            .sheet(item: $sheetTarget) { target in
                LogTipSheet(target: target).paydayAppearance()
            }
        }
        .undoDeleteToast(undoState, context: modelContext)
        .presentationDetents([.medium, .large])
        .presentationBackground(PaydayColor.background)
    }

    /// The sheet's one hero — same grammar as the Dashboard/Period-detail
    /// heroes (caption above a big monospaced number), floating directly on
    /// the sheet's background rather than inside its own card: this sheet
    /// has no second object competing for attention, so a shadow here would
    /// mark nothing.
    /// A shift's note. Not a ShiftDetails field: `note` lives per-entry
    /// rather than on the one canonical row, and LogTipSheet writes the
    /// same text onto every row of a shift, so this takes the first
    /// non-empty one rather than joining duplicates.
    private static func shiftNote(from entries: [TipEntry]) -> String? {
        entries.compactMap(\.note).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The label is the figure's own — `EarningsFigure` decides whether this
    /// day may be called a "Total", and `.partial` never may.
    private func heroCard(figure: EarningsFigure) -> some View {
        VStack(spacing: 6) {
            Text(figure.label)
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(figure.text ?? ShiftDayRow.unavailablePlaceholder)
                .font(PaydayFont.displayLarge)
                .monospacedDigit()
                .foregroundStyle(figure.isUnavailable ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: figure.cents)
            if let caption = figure.caption {
                Text(caption)
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PaydaySpacing.p24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            figure.text.map { "\(figure.label). \($0)" } ?? "\(figure.label). Amount unavailable."
        )
    }

    @ViewBuilder
    private func shiftRow(
        for group: (day: Date, shiftID: UUID, items: [TipEntry]),
        rowFacts: ShiftDayRowFacts
    ) -> some View {
        if let anchor = group.items.first {
            Button {
                sheetTarget = .edit(anchor)
            } label: {
                ShiftDayRow(facts: rowFacts)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    undoState.delete(group.items, in: modelContext)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .shiftContextMenu(group.items, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
        }
    }
}
