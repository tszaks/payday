import Combine
import SwiftUI
import SwiftData

/// One immutable History render.
///
/// PR 5 group 2.4, wave 1. The contract is
/// `Payday/Earnings/SnapshotFacts.swift`; this struct keeps only
/// presentation, and every cents figure on it arrived from an
/// `EarningsSnapshot` query that it does not touch.
///
/// A row's figure is `snapshot.range(that period's civil days)` — literally
/// the query `PeriodDetailFacts` asks for its hero — so a row and the screen
/// it opens are one engine answering once, not two additions that agree. It
/// used to be `TipBreakdown.netTotalCents + PeriodIncome.wages(...)
/// .totalCents` over entries re-bucketed per period, which is a different
/// chain from the detail's and allocated overtime inside the period rather
/// than across the workweek.
struct PeriodsPageFacts: SnapshotFacts {
    struct Row: Identifiable {
        var id: PayPeriod { period }

        // MARK: Presentation

        let period: PayPeriod
        let payDate: Date
        let isCurrent: Bool
        /// The shift's entries are not here on purpose: a row navigates, it
        /// does not edit.
        let paycheck: PaycheckRecord?

        // MARK: Money, from the engine

        /// The period's result, kept whole so a caller can compare scopes
        /// and completeness rather than bare cents.
        let result: EarningsResult?
        /// The row's one money line, labelled by its own completeness.
        let earned: EarningsFigure
        /// The recorded check next to what this period's own result expects,
        /// or nil when no check has been entered.
        let checked: PeriodCheckComparison?
    }

    // MARK: Presentation

    let rows: [Row]
    let year: Int
    /// Whether the year-to-date header has anything to say. False on a fresh
    /// install, where the old code checked "are there any nights" and this
    /// checks the engine's own shift count for the year.
    let hasYearToDate: Bool
    /// `CompletenessCopy.shiftCount` — "1 shift" / "N shifts" — over the
    /// year's own selection, so the caption cannot count shifts the headline
    /// above it did not.
    let yearToDateShiftCountText: String

    // MARK: Money, from the engine

    /// `snapshot.yearToDate(year:)`. The old figure summed
    /// `StatsEngine.nightlyTotals` (which is `nonWageEarnings`) and added
    /// `PeriodIncome.wages` on top, with the year filter taken in
    /// `Calendar.current` rather than the frozen payroll zone.
    let yearToDate: EarningsFigure
    let stamp: SnapshotStamp?

    /// - Parameters:
    ///   - snapshot: `HistoryEarnings.build`'s, until PR 2 S7 makes it
    ///     `earningsStore.snapshot`. Nil renders placeholders, never zeros.
    ///   - schedule: the pay-period GRID. Presentational: it decides which
    ///     periods exist and when each one is paid, and it prices nothing.
    ///     Its `firstWeekday` is NOT a workweek and never reaches a money
    ///     path from here.
    ///   - payrollTimeZone: the FROZEN payroll zone, for reading a period's
    ///     boundary midnights back as civil days.
    init(
        snapshot: EarningsSnapshot?,
        paycheckRecords: [PaycheckRecord],
        schedule: PaySchedule?,
        payrollTimeZone: TimeZone,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let periodCalculator = PayPeriodCalculator(
            payrollTimeZone: payrollTimeZone,
            schedule: schedule ?? .fallback,
            calendar: calendar
        )
        stamp = snapshot?.stamp

        var periods: [PayPeriod] = []
        var cursor = periodCalculator.period(containing: now)
        periods.append(cursor)

        // How far back to walk. The snapshot holds its shifts in canonical
        // work-day order, so the earliest one is `shifts.first` — no scan of
        // the entries and no second date rule.
        let earliestShiftDate = snapshot?.shifts.first?.workDay.date(in: payrollTimeZone)
        let earliestPaycheckDate = paycheckRecords.lazy.map(\.periodStart).min()
        let earliestRelevantDate = [earliestShiftDate, earliestPaycheckDate].compactMap { $0 }.min()
        if let earliestRelevantDate {
            while periods.count < 24, cursor.start > earliestRelevantDate {
                let previousEnd = calendar.date(byAdding: .day, value: -1, to: cursor.start) ?? cursor.start
                cursor = periodCalculator.period(containing: previousEnd)
                periods.append(cursor)
            }
        }

        rows = periods.enumerated().map { index, period in
            let result = HistoryEarnings.earnings(snapshot, for: period, in: payrollTimeZone)
            let paycheck = HistoryEarnings.paycheck(for: period, in: paycheckRecords)
            return Row(
                period: period,
                payDate: periodCalculator.payDate(for: period),
                isCurrent: index == 0,
                paycheck: paycheck,
                result: result,
                earned: result.map(EarningsFigure.earnedIncome) ?? .unavailable(),
                checked: PeriodCheckComparison(result: result, paycheck: paycheck)
            )
        }

        let currentYear = calendar.component(.year, from: now)
        year = currentYear
        let yearResult = snapshot?.yearToDate(year: currentYear)
        yearToDate = yearResult.map(EarningsFigure.earnedIncome) ?? .unavailable()
        hasYearToDate = (yearResult?.completeness.totalShifts ?? 0) > 0
        yearToDateShiftCountText = CompletenessCopy.shiftCount(yearResult?.completeness.totalShifts ?? 0)
    }
}

