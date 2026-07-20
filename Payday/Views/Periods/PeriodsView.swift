import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Defers the actual CSV build (and its temp-file write) until the share
/// sheet asks for the file's data, inside FileRepresentation's closure —
/// never while ShareLink itself is just rendering in the toolbar. Fixes a
/// real perf regression: the plain-URL version this replaced regenerated
/// the whole export and rewrote the file on every single body render.
private struct CSVExport: Transferable {
    let entries: [TipEntry]
    let paycheckRecords: [PaycheckRecord]
    let calculator: PayPeriodCalculator

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Payday-Export.csv")
            let csv = CSVExporter.export(entries: export.entries, paycheckRecords: export.paycheckRecords, calculator: export.calculator)
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

struct PeriodsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(TabRouter.self) private var tabRouter
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    private var calculator: PayPeriodCalculator {
        PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
    }

    /// Current period plus history, walking backward until we run out of
    /// entries/paychecks to show, capped so the list stays bounded.
    private var periods: [PayPeriod] {
        var result: [PayPeriod] = []
        var cursor = calculator.period(containing: .now)
        result.append(cursor)

        let earliestEntryDate = allEntries.map(\.date).min()
        let earliestPaycheckDate = paycheckRecords.map(\.periodStart).min()
        let earliestRelevantDate = [earliestEntryDate, earliestPaycheckDate].compactMap { $0 }.min()

        guard let earliestRelevantDate else { return result }

        while result.count < 24, cursor.start > earliestRelevantDate {
            let previousEnd = Calendar.current.date(byAdding: .day, value: -1, to: cursor.start) ?? cursor.start
            cursor = calculator.period(containing: previousEnd)
            result.append(cursor)
        }
        return result
    }

    private func breakdown(for period: PayPeriod) -> TipBreakdown {
        TipBreakdown.total(of: allEntries.filter { $0.date >= period.start && $0.date <= period.end })
    }

    /// Base wage + overtime for a period's shifts, same definition of period
    /// income the dashboard hero and period detail use — nil when no rate
    /// is set.
    private func wages(for period: PayPeriod) -> PeriodIncome.Wages? {
        let periodEntries = allEntries.filter { $0.date >= period.start && $0.date <= period.end }
        return PeriodIncome.wages(entries: periodEntries, wageCentsPerHour: preferencesStore.baseHourlyWageCents, firstWeekday: scheduleStore.schedule?.firstWeekday)
    }

    private func paycheck(for period: PayPeriod) -> PaycheckRecord? {
        // Containment match (see PeriodDetailView) so paychecks survive a
        // schedule change instead of orphaning on exact-boundary equality.
        paycheckRecords.first { $0.periodEnd >= period.start && $0.periodEnd <= period.end }
    }

    /// This calendar year's entries — every YTD figure below reads from
    /// this single filtered set.
    private var yearToDateEntries: [TipEntry] {
        let year = Calendar.current.component(.year, from: .now)
        return allEntries.filter { Calendar.current.component(.year, from: $0.date) == year }
    }

    /// Net of any tip-outs — same rule StatsEngine applies everywhere else
    /// money gets summed. Tips-only; wages are added in separately below.
    private var yearToDateNights: [(date: Date, cents: Int)] {
        StatsEngine(records: yearToDateEntries.map(TipRecord.init)).nightlyTotals()
    }

    /// Base wage + overtime across the whole year, computed ONCE over all of
    /// the year's entries (not per period) so overtime buckets by calendar
    /// workweek exactly like a real paycheck, regardless of pay-period
    /// boundaries — same definition of period income every other total here
    /// uses, just widened to the year.
    private var yearToDateWages: PeriodIncome.Wages? {
        PeriodIncome.wages(entries: yearToDateEntries, wageCentsPerHour: preferencesStore.baseHourlyWageCents, firstWeekday: scheduleStore.schedule?.firstWeekday)
    }

