import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// PR A: "card tips paid at close" and "tip share received", on the facts the
/// screens render. Built the way `DashboardView.body` builds them, from
/// records through `DashboardEarnings.build`. Synthetic round numbers.
@Suite("Tip share received and card tips paid at close, on screen facts")
@MainActor
struct TipShareAndPayoutFactsTests {
    private static let zone = PaydayTestZone.payroll

    private static func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func policies(rateCents: Int) -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("pr-a/rate"),
                effectiveFrom: .distantPast, hourlyRateCents: rateCents, provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("pr-a/calendar"),
                effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone
            )]
        )
    }

    private static func schedule() -> PaySchedule {
        PaySchedule(
            frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0),
            payDelayDays: 5, firstWeekday: 2
        )
    }

    private func facts(
        _ records: [ShiftRecord],
        cardTipsPaidAtClose: Bool,
        rateCents: Int = 1_000,
        paychecks: [PaycheckRecord] = []
    ) -> DashboardFacts {
        let dataset = DashboardEarnings.build(
            records: records, policies: Self.policies(rateCents: rateCents),
            payrollTimeZone: Self.zone, paychecks: paychecks,
            cardTipsPaidAtClose: cardTipsPaidAtClose
        )
        #expect(dataset.cardTipsPaidAtClose == cardTipsPaidAtClose)
        return DashboardFacts(
            snapshot: dataset.snapshot,
            allShiftRecords: dataset.shiftRecordDays,
            allTipRecords: dataset.tipRecords,
            withholdingModel: dataset.withholdingModel,
            cardTipsPaidAtClose: dataset.cardTipsPaidAtClose,
            schedule: Self.schedule(),
            now: Self.at(2026, 10, 7, hour: 12),
            // Puts the payday card on screen for the period just closed.
            forcedPaydayPhase: .periodClosed,
            dismissedClosedEnd: nil,
            dismissedCheckEnd: nil,
            payrollTimeZone: Self.zone
        )
    }

    /// Cash, card, gratuity-free, a share and a tip-out in one closed period,
    /// with 8h at $10.00 so the wage is $80.00.
    private static func mixedNight() -> [ShiftRecord] {
        let day = at(2026, 10, 5)
        return [
            ShiftRecord(workDate: day, shiftPeriod: .dinner,
                        cashTipsCents: 2_000, creditTipsCents: 6_000, tipOutCents: 5_000,
                        hoursWorked: 8, tipShareInCents: 18_000, recordedAt: day),
        ]
    }

    // MARK: - Acceptance 1: the bartender

    @Test("a bartender with only a tip share keeps share minus tip-out, with a drawer row and no tip percent")
    func bartenderKeepsTheShare() throws {
        let day = Self.at(2026, 10, 5)
        let record = ShiftRecord(workDate: day, shiftPeriod: .dinner,
                                 tipOutCents: 4_000, tipShareInCents: 18_000, recordedAt: day)
        let facts = facts([record], cardTipsPaidAtClose: false, rateCents: 0)
        let snapshot = try #require(facts.snapshot)
        let valuation = try #require(snapshot.valuation(record.id))
        #expect(valuation.components.nonWageEarningsCents == 14_000)
        #expect(valuation.components.voluntaryTipsCents == 0)

        let result = snapshot.range(DayRange(
            start: CivilDay(day, in: Self.zone), end: CivilDay(day, in: Self.zone)))
        let rows = BreakdownRow.ledgerRows(result)
        let share = try #require(rows.first { $0.label == "Tip share received" })
        #expect(share.cents == 18_000)
        #expect(MetricID.tipShareIn.allowedLabels.contains(share.label))
        #expect(BreakdownRow.total(result).cents == 14_000)

        // No sales, no guest tips: the tip-percent tile has nothing to say.
        let engine = StatsEngine(payrollTimeZone: Self.zone, records: StatsRecordAdapter.tipRecords(from: [record]))
        #expect(engine.tipPercent(forNightAt: day) == nil)
    }

    @Test("no drawer row when nothing was received")
    func noShareNoRow() throws {
        let day = Self.at(2026, 10, 5)
        let record = ShiftRecord(workDate: day, creditTipsCents: 5_000, recordedAt: day)
        let facts = facts([record], cardTipsPaidAtClose: false)
        let snapshot = try #require(facts.snapshot)
        let result = snapshot.range(DayRange(
            start: CivilDay(day, in: Self.zone), end: CivilDay(day, in: Self.zone)))
        #expect(!BreakdownRow.ledgerRows(result).contains { $0.label == "Tip share received" })
    }

    // MARK: - Acceptance 2: the payday card, both settings

    @Test("on the check: card tips and the share ride the check, cash is already paid")
    func onTheCheck() throws {
        let facts = facts(Self.mixedNight(), cardTipsPaidAtClose: false)
        #expect(!facts.cardTipsPaidAtClose)
        // (6000 card + 18000 share - 5000 tip-out) + 8000 wages
        #expect(facts.predictedPaycheck.cents == 27_000)
        #expect(facts.paydayCash.cents == 2_000)
        #expect(facts.paydayCash.label == "Cash tips")
        let hero = try #require(facts.hero.cents)
        #expect(hero - 27_000 == 2_000, "the gap from the hero is exactly what was already paid")
    }

    @Test("paid at close: the check is gratuity + wages and every tip is already paid")
    func paidAtClose() throws {
        let facts = facts(Self.mixedNight(), cardTipsPaidAtClose: true)
        #expect(facts.cardTipsPaidAtClose)
        #expect(facts.predictedPaycheck.cents == 8_000)
        // 2000 cash + 6000 card + 18000 share - 5000 tip-out
        #expect(facts.paydayCash.cents == 21_000)
        #expect(facts.paydayCash.label == "Tips")
        #expect(facts.paydayCash.metric.allowedLabels.contains(facts.paydayCash.label))
        let hero = try #require(facts.hero.cents)
        #expect(hero - 8_000 == 21_000, "the gap from the hero is exactly what was already paid")
    }

    @Test("paid at close, the after-tax line is still there once stubs can fit a model")
    func paidAtCloseKeepsAfterTax() {
        func stub(_ day: Int, _ gross: Int, _ net: Int) -> PaycheckRecord {
            PaycheckRecord(periodStart: Self.at(2026, 8, day, hour: 0), periodEnd: Self.at(2026, 8, day + 1, hour: 0),
                           paidTipsCents: 0, grossPayCents: gross, netPayCents: net)
        }
        let facts = facts(Self.mixedNight(), cardTipsPaidAtClose: true,
                          paychecks: [stub(1, 100_000, 85_000), stub(5, 120_000, 100_000), stub(9, 80_000, 70_000)])
        #expect(!facts.predictedPaycheckNet.isUnavailable)
        #expect(facts.paydayNetLine != nil)
    }

    // MARK: - The paycheck sheet and History

    @Test("paid at close, the sheet states no tips-line expectation and audits none")
    func sheetHidesTheTipsLineAtClose() throws {
        let facts = facts(Self.mixedNight(), cardTipsPaidAtClose: true)
        let snapshot = try #require(facts.snapshot)
        let day = Self.at(2026, 10, 5)
        let result = snapshot.range(DayRange(
            start: CivilDay(day, in: Self.zone), end: CivilDay(day, in: Self.zone)))

        let atClose = PaycheckReconciler.Expectation(result: result, stamp: snapshot.stamp, cardTipsOnCheck: false)
        let sheet = PaycheckEntryFacts(expectation: atClose, observation: .init(paidTipsCents: 0))
        #expect(sheet.expectedTipsLine.isUnavailable)
        #expect(!sheet.findings.contains { $0.id == "tips-vs-logged" })

        let onCheck = PaycheckReconciler.Expectation(result: result, stamp: snapshot.stamp)
        let onCheckSheet = PaycheckEntryFacts(expectation: onCheck, observation: .init(paidTipsCents: 0))
        #expect(onCheckSheet.expectedTipsLine.cents == 19_000)
    }

    @Test("the Settings choice syncs both ways and survives a payload without it")
    func settingRoundTrips() throws {
        let suite = "pr-a-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserPreferencesStore(defaults: defaults, wageDefaults: defaults)
        #expect(!store.isCardTipsPaidAtClose)
        store.isCardTipsPaidAtClose = true
        #expect(UserPreferencesStore.storedCardTipsPaidAtClose(defaults))
        #expect(UserPreferencesStore(defaults: defaults, wageDefaults: defaults).isCardTipsPaidAtClose)

        let json = #"{"user_id":"11111111-1111-4111-8111-111111111111","smart_nudge_enabled":true,"payday_reminder_enabled":true,"move_ledger":{},"card_tips_paid_at_close":true,"client_updated_at":"2026-10-01T00:00:00Z"}"#
        let decoded = try JSONDecoder().decode(RemoteUserSettings.self, from: Data(json.utf8))
        #expect(decoded.cardTipsPaidAtClose == true)
        let older = #"{"user_id":"11111111-1111-4111-8111-111111111111","smart_nudge_enabled":true,"payday_reminder_enabled":true,"move_ledger":{},"client_updated_at":"2026-10-01T00:00:00Z"}"#
        #expect(try JSONDecoder().decode(RemoteUserSettings.self, from: Data(older.utf8)).cardTipsPaidAtClose == nil)
    }

    @Test("a share-only shift may be saved")
    func shareOnlyIsSavable() {
        #expect(ShiftCommands.hasSomethingToSave(
            cashTipsCents: 0, creditTipsCents: 0, hoursWorked: nil, receiptMetrics: nil,
            tipShareInCents: 18_000))
        #expect(!ShiftCommands.hasSomethingToSave(
            cashTipsCents: 0, creditTipsCents: 0, hoursWorked: nil, receiptMetrics: nil))
    }
}
