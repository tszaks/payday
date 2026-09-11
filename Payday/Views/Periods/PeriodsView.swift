import Combine
import SwiftUI
import SwiftData

/// One immutable History render. Entries and paychecks are partitioned once
/// instead of filtering the entire data set again for every visible period.
struct PeriodsPageFacts {
    struct Row {
        let period: PayPeriod
        let breakdown: TipBreakdown
        let wages: PeriodIncome.Wages?
        let paycheck: PaycheckRecord?
    }

    let calculator: PayPeriodCalculator
    let rows: [Row]
    let yearToDateNights: [(date: Date, cents: Int)]
    let yearToDateWages: PeriodIncome.Wages?
    let yearToDateShiftCount: Int

    init(
        allEntries: [TipEntry],
        paycheckRecords: [PaycheckRecord],
        schedule: PaySchedule?,
        wageCentsPerHour: Int?,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let periodCalculator = PayPeriodCalculator(schedule: schedule ?? .fallback, calendar: calendar)
        calculator = periodCalculator

        var periods: [PayPeriod] = []
        var cursor = periodCalculator.period(containing: now)
        periods.append(cursor)

        let earliestEntryDate = allEntries.lazy.map(\.date).min()
        let earliestPaycheckDate = paycheckRecords.lazy.map(\.periodStart).min()
        let earliestRelevantDate = [earliestEntryDate, earliestPaycheckDate].compactMap { $0 }.min()
        if let earliestRelevantDate {
            while periods.count < 24, cursor.start > earliestRelevantDate {
                let previousEnd = calendar.date(byAdding: .day, value: -1, to: cursor.start) ?? cursor.start
                cursor = periodCalculator.period(containing: previousEnd)
                periods.append(cursor)
            }
        }

        let entriesByPeriod = Dictionary(grouping: allEntries) {
            periodCalculator.period(containing: $0.date)
        }
        var paychecksByPeriod: [PayPeriod: PaycheckRecord] = [:]
        for paycheck in paycheckRecords {
            let period = periodCalculator.period(containing: paycheck.periodEnd)
            if paychecksByPeriod[period] == nil {
                paychecksByPeriod[period] = paycheck
            }
        }
        rows = periods.map { period in
            let entries = entriesByPeriod[period] ?? []
            return Row(
                period: period,
                breakdown: TipBreakdown.total(of: entries),
                wages: PeriodIncome.wages(
                    entries: entries,
                    wageCentsPerHour: wageCentsPerHour,
                    firstWeekday: schedule?.firstWeekday
                ),
                paycheck: paychecksByPeriod[period]
            )
        }

        let currentYear = calendar.component(.year, from: now)
        let yearEntries = allEntries.filter {
            calendar.component(.year, from: $0.date) == currentYear
        }
        yearToDateNights = StatsEngine(records: yearEntries.map(TipRecord.init)).nightlyTotals()
        yearToDateWages = PeriodIncome.wages(
            entries: yearEntries,
            wageCentsPerHour: wageCentsPerHour,
            firstWeekday: schedule?.firstWeekday
        )
        yearToDateShiftCount = ShiftDays.groupedByShift(
            yearEntries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: calendar
        ).count
    }
}

private struct PeriodsPageFactsKey: Equatable {
    let entriesRevision: Int
    let paychecksRevision: Int
    let frequency: PayFrequency?
    let anchorPeriodEnd: Date?
    let payDelayDays: Int?
    let firstWeekday: Int?
    let wageCentsPerHour: Int?
    let currentDay: Date
}

private struct PeriodsPageFactsCache {
    let key: PeriodsPageFactsKey
    let facts: PeriodsPageFacts
}

