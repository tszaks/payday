import Testing
import Foundation
@testable import Payday

// MARK: - Fixtures

private func payrollCalendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
    payrollCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func shiftID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}

/// The compensation history a test STATES as its own. Whole
/// `CompensationPolicies`, never a scalar rate and never a scalar weekday:
/// wave 0 measured $520.00/`.complete` against the correct
/// $440.00/`.estimated` when a scalar rate became a `.distantPast` confirmed
/// policy.
private func testPolicies(rateCents: Int? = 1_000, workweekStartWeekday: Int = 1) -> CompensationPolicies {
    let calendar = PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("paycheck/calendar/\(workweekStartWeekday)"),
        effectiveFrom: .distantPast,
        workweekStartWeekday: workweekStartWeekday,
        payrollTimeZone: PaydayTestZone.payroll
    )
    guard let rateCents, rateCents > 0 else {
        return CompensationPolicies(rates: [], calendars: [calendar])
    }
    return CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("paycheck/rate/\(rateCents)"),
            effectiveFrom: .distantPast,
            hourlyRateCents: rateCents,
            provenance: .confirmed
        )],
        calendars: [calendar]
    )
}

/// Biweekly, ending Sat 2026-10-10, with the GRID's weekday deliberately set
/// against the policy's workweek.
private func testSchedule(firstWeekday: Int = 2) -> PaySchedule {
    PaySchedule(
        frequency: .biweekly,
        anchorPeriodEnd: at(2026, 10, 10, hour: 0),
        firstWeekday: firstWeekday
    )
}

private let testPeriod = PayPeriod(start: at(2026, 9, 27, hour: 0), end: at(2026, 10, 10, hour: 0))

/// The fixture that carries BOTH halves of the divergence group 2.5 closes,
/// because either half alone passes on a fixture lacking the other. It is the
/// same shape `PaycheckAuditBasisParityTests` measures the period side on, so
/// the $1,310.00 these tests assert is independently pinned there:
///
/// - **A final-day shift.** 6h at 18:00 on 2026-10-10, the period's last day.
///   `PayPeriod.end` is that day's MIDNIGHT, so the sheet's superseded
///   `entry.date <= period.end` filter dropped it.
/// - **A grid weekday set against the policy.** The POLICY's workweek starts
///   Sunday; `PaySchedule.firstWeekday` says Monday. Five 10-hour days from
///   Sunday 2026-09-27 are one 50h week under the policy (10h of overtime)
///   and 10h + 40h under the grid (none).
///
/// Credit tips $700.00, wages $610.00 (40h regular + 10h overtime in the
/// Sunday week at $10/hr, plus 6h regular in the next), expected check
/// $1,310.00.
private func dividedFixtureEntries() -> [TipEntry] {
    let week: [TipEntry] = [
        (2026, 9, 27, 1), (2026, 9, 28, 2), (2026, 9, 29, 3),
        (2026, 9, 30, 4), (2026, 10, 1, 5)
    ].map { year, month, day, index in
        TipEntry(date: at(year, month, day), amountCents: 10_000, kind: .credit,
                 hoursWorked: 10, shiftID: shiftID(index))
    }
    let finalDay = TipEntry(
        date: at(2026, 10, 10, hour: 18), amountCents: 20_000, kind: .credit,
        hoursWorked: 6, shiftID: shiftID(6)
    )
    return week + [finalDay]
}

/// One render of the period AND the sheet that period opens, built exactly as
/// `PeriodDetailView` builds them: the sheet is HANDED
/// `facts.expectation`, so this helper cannot accidentally give the two
/// surfaces two expectations. That is the structure under test.
private struct PaycheckRender {
    let snapshot: EarningsSnapshot?
    let detail: PeriodDetailFacts
    let sheet: PaycheckEntryFacts

