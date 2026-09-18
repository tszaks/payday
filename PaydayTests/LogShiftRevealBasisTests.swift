import Testing
import Foundation
@testable import Payday

// ═══════════════════════════════════════════════════════════════════════════
//  The post-save reveal card has TWO lines, and until this change they were
//  computed on two different bases.
//
//  Line one, the headline, is the ledger's `EarningsFigure` ([LS-13]) — the
//  same figure the sheet's header showed a beat earlier and the same one
//  `ShiftDayRow` renders on Dashboard a second later.
//
//  Line two is `RevealCopy.comparison`, and it PRINTS ITS OWN CENTS out loud:
//  "topping your previous record of $X", "$Y above your Friday average". It
//  came from `StatsEngine`, whose history prices every shift
//  `netCents + WageEstimate.cents(scalar rate, hours)` — base rate only, per
//  shift, no workweek, today's rate applied to every shift ever worked.
//
//  Two directions, opposite signs:
//
//  • OVERTIME: the ledger figure is LARGER than the scalar one, so handing the
//    ledger figure to a scalar-priced history would declare a $550 shift a
//    record against a $500-basis history. That is the direction the original
//    deferral reasoned about, and it is a magnitude error.
//  • RATE HISTORY: the ledger figure is SMALLER, because the scalar reprices a
//    pre-raise shift at today's rate. That direction produces a visible
//    self-contradiction: a headline BELOW the record it claims to have topped.
//
//  The fix is not to re-price the headline. `StatsEngine` now takes
//  `valuedShiftCents`, the ledger's `earnedIncome` per shift, so its history
//  reads the same basis the headline prints. Dashboard's tonight echo seeds
//  the identical parameter from its own snapshot, which is what makes the two
//  surfaces agree — the second suite below is that gate.
// ═══════════════════════════════════════════════════════════════════════════

private func revealCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    return calendar
}

private func on(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
    revealCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func revealShiftID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 500 + index))!
}