struct PeriodsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(TabRouter.self) private var tabRouter
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    /// Owned by HistoryView's single NavigationStack — passed down rather
    /// than @State here so pushes from this lens and the QA/deep-link hooks
    /// below land on the same stack the Calendar lens shares.
    @Binding var path: NavigationPath
    @State private var factsCache: PeriodsPageFactsCache?
    @State private var dataRevision = 0
    @State private var currentDay = Calendar.current.startOfDay(for: .now)

    var body: some View {
        let schedule = scheduleStore.schedule
        let key = PeriodsPageFactsKey(
            entriesRevision: dataRevision,
            paychecksRevision: dataRevision,
            frequency: schedule?.frequency,
            anchorPeriodEnd: schedule?.anchorPeriodEnd,
            payDelayDays: schedule?.payDelayDays,
            firstWeekday: schedule?.firstWeekday,
            wageCentsPerHour: preferencesStore.baseHourlyWageCents,
            currentDay: currentDay
        )
        let facts = factsCache?.key == key
            ? factsCache!.facts
            : makeFacts()
        ScrollView {
            LazyVStack(spacing: 0) {
                if !facts.yearToDateNights.isEmpty {
                    yearToDateCard(facts)
                    Divider()
                }
                ForEach(Array(facts.rows.enumerated()), id: \.element.period) { index, row in
                    NavigationLink(value: row.period) {
                        PeriodRow(
                            period: row.period,
                            isCurrent: index == 0,
                            loggedCents: row.breakdown.netTotalCents + (row.wages?.totalCents ?? 0),
                            expectedTipAndGratuityCents: PredictedPaycheck.tipsLineCents(from: row.breakdown) + row.breakdown.gratuityFeesCents,
                            payDate: facts.calculator.payDate(for: row.period),
                            paycheck: row.paycheck
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    if index < facts.rows.count - 1 {
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
        .task(id: key) {
            guard factsCache?.key != key else { return }
            factsCache = PeriodsPageFactsCache(key: key, facts: facts)
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            dataRevision &+= 1
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

    private func makeFacts() -> PeriodsPageFacts {
        PeriodsPageFacts(
            allEntries: allEntries,
            paycheckRecords: paycheckRecords,
            schedule: scheduleStore.schedule,
            wageCentsPerHour: preferencesStore.baseHourlyWageCents,
            now: currentDay
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

extension PeriodsView {
    /// A distinct header block, not a card — type hierarchy (the display-size
    /// amount) is what marks this as the year's headline figure, the same way
    /// the rest of this budget pass replaces elevation with typography.
    fileprivate func yearToDateCard(_ facts: PeriodsPageFacts) -> some View {
        let totalCents = facts.yearToDateNights.reduce(0) { $0 + $1.cents } + (facts.yearToDateWages?.totalCents ?? 0)
        let year = Calendar.current.component(.year, from: .now)
        let shiftCount = facts.yearToDateShiftCount
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(String(year)) Year to Date")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: totalCents))
                    .font(PaydayFont.displaySmall)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
            }
            Spacer(minLength: 0)
            Text(shiftCount == 1 ? "1 shift" : "\(shiftCount) shifts")
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
        }
        .padding(.vertical, PaydaySpacing.p12)
    }
}

private struct PeriodRow: View {
    let period: PayPeriod
    let isCurrent: Bool
    let loggedCents: Int
    /// What the stub's Tips and Gratuity lines should total for this period:
    /// credit tips net of tip-out plus separately logged employee gratuity.
    /// This is never the wage-inclusive loggedCents.
    let expectedTipAndGratuityCents: Int
    let payDate: Date
    let paycheck: PaycheckRecord?

    var body: some View {
        HStack(alignment: .center, spacing: PaydaySpacing.p12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dateRangeString)
                        .font(PaydayFont.headline)
                        .foregroundStyle(PaydayColor.textPrimary)
                    if isCurrent {
                        Text("Current")
                            .font(PaydayFont.caption2)
                            .foregroundStyle(PaydayColor.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(PaydayColor.primary.opacity(0.15), in: Capsule())
                    }
                }
                Text(Money.string(fromCents: loggedCents))
                    .font(PaydayFont.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(PaydayCopy.payDateText(payDate: payDate))
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            Spacer(minLength: 0)
            // Every row here is a NavigationLink — the disclosure chevron
            // shows on all of them now, not just the one row that happens
            // to have no paycheck comparison yet, so tappability reads
            // consistently regardless of what else is showing.
            HStack(spacing: 6) {
                if let paycheck {
                    let paidTipEarningsCents = PredictedPaycheck.paidTipEarningsCents(
                        tipsCents: paycheck.reconciledPaidTipsCents,
                        gratuityCents: paycheck.gratuityCents
                    )
                    let delta = paidTipEarningsCents - expectedTipAndGratuityCents
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(deltaString(delta))
                            .font(PaydayFont.displaySmall)
                            .monospacedDigit()
                            .foregroundStyle(delta < 0 ? PaydayColor.error : PaydayColor.primary)
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

    private var dateRangeString: String {
        "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(period.end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func deltaString(_ deltaCents: Int) -> String {
        let sign = deltaCents > 0 ? "+" : (deltaCents < 0 ? "-" : "")
        return sign + Money.string(fromCents: abs(deltaCents))
    }
}