    init(
        entries: [TipEntry],
        paychecks: [PaycheckRecord] = [],
        stub: PaycheckReconciler.Observation = .empty,
        policies: CompensationPolicies = testPolicies(),
        schedule: PaySchedule? = testSchedule(),
        period: PayPeriod = testPeriod
    ) {
        let calendar = payrollCalendar()
        let build = HistoryEarnings.build(
            entries: entries,
            policies: policies,
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: calendar
        )
        snapshot = build.snapshot
        detail = PeriodDetailFacts(
            snapshot: build.snapshot,
            shiftDays: build.shiftDays,
            paycheckRecords: paychecks,
            period: period,
            schedule: schedule,
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: calendar
        )
        sheet = PaycheckEntryFacts(expectation: detail.expectation, observation: stub)
    }
}

/// The stub a record holds, as the sheet's own state would hold it after
/// opening on that record. Built here rather than on `PaycheckRecord`: a
/// derived money value on that @Model is what four surfaces read silently
/// last time.
private func observation(of record: PaycheckRecord) -> PaycheckReconciler.Observation {
    PaycheckReconciler.Observation(
        paidTipsCents: record.paidTipsCents,
        regularWagesCents: record.regularWagesCents,
        overtimeWagesCents: record.overtimeWagesCents,
        gratuityCents: record.gratuityCents,
        grossCents: record.grossPayCents,
        taxesCents: record.taxesCents,
        netCents: record.netPayCents
    )
}

/// P1's stub, as a `PaycheckRecord` for the period above: tips 10000, regular
/// 5000, gross 15050, so the gross equation implies 10050.
private func p1Record() -> PaycheckRecord {
    let record = PaycheckRecord(
        periodStart: testPeriod.start,
        periodEnd: testPeriod.end,
        paidTipsCents: 10_000
    )
    record.regularWagesCents = 5_000
    record.overtimeWagesCents = 0
    record.gratuityCents = 0
    record.grossPayCents = 15_050
    return record
}

// MARK: - The invariant

