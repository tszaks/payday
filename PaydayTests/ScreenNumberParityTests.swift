import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// S12's actual purpose: **one fixture, every screen, the same number.**
///
/// This is the goal's own sentence at the screen level — *no two surfaces
/// disagree about the same fact* — and it is the gate S12 was supposed to
/// provide.
///
/// ## What was there instead
///
/// `BridgeRepresentationParityTests`, two tests, both at the ADAPTER level:
/// the bridge produces an identical `ShiftInput` from either row type, and a
/// snapshot values either row type to the same cents. Those are true and
/// worth having, and they are not this: two representations can agree at the
/// adapter and still disagree on screen, because a screen chooses which
/// query to ask and which figure to render. The nine unswitched readers the
/// flip sweep found were all downstream of an adapter that was already
/// correct.
///
/// The slice also names "the 16 `ScreenNumbers` fields". **That type does not
/// exist and never did** — it was a planned artifact, so implementing the
/// spec literally would mean inventing it. What matters is the claim, not
/// the vehicle, so this drives the real adapters instead.
///
/// ## One representation now
///
/// This suite used to run every surface twice — once over `ShiftRecord`s,
/// once over hand-built `TipEntry` rows — because both were live reads and
/// the hazard was the two disagreeing. The flip deleted the legacy arm from
/// every surface; `ShiftRecord` is the only stored shape the screens read.
/// What remains to pin is the claim the arms were measuring toward: that
/// Dashboard, History, Calendar, the day sheet and the export all report the
/// engine's own figure for the same fixture, stated as literals so all of
/// them being wrong together still fails.
@Suite("Screen number parity: one fixture, every surface, one number", .serialized)
@MainActor
struct ScreenNumberParityTests {

    private static let zone = PaydayTestZone.payroll

    private static func at(_ y: Int, _ m: Int, _ d: Int, hour: Int = 17) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private static func policies() -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("screennum/rate"),
                effectiveFrom: .distantPast, hourlyRateCents: 1_800, provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("screennum/calendar"),
                effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone
            )]
        )
    }

    // Two nights. Night one carries a tip-out so the subtraction is
    // exercised; night two does not, so a sign error shows as a difference
    // between them rather than a uniform shift.
    private static let nightOne = at(2026, 10, 5)
    private static let nightTwo = at(2026, 10, 6)

    /// The fixture, in the only stored shape the screens read since the flip.
    private static func records() -> [ShiftRecord] {
        [
            ShiftRecord(workDate: nightOne, shiftPeriod: .dinner,
                        cashTipsCents: 6_000, creditTipsCents: 20_000, tipOutCents: 3_000,
                        hoursWorked: 8, recordedAt: nightOne),
            ShiftRecord(workDate: nightTwo, shiftPeriod: .dinner,
                        cashTipsCents: 4_000, creditTipsCents: 15_000,
                        hoursWorked: 7, recordedAt: nightTwo),
        ]
    }

    /// Stated once, as literals, so "the surfaces agree" cannot be satisfied
    /// by all of them being wrong together.
    ///
    /// Night one: 6000 + 20000 − 3000 tips, plus 8h at 1800 = 14400 wages.
    /// Night two: 4000 + 15000 tips, plus 7h at 1800 = 12600 wages.
    private static let nightOneCents = 6_000 + 20_000 - 3_000 + 14_400
    private static let nightTwoCents = 4_000 + 15_000 + 12_600

    private static func range() -> DayRange {
        DayRange(start: CivilDay(at(2026, 9, 28, hour: 0), in: zone),
                 end: CivilDay(at(2026, 10, 11, hour: 0), in: zone))
    }

    // MARK: - The fixture itself agrees with the engine

    /// Before comparing screens, pin that the fixture's literals ARE what the
    /// engine computes. Otherwise a later failure is ambiguous between "a
    /// screen drifted" and "the fixture was always wrong".
    @Test("the fixture produces the engine's own figures")
    func fixtureMatchesTheEngine() throws {
        let comp = Self.policies()
        let snapshot = try #require(HistoryEarnings.build(
            records: Self.records(), policies: comp,
            payrollTimeZone: Self.zone
        ).snapshot)

        let one = CivilDay(Self.nightOne, in: Self.zone)
        let two = CivilDay(Self.nightTwo, in: Self.zone)

        #expect(snapshot.day(one).knownComponents.earnedIncomeCents == Self.nightOneCents)
        #expect(snapshot.day(two).knownComponents.earnedIncomeCents == Self.nightTwoCents)
    }

    // MARK: - Every screen, one number

    /// **The gate.** Each surface reports the same period total, and that
    /// total is the engine's.
    ///
    /// Driven through the adapters the views construct, not through
    /// re-derived arithmetic, so a screen that reads the wrong query shows up
    /// here rather than agreeing with a test that made the same mistake.
    @Test("Dashboard, History rows, period detail and Calendar agree")
    func everySurfaceAgrees() throws {
        let comp = Self.policies()
        let records = Self.records()
        let range = Self.range()
        let expected = Self.nightOneCents + Self.nightTwoCents

        // Dashboard.
        let dashboard = try #require(DashboardEarnings.build(
            records: records, policies: comp, payrollTimeZone: Self.zone
        ).snapshot).range(range).knownComponents.earnedIncomeCents

        // History rows and period detail share `HistoryEarnings.build`.
        let history = try #require(HistoryEarnings.build(
            records: records, policies: comp,
            payrollTimeZone: Self.zone
        ).snapshot).range(range).knownComponents.earnedIncomeCents

        // Calendar.
        let calendar = try #require(CalendarEarnings.snapshot(
            records: records, policies: comp, payrollTimeZone: Self.zone
        )).range(range).knownComponents.earnedIncomeCents

        // Every surface against the literal — not merely against each other,
        // so all of them being wrong together still fails.
        for (name, value) in [
            ("dashboard", dashboard), ("history", history), ("calendar", calendar),
        ] {
            #expect(value == expected, "\(name) reported \(value), expected \(expected)")
        }
        #expect(expected > 0)
    }

    /// The day sheet, on the night that carries the tip-out.
    @Test("the day sheet reports the engine's figure")
    func dayDetailReportsTheEngine() throws {
        let comp = Self.policies()
        let facts = DayDetailFacts(
            shiftRecords: Self.records(), date: Self.nightOne,
            policies: comp, payrollTimeZone: Self.zone
        )
        #expect(facts.total.cents == Self.nightOneCents)
    }

    /// The CSV export, since it is the one surface a person keeps after the
    /// app is gone.
    @Test("the export reports the same money")
    func exportReportsTheSameMoney() throws {
        let calculator = PayPeriodCalculator(payrollTimeZone: Self.zone, schedule: .fallback)
        let csv = CSVExporter.export(
            records: Self.records(), paycheckRecords: [],
            calculator: calculator
        )
        // Two shifts, so two rows under the header.
        #expect(csv.split(separator: "\n").count == 3)

        // The Net column, night by night. Compared as the NON-WAGE total the
        // CSV prints, which is cash + credit - tipOut.
        let lines = csv.split(separator: "\n").map(String.init)
        let header = try #require(lines.first?.split(separator: ",").map(String.init))
        let net = try #require(header.firstIndex(of: "Net"))
        let nets = lines.dropFirst()
            .map { String($0.split(separator: ",", omittingEmptySubsequences: false)[net]) }
        #expect(nets == ["230.00", "190.00"], "6000+20000-3000 and 4000+15000")
    }
}