    /// A shift, not a day — a double day is 2 shifts, same counting rule the
    /// Dashboard's Shifts section uses.
    private var yearToDateShiftCount: Int {
        ShiftDays.groupedByShift(yearToDateEntries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod).count
    }

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: PaydaySpacing.p12) {
                    if !yearToDateNights.isEmpty {
                        yearToDateCard
                    }
                    ForEach(periods.indices, id: \.self) { index in
                        let period = periods[index]
                        let periodBreakdown = breakdown(for: period)
                        let periodWages = wages(for: period)
                        NavigationLink(value: period) {
                            PeriodRow(
                                period: period,
                                isCurrent: index == 0,
                                loggedCents: periodBreakdown.netTotalCents + (periodWages?.totalCents ?? 0),
                                loggedCreditCents: periodBreakdown.creditCents,
                                tipsNetCents: periodBreakdown.netTotalCents,
                                payDate: calculator.payDate(for: period),
                                paycheck: paycheck(for: period)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.horizontal, PaydaySpacing.p16)
                .padding(.top, PaydaySpacing.p8)
            }
            .contentMargins(.bottom, 88, for: .scrollContent)
            .background(PaydayColor.background)
            .navigationTitle("Periods")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // The CSV itself is only built and written to disk when
                    // the share sheet actually asks for the file's data
                    // (inside CSVExport's FileRepresentation closure) —
                    // never on a plain render of this toolbar item.
                    ShareLink(
                        item: CSVExport(entries: allEntries, paycheckRecords: paycheckRecords, calculator: calculator),
                        preview: SharePreview("Payday-Export.csv")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenPeriodWithPaycheck"), path.isEmpty,
                   let periodWithPaycheck = periods.first(where: { paycheck(for: $0) != nil }) {
                    path.append(periodWithPaycheck)
                }
            }
            #endif
            .onAppear { consumePendingCurrentPeriodDetail() }
            .onChange(of: tabRouter.pendingCurrentPeriodDetail) { _, _ in consumePendingCurrentPeriodDetail() }
            .navigationDestination(for: PayPeriod.self) { period in
                PeriodDetailView(period: period)
            }
        }
    }

    /// "See all" on Dashboard sets the flag and switches tabs in the same
    /// beat — this view may not have appeared yet at that instant, so both
    /// onAppear and onChange call through here rather than picking one.
    /// Only acts when the stack is empty, same guard the -OpenPeriodWithPaycheck
    /// debug hook uses, so it never interrupts navigation already in flight.
    private func consumePendingCurrentPeriodDetail() {
        guard tabRouter.pendingCurrentPeriodDetail, path.isEmpty, let currentPeriod = periods.first else { return }
        path.append(currentPeriod)
        tabRouter.pendingCurrentPeriodDetail = false
    }
}

extension PeriodsView {
    fileprivate var yearToDateCard: some View {
        let totalCents = yearToDateNights.reduce(0) { $0 + $1.cents } + (yearToDateWages?.totalCents ?? 0)
        let year = Calendar.current.component(.year, from: .now)
        let shiftCount = yearToDateShiftCount
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
        .paydayCard()
    }
}

private struct PeriodRow: View {
    let period: PayPeriod
    let isCurrent: Bool
    let loggedCents: Int
    let loggedCreditCents: Int
    /// Tips-only net (no wages), for the "checked" comparison's all-cash
    /// fallback below — a paycheck's tips line never includes wages, so
    /// that comparison can't use the wage-inclusive loggedCents either.
    let tipsNetCents: Int
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
                    .foregroundStyle(PaydayColor.textTertiary)
            }
            Spacer(minLength: 0)
            // Every row here is a NavigationLink — the disclosure chevron
            // shows on all of them now, not just the one row that happens
            // to have no paycheck comparison yet, so tappability reads
            // consistently regardless of what else is showing.
            HStack(spacing: 6) {
                if let paycheck {
                    // Match PaycheckComparisonView: credit if any, else fall
                    // back to the tips-only total (legacy all-cash periods
                    // have no credit to compare) — never the wage-inclusive
                    // loggedCents, since a paycheck's tips line never
                    // includes wages either.
                    let comparedCents = loggedCreditCents > 0 ? loggedCreditCents : tipsNetCents
                    let delta = paycheck.paidTipsCents - comparedCents
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(deltaString(delta))
                            .font(PaydayFont.displaySmall)
                            .monospacedDigit()
                            .foregroundStyle(delta < 0 ? PaydayColor.error : PaydayColor.primary)
                        Text("checked")
                            .font(PaydayFont.caption2)
                            .foregroundStyle(PaydayColor.textTertiary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textTertiary)
            }
        }
        .paydayCard()
    }

    private var dateRangeString: String {
        "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(period.end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func deltaString(_ deltaCents: Int) -> String {
        let sign = deltaCents > 0 ? "+" : (deltaCents < 0 ? "-" : "")
        return sign + Money.string(fromCents: abs(deltaCents))
    }
}