/// The parity invariant group 2.5 exists to close: **the expected side shown
/// in the paycheck sheet equals the expected side shown on the period detail
/// for the same period.**
///
/// Wave 1's cross lens found that migrating period detail's expectation
/// without migrating the sheet SPLIT the paycheck comparison across the sheet
/// boundary. Wave 1 handed the basis down; group 2.5 makes both sides read
/// the same `PaycheckReconciler.Expectation` property, and renders it on the
/// sheet so a person auditing a stub sees the figure the screen behind it
/// showed.
@Suite("The paycheck sheet and the period it opens are one expectation")
struct PaycheckSheetEqualsPeriodExpectationTests {
    @Test("every expected component in the sheet equals the period's, to the cent")
    func sheetExpectationEqualsPeriods() throws {
        let render = PaycheckRender(entries: dividedFixtureEntries())
        let snapshot = try #require(render.snapshot)
        let result = try #require(render.detail.result)

        // Every shift the engine selected, the final-day one included.
        #expect(result.shiftIDs.count == 6)

        // The third answer, asked straight of the engine over the same days.
        let query = snapshot.range(DayRange(
            start: CivilDay(testPeriod.start, in: PaydayTestZone.payroll),
            end: CivilDay(testPeriod.end, in: PaydayTestZone.payroll)
        ))
        let engine = PaycheckReconciler.Expectation(result: query, stamp: snapshot.stamp)

        // Credit tips $700.00; wages $460.00 regular + $150.00 overtime.
        #expect(render.sheet.expectation.auditableTipsLineCents == 70_000)
        #expect(render.sheet.expectation.regularWagesCents == 46_000)
        #expect(render.sheet.expectation.overtimeWagesCents == 15_000)
        #expect(render.sheet.expectation.wagesCents == 61_000)
        #expect(render.sheet.expectation.grossCents == 131_000)

        // Sheet == period == engine, per component.
        #expect(render.sheet.expectation == render.detail.expectation)
        #expect(render.sheet.expectation.grossCents == engine.grossCents)
        #expect(render.sheet.expectation.auditableTipsLineCents == engine.auditableTipsLineCents)
        #expect(render.sheet.expectation.wagesCents == engine.wagesCents)
        #expect(render.sheet.expectation.overtimeMinutes == engine.overtimeMinutes)

        // And the FIGURES a person reads, not just the cents behind them.
        #expect(render.sheet.expectedGross.text == "$1,310.00")
        #expect(render.sheet.expectedGross.cents == render.detail.expectedCheckCents)
        #expect(render.detail.noPaycheckCaption.contains("$1,310.00"))
        #expect(render.sheet.expectedTipsLine.text == "$700.00")

        // Same dataset, provably.
        #expect(render.sheet.stamp == render.detail.stamp)
        #expect(render.sheet.stamp == snapshot.stamp)

        // The two superseded halves, named so a regression is legible.
        #expect(render.sheet.expectation.auditableTipsLineCents != 50_000,
                "the superseded entry.date <= period.end filter, dropping the final-day shift")
        #expect(render.sheet.expectation.wagesCents != 50_000,
                "the superseded PaySchedule.firstWeekday allocation, losing the week's overtime")
        #expect(render.sheet.expectedGross.cents != 100_000,
                "the superseded basis: both halves at once, $310.00 away from the screen")
    }

    /// The disagreeing case for the grid: move only the GRID's weekday and
    /// nothing the sheet or the period shows may move, because no money
    /// input on either comes from `PaySchedule` any more.
    @Test("the pay-period grid's weekday moves no expected figure on either surface")
    func gridWeekdayMovesNothing() {
        let entries = dividedFixtureEntries()
        let monday = PaycheckRender(entries: entries, schedule: testSchedule(firstWeekday: 2))
        let sunday = PaycheckRender(entries: entries, schedule: testSchedule(firstWeekday: 1))
        #expect(monday.sheet.expectation.grossCents == 131_000)
        // The DATASET is identical, which is the strongest form of this
        // claim: same manifest digest, so the grid weekday is not even an
        // input to the snapshot the sheet reads. (`SnapshotStamp` itself is
        // not compared: it carries `computedAt`, a clock, so two builds of
        // the same inputs are unequal as stamps and equal as datasets.)
        #expect(monday.sheet.stamp?.digest == sunday.sheet.stamp?.digest)
        #expect(monday.sheet.expectation.components == sunday.sheet.expectation.components)
        #expect(monday.sheet.expectation.overtimeMinutes == sunday.sheet.expectation.overtimeMinutes)
        #expect(monday.sheet.expectedGross == sunday.sheet.expectedGross)
        #expect(monday.sheet.expectedTipsLine == sunday.sheet.expectedTipsLine)
        #expect(monday.sheet.findings == sunday.sheet.findings)
        #expect(monday.detail.expectedCheckCents == sunday.detail.expectedCheckCents)
    }

    /// Rule 4, on the sheet: an unreadable dataset renders no currency at
    /// all, and every engine-side check falls silent rather than reporting a
    /// real stub as $X over zero.
    @Test("with no dataset the sheet renders no currency and states no verdict")
    func unbackedSheetRefuses() {
        let sheet = PaycheckEntryFacts(
            expectation: .unbacked,
            observation: PaycheckReconciler.Observation(
                paidTipsCents: 9_500,
                regularWagesCents: 1_000,
                overtimeWagesCents: 0,
                gratuityCents: 0,
                grossCents: 10_500,
                taxesCents: 500,
                netCents: 10_000
            )
        )
        #expect(sheet.isUnbacked)
        #expect(sheet.stamp == nil)
        #expect(sheet.hasExpectation == false)
        #expect(sheet.expectedGross.isUnavailable)
        #expect(sheet.expectedGross.text == nil)
        #expect(sheet.expectedTipsLine.isUnavailable)
        #expect(sheet.expectedTipsLine.text == nil)
        #expect(sheet.findings.contains { $0.id == "tips-vs-logged" } == false)
        #expect(sheet.findings.contains { $0.id == "wages-vs-computed" } == false)
        #expect(sheet.findings.contains { $0.id == "overtime-missing" } == false)
        // The stub-internal checks need nothing from the engine, so they
        // still run: this stub's own lines do add up.
        #expect(sheet.findings.first { $0.id == "gross-math" }?.severity == .reconciles)
        #expect(sheet.findings.first { $0.id == "net-math" }?.severity == .reconciles)
    }

    /// `.partial` never renders "Total", and the expected check says what is
    /// missing. The final-day shift loses its hours, so one of six shifts is
    /// unpriced: wages drop by the 6h that shift contributed ($60.00) and the
    /// expected check falls from $1,310.00 to $1,250.00 with a caption.
    @Test("a partial period's expected check carries its caption and is never a Total")
    func partialExpectationIsCaptioned() {
        var entries = dividedFixtureEntries()
        entries[5] = TipEntry(
            date: at(2026, 10, 10, hour: 18), amountCents: 20_000, kind: .credit,
            hoursWorked: nil, shiftID: shiftID(6)
        )
        let render = PaycheckRender(entries: entries)
        #expect(render.detail.result?.completeness.state == .partial(missingHours: 1, missingRate: 0))
        #expect(render.sheet.expectation.wagesCents == 55_000)
        #expect(render.sheet.expectedGross.cents == 125_000)
        #expect(render.sheet.expectedGross.text == "$1,250.00")
        #expect(render.sheet.expectedGross.caption == "wages missing for 1 shift")
        #expect(render.sheet.expectedGross.mayBeCalledATotal == false)
        #expect(render.sheet.expectedGross.cents == render.detail.expectedCheckCents)
    }

    /// **The disagreeing case for the tips-line figure, through the real
    /// adapters.** The line the sheet prints under the TIPS ON STUB field is
    /// the same quantity the `tips-vs-logged` check compares the stub
    /// against — so the sheet cannot state an expectation about a payroll
    /// field that the engine on the same sheet refuses to audit.
    ///
    /// MEASURED before the fix, on this exact fixture: a cash-only period
    /// (one 8h shift, $120.00 cash, no credit) rendered "Your check's tips
    /// line $120.00" under the stub's tips field while
    /// `auditableTipsLineCents` was nil, so the CHECKS section emitted no
    /// `tips-vs-logged` finding at all. Cash never runs through payroll, so
    /// the figure was guidance Payday volunteered and could not stand behind
    /// — and a person who typed $120.00 to match it would have stored a
    /// false `observedPaidTips` that then read back as a green "reconciles".
    @Test("a cash-only period prints no tips-line figure, and a credit period prints the audited one")
    func tipsLineFigureMatchesTheAudit() {
        // Cash only. One 8h shift, $120.00 cash, at $10/hr.
        let cashOnly = PaycheckRender(entries: [TipEntry(
            date: at(2026, 9, 28), amountCents: 12_000, kind: .cash,
            hoursWorked: 8, shiftID: shiftID(11)
        )])
        #expect(cashOnly.sheet.isUnbacked == false, "there IS a dataset; only the tips line is unknowable")
        #expect(cashOnly.sheet.expectation.tipsLineCents == 12_000, "the registry's cash fallback is unchanged")
        #expect(cashOnly.sheet.expectation.auditableTipsLineCents == nil)
        #expect(cashOnly.sheet.expectedTipsLine.isUnavailable)
        #expect(cashOnly.sheet.expectedTipsLine.text == nil,
                "expectedFigureLine withholds the whole line for an unavailable figure")
        #expect(cashOnly.sheet.expectedTipsLine.text != "$120.00",
                "the superseded fallback figure, printed under a payroll field the audit will not compare")
        // The sheet and the audit agree, which is the invariant: no figure,
        // no finding.
        #expect(cashOnly.sheet.findings.contains { $0.id == "tips-vs-logged" } == false)
        // The whole-check comparison keeps the fallback, because that is the
        // comparison the person asked for: $120.00 of tips + $80.00 of wages.
        #expect(cashOnly.sheet.expectedGross.text == "$200.00")
        #expect(cashOnly.sheet.expectedGross.cents == cashOnly.detail.expectedCheckCents)

        // Credit tips, same shape, so this cannot pass by withholding
        // everything: the printed figure IS the audited cents.
        let credit = PaycheckRender(
            entries: dividedFixtureEntries(),
            stub: PaycheckReconciler.Observation(paidTipsCents: 60_000)
        )
        #expect(credit.sheet.expectation.auditableTipsLineCents == 70_000)
        #expect(credit.sheet.expectedTipsLine.isUnavailable == false)
        #expect(credit.sheet.expectedTipsLine.cents == credit.sheet.expectation.auditableTipsLineCents)
        #expect(credit.sheet.expectedTipsLine.text == "$700.00")
        #expect(credit.sheet.findings.first { $0.id == "tips-vs-logged" } == PaycheckAudit.Finding(
            id: "tips-vs-logged",
            severity: .discrepancy,
            message: "You logged $700 in credit tips; the stub pays $600 in tips. $100 short."
        ))
    }

    /// Every label the sheet renders is one the registry sanctions.
    @Test("the sheet's figures carry registry labels only")
    func labelsAreFromTheRegistry() {
        let render = PaycheckRender(entries: dividedFixtureEntries())
        #expect(render.sheet.expectedGross.label == "Expected")
        #expect(MetricID.expectedPaycheckGross.allowedLabels
            .contains(render.sheet.expectedGross.label))
        #expect(render.sheet.expectedTipsLine.label == "Your check's tips line")
        #expect(MetricID.expectedPaycheckTipsLine.allowedLabels
            .contains(render.sheet.expectedTipsLine.label))
    }
}

