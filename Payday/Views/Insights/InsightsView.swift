import Combine
import SwiftUI
import SwiftData

/// Entirely deterministic. Every number and every sentence on this page is
/// computed from local records, so the page renders the same offline as on,
/// instantly, with no spinner and no failure state.
///
/// It used to narrate through a model. That came off because the one job a
/// model could do here that arithmetic cannot — reading a written shift
/// note and tying it to a number — depends on shift notes, which are a
/// rarely-used feature. What remained was a model forbidden from doing
/// arithmetic, choosing among facts the engine already ranks, in exchange
/// for latency, a network dependency, a failure mode, and wording that
/// changed between visits. PR 5 group 2.7 finished that removal:
/// `InsightsService`, its prompt's sixteen money figures, and
/// `InsightsFactsCopy`'s ten prose sections are deleted, not dormant.
///
/// ## A PR 5 wave 2 adapter (groups 2.6 and 2.7)
///
/// To the contract in `Payday/Earnings/SnapshotFacts.swift`: presentation on
/// the facts struct, every money figure derived from one `EarningsSnapshot`,
/// no `Key` struct and no `dataRevision`, and no arithmetic in the view.
///
/// **What it fixes.** This view built its `StatsEngine` with no wage rate at
/// all, so every fact, chart point, typical range, trend, forecast and Move
/// on the page was `nonWageEarnings` while the hero on every other screen —
/// and the word "earnings" in this page's own section headers — was
/// wage-inclusive `earnedIncome`. `docs/METRICS.md` rows [IL-01] through
/// [IL-27] all carried "basis nonWageEarnings" for that reason. The engine is
/// now fed `InsightsEarnings.pricing(...)`, the ledger's own per-shift
/// `earnedIncome`, so one basis runs through every comparison on the page —
/// and that basis is DECLARED, once, by `InsightsBasis.note`, including when
/// it has to fall back to tips because some shift cannot be priced. Read
/// `InsightsEarnings`' header for why the fall-back is the whole page rather
/// than the offending comparison.
struct InsightsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PolicyStore.self) private var policyStore
    /// The other representation. `InsightsEarnings.build` picks one, and it
    /// has to be the same one Dashboard picks: group 2.6's whole point is
    /// that this page and the headline above it share a basis, and reading a
    /// different REPRESENTATION is a sharper version of the same defect than
    /// reading a different basis.
    @Query(sort: \ShiftRecord.workDate, order: .reverse) private var shiftRecords: [ShiftRecord]

    @State private var isShowingBackfillSheet = false
    @State private var renderCache: InsightsRenderCache?
    /// Bumped by `LegacySnapshotRevision` — `EarningsStore`'s own rebuild
    /// triggers — so the cached snapshot is rebuilt when, and only when, an
    /// input to it moved. Replaces the `@State private var dataRevision`
    /// this screen carried, which watched `ModelContext.didSave` alone: a
    /// queued policy change or a midnight rollover left the page serving
    /// figures computed under the old inputs. Gone entirely when PR 2 slice
    /// S7 lets this read `earningsStore.snapshot`.
    @State private var snapshotRevision = 0
    /// Any instant on the current civil day. The DAY itself is derived in
    /// `body` through the payroll calendar, not stored: a stored
    /// `Calendar.current.startOfDay` was the DEVICE's day, so a person who
    /// flew somewhere read a different reference date from the one the
    /// engine buckets by.
    @State private var dayTick = Date.now
    /// The Insights role filter. Nil is "All". Only offered when two or more
    /// roles have shifts (`InsightsEarnings.roleOptions`).
    @State private var selectedRole: String?
    /// The Insights job filter (E3). Nil is "All". Only offered with two or
    /// more jobs (`InsightsEarnings.jobOptions`).
    @State private var selectedJobID: UUID?

    var body: some View {
        let jobOptions = InsightsEarnings.jobOptions(policyStore.policies.jobs)
        // A job that has left the list reads as All.
        let pickedJob = jobOptions.first { $0.id == selectedJobID }
        let job: JobScope = pickedJob.map { .job($0.tag) } ?? .all
        // A picked job's page is in that job's payroll zone; All and one
        // job read the primary's, as before.
        let payrollTimeZone = pickedJob.map { policyStore.payrollTimeZone(forJob: $0.tag) } ?? policyStore.payrollTimeZone
        let payrollCalendar = PayrollCalendar.gridCalendar(in: payrollTimeZone)
        let currentDay = payrollCalendar.startOfDay(for: dayTick)
        // The half of the render cache the snapshot's digest cannot cover,
        // because none of it is an input to the engine. Rule 3 deleted
        // `InsightsPageFactsKey`, which listed the inputs this screen THOUGHT
        // could move a number — the policies, the payroll zone, a
        // `dataRevision` counter. Every one of those is inside
        // `SnapshotStamp.digest` now, a SHA-256 over the complete input set.
        // What is left is genuinely presentational: which civil day it is.
        let selection = InsightsSelection(day: currentDay)
        // ONE grouping and ONE snapshot built from it, over the WHOLE history
        // — the recent-window scoping this page applies is a query argument,
        // never a property of the dataset, because the ledger allocates the
        // overtime threshold across a complete workweek and a windowed slice
        // cannot price the forty-first hour of a week that began before the
        // window. `InsightsEarnings` holds the pair together and its header
        // carries the two defects that come from doing either one twice.
        //
        // The representation switch, inside `InsightsEarnings.build` exactly
        // as this comment promised before the switch existed, and on the
        // same predicate every other switched screen uses.
        let roleOptions = InsightsEarnings.roleOptions(records: shiftRecords, job: job)
        // A role that has left the list (its last shift deleted or renamed)
        // reads as All rather than an empty page.
        let role = selectedRole.flatMap { selected in
            roleOptions.first { ShiftRoleList.matches($0, selected) }
        }
        let dataset = renderCache?.revision == snapshotRevision && renderCache?.role == role
            && renderCache?.job == job
            ? renderCache!.dataset
            : InsightsEarnings.build(
                records: shiftRecords,
                policies: policyStore.policies,
                payrollTimeZone: payrollTimeZone,
                role: role,
                job: job
            )
        // Rule 3: the facts are keyed on the dataset's own digest, the
        // complete computed key, plus this screen's presentational selection.
        let pageFacts = renderCache?.digest == dataset.snapshot?.stamp.digest
            && renderCache?.selection == selection
            && renderCache?.job == job
            ? renderCache!.facts
            : InsightsPageFacts(
                dataset: dataset,
                payrollTimeZone: payrollTimeZone,
                calendar: payrollCalendar,
                now: currentDay
            )
        NavigationStack {
            Group {
                if let facts = pageFacts.facts {
                    resultList(facts, pageFacts: pageFacts, roleOptions: roleOptions, jobOptions: jobOptions)
                } else {
                    ScrollView {
                        VStack(spacing: PaydaySpacing.p16) {
                            // Kept above the empty state too, so a role with
                            // too few shifts for insights can be switched
                            // back to All.
                            jobPicker(jobOptions)
                            rolePicker(roleOptions)
                            emptyState(unlocks: pageFacts.unlocks, shiftCount: pageFacts.shiftCount)
                                .frame(maxWidth: .infinity)
                        }
                        .padding()
                    }
                }
            }
            .background(PaydayColor.background)
            .navigationTitle("Insights")
            .sheet(isPresented: $isShowingBackfillSheet) {
                BackfillSheet().paydayAppearance()
            }
            // QA-only, same launch-arg pattern as -InitialTab: simctl can't
            // tap, so screenshot QA needs the sheet to present itself.
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenBackfillSheet") {
                    isShowingBackfillSheet = true
                }
            }
        }
        .task(id: InsightsCacheIdentity(revision: snapshotRevision, selection: selection, role: role, job: job)) {
            renderCache = InsightsRenderCache(
                revision: snapshotRevision,
                role: role,
                job: job,
                dataset: dataset,
                digest: dataset.snapshot?.stamp.digest,
                selection: selection,
                facts: pageFacts
            )
        }
        .legacySnapshotRevision($snapshotRevision)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            dayTick = .now
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { dayTick = .now }
        }
    }

    /// "All · Bar · Floor". Nothing at all unless two or more roles have
    /// shifts, so an account without roles sees today's page.
    @ViewBuilder
    private func rolePicker(_ roleOptions: [String]) -> some View {
        if !roleOptions.isEmpty {
            Picker("Role", selection: $selectedRole) {
                Text("All").tag(String?.none)
                ForEach(roleOptions, id: \.self) { role in
                    Text(role).tag(Optional(role))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Show insights for")
        }
    }

    /// "All · <job> · <job>", primary first, the Periods picker's look.
    /// Nothing at all with one job, so a one-job account sees today's page.
    @ViewBuilder
    private func jobPicker(_ jobOptions: [JobPolicy]) -> some View {
        if !jobOptions.isEmpty {
            Picker("Job", selection: $selectedJobID) {
                Text("All").tag(UUID?.none)
                ForEach(jobOptions) { job in
                    Text(job.name).tag(UUID?.some(job.id))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Show insights for job")
        }
    }

    /// Five blocks, in this order: THIS MONTH (with the chart), WHAT A
    /// SHIFT USUALLY PAYS, NEXT WEEK, HOW IT'S BEEN RUNNING, BY THE
    /// NUMBERS. Built on the one thing every tipped worker logs, shifts and
    /// what each paid; a block that needs sales, hours or tables is simply
    /// absent for a person who does not log them. Insights reports what
    /// happened, never what "would have" happened (docs/DESIGN.md rule 14).
    private func resultList(_ facts: InsightsFacts, pageFacts: InsightsPageFacts, roleOptions: [String], jobOptions: [JobPolicy]) -> some View {
        let numberRows = InsightsNumbersGrid.rows(for: facts, hourly: pageFacts.hourly)
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                jobPicker(jobOptions)
                rolePicker(roleOptions)

                // The basis, said ONCE, above every figure it governs.
                if let note = pageFacts.basis.note {
                    Text(note)
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 1. THIS MONTH, then the chart whose bar it equals.
                VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
                    if let month = pageFacts.month, let text = month.figure.wholeDollarText {
                        VStack(alignment: .leading, spacing: 2) {
                            kicker("THIS MONTH")
                            Text(text)
                                .font(PaydayFont.displayLarge)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(PaydayColor.textPrimary)
                            Text(month.label)
                                .font(PaydayFont.caption)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    // Chart card: the one visual, and this screen's object.
                    // The chart owns its own label (it doubles as the scrub
                    // readout).
                    NightlyEarningsChart(facts: pageFacts.chartFacts)
                        .paydayCard()
                }
                Divider()

                // 2. WHAT A SHIFT USUALLY PAYS. The spread, which is what
                // anyone budgeting on variable income needs.
                if let reliability = pageFacts.reliability, reliability.hasVisibleRanges {
                    reliabilitySection(reliability)
                    Divider()
                }

                // 3. NEXT WEEK. A description of the coming week at the
                // reader's own rhythm, not a schedule to follow.
                if let plan = pageFacts.plan {
                    VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
                        VStack(alignment: .leading, spacing: 2) {
                            kicker("NEXT WEEK")
                            Text(PlanForwardCopy.headline(for: plan))
                                .font(PaydayFont.displayLarge)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(PaydayColor.textPrimary)
                            // The forecast's own track record: the one
                            // warning about this number.
                            if let accuracy = pageFacts.forecastAccuracy {
                                Text(RevealCopy.forecastAccuracyLine(accuracy))
                                    .font(PaydayFont.caption)
                                    .foregroundStyle(PaydayColor.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        VStack(spacing: PaydaySpacing.p12) {
                            ForEach(plan.nights, id: \.weekday) { night in
                                planNightRow(night)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                // 4. HOW IT'S BEEN RUNNING. Often correctly absent: it needs
                // twelve shifts a side and names both windows. See
                // StatsEngine.earningTrend.
                if let trend = pageFacts.trend {
                    trendSection(trend)
                    Divider()
                }

                // 5. BY THE NUMBERS. Each tile only when its data exists.
                if !numberRows.isEmpty {
                    VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
                        kicker("BY THE NUMBERS")
                        VStack(spacing: PaydaySpacing.p16) {
                            ForEach(numberRows, id: \.first?.id) { row in
                                HStack(alignment: .top, spacing: PaydaySpacing.p16) {
                                    ForEach(row) { tile in
                                        statTile(tile)
                                    }
                                }
                            }
                        }
                    }
                }

                Color.clear.frame(height: PaydaySpacing.p8).id("insights-bottom")
            }
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        // QA-only, same launch-arg pattern as -InitialTab: simctl can
        // screenshot but not scroll, so below-the-fold QA scrolls itself.
        .onAppear {
            guard ProcessInfo.processInfo.arguments.contains("-ScrollInsightsBottom") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(nil) { proxy.scrollTo("insights-bottom", anchor: .bottom) }
            }
        }
        }
    }

    private func kicker(_ text: String) -> some View {
        Text(text)
            .font(PaydayFont.caption2)
            .tracking(0.8)
            .foregroundStyle(PaydayColor.primary)
    }

    /// One tile in BY THE NUMBERS: a green uppercase label, a big
    /// monospaced value, and a basis line only when the tile names its own.
    private func statTile(_ tile: InsightsNumberTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.label)
                .font(PaydayFont.caption2)
                .tracking(0.8)
                .foregroundStyle(PaydayColor.primary)
            Text(tile.value)
                .font(PaydayFont.displayCompact)
                .foregroundStyle(PaydayColor.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let context = tile.context {
                Text(context)
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Ranges are a TABLE, not prose: weekday, range, sample size. Written
    /// as sentences it came out as five near-identical lines all opening
    /// with "Half your …", which read as a form letter and ate the whole
    /// first screen. The qualifier belongs in the subhead, said once.
    ///
    /// Deliberately the same row shape as NEXT WEEK below (see
    /// planNightRow): label and sample on the left, the number on the
    /// right, monospaced so the column lines up.
    private func reliabilitySection(_ reliability: StatsEngine.ReliabilityFacts) -> some View {
        VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
            VStack(alignment: .leading, spacing: 4) {
                // NOT "what you can count on", which is what this said
                // first and which the statistic does not support. A
                // middle-50% range is not a floor — a quarter of shifts
                // come in under the low number. You can count on a floor;
                // you cannot count on a middle. This header describes the
                // range rather than promising something about it.
                kicker("WHAT A SHIFT USUALLY PAYS")
                // Said once here instead of five times below. One
                // sentence (Tyler, 2026-11-08: fewer words).
                Text("Half your shifts land in these ranges.")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            VStack(spacing: PaydaySpacing.p12) {
                ForEach(reliability.byWeekday, id: \.self) { entry in
                    typicalRangeRow(
                        label: Self.rangeSubject(for: entry),
                        basis: Self.shiftCountBasis(entry.range.shiftCount),
                        range: entry.range
                    )
                }
                if let overall = reliability.overall {
                    // A different statistic, not a summary of the rows: its
                    // width is driven by weekday mix rather than by
                    // night-to-night uncertainty. Separated and quieted.
                    Divider()
                    typicalRangeRow(
                        label: "All shifts",
                        basis: Self.shiftCountBasis(overall.shiftCount),
                        range: overall,
                        isMuted: true
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func typicalRangeRow(label: String, basis: String?, range: StatsEngine.TypicalRange, isMuted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PaydaySpacing.p12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(PaydayFont.subheadlineSemibold)
                    .foregroundStyle(isMuted ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                if let basis {
                    Text(basis)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
            }
            Spacer(minLength: PaydaySpacing.p12)
            Text("\(Money.wholeDollarString(fromCents: range.lowCents))–\(Money.wholeDollarString(fromCents: range.highCents))")
                .font(PaydayFont.subheadlineSemibold)
                .monospacedDigit()
                .foregroundStyle(isMuted ? PaydayColor.textSecondary : PaydayColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), half land between \(Money.wholeDollarString(fromCents: range.lowCents)) and \(Money.wholeDollarString(fromCents: range.highCents))." + (basis.map { " \($0)." } ?? ""))
    }

    /// Just the count. It used to read "Across 13 Sunday lunches" directly
    /// under a row already titled "Sunday lunches", which put the same
    /// words on two adjacent lines of every single row. The sample size is
    /// an honesty device while the sample is thin; at
    /// `InsightsNumbersGrid.minimumShiftsForFullSample` or more it says
    /// nothing new and goes (Tyler, 2026-11-08).
    private static func shiftCountBasis(_ count: Int) -> String? {
        guard count < InsightsNumbersGrid.minimumShiftsForFullSample else { return nil }
        return count == 1 ? "1 shift" : "\(count) shifts"
    }

    /// "Fridays", or "Friday lunches" / "Friday dinners" when the weekday
    /// was split because each service clears the bar on its own.
    private static func rangeSubject(for entry: StatsEngine.WeekdayTypicalRange) -> String {
        let name = InsightsPresentation.weekdayName(entry.weekday)
        switch entry.shiftPeriod {
        case .lunch: return "\(name) lunches"
        case .dinner: return "\(name) dinners"
        case nil: return "\(name)s"
        }
    }

    /// The level line and the schedule line stay separate on purpose:
    /// working more is not earning more per shift, and running them
    /// together is the exact conflation the stratification prevents.
    private func trendSection(_ trend: StatsEngine.EarningTrend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            kicker("HOW IT'S BEEN RUNNING")
            Text(RevealCopy.trendLine(trend))
                .font(PaydayFont.bodyRegular)
                .foregroundStyle(PaydayColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let scheduleLine = RevealCopy.trendScheduleLine(trend) {
                Text(scheduleLine)
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planNightRow(_ night: PlanForward.Night) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PaydaySpacing.p12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(InsightsPresentation.weekdayName(night.weekday))
                    .font(PaydayFont.subheadlineSemibold)
                    .foregroundStyle(PaydayColor.textPrimary)
                if let basis = InsightsPresentation.sampleBasis(weekday: night.weekday, count: night.nightCount) {
                    Text(basis)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
            }
            Spacer(minLength: PaydaySpacing.p12)
            Text(Money.wholeDollarString(fromCents: night.averageNetCents))
                .font(PaydayFont.displaySmall)
                .foregroundStyle(PaydayColor.textPrimary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func emptyState(unlocks: [Unlock], shiftCount: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(PaydayFont.iconXL)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(shiftCount == 0 ? "Log \(StatsEngine.minimumShiftsForInsights) shifts for insights" : "Insights unlock at \(StatsEngine.minimumShiftsForInsights) shifts")
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
            if let insightsUnlock = unlocks.first(where: { $0.kind == .insights }), shiftCount > 0 {
                Text("\(insightsUnlock.have) of \(insightsUnlock.need)")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Capsule()
                    .fill(PaydayColor.fieldBackground)
                    .frame(width: 160, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(PaydayColor.primary)
                            .frame(width: 160 * CGFloat(insightsUnlock.have) / CGFloat(insightsUnlock.need), height: 4)
                    }
                    .accessibilityHidden(true)
            }
            Button("Add Past Shifts") { isShowingBackfillSheet = true }
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.primary)
                .buttonStyle(.plain)
        }
        .padding(.top, 40)
    }

}

/// Every number Insights shows, computed once per render.
///
/// A PR 5 adapter: presentation and already-computed figures only. The two
/// things it adds over the pre-wave-2 version are the reason group 2.6
/// exists — `basis`, the page's declared metric, and `hourly`, the one $/hr
/// figure, taken from the engine rather than divided here.
///
/// It carries `stamp` (contract rule 3) so a disagreement with another
/// screen is diffable: same digest means same dataset, by construction. A nil
/// stamp means no dataset stands behind the page at all, and then `basis` is
/// `.unavailable` and every figure below refuses rather than reading zero.
///
/// **Internal, not private**, for the reason `DashboardFacts`,
/// `PeriodsPageFacts`, `PeriodDetailFacts`, `DayDetailFacts` and
/// `LogShiftFacts` are: the plan's completion rule 2 is "its parity test
/// passes against the real adapter, not a helper." While this was private the
/// suite could not reach it, restated the construction in a helper of its
/// own, and therefore did not gate the screen at all — with
/// `valuedShiftCents` patched to nil here, reverting the whole page to
/// tips-only under wage-inclusive headers, the full app suite still reported
/// `Test run with 855 tests in 154 suites passed`.
struct InsightsPageFacts: SnapshotFacts {
    let stamp: SnapshotStamp?
    /// What every money figure on this page is, in one value. Rendered as a
    /// sentence above the figures by `resultList`.
    let basis: InsightsBasis
    /// `MetricID.hourlyRate` over the same recent window the grid covers,
    /// with its coverage. Nil when the engine cannot answer — never a
    /// fabricated `$0/hr` — **and nil whenever the page is not on a
    /// wage-inclusive basis**, because `hourlyRate` is `earnedIncome` over
    /// minutes by registry definition (`EarningsResult.hourlyRateCents`
    /// divides `coveredComponents.earnedIncomeCents`) and there is no
    /// tips-only rate in the registry to fall back to. A $/hr tile under
    /// "Every figure below is tips only" would be the one wage-inclusive
    /// number left on a tips-only page.
    ///
    /// The consequence, stated rather than hidden: a wage-inclusive basis
    /// means every shift in the dataset is wage-valued, which means every
    /// shift has hours, so `HourlyRate.coverage`'s "across 5 of 6 shifts"
    /// fraction is now unreachable FROM THIS SCREEN. It stays because
    /// `docs/METRICS.md`'s presentation rules require it of the metric and
    /// History's caption for the same metric still reaches it. Whether
    /// Insights should instead show a tips-only $/hr — which needs a
    /// registry metric, not a division here — is a decision for Tyler,
    /// flagged the same way the whole-history completeness gate is.
    let hourly: InsightsEarnings.HourlyRate?
    let facts: InsightsFacts?
    /// THIS MONTH: this calendar month's figure on the page basis, or the
    /// previous month's when nothing is logged yet this month. Nil only
    /// when there is no snapshot.
    let month: InsightsMonthFigure?
    /// Full history, one engine query per bar. NightlyEarningsChart owns
    /// progressive aggregation, so more history produces fewer, more
    /// meaningful weekly/monthly/yearly bars instead of an ever-denser row
    /// of daily marks.
    ///
    /// PR 5 wave 0: the bars used to be `StatsEngine.nightlyTotals`, which
    /// is `nonWageEarnings` — so under a wage-inclusive page they were
    /// short by every hour worked and had no way to say so (the M1 fixture's
    /// defect). They are now `snapshot.day(_:)`, wage-inclusive and carrying
    /// their own completeness, each bar rendering an `EarningsFigure`. Wave 2
    /// put everything ELSE on this screen on the same basis, via
    /// `StatsEngine`'s pricing.
    ///
    /// And then the bars follow the PAGE basis rather than being
    /// wage-inclusive by construction. Wave 2's first cut hard-coded
    /// `EarningsFigure.earnedIncome` in `EarningsChartPoint`, so on a
    /// `.partial` dataset — the ordinary case, since every shift added through
    /// "Add Past Shifts" is hours-less — the bars read 26,500c / 24,000c /
    /// 7,500c / 25,800c / 25,500c over the same five days the tiles, the
    /// typical range, the plan and the day totals read 10,500c / 9,000c /
    /// 7,500c / 9,800c / 10,500c, under a note saying every figure below was
    /// tips only and a bar label saying "Total". `basis.chartMetric` is what
    /// closes that.
    let chartFacts: EarningsChartFacts
    /// What unlocks next, and how close — see UnlockProgress.
    let unlocks: [Unlock]
    let shiftCount: Int
    /// A deterministic look one week ahead — see StatsEngine.planForward.
    let plan: PlanForward?
    /// What a shift typically pays — see StatsEngine.typicalRanges.
    let reliability: StatsEngine.ReliabilityFacts?
    /// Whether the earning LEVEL moved — see StatsEngine.earningTrend.
    let trend: StatsEngine.EarningTrend?
    /// How close `plan` has been — see StatsEngine.forecastAccuracy.
    /// Twelve retrospective engines, so it belongs here in the cached
    /// facts and never in a view body.
    let forecastAccuracy: StatsEngine.ForecastAccuracy?

    /// - Parameters:
    ///   - dataset: the page's ONE snapshot and the grouping it was built
    ///     from. The records below are flattened out of that same grouping
    ///     rather than passed in alongside it, so the engine and the snapshot
    ///     cannot be looking at two different sets of rows.
    ///   - calendar: the GRID calendar in the frozen payroll zone, the SAME
    ///     one `InsightsEarnings.build` grouped with. It has to be: a legacy
    ///     `TipEntry` with `shiftID == nil` takes a deterministic id derived
    ///     from `calendar.startOfDay(...)`, so two calendars mint two ids for
    ///     one shift and the pricing map misses.
    init(
        dataset: InsightsEarnings.Dataset,
        payrollTimeZone: TimeZone,
        calendar: Calendar,
        now: Date = .now
    ) {
        let snapshot = dataset.snapshot
        stamp = snapshot?.stamp
        // ONE decision, from the dataset's own `Completeness`, before any
        // figure is computed — and then every money surface below reads it.
        // Group 2.6 first shipped with only `StatsEngine` governed by it,
        // which left the chart and the HOURLY tile wage-inclusive under a
        // note reading "Every figure below is tips only": one day was
        // $265.00 on the chart and $105.00 in the tiles beside it.
        let basis = InsightsEarnings.basis(for: snapshot)
        self.basis = basis
        let records = dataset.tipRecords
        // The engine is built by `InsightsEarnings.engine`, not here, so the
        // parity suite gates this wiring instead of restating it. See that
        // function's header for the measurement that made it a function.
        let statsEngine = InsightsEarnings.engine(
            for: dataset,
            payrollTimeZone: payrollTimeZone,
            calendar: calendar
        )
        facts = statsEngine.insightsFacts(referenceDate: now)
        // `hourlyRate` is `earnedIncome` over minutes by registry definition,
        // so it is only askable on a wage-inclusive page. See the property.
        hourly = basis.isWageInclusive
            ? InsightsEarnings.hourlyRate(
                snapshot,
                referenceDate: now,
                in: payrollTimeZone
            )
            : nil
        month = InsightsMonthFigure(
            snapshot: snapshot,
            today: CivilDay(now, in: payrollTimeZone),
            timeZone: payrollTimeZone,
            metric: basis.chartMetric
        )
        chartFacts = EarningsChartFacts(
            wholeOf: snapshot,
            timeZone: payrollTimeZone,
            // The bars name the metric the page declared, so the peak
            // callout, the scrub readout and the bar label are the same
            // cents and the same noun as everything under the note.
            metric: basis.chartMetric
        )
        // Use the same rotation PLAN names as "your usual nights."
        unlocks = UnlockProgress.nextUnlocks(
            records: records,
            usualWeekdays: statsEngine.workRhythm(referenceDate: now).usualWeekdays
        )
        shiftCount = UnlockProgress.shiftCount(records: records)
        plan = statsEngine.planForward(referenceDate: now)
        reliability = statsEngine.typicalRanges(referenceDate: now)
        trend = statsEngine.earningTrend(referenceDate: now)
        forecastAccuracy = statsEngine.forecastAccuracy(referenceDate: now)
    }
}

/// The presentational remainder the snapshot's digest cannot cover.
///
/// `day` because every window on this page (the 180-day facts window, the
/// trend's two eight-week halves, the forecast's twelve weeks, the plan's
/// coming week) is measured back from today.
private struct InsightsSelection: Hashable {
    let day: Date
}

private struct InsightsCacheIdentity: Hashable {
    let revision: Int
    let selection: InsightsSelection
    let role: String?
    let job: JobScope
}

/// One render's worth of work, kept so a `@State` change (presenting the
/// backfill sheet, scrubbing the chart) does not redo it.
///
/// Two independent reuse tests, because the two halves cost different things,
/// the same split `DashboardRenderCache` documents:
///
/// - The DATASET (the grouping and the snapshot built from it) is valid while
///   `revision` has not moved. `LegacySnapshotBridge` costs 41.7 ms over
///   1,000 shifts and 307.4 ms over 10,000 (MEASURED, iPhone 17 Pro
///   simulator, 2026-09-18), so it must not run per `body`.
/// - The FACTS are valid while the dataset digest and the selection have not
///   moved. `digest` is the complete key; `selection` is the presentational
///   remainder.
private struct InsightsRenderCache {
    let revision: Int
    /// The role filter the dataset was built for; nil is All.
    let role: String?
    /// The job filter the dataset was built for; `.all` is All.
    let job: JobScope
    /// The grouping AND the snapshot built from it, together, because they
    /// have to be the same pair every render: the grouping's `shiftID`s are
    /// what index the snapshot, and what the pricing map is checked against.
    let dataset: InsightsEarnings.Dataset
    let digest: String?
    let selection: InsightsSelection
    let facts: InsightsPageFacts
}

/// Page-level presentation helpers. Internal (rather than private) so they
/// can be tested directly.
enum InsightsPresentation {
    static func weekdayName(_ weekday: Int) -> String {
        guard Calendar.current.weekdaySymbols.indices.contains(weekday - 1) else { return "Shift" }
        return Calendar.current.weekdaySymbols[weekday - 1]
    }

    /// Nil at `InsightsNumbersGrid.minimumShiftsForFullSample` or more: the
    /// count is only a warning while the sample is thin (Tyler, 2026-11-08).
    static func sampleBasis(weekday: Int, count: Int) -> String? {
        guard count < InsightsNumbersGrid.minimumShiftsForFullSample else { return nil }
        let name = weekdayName(weekday)
        return count == 1 ? "Based on 1 \(name)" : "Based on \(count) \(name)s"
    }
}

/// THIS MONTH's one number and its label.
///
/// The SAME query the Calendar uses for its month figure,
/// `snapshot.range(month.range)`, read through the page's chart metric, so
/// the number is the cents the chart would draw for that month on the same
/// basis. The month shown is the latest month with a shift on or before
/// today. "November so far" while that is the open month, clamped to today so
/// a shift logged ahead for a later day does not count yet. By name
/// ("October", or "October 2025" when it is not this year's) when nothing is
/// logged yet this month, so the first days of a month, or a break of a few
/// months, never lead the page with $0. Nil when no shift is on or before
/// today.
struct InsightsMonthFigure: Equatable {
    let month: YearMonth
    let figure: EarningsFigure
    let label: String

    init?(snapshot: EarningsSnapshot?, today: CivilDay, timeZone: TimeZone, metric: EarningsChartMetric) {
        guard let snapshot,
              let latestWorkDay = snapshot.shifts.map(\.workDay).filter({ $0 <= today }).max()
        else { return nil }
        let current = YearMonth(today)
        let shown = YearMonth(latestWorkDay)
        let isOpen = shown == current
        let firstDay = shown.firstDay.date(in: timeZone)
        let name = firstDay.formatted(Date.FormatStyle(timeZone: timeZone).month(.wide))
        month = shown
        figure = metric.figure(snapshot.range(shown.range, asOf: isOpen ? today : nil))
        if isOpen {
            label = "\(name) so far"
        } else if shown.year == current.year {
            label = name
        } else {
            label = firstDay.formatted(Date.FormatStyle(timeZone: timeZone).month(.wide).year())
        }
    }
}
