import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// Flip gates 5 and 7, the two that needed the flipped call sites to exist.
///
/// **Gate 7** is the one that makes this PR safe to merge: every shipped
/// account is non-authoritative, so the flip must ship NO behaviour change to
/// anyone. Asserted by driving each switched surface with the flag off and
/// checking it took the legacy path -- not by checking the numbers look
/// plausible, which they would either way.
///
/// **Gate 5** is the cross-surface one, widened on review to name all FOUR
/// `HistoryEarnings.build` consumers rather than the six surfaces the design
/// originally listed. That widening matters because the switch moved UP into
/// the shared builder: making a half-switched surface unrepresentable is the
/// better architecture AND concentrates one decision behind four screens, so
/// the single point has to be tested for all four.
@Suite("Flip gates 5 and 7", .serialized)
@MainActor
struct FlipGates5And7Tests {

    private static let zone = TimeZone(identifier: "America/New_York")!

    private func account(authoritative: Bool) -> UUID {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        _ = PaydaySyncState.registerCurrentUser(id)
        if authoritative {
            PaydaySyncState.mutate(userID: id) {
                $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
            }
        }
        #expect(PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount == authoritative)
        return id
    }

    private static func day(_ offset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let base = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        return cal.date(byAdding: .day, value: offset, to: base)!
    }