// MARK: - The observed side is never mutated

/// Fixture P1, end to end through the real adapters: **the observed value is
/// never mutated by the reconciler.**
///
/// `MetricID.observedPaidTips` is "the stub field exactly as stored, no
/// inference applied anywhere it is read, exported, or synced". P1's
/// `wrongAnswers` lists five reads that returned 10050 for a stub saying
/// 10000 — the periods list's delta, period detail's "check paid", the
/// editor's prefill, the value an unedited Save wrote back, and the scan
/// prefill. All five went through `PaycheckRecord.reconciledPaidTipsCents`,
/// which group 2.5 deleted.
@Suite("P1: the stub's tips line is never rewritten, only a correction is proposed")
struct ObservedPaidTipsAreNeverMutatedTests {
    @Test("the reconciler proposes 10050 and leaves the observation at 10000")
    func proposalDoesNotMutate() {
        let record = p1Record()
        let render = PaycheckRender(
            entries: dividedFixtureEntries(),
            paychecks: [record],
            stub: observation(of: record)
        )

        // P1.observedPaidTipsCents, on the model and on the observation.
        #expect(record.paidTipsCents == 10_000)
        #expect(render.sheet.observation.paidTipsCents == 10_000)

        // P1.proposedPaidTipsCorrection, as a separate labelled fact.
        #expect(render.sheet.proposal?.observedCents == 10_000)
        #expect(render.sheet.proposal?.proposedCents == 10_050)
        #expect(render.sheet.proposal?.correctionCents == 50)
        #expect(render.sheet.proposal?.label == "Looks like $100.50 (accept?)")

        // P1.observedPaidTipsCentsAfterProposal: reading the proposal, the
        // figures and every audit sentence leaves the record alone.
        _ = render.sheet.findings
        _ = render.sheet.expectedGross
        #expect(record.paidTipsCents == 10_000)
        #expect(render.sheet.observation.paidTipsCents == 10_000)

        // P1.reconciliationObservedTipsSideCents: the period's own verdict
        // compares the person's figure, not Payday's inference. This read was
        // `reconciledPaidTipsCents`, i.e. 10050.
        let checked = render.detail.checked
        #expect(checked?.paidTipEarningsCents == 10_000)
        #expect(checked?.paidTipEarningsCents != 10_050,
                "P1.wrongAnswers.periodDetailCheckPaidCents")

