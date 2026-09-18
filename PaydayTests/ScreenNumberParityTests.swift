import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// S12's actual purpose: **one fixture, every screen, both representations,
/// the same number.**
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
/// ## Both arms are CONSTRUCTED, not mirrored
///
/// The obvious way to get one fixture in two representations is
/// `ShiftProjection.rows(for:)`. That is the mirror, and a test built by
/// mirroring cannot catch a defect in the mirror — it would prove the
/// screens agree about the projection's view of a record rather than about a
/// shift that genuinely exists each way.
///
/// So both sides are hand-built to describe the same two nights, and the
/// expected cents are stated once as literals. If the two arms disagree, at
/// least one screen is wrong; if both agree but differ from the literals,
/// the engine moved.
@Suite("Screen number parity across representations", .serialized)
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

    /// The records arm, built directly.
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

    /// The legacy arm, built INDEPENDENTLY to describe the same two nights.
    ///
    /// Not `ShiftProjection.rows(for:)`. Hand-built so a defect in the
    /// projection cannot hide here, which is the whole reason this suite
    /// exists rather than reusing the mirrored helpers other suites use.
    ///
    /// Shift-level values sit on ONE row per night, which is the shape the
    /// legacy model actually stores (`ShiftDetails.resolve` picks a single
    /// canonical value).
    private static func entries() -> [TipEntry] {
        let one = UUID(), two = UUID()
        return [
            TipEntry(date: nightOne, amountCents: 6_000, kind: .cash, recordedAt: nightOne,
                     hoursWorked: 8, tipOutCents: 3_000, shiftPeriod: .dinner, shiftID: one),
            TipEntry(date: nightOne, amountCents: 20_000, kind: .credit, recordedAt: nightOne,
                     shiftPeriod: .dinner, shiftID: one),
            TipEntry(date: nightTwo, amountCents: 4_000, kind: .cash, recordedAt: nightTwo,
                     hoursWorked: 7, shiftPeriod: .dinner, shiftID: two),
            TipEntry(date: nightTwo, amountCents: 15_000, kind: .credit, recordedAt: nightTwo,
                     shiftPeriod: .dinner, shiftID: two),
        ]
    }

    /// Stated once, as literals, so "the two arms agree" cannot be satisfied
    /// by both being wrong together.
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
    @Test("both arms produce the engine's own figures for the fixture")
    func fixtureMatchesTheEngine() throws {
        let comp = Self.policies()
        let fromRecords = try #require(HistoryEarnings.build(
            entries: [], records: Self.records(), policies: comp,
            payrollTimeZone: Self.zone, representation: .records
        ).snapshot)
        let fromLegacy = try #require(HistoryEarnings.build(
            entries: Self.entries(), records: [], policies: comp,
            payrollTimeZone: Self.zone, representation: .legacy
        ).snapshot)

        let one = CivilDay(Self.nightOne, in: Self.zone)
        let two = CivilDay(Self.nightTwo, in: Self.zone)

        #expect(fromRecords.day(one).knownComponents.earnedIncomeCents == Self.nightOneCents)
        #expect(fromRecords.day(two).knownComponents.earnedIncomeCents == Self.nightTwoCents)
        #expect(fromLegacy.day(one).knownComponents.earnedIncomeCents == Self.nightOneCents)
        #expect(fromLegacy.day(two).knownComponents.earnedIncomeCents == Self.nightTwoCents)
    }

    // MARK: - Every screen, both arms, one number

    /// **The gate.** Each surface reports the same period total from either
    /// representation, and that total is the engine's.
    ///
    /// Driven through the adapters the views construct, not through
    /// re-derived arithmetic, so a screen that reads the wrong query shows up
    /// here rather than agreeing with a test that made the same mistake.
    @Test("Dashboard, History rows, period detail and Calendar agree across both arms")
    func everySurfaceAgreesAcrossArms() throws {
        let comp = Self.policies()
        let records = Self.records()
        let entries = Self.entries()
        let range = Self.range()
        let expected = Self.nightOneCents + Self.nightTwoCents

        // Dashboard.
        let dashRecords = try #require(DashboardEarnings.build(
            records: records, policies: comp, payrollTimeZone: Self.zone
        ).snapshot).range(range).knownComponents.earnedIncomeCents
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.zone
        let dashLegacy = try #require(DashboardEarnings.build(
            entries: entries, policies: comp, payrollTimeZone: Self.zone, calendar: cal
        ).snapshot).range(range).knownComponents.earnedIncomeCents

        // History rows and period detail share `HistoryEarnings.build`.
        let histRecords = try #require(HistoryEarnings.build(
            entries: [], records: records, policies: comp,
            payrollTimeZone: Self.zone, representation: .records
        ).snapshot).range(range).knownComponents.earnedIncomeCents
        let histLegacy = try #require(HistoryEarnings.build(
            entries: entries, records: [], policies: comp,
            payrollTimeZone: Self.zone, representation: .legacy
        ).snapshot).range(range).knownComponents.earnedIncomeCents

        // Calendar.
        let calRecords = try #require(CalendarEarnings.snapshot(
            records: records, policies: comp, payrollTimeZone: Self.zone
        )).range(range).knownComponents.earnedIncomeCents
        let calLegacy = try #require(CalendarEarnings.snapshot(
            entries: entries, records: [], policies: comp,
            payrollTimeZone: Self.zone, representation: .legacy
        )).range(range).knownComponents.earnedIncomeCents

        // Every surface, every arm, against the literal — not merely against
        // each other, so all six being wrong together still fails.
        for (name, value) in [
            ("dashboard/records", dashRecords), ("dashboard/legacy", dashLegacy),
            ("history/records", histRecords), ("history/legacy", histLegacy),
            ("calendar/records", calRecords), ("calendar/legacy", calLegacy),
        ] {
            #expect(value == expected, "\(name) reported \(value), expected \(expected)")
        }
        #expect(expected > 0)
    }

    /// The day sheet, both arms, on the night that carries the tip-out.
    ///
    /// Its own test because `DayDetailFacts` has two initializers rather than
    /// a representation parameter, so it is the one surface where the arms
    /// are separate code paths rather than one builder choosing.
    @Test("the day sheet reports the same night from either representation")
    func dayDetailAgreesAcrossArms() throws {
        let comp = Self.policies()
        let fromRecords = DayDetailFacts(
            shiftRecords: Self.records(), date: Self.nightOne,
            policies: comp, payrollTimeZone: Self.zone
        )
        let fromLegacy = DayDetailFacts(
            allEntries: Self.entries(), date: Self.nightOne,
            policies: comp, payrollTimeZone: Self.zone
        )
        #expect(fromRecords.total.cents == Self.nightOneCents)
        #expect(fromLegacy.total.cents == Self.nightOneCents)
        #expect(fromRecords.total.cents == fromLegacy.total.cents)
    }

    /// The CSV export, both arms, since it is the one surface a person keeps
    /// after the app is gone.
    @Test("the export reports the same money from either representation")
    func exportAgreesAcrossArms() throws {
        let calculator = PayPeriodCalculator(payrollTimeZone: Self.zone, schedule: .fallback)
        let fromRecords = CSVExporter.export(
            entries: [], records: Self.records(), paycheckRecords: [],
            calculator: calculator, representation: .records
        )
        let fromLegacy = CSVExporter.export(
            entries: Self.entries(), records: [], paycheckRecords: [],
            calculator: calculator, representation: .legacy
        )
        // Two shifts, so two rows under the header on each side.
        #expect(fromRecords.split(separator: "\n").count == 3)
        #expect(fromLegacy.split(separator: "\n").count == 3)

        // The Net column, night by night, from both arms. Compared as the
        // NON-WAGE total the CSV prints, which is cash + credit - tipOut.
        func nets(_ csv: String) -> [String] {
            let lines = csv.split(separator: "\n").map(String.init)
            guard let header = lines.first?.split(separator: ",").map(String.init),
                  let net = header.firstIndex(of: "Net") else { return [] }
            return lines.dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false)[net] }
                .map(String.init)
        }
        let recordNets = nets(fromRecords)
        let legacyNets = nets(fromLegacy)
        #expect(recordNets == ["230.00", "190.00"], "6000+20000-3000 and 4000+15000")
        #expect(recordNets == legacyNets, "the export must not depend on how the shift is stored")
    }
}