/// The reveal's own engine, built the way `LogTipSheet.saveNew` builds it:
/// the ledger's per-shift `earnedIncome` on the history side, the ledger's
/// figure on the tonight side.
private func ledgerBasisEngine(records: [TipEntry], snapshot: EarningsSnapshot?) -> StatsEngine {
    StatsEngine(
        payrollTimeZone: PaydayTestZone.payroll,
        records: records.map(TipRecord.init),
        calendar: revealCalendar(),
        valuedShiftCents: snapshot.map { snap in
            Dictionary(
                snap.shifts.map { ($0.id, $0.components.earnedIncomeCents) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    )
}

/// What shipped before this change: a scalar rate on both sides.
private func scalarBasisEngine(records: [TipEntry], rateCents: Int) -> StatsEngine {
    StatsEngine(
        payrollTimeZone: PaydayTestZone.payroll,
        records: records.map(TipRecord.init),
        calendar: revealCalendar(),
        wageCentsPerHour: rateCents
    )
}

/// One pay period wide enough to hold every fixture below, so the period
/// filter is the same on both sides of every comparison and cannot be what
/// makes two strings differ.
private func wholeFixturePeriod() -> PayPeriod {
    PayPeriod(start: on(2026, 1, 1, hour: 0), end: on(2026, 12, 31, hour: 0))
}

/// $10.00/hr until 2026-06-01, $30.00/hr from then on. Sunday-start weeks.
///
/// The raise is what makes the scalar basis wrong in the OTHER direction: a
/// shift worked in March is priced at March's rate by the ledger and at
/// today's rate by `WageEstimate.cents`.
private func raisePolicies() -> CompensationPolicies {
    CompensationPolicies(
        rates: [
            PayRatePolicy(
                id: PolicyMigration.deterministicID("reveal/rate/old"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 1_000,
                provenance: .confirmed
            ),
            PayRatePolicy(
                id: PolicyMigration.deterministicID("reveal/rate/new"),
                effectiveFrom: CivilDay(year: 2026, month: 6, day: 1),
                hourlyRateCents: 3_000,
                provenance: .confirmed
            )
        ],
        calendars: [PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("reveal/calendar/sunday"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 1,
            payrollTimeZone: PaydayTestZone.payroll
        )]
    )
}

@Suite("Log Shift reveal: one basis for both lines of the card")
@MainActor
struct LogShiftRevealBasisTests {
    /// The previous best: $260.00 of credit and NO hours, so it is worth
    /// exactly $260.00 on either basis. Sat 2026-07-04, its own week.
    private static func previousBest() -> TipEntry {
        TipEntry(
            date: on(2026, 7, 4),
            amountCents: 26_000,
            kind: .credit,
            recordedAt: on(2026, 7, 4, hour: 23),
            shiftPeriod: .dinner,
            shiftID: revealShiftID(1)
        )
    }

    /// The draft: a March shift backfilled long after the raise. Ten hours at
    /// MARCH's $10.00/hr is $100.00 of wages; $150.00 of credit on top is
    /// $250.00. The scalar basis prices the same ten hours at today's $30.00
    /// and reads $450.00.
    private static let draftID = revealShiftID(2)
    private static let draftDate = on(2026, 3, 13)

    private static func draftRows() -> [TipEntry] {
        ShiftDraftPreview.rows(
            date: draftDate,
            cashCents: 0,
            creditCents: 15_000,
            recordedAt: on(2026, 3, 13, hour: 23),
            shiftID: draftID,
            hoursWorked: 10,
            tipOutCents: 0,
            salesCents: 0,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil,
            receiptMetrics: nil
        )
    }

    /// The whole history with the draft substituted in, UNWINDOWED — what
    /// `LogTipSheet.revealHistorySnapshot()` builds. A window would be wrong
    /// here for a reason that is not about performance: an all-time record
    /// lives outside this week almost by definition, so a windowed comparison
    /// set would leave most of the history on the scalar fallback, mixing the
    /// two bases inside one comparison instead of removing one of them.
    private static func revealSnapshot(history: [TipEntry]) -> EarningsSnapshot? {
        ShiftDraftPreview.snapshot(
            draft: ShiftDraftPreview.draftInput(
                rows: draftRows(),
                shiftID: draftID,
                payrollTimeZone: PaydayTestZone.payroll
            ),
            entries: history,
            policies: raisePolicies(),
            payrollTimeZone: PaydayTestZone.payroll,
            windowed: false
        )
    }

    private static func draftFigure(history: [TipEntry]) -> EarningsFigure {
        LogShiftFacts(
            snapshot: ShiftDraftPreview.snapshot(
                draft: ShiftDraftPreview.draftInput(
                    rows: draftRows(),
                    shiftID: draftID,
                    payrollTimeZone: PaydayTestZone.payroll
                ),
                entries: history,
                policies: raisePolicies(),
                payrollTimeZone: PaydayTestZone.payroll
            ),
            draftID: draftID,
            date: draftDate,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            hoursWorked: 10,
            calendar: revealCalendar(),
            now: on(2026, 9, 18)
        ).total
    }

    @Test("the headline is never declared a record against a figure larger than itself")
    func theCardNoLongerContradictsItself() throws {
        let history = [Self.previousBest()]
        let figure = Self.draftFigure(history: history)
        let headlineCents = try #require(figure.cents)
        // MEASURED: $150.00 of credit plus ten March hours at March's
        // $10.00/hr. The raise is real and it is not retroactive.
        #expect(headlineCents == 25_000)

        let engine = ledgerBasisEngine(records: history, snapshot: Self.revealSnapshot(history: history))
        let result = engine.reveal(
            forNightAt: revealCalendar().startOfDay(for: Self.draftDate),
            cents: headlineCents,
            period: wholeFixturePeriod(),
            shiftID: Self.draftID
        )

        // $250.00 is not a record against $260.00, and the card says so.
        #expect(result.isRecord == false)
        #expect(result.cents == headlineCents)
        let comparison = RevealCopy.comparison(for: result.comparison, period: .dinner)
        #expect(comparison.contains("topping your previous record") == false)

        // What shipped: the same draft, priced by the scalar at today's rate,
        // handed to a scalar-priced history. MEASURED — the card rendered
        // "$250.00 this shift." directly above a claim to have beaten $260.00.
        let brokenCents = 15_000 + (WageEstimate.cents(wageCentsPerHour: 3_000, hours: 10) ?? 0)
        #expect(brokenCents == 45_000)
        let broken = scalarBasisEngine(records: history, rateCents: 3_000).reveal(
            forNightAt: revealCalendar().startOfDay(for: Self.draftDate),
            cents: brokenCents,
            period: wholeFixturePeriod(),
            shiftID: Self.draftID
        )
        #expect(broken.isRecord == true)
        let brokenComparison = RevealCopy.comparison(for: broken.comparison, period: .dinner)
        #expect(brokenComparison.contains("$260.00"))
        #expect(RevealCopy.headline(cents: headlineCents, includesNonTipIncome: true) == "$250.00 this shift.")
    }

    @Test("the cents the comparison was computed on are the cents the headline prints")
    func theComparisonBasisIsTheHeadline() throws {
        let history = [Self.previousBest()]
        let figure = Self.draftFigure(history: history)
        let headlineCents = try #require(figure.cents)
        let engine = ledgerBasisEngine(records: history, snapshot: Self.revealSnapshot(history: history))
        let result = engine.reveal(
            forNightAt: revealCalendar().startOfDay(for: Self.draftDate),
            cents: headlineCents,
            period: wholeFixturePeriod(),
            shiftID: Self.draftID
        )
        // The whole defect in one line: these two were 25000 and 45000.
        #expect(result.cents == headlineCents)
    }

    @Test("the history the comparison reads is the ledger's, not a scalar repricing of it")
    func theHistoryIsLedgerValued() throws {
        // A prior shift whose ledger value and scalar value differ: ten hours
        // in March, $0 of tips. The ledger says $100.00; the scalar at today's
        // $30.00/hr says $300.00.
        let prior = TipEntry(
            date: on(2026, 3, 6),
            amountCents: 0,
            kind: .credit,
            recordedAt: on(2026, 3, 6, hour: 23),
            hoursWorked: 10,
            shiftPeriod: .dinner,
            shiftID: revealShiftID(3)
        )
        let history = [prior]
        let snapshot = try #require(Self.revealSnapshot(history: history))
        let valued = try #require(snapshot.valuation(revealShiftID(3)))
        #expect(valued.components.earnedIncomeCents == 10_000)

        let ledgerEngine = ledgerBasisEngine(records: history, snapshot: snapshot)
        let ledgerResult = ledgerEngine.reveal(
            forNightAt: revealCalendar().startOfDay(for: Self.draftDate),
            cents: 25_000,
            period: wholeFixturePeriod(),
            shiftID: Self.draftID
        )
        // $250.00 IS a record against a $100.00 history, and the record it
        // names is the figure that shift's own row shows.
        #expect(ledgerResult.isRecord == true)
        #expect(RevealCopy.comparison(for: ledgerResult.comparison, period: .dinner).contains("$100.00"))

        // The scalar engine reprices the same shift at TODAY's rate — ten
        // March hours at $30.00 = $300.00 — so the identical $250.00 draft
        // stops being a record and becomes a shift below average. One shift,
        // one evening, two opposite verdicts, decided entirely by which basis
        // the history was priced on. Both MEASURED.
        let scalarResult = scalarBasisEngine(records: history, rateCents: 3_000).reveal(
            forNightAt: revealCalendar().startOfDay(for: Self.draftDate),
            cents: 25_000,
            period: wholeFixturePeriod(),
            shiftID: Self.draftID
        )
        #expect(scalarResult.isRecord == false)
        #expect(RevealCopy.comparison(for: scalarResult.comparison, period: .dinner)
            == "$50.00 below your Friday average (across one Fridays).")
    }
}

/// The CROSS-SURFACE gate. Two screens show the same shift's reveal verdict
/// within one tap of each other: the log sheet's post-save card, and
/// Dashboard's tonight echo. They must not disagree about the delta or the
/// rank.
///
/// MEASURED before this change, on the fixture below: the log sheet said
/// "$0.00 above your Friday average" and Dashboard said "$50.00 below your
/// Friday average" about the same shift, because the prior Friday was 20000 to
/// Dashboard (a 50-hour week's overtime, allocated by the ledger) and 15000 to
/// the log sheet (the base rate, per shift, no workweek). The HEADLINES agreed
/// — both are `EarningsFigure.shiftEarnedIncome` — which is what made it hard
/// to see: only the sentence underneath disagreed.
///
/// The two sides below build their comparison inputs the way each screen does:
/// Dashboard from a `LegacySnapshotBridge` snapshot of the SAVED history, the
/// log sheet from a `ShiftDraftPreview` snapshot with tonight still a DRAFT.
/// That is the substantive claim — a draft that has not been written yet and
/// the row it becomes are the same dataset to the ledger, so the copy is
/// byte-identical.
@Suite("Reveal comparison parity: the log sheet and Dashboard's echo say one thing")
@MainActor
struct RevealComparisonParityTests {
    /// Monday-start weeks at $10.00/hr — five 10-hour shifts Mon–Fri put the
    /// prior Friday inside a 50-hour week, so it carries real overtime that no
    /// per-shift formula can see.
    private static func mondayStartPolicies() -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("reveal/rate/flat"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 1_000,
                provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("reveal/calendar/monday"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.payroll
            )]
        )
    }

    /// Mon 2026-09-07 through Fri 2026-09-11, ten hours each: fifty hours in
    /// one Monday-start week. Friday is last, so the 40-hour threshold is
    /// already crossed when it starts and every one of its minutes is
    /// overtime — the whole point of the fixture.
    ///
    /// Friday carries $50.00 of credit and Monday through Thursday $10.00. The
    /// quiet weekdays are deliberate: with all five at $50.00, tonight ties the
    /// minimum and `StatsEngine` short-circuits to `.slowestRecently`, a
    /// comparison that prints NO figure — so both bases produce the same
    /// sentence and the fixture proves nothing. MEASURED: "Your quietest
    /// dinner in a while." on both sides.
    private static func priorWeek() -> [TipEntry] {
        (7...11).map { day in
            TipEntry(
                date: on(2026, 9, day),
                amountCents: day == 11 ? 5_000 : 1_000,
                kind: .credit,
                recordedAt: on(2026, 9, day, hour: 23),
                hoursWorked: 10,
                shiftPeriod: .dinner,
                shiftID: revealShiftID(10 + day)
            )
        }
    }

    private static let priorFridayID = revealShiftID(21)
    private static let tonightID = revealShiftID(30)
    private static let tonightDate = on(2026, 9, 18)

    private static func tonightRows(shiftID: UUID) -> [TipEntry] {
        ShiftDraftPreview.rows(
            date: tonightDate,
            cashCents: 0,
            creditCents: 5_000,
            recordedAt: on(2026, 9, 18, hour: 23),
            shiftID: shiftID,
            hoursWorked: 10,
            tipOutCents: 0,
            salesCents: 0,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil,
            receiptMetrics: nil
        )
    }

    @Test("the prior Friday's overtime is exactly what the two bases disagreed about")
    func thePriorFridayCarriesOvertime() throws {
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            entries: Self.priorWeek(),
            policies: Self.mondayStartPolicies(),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: Self.tonightDate
        ))
        let friday = try #require(snapshot.valuation(Self.priorFridayID))
        // The ledger: the 40-hour threshold fell before Friday started, so all
        // 600 of its minutes are overtime. $150.00 of wages plus $50.00 of
        // credit = $200.00. MEASURED.
        #expect(friday.components.earnedIncomeCents == 20_000)

        // The scalar basis the comparison used to read: base rate, per shift,
        // no workweek. $150.00, and $50.00 of overtime simply absent.
        let scalar = 5_000 + (WageEstimate.cents(wageCentsPerHour: 1_000, hours: 10) ?? 0)
        #expect(scalar == 15_000)
    }

    @Test("the log sheet's comparison copy is byte-identical to Dashboard's echo for the same shift")
    func bothSurfacesPrintOneSentence() throws {
        let policies = Self.mondayStartPolicies()
        let history = Self.priorWeek()
        let period = wholeFixturePeriod()
        let night = revealCalendar().startOfDay(for: Self.tonightDate)

        // ── DASHBOARD's echo: tonight is SAVED, and the snapshot is the
        //    bridge's over the whole stored history.
        let saved = Self.tonightRows(shiftID: Self.tonightID)
        let dashboardSnapshot = try #require(LegacySnapshotBridge.snapshot(
            entries: history + saved,
            policies: policies,
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: Self.tonightDate
        ))
        let dashboardFigure = EarningsFigure.shiftEarnedIncome(
            dashboardSnapshot.valuation(Self.tonightID),
            wageFeatureEnabled: dashboardSnapshot.wageFeatureEnabled
        )
        let dashboardCents = try #require(dashboardFigure.cents)
        let dashboardResult = ledgerBasisEngine(
            records: history + saved,
            snapshot: dashboardSnapshot
        ).reveal(
            forNightAt: night,
            cents: dashboardCents,
            period: period,
            shiftID: Self.tonightID
        )

        // ── THE LOG SHEET: tonight is still a DRAFT, and the snapshot is the
        //    preview's over the same history with the draft substituted in.
        let draftRows = Self.tonightRows(shiftID: Self.tonightID)
        let logSnapshot = try #require(ShiftDraftPreview.snapshot(
            draft: ShiftDraftPreview.draftInput(
                rows: draftRows,
                shiftID: Self.tonightID,
                payrollTimeZone: PaydayTestZone.payroll
            ),
            entries: history,
            policies: policies,
            payrollTimeZone: PaydayTestZone.payroll,
            windowed: false
        ))
        let logFigure = LogShiftFacts(
            snapshot: ShiftDraftPreview.snapshot(
                draft: ShiftDraftPreview.draftInput(
                    rows: draftRows,
                    shiftID: Self.tonightID,
                    payrollTimeZone: PaydayTestZone.payroll
                ),
                entries: history,
                policies: policies,
                payrollTimeZone: PaydayTestZone.payroll
            ),
            draftID: Self.tonightID,
            date: Self.tonightDate,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            hoursWorked: 10,
            calendar: revealCalendar(),
            now: on(2026, 9, 18, hour: 23)
        ).total
        let logCents = try #require(logFigure.cents)
        let logResult = ledgerBasisEngine(
            records: history,
            snapshot: logSnapshot
        ).reveal(
            forNightAt: night,
            cents: logCents,
            period: period,
            shiftID: Self.tonightID
        )

        // The headlines already agreed before this change. They still do.
        #expect(logCents == dashboardCents)
        #expect(logCents == 15_000)

        // The sentence underneath is the gate. Byte-identical, both the
        // comparison case and every figure inside it.
        let logCopy = RevealCopy.comparison(for: logResult.comparison, period: .dinner)
        let dashboardCopy = RevealCopy.comparison(for: dashboardResult.comparison, period: .dinner)
        #expect(logCopy == dashboardCopy)
        #expect(logResult.isRecord == dashboardResult.isRecord)
        // And it is the LEDGER's delta and the LEDGER's rank: $150.00 tonight
        // against a prior Friday the ledger valued at $200.00, second-best in
        // the period rather than best. MEASURED.
        #expect(logCopy == "$50.00 below your Friday average (across one Fridays). Second-best dinner this period.")

        // What the log sheet said before: the same shift, the same evening,
        // a different verdict.
        let brokenCents = 5_000 + (WageEstimate.cents(wageCentsPerHour: 1_000, hours: 10) ?? 0)
        let brokenCopy = RevealCopy.comparison(
            for: scalarBasisEngine(records: history, rateCents: 1_000).reveal(
                forNightAt: night,
                cents: brokenCents,
                period: period,
                shiftID: Self.tonightID
            ).comparison,
            period: .dinner
        )
        #expect(brokenCopy != dashboardCopy)
        // It disagreed about BOTH numbers: the delta and the rank. MEASURED.
        #expect(brokenCopy == "$0.00 above your Friday average (across one Fridays). Best dinner this period.")
    }
}