        // And the delta is measured against the period's own expectation:
        // observed 10000 minus expected 131000.
        #expect(checked?.expectedTipsAndGratuityCents == 70_000)
        #expect(checked?.deltaCents == 10_000 - 70_000)
        #expect(checked?.isShort == true)
    }

    /// The editor prefill, which is where the silent rewrite became
    /// permanent: `PaycheckEntrySheet` opened on the INFERRED value, so
    /// tapping Save wrote 10050 over the stored 10000.
    @Test("the editor opens on the stored figure, so an unedited save cannot rewrite it")
    func editorPrefillIsTheStoredFigure() {
        let record = p1Record()
        // What `PaycheckEntrySheet.init` reads for `amountCents`.
        #expect(record.paidTipsCents == 10_000)
        #expect(PaycheckReconciler.proposal(for: observation(of: record))?.proposedCents == 10_050,
                "P1.wrongAnswers.paycheckEditorPrefillAmountCents, now offered rather than applied")
    }

    /// Accepting the proposal is a person's action and it is idempotent: once
    /// the tips field holds the inferred figure the stub's own gross equation
    /// balances, so there is nothing left to propose.
    @Test("accepting the proposal balances the stub and retires the proposal")
    func acceptingTheProposalRetiresIt() {
        let record = p1Record()
        let before = PaycheckEntryFacts(expectation: .unbacked, observation: observation(of: record))
        let proposal = before.proposal
        #expect(proposal?.proposedCents == 10_050)

        var accepted = observation(of: record)
        accepted = PaycheckReconciler.Observation(
            paidTipsCents: proposal?.proposedCents,
            regularWagesCents: accepted.regularWagesCents,
            overtimeWagesCents: accepted.overtimeWagesCents,
            gratuityCents: accepted.gratuityCents,
            grossCents: accepted.grossCents,
            taxesCents: accepted.taxesCents,
            netCents: accepted.netCents
        )
        let after = PaycheckEntryFacts(expectation: .unbacked, observation: accepted)
        #expect(after.observation.paidTipsCents == 10_050)
        #expect(after.proposal == nil)
        #expect(after.reconciliation.stubInternalGrossDeltaCents == 0)
        // And the stored record is still untouched: acceptance is a write the
        // sheet's Save performs, not something reading the facts did.
        #expect(record.paidTipsCents == 10_000)
    }
}

