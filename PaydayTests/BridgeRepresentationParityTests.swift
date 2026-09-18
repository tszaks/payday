import Foundation
import Testing
@testable import Payday

/// PR 2, reader-switch cut: the legacy money bridges are generic over
/// `LegacyShiftRow`, and widening them changed nothing.
///
/// `LegacyLedgerBridge` and `LegacySnapshotBridge` were the last two links
/// still bound to `TipEntry`. Everything they call — `ShiftDetails.resolve`,
/// `TipBreakdown.total`, `ShiftDays.groupedByShift` — was already generic, so
/// this is a signature-only change. Six readers funnel through these bridges
/// (Calendar, Dashboard, Insights, History, ShiftDraftPreview and
/// PaydayPushScheduler), which is why widening them once is its own PR rather
/// than repeated inside six reader switches.
///
/// What is asserted here is the claim a signature-only change actually makes:
/// for the SAME field values, the bridge produces the same `ShiftInput`
/// whichever row type carries them. That is narrower than "conversion is
/// correct" — the migration owns that — and it is the part that could break
/// if generic dispatch ever resolved differently per type.
@Suite("Bridge representation parity")
struct BridgeRepresentationParityTests {

    private static let zone = TimeZone(identifier: "America/New_York")!
    private static let day = Date(timeIntervalSince1970: 1_756_000_000)

    private static func record() -> ShiftRecord {
        var metrics = ShiftReceiptMetrics()
        metrics.gratuityFeesCents = 2_500
        metrics.netSalesCents = 88_000
        metrics.earningsSchemaVersion = 2
        return ShiftRecord(
            workDate: day,
            shiftPeriod: .dinner,
            cashTipsCents: 4_200,
            creditTipsCents: 7_350,
            tipOutCents: 1_100,
            salesCents: 88_000,
            hoursWorked: 6.5,
            clockIn: day.addingTimeInterval(43_200),
            clockOut: day.addingTimeInterval(66_600),
            serverCount: 3,
            receiptMetrics: metrics,
            recordedAt: day.addingTimeInterval(3_600)
        )
    }

    /// `TipEntry` rows carrying exactly the field values the projection
    /// produces, so the only difference between the two inputs is the TYPE.
    /// Built from the projected rows rather than hand-written, because
    /// hand-written values would be testing my transcription rather than the
    /// bridge.
    private static func mirroredEntries(of projected: [ProjectedShiftRow]) -> [TipEntry] {
        projected.map { row in
            TipEntry(
                id: row.id,
                date: row.date,
                amountCents: row.amountCents,
                kind: row.kind,
                note: row.note,
                recordedAt: row.recordedAt,
                hoursWorked: row.hoursWorked,
                tipOutCents: row.tipOutCents,
                salesCents: row.salesCents,
                shiftPeriod: row.shiftPeriod,
                shiftID: row.shiftID,
                clockIn: row.clockIn,
                clockOut: row.clockOut,
                serverCount: row.serverCount,
                receiptMetrics: row.receiptMetrics
            )
        }
    }

    @Test("the bridge produces an identical ShiftInput from either row type")
    func identicalShiftInputFromEitherRowType() throws {
        let shift = Self.record()
        let projected = ShiftProjection.rows(for: shift)
        let entries = Self.mirroredEntries(of: projected)

        let fromProjection = try #require(LegacySnapshotBridge.shiftInput(
            for: (day: Self.day, shiftID: shift.id, items: projected),
            payrollTimeZone: Self.zone
        ))
        let fromLegacy = try #require(LegacySnapshotBridge.shiftInput(
            for: (day: Self.day, shiftID: shift.id, items: entries),
            payrollTimeZone: Self.zone
        ))

        // Every money field, named one by one rather than compared whole, so
        // a failure says WHICH figure diverged.
        #expect(fromProjection.voluntaryCashCents == fromLegacy.voluntaryCashCents)
        #expect(fromProjection.voluntaryCreditCents == fromLegacy.voluntaryCreditCents)
        #expect(fromProjection.gratuityFeesCents == fromLegacy.gratuityFeesCents)
        #expect(fromProjection.tipOutCents == fromLegacy.tipOutCents)
        #expect(fromProjection.minutesWorked == fromLegacy.minutesWorked)
        #expect(fromProjection.workDay == fromLegacy.workDay)
        #expect(fromProjection.period == fromLegacy.period)
        #expect(fromProjection.id == fromLegacy.id)

        // And the values are the real ones, not two sets of zeros — the
        // failure mode an earlier parity test in this project actually had.
        #expect(fromProjection.voluntaryCashCents == 4_200)
        #expect(fromProjection.voluntaryCreditCents == 7_350)
        #expect(fromProjection.gratuityFeesCents == 2_500)
        #expect(fromProjection.tipOutCents == 1_100)
        #expect(fromProjection.minutesWorked == 390)
    }

    /// The same equivalence one level up, through the whole snapshot, so the
    /// valued cents agree and not merely the inputs.
    @Test("a snapshot values either row type to the same cents")
    func snapshotValuesEitherRowTypeIdentically() throws {
        let shift = Self.record()
        let projected = ShiftProjection.rows(for: shift)
        let entries = Self.mirroredEntries(of: projected)

        let policies = CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("bridgeparity/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 283,
                provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("bridgeparity/calendar"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: Self.zone
            )]
        )

        let a = try #require(LegacySnapshotBridge.snapshot(
            entries: projected, policies: policies, payrollTimeZone: Self.zone, asOf: .distantFuture))
        let b = try #require(LegacySnapshotBridge.snapshot(
            entries: entries, policies: policies, payrollTimeZone: Self.zone, asOf: .distantFuture))

        let dayRange = CivilDay(Self.day, in: Self.zone)
        let ra = a.day(dayRange)
        let rb = b.day(dayRange)
        #expect(ra.knownComponents.earnedIncomeCents == rb.knownComponents.earnedIncomeCents)
        #expect(ra.minutes == rb.minutes)
        // Non-zero, so the equality above is not two empty snapshots.
        #expect(ra.knownComponents.earnedIncomeCents > 0)
        #expect(ra.minutes == 390)
    }
}