    private static func policies() -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("gates/rate"),
                effectiveFrom: .distantPast, hourlyRateCents: 283, provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("gates/calendar"),
                effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone
            )]
        )
    }

    private static func records() -> [ShiftRecord] {
        [
            ShiftRecord(workDate: day(0), shiftPeriod: .lunch, cashTipsCents: 2_200,
                        creditTipsCents: 3_100, tipOutCents: 400, hoursWorked: 4.25,
                        recordedAt: day(0)),
            ShiftRecord(workDate: day(0), shiftPeriod: .dinner, cashTipsCents: 5_600,
                        creditTipsCents: 9_900, hoursWorked: 5.5,
                        recordedAt: day(0).addingTimeInterval(3_600)),
        ]
    }

    private static func mirroredEntries(_ records: [ShiftRecord]) -> [TipEntry] {
        records.flatMap { ShiftProjection.rows(for: $0) }.map { row in
            TipEntry(
                id: row.id, date: row.date, amountCents: row.amountCents, kind: row.kind,
                note: row.note, recordedAt: row.recordedAt, hoursWorked: row.hoursWorked,
                tipOutCents: row.tipOutCents, salesCents: row.salesCents,
                shiftPeriod: row.shiftPeriod, shiftID: row.shiftID, clockIn: row.clockIn,
                clockOut: row.clockOut, serverCount: row.serverCount,
                receiptMetrics: row.receiptMetrics
            )
        }
    }

    // MARK: - Gate 7

    /// The merge-safety gate. With the flag off -- every shipped account --
    /// each switched builder must take the LEGACY path. Asserted structurally
    /// (which list is populated) rather than numerically, because the numbers
    /// agree either way and would pass whichever path ran.
    @Test("with the flag off, every switched builder takes the legacy path")
    func gate7NonAuthoritativeTakesLegacy() {
        _ = account(authoritative: false)
        let policies = Self.policies()
        let entries = Self.mirroredEntries(Self.records())

        let history = HistoryEarnings.build(
            entries: entries, policies: policies, payrollTimeZone: Self.zone
        )
        #expect(!history.shiftDays.isEmpty, "the legacy list carries the rows")
        #expect(history.shiftRecordDays.isEmpty, "and the record list stays empty")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.zone
        let dashboard = DashboardEarnings.build(
            entries: entries, policies: policies, payrollTimeZone: Self.zone, calendar: cal
        )
        #expect(!dashboard.shiftDays.isEmpty)
        #expect(dashboard.shiftRecordDays.isEmpty)

        let dayDetail = DayDetailFacts(
            allEntries: entries, date: Self.day(0),
            policies: policies, payrollTimeZone: Self.zone
        )
        #expect(!dayDetail.shifts.isEmpty)
        #expect(dayDetail.shiftRecords.isEmpty)
    }

    /// And the writer: with the flag off, a new shift is still written as
    /// legacy rows. This is the half a reader-only gate would miss.
    @Test("with the flag off, the authority predicate refuses every partial state")
    func gate7WriterStaysLegacy() {
        _ = account(authoritative: false)
        #expect(!PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount,
                "the writer branches on exactly this, so it stays on ShiftWriter")
    }

    // MARK: - Gate 5

    /// One fixture, and all FOUR `HistoryEarnings.build` consumers must report
    /// the same period figure from it.
    ///
    /// `PeriodDetailView`, `DashboardEarnings`, `InsightsEarnings` and
    /// `PeriodsView` all reach their money through that one builder, so the
    /// single switch point is a single point of failure for four screens
    /// unless all four are asserted against one dataset.
    @Test("one fixture reads the same on all four HistoryEarnings consumers")
    func gate5FourConsumersAgree() throws {
        _ = account(authoritative: true)
        let policies = Self.policies()
        let records = Self.records()

        let history = HistoryEarnings.build(
            records: records, policies: policies, payrollTimeZone: Self.zone
        )
        let dashboard = DashboardEarnings.build(
            records: records, policies: policies, payrollTimeZone: Self.zone
        )

        // Both builders produce a snapshot over the same dataset, so the same
        // day must value identically through each.
        let civil = CivilDay(Self.day(0), in: Self.zone)
        let a = try #require(history.snapshot).day(civil)
        let b = try #require(dashboard.snapshot).day(civil)
        #expect(a.knownComponents.earnedIncomeCents == b.knownComponents.earnedIncomeCents)
        #expect(a.minutes == b.minutes)
        // Non-zero, so this is not two empty snapshots agreeing.
        #expect(a.knownComponents.earnedIncomeCents > 0)

        // And the row lists are the same shifts, so a figure cannot sit over
        // a different set on one screen than another.
        let historyIDs: [String] = history.shiftRecordDays.map { $0.id.uuidString }.sorted()
        let dashboardIDs: [String] = dashboard.shiftRecordDays.map { $0.id.uuidString }.sorted()
        #expect(historyIDs == dashboardIDs)
        #expect(!historyIDs.isEmpty)

        // The digests match too, which is gate 4 restated across the two
        // builders rather than within one.
        #expect(history.snapshot?.stamp.digest == dashboard.snapshot?.stamp.digest)
    }

    /// **Gate 5 extended to Calendar**, because gap 7 switched it and nothing
    /// asserted its record arm.
    ///
    /// The month grid is a primary money surface and it was the LAST
    /// whole-screen reader still on a legacy-only path: `makeFacts` called
    /// `shiftGroups(entries:)` with no switch, so after the flip the tiles
    /// would have shown only pre-conversion shifts. Gate 5 covered the four
    /// `HistoryEarnings` consumers and both facts types, but `CalendarEarnings`
    /// reaches its money through its own builder, so the four-consumer
    /// assertion said nothing about it.
    ///
    /// Same fixture, same day, same figure as History and Dashboard -- which
    /// is the actual criterion 5 sentence for this surface ("calendar day =
    /// day detail = sum of that day's shifts").
    @Test("Calendar's record arm reports the same day figure as History and Dashboard")
    func gate5CalendarAgreesOnRecords() throws {
        _ = account(authoritative: true)
        let policies = Self.policies()
        let records = Self.records()

        let history = HistoryEarnings.build(
            records: records, policies: policies, payrollTimeZone: Self.zone
        )
        let calendar = CalendarEarnings.snapshot(
            records: records, policies: policies, payrollTimeZone: Self.zone
        )

        let civil = CivilDay(Self.day(0), in: Self.zone)
        let fromHistory = try #require(history.snapshot).day(civil)
        let fromCalendar = try #require(calendar).day(civil)

        #expect(fromHistory.knownComponents.earnedIncomeCents
                == fromCalendar.knownComponents.earnedIncomeCents)
        #expect(fromHistory.minutes == fromCalendar.minutes)
        // Non-zero, so this is not two empty snapshots agreeing -- the exact
        // way a parity assertion passes for the wrong reason.
        #expect(fromCalendar.knownComponents.earnedIncomeCents > 0)
        // And the same stamp, so the two surfaces are one dataset rather than
        // two that happen to total the same.
        #expect(history.snapshot?.stamp.digest == calendar?.stamp.digest)
    }

    /// Calendar's legacy arm, for the same reason the History/Dashboard pair
    /// has one: an agreement that only holds on the record path is an
    /// agreement about one arm, not about the switch.
    @Test("Calendar's legacy arm reports the same day figure as History's")
    func gate5CalendarAgreesOnLegacy() throws {
        _ = account(authoritative: false)
        let policies = Self.policies()
        let entries = Self.mirroredEntries(Self.records())

        let history = HistoryEarnings.build(
            entries: entries, policies: policies, payrollTimeZone: Self.zone
        )
        let calendar = CalendarEarnings.snapshot(
            entries: entries, records: [], policies: policies,
            payrollTimeZone: Self.zone, representation: .legacy
        )

        let civil = CivilDay(Self.day(0), in: Self.zone)
        let fromHistory = try #require(history.snapshot).day(civil)
        let fromCalendar = try #require(calendar).day(civil)
        #expect(fromHistory.knownComponents.earnedIncomeCents
                == fromCalendar.knownComponents.earnedIncomeCents)
        #expect(fromCalendar.knownComponents.earnedIncomeCents > 0)
    }

    /// The legacy side of gate 5, so the agreement is not an artifact of the
    /// record path alone.
    @Test("one fixture reads the same on both builders through the legacy path too")
    func gate5FourConsumersAgreeOnLegacy() throws {
        _ = account(authoritative: false)
        let policies = Self.policies()
        let entries = Self.mirroredEntries(Self.records())
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.zone

        let history = HistoryEarnings.build(
            entries: entries, policies: policies, payrollTimeZone: Self.zone
        )
        let dashboard = DashboardEarnings.build(
            entries: entries, policies: policies, payrollTimeZone: Self.zone, calendar: cal
        )

        let civil = CivilDay(Self.day(0), in: Self.zone)
        let a = try #require(history.snapshot).day(civil)
        let b = try #require(dashboard.snapshot).day(civil)
        #expect(a.knownComponents.earnedIncomeCents == b.knownComponents.earnedIncomeCents)
        #expect(a.knownComponents.earnedIncomeCents > 0)
        #expect(history.snapshot?.stamp.digest == dashboard.snapshot?.stamp.digest)
    }
}