// MARK: - The stamp is the cache key

/// The sheet's other closed P0: it cached its audit context with NO key.
///
/// `AuditContext` was filled once by a `.task` and refreshed only on
/// `ModelContext.didSave`, so changing the wage or the workweek start while
/// the sheet was open left every CHECKS sentence standing on the old numbers.
/// The key is now `SnapshotStamp`, whose `digest` is a SHA-256 over every
/// input that can move a result, the rate history and the workweek included.
@Suite("The paycheck sheet's facts are keyed on the snapshot stamp")
struct PaycheckEntryFactsStampKeyTests {
    /// MEASURED: the same six shifts at $10/hr expect $1,310.00 and at
    /// $20/hr expect $1,920.00. A wage change made while the sheet is open is
    /// a new stamp, so the facts are re-derived; under the old unkeyed cache
    /// the sheet went on auditing against $1,310.00.
    @Test("a wage change is a new stamp, a new expectation and a new audit sentence")
    func aWageChangeInvalidatesTheCache() throws {
        let entries = dividedFixtureEntries()
        let stub = PaycheckReconciler.Observation(
            paidTipsCents: 70_000,
            regularWagesCents: 46_000,
            overtimeWagesCents: 15_000
        )
        let tenDollars = PaycheckRender(entries: entries, stub: stub, policies: testPolicies(rateCents: 1_000))
        let twentyDollars = PaycheckRender(entries: entries, stub: stub, policies: testPolicies(rateCents: 2_000))

        let cheapStamp = try #require(tenDollars.sheet.stamp)
        let dearStamp = try #require(twentyDollars.sheet.stamp)
        #expect(cheapStamp != dearStamp, "the rate history is inside the stamp's digest")
        #expect(cheapStamp.digest != dearStamp.digest)

        #expect(tenDollars.sheet.expectedGross.cents == 131_000)
        #expect(twentyDollars.sheet.expectedGross.cents == 192_000)
        #expect(twentyDollars.sheet.expectation.wagesCents == 122_000)

        // The sentence a person reads changes with it. At $10/hr the stub's
        // wage lines match; at $20/hr they are $610.00 short.
        #expect(tenDollars.sheet.findings.first { $0.id == "wages-vs-computed" }?.severity == .reconciles)
        #expect(twentyDollars.sheet.findings.first { $0.id == "wages-vs-computed" } == PaycheckAudit.Finding(
            id: "wages-vs-computed",
            severity: .discrepancy,
            message: "From your punches Payday computes $920 regular and $300 overtime - the stub pays $610. You may be owed $610."
        ))

        // The cache itself: a stale entry from the old dataset is not reused.
        let reused = PaycheckEntryFacts.reusing(
            tenDollars.sheet,
            expectation: twentyDollars.sheet.expectation,
            observation: stub
        )
        #expect(reused.stamp == dearStamp)
        #expect(reused.expectedGross.cents == 192_000)
        #expect(reused != tenDollars.sheet)
    }

    /// The disagreeing case in the other direction, so the key is not merely
    /// "always miss": the same dataset and the same stub reuse the cached
    /// facts untouched.
    @Test("the same stamp and the same stub reuse the cached facts")
    func anUnchangedKeyReuses() {
        let stub = PaycheckReconciler.Observation(paidTipsCents: 70_000)
        let render = PaycheckRender(entries: dividedFixtureEntries(), stub: stub)
        let reused = PaycheckEntryFacts.reusing(
            render.sheet,
            expectation: render.detail.expectation,
            observation: stub
        )
        #expect(reused == render.sheet)
    }

    /// Typing in the sheet is the other half of the key: the stub is this
    /// screen's own presentational input, so a keystroke re-derives the audit
    /// while the dataset stays put.
    @Test("a change to the stub re-derives while the stamp stays the same")
    func aStubChangeInvalidatesTheCache() {
        let render = PaycheckRender(
            entries: dividedFixtureEntries(),
            stub: PaycheckReconciler.Observation(paidTipsCents: 70_000)
        )
        let typed = PaycheckReconciler.Observation(paidTipsCents: 60_000)
        let reused = PaycheckEntryFacts.reusing(
            render.sheet,
            expectation: render.detail.expectation,
            observation: typed
        )
        #expect(reused.stamp == render.sheet.stamp, "the dataset did not move")
        #expect(reused != render.sheet)
        #expect(render.sheet.findings.first { $0.id == "tips-vs-logged" }?.severity == .reconciles)
        #expect(reused.findings.first { $0.id == "tips-vs-logged" } == PaycheckAudit.Finding(
            id: "tips-vs-logged",
            severity: .discrepancy,
            message: "You logged $700 in credit tips; the stub pays $600 in tips. $100 short."
        ))
    }

    /// A workweek change is inside the stamp too, and it is the one the old
    /// key could not have covered even in principle: the workweek lives on
    /// the payroll CALENDAR POLICY, which the sheet never read.
    @Test("a workweek-start change is a new stamp and a new overtime picture")
    func aWorkweekChangeInvalidatesTheCache() throws {
        let entries = dividedFixtureEntries()
        let sunday = PaycheckRender(entries: entries, policies: testPolicies(workweekStartWeekday: 1))
        let monday = PaycheckRender(entries: entries, policies: testPolicies(workweekStartWeekday: 2))

        let sundayStamp = try #require(sunday.sheet.stamp)
        let mondayStamp = try #require(monday.sheet.stamp)
        #expect(sundayStamp != mondayStamp)
        // Sunday-start: one 50h week, 10h of overtime. Monday-start: 10h then
        // 40h, no overtime at all, so the same six shifts expect $50.00 less
        // — the overtime PREMIUM on 10h at $10/hr, which is the half-rate
        // ($150.00 of overtime against the $100.00 those hours pay flat).
        #expect(sunday.sheet.expectation.overtimeWagesCents == 15_000)
        #expect(sunday.sheet.expectation.overtimeMinutes == 600)
        #expect(monday.sheet.expectation.overtimeWagesCents == 0)
        #expect(monday.sheet.expectation.overtimeMinutes == 0)
        #expect(sunday.sheet.expectedGross.cents == 131_000)
        #expect(monday.sheet.expectedGross.cents == 126_000)
    }
}
