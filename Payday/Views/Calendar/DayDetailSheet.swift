import SwiftUI
import SwiftData

private struct DayDetailFacts: SnapshotFacts {
    let shifts: [(day: Date, shiftID: UUID, items: [TipEntry])]
    /// The engine's valuation of exactly the shifts `shifts` lists, so each
    /// row prints its own slice of the ledger's allocation and the hero is
    /// the sum of exactly those slices.
    ///
    /// PR 5 wave 0 changed where this comes from, not what it says: the
    /// wages are the same `CompensationLedger` allocation `WageEstimate
    /// .centsByShiftID` was already returning, now reached through a whole
    /// `EarningsSnapshot` so a row can take a `ShiftValuation` instead of a
    /// loose `Int` that cannot tell zero from unknown.
    ///
    /// Group 2.2 (Calendar + day detail) is WAVE 1. The hero below is
    /// deliberately still composed the old way; wave 1 replaces it with
    /// `snapshot.day(_:)`, which is also what finally closes the known
    /// issue in `EarningsParityTests`.
    let snapshot: EarningsSnapshot?
    let stamp: SnapshotStamp?
    let totalCents: Int

    init(allEntries: [TipEntry], date: Date, wageCentsPerHour: Int?, payrollTimeZone: TimeZone, workweekStartWeekday: Int) {
        var calendar = Calendar.current
        // The same civil day the tile that opened this sheet drew.
        calendar.timeZone = payrollTimeZone
        let day = calendar.startOfDay(for: date)
        let entries = allEntries.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let resolvedShifts = ShiftDays.groupedByShift(
            entries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: calendar
        )
        let resolvedSnapshot = LegacySnapshotBridge.snapshot(
            shifts: resolvedShifts,
            rateCents: wageCentsPerHour,
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: workweekStartWeekday,
            asOf: date
        )
        shifts = resolvedShifts
        snapshot = resolvedSnapshot
        stamp = resolvedSnapshot?.stamp
        // Σ of the rows' own figures, never a separately-computed total.
        totalCents = TipBreakdown.total(of: entries).netTotalCents
            + resolvedShifts.reduce(0) { $0 + (resolvedSnapshot?.valuation($1.shiftID)?.components.wagesCents ?? 0) }
    }

    func rowFacts(
        for group: (day: Date, shiftID: UUID, items: [TipEntry]),
        shiftCount: Int,
        note: String?
    ) -> ShiftDayRowFacts {
        ShiftDayRowFacts(
            valuation: snapshot?.valuation(group.shiftID),
            wageFeatureEnabled: snapshot?.wageFeatureEnabled ?? false,
            stamp: stamp,
            day: group.day,
            period: ShiftDetails.resolve(from: group.items).shiftPeriod,
            dayHasMultipleShifts: shiftCount >= 2,
            note: note
        )
    }
}

struct DayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(PayScheduleStore.self) private var scheduleStore
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
        let facts = DayDetailFacts(
            allEntries: allEntries,
            date: date,
            wageCentsPerHour: preferencesStore.baseHourlyWageCents,
            payrollTimeZone: policyStore.payrollTimeZone,
            workweekStartWeekday: policyStore.latestCalendarPolicy?.workweekStartWeekday
                ?? scheduleStore.schedule?.resolvedFirstWeekday
                ?? Calendar.current.firstWeekday
        )
        NavigationStack {
            List {
                if facts.shifts.isEmpty {
                    Text("No tips logged this day.")
                        .foregroundStyle(PaydayColor.textSecondary)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        heroCard(totalCents: facts.totalCents)
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

    private func heroCard(totalCents: Int) -> some View {
        VStack(spacing: 6) {
            Text("Total")
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(Money.string(fromCents: totalCents))
                .font(PaydayFont.displayLarge)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: totalCents)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PaydaySpacing.p24)
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