/// What the snapshot itself was built from, and the ONLY thing this screen
/// caches.
///
/// There is no `PeriodsPageFactsKey` any more, and rule 3 is why: a
/// hand-maintained list of the inputs that can move a number is a list with
/// something missing from it. `stamp.digest` is the complete one, computed —
/// every shift, both policy histories, the cutoff and the engine version. So
/// the facts are no longer cached at all; they are recomputed from the cached
/// snapshot on every pass, which is 24 `range(_:)` queries over a
/// binary-searched index and MEASURED at 0.2ms over a 10,000-shift history
/// against the 69ms the snapshot BUILD costs. Caching the cheap half and
/// keying it by hand is what produced the stale-figure bugs the stamp exists
/// to end.
///
/// The build still needs a cache, and it needs a trigger a stamp cannot
/// give: a snapshot has to exist before it has a stamp. These three fields
/// are that trigger. They are not a dependency list — "the local store was
/// written" and "the policy value changed" between them cover every input
/// the build reads.
///
/// When PR 2 S7 lands, `EarningsStore` owns this and the whole struct goes.
private struct HistorySnapshotCache {
    let writes: Int
    let policies: CompensationPolicies
    let payrollTimeZone: TimeZone
    let build: HistoryEarnings.Build
}

struct PeriodsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(PolicyStore.self) private var policyStore
    @Environment(TabRouter.self) private var tabRouter
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    /// Owned by HistoryView's single NavigationStack — passed down rather
    /// than @State here so pushes from this lens and the QA/deep-link hooks
    /// below land on the same stack the Calendar lens shares.
    @Binding var path: NavigationPath
    @State private var snapshotCache: HistorySnapshotCache?
    /// Local writes, counted. The snapshot's rebuild trigger and nothing
    /// else: no figure, no label and no cache key is derived from it.
    @State private var writes = 0
    @State private var currentDay = Calendar.current.startOfDay(for: .now)

    var body: some View {
        let schedule = scheduleStore.schedule
        let build = snapshotBuild()
        let facts = PeriodsPageFacts(
            snapshot: build.snapshot,
            paycheckRecords: paycheckRecords,
            schedule: schedule,
            payrollTimeZone: policyStore.payrollTimeZone,
            now: currentDay
        )
        ScrollView {
            LazyVStack(spacing: 0) {
                if facts.hasYearToDate {
                    yearToDateCard(facts)
                    Divider()
                }
                ForEach(facts.rows) { row in
                    NavigationLink(value: row.period) {
                        PeriodRow(row: row)
                    }
                    .buttonStyle(PressableButtonStyle())
                    if row.period != facts.rows.last?.period {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .background(PaydayColor.background)
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-OpenPeriodWithPaycheck"), path.isEmpty,
               let periodWithPaycheck = facts.rows.first(where: { $0.paycheck != nil })?.period {
                path.append(periodWithPaycheck)
            }
        }
        #endif
        .onAppear { consumePendingCurrentPeriodDetail(facts) }
        .onChange(of: tabRouter.pendingCurrentPeriodDetail) { _, _ in consumePendingCurrentPeriodDetail(facts) }
        .task(id: SnapshotBuildKey(
            writes: writes,
            policies: policyStore.policies,
            payrollTimeZone: policyStore.payrollTimeZone
        )) {
            // The build ran during `body` on a cache miss; storing it there
            // would be a `@State` write mid-render, so the store happens
            // here on the next turn of the loop.
            snapshotCache = HistorySnapshotCache(
                writes: writes,
                policies: policyStore.policies,
                payrollTimeZone: policyStore.payrollTimeZone,
                build: build
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            writes &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshCurrentDay()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshCurrentDay() }
        }
        .navigationDestination(for: PayPeriod.self) { period in
            PeriodDetailView(period: period)
        }
    }

    /// The snapshot, rebuilt only when the local store or the compensation
    /// policies move.
    private func snapshotBuild() -> HistoryEarnings.Build {
        let policies = policyStore.policies
        let zone = policyStore.payrollTimeZone
        if let cached = snapshotCache,
           cached.writes == writes,
           cached.policies == policies,
           cached.payrollTimeZone == zone {
            return cached.build
        }
        return HistoryEarnings.build(
            entries: allEntries,
            policies: policies,
            payrollTimeZone: zone
        )
    }

    private func refreshCurrentDay() {
        currentDay = Calendar.current.startOfDay(for: .now)
    }

    /// "See all" on Dashboard sets the flag and switches tabs in the same
    /// beat — this view may not have appeared yet at that instant, so both
    /// onAppear and onChange call through here rather than picking one.
    /// Only acts when the stack is empty, same guard the -OpenPeriodWithPaycheck
    /// debug hook uses, so it never interrupts navigation already in flight.
    private func consumePendingCurrentPeriodDetail(_ facts: PeriodsPageFacts) {
        guard tabRouter.pendingCurrentPeriodDetail, path.isEmpty, let currentPeriod = facts.rows.first?.period else { return }
        path.append(currentPeriod)
        tabRouter.pendingCurrentPeriodDetail = false
    }
}

/// The three inputs a snapshot rebuild depends on. Not a figure key: nothing
/// rendered is derived from it.
struct SnapshotBuildKey: Equatable {
    let writes: Int
    let policies: CompensationPolicies
    let payrollTimeZone: TimeZone
}

extension PeriodsView {
    /// A distinct header block, not a card — type hierarchy (the display-size
    /// amount) is what marks this as the year's headline figure, the same way
    /// the rest of this budget pass replaces elevation with typography.
    ///
    /// This is the one figure on the screen that carries a LABEL, so it is
    /// the one that carries the completeness caption: "Wages estimated from
    /// your current rate" belongs on a headline once, not appended to
    /// twenty-four rows that would all say it.
    fileprivate func yearToDateCard(_ facts: PeriodsPageFacts) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(String(facts.year)) Year to Date")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(facts.yearToDate.text ?? ShiftDayRow.unavailablePlaceholder)
                    .font(PaydayFont.displaySmall)
                    .monospacedDigit()
                    .foregroundStyle(
                        facts.yearToDate.isUnavailable
                            ? PaydayColor.textSecondary
                            : PaydayColor.textPrimary
                    )
                if let caption = facts.yearToDate.caption {
                    Text(caption)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Text(facts.yearToDateShiftCountText)
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
        }
        .padding(.vertical, PaydaySpacing.p12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(yearToDateAccessibilityLabel(facts))
    }

    /// VoiceOver gets the LABEL the completeness rules allow next to the
    /// figure, which the visual header leaves to its kicker: "Known so far"
    /// rather than a bare amount that sounds settled.
    fileprivate func yearToDateAccessibilityLabel(_ facts: PeriodsPageFacts) -> String {
        let prefix = "\(String(facts.year)) year to date, \(facts.yearToDate.label)"
        guard let amount = facts.yearToDate.text else {
            return "\(prefix), amount unavailable. \(facts.yearToDateShiftCountText)."
        }
        return "\(prefix) \(amount). \(facts.yearToDateShiftCountText)."
    }
}

private struct PeriodRow: View {
    let row: PeriodsPageFacts.Row

    var body: some View {
        HStack(alignment: .center, spacing: PaydaySpacing.p12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dateRangeString)
                        .font(PaydayFont.headline)
                        .foregroundStyle(PaydayColor.textPrimary)
                    if row.isCurrent {
                        Text("Current")
                            .font(PaydayFont.caption2)
                            .foregroundStyle(PaydayColor.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(PaydayColor.primary.opacity(0.15), in: Capsule())
                    }
                }
                // One money line, and no label beside it — which is also why
                // a partial period cannot print the word "Total" here. An
                // unreadable dataset prints the placeholder, never $0.00.
                Text(row.earned.text ?? ShiftDayRow.unavailablePlaceholder)
                    .font(PaydayFont.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(payDateLine)
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            Spacer(minLength: 0)
            // Every row here is a NavigationLink — the disclosure chevron
            // shows on all of them now, not just the one row that happens
            // to have no paycheck comparison yet, so tappability reads
            // consistently regardless of what else is showing.
            HStack(spacing: 6) {
                if let checked = row.checked {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(deltaString(checked.deltaCents))
                            .font(PaydayFont.displaySmall)
                            .monospacedDigit()
                            .foregroundStyle(checked.isShort ? PaydayColor.error : PaydayColor.primary)
                        Text("checked")
                            .font(PaydayFont.caption2)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textTertiary)
            }
        }
        .padding(.vertical, PaydaySpacing.p12)
    }

    /// The quiet third line. A period the engine could only partly value
    /// says so HERE, on a line that already exists, rather than in a fourth
    /// one — and only for `.partial`, which is specific to this period and
    /// fixable in the app. `.estimated` applies to every row at once and is
    /// disclosed on the year-to-date headline instead.
    private var payDateLine: String {
        let payDate = PaydayCopy.payDateText(payDate: row.payDate)
        guard case .partial = row.earned.completeness.state, let caption = row.earned.caption else {
            return payDate
        }
        return "\(payDate) · \(caption)"
    }

    private var dateRangeString: String {
        "\(row.period.start.formatted(.dateTime.month(.abbreviated).day())) – \(row.period.end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func deltaString(_ deltaCents: Int) -> String {
        let sign = deltaCents > 0 ? "+" : (deltaCents < 0 ? "-" : "")
        return sign + Money.string(fromCents: abs(deltaCents))
    }
}
