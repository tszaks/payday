import Testing
import Foundation
import SwiftData
@testable import Payday

/// A fixed payroll zone, stated rather than inherited from the device.
private let payroll = TimeZone(identifier: "America/New_York")!

private func instant(_ year: Int, _ month: Int, _ d: Int, hour: Int = 17, zone: TimeZone = payroll) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: d, hour: hour))!
}

private func mondayCalendarPolicy(
    from day: CivilDay = CivilDay(year: 2025, month: 12, day: 29),
    zone: TimeZone = payroll,
    id: String = "AAAAAAAA-0000-4000-8000-000000000001"
) -> PayrollCalendarPolicy {
    PayrollCalendarPolicy(
        id: UUID(uuidString: id)!,
        effectiveFrom: day,
        workweekStartWeekday: 2,
        payrollTimeZone: zone
    )
}

@Suite("ShiftInputAdapter")
@MainActor
struct ShiftInputAdapterTests {
    @Test("a record becomes one input: hours in minutes, gratuity off the receipt, tip-out left nil")
    func adaptsOneRecord() {
        let record = ShiftRecord(
            workDate: instant(2026, 9, 28),
            shiftPeriod: .dinner,
            cashTipsCents: 5_000,
            creditTipsCents: 8_000,
            tipOutCents: nil,
            hoursWorked: 6.3833,
            receiptMetrics: ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 1_200),
            recordedAt: instant(2026, 9, 28, hour: 23)
        )

        let input = ShiftInputAdapter.input(from: record, calendars: [mondayCalendarPolicy()])

        #expect(input.id == record.id)
        #expect(input.workDay == CivilDay(year: 2026, month: 9, day: 28))
        #expect(input.period == ShiftPeriodTag.dinner)
        #expect(input.recordedAt == record.recordedAt)
        #expect(input.voluntaryCashCents == 5_000)
        #expect(input.voluntaryCreditCents == 8_000)
        #expect(input.gratuityFeesCents == 1_200)
        #expect(input.tipOutCents == nil, "nil tip-out is a different fact from zero")
        // 6.3833 h -> 383 minutes, the E1 fixture's conversion.
        #expect(input.minutesWorked == 383)
        // The adapter's non-wage components must agree with the record's own
        // generated-column twin, or the engine and the row disagree.
        #expect(input.nonWageComponents.nonWageEarningsCents == record.nonWageEarningsCents)
    }

    @Test("a tip-out of zero survives as zero, not as nil")
    func zeroTipOutIsPreserved() {
        let record = ShiftRecord(workDate: instant(2026, 9, 28), tipOutCents: 0)
        let input = ShiftInputAdapter.input(from: record, calendars: [mondayCalendarPolicy()])
        #expect(input.tipOutCents == 0)
    }

    @Test("a wage-only record adapts with zero tips and real minutes (Z1)")
    func wageOnlyRecord() {
        let record = ShiftRecord(workDate: instant(2026, 9, 28), hoursWorked: 5.0)
        let input = ShiftInputAdapter.input(from: record, calendars: [mondayCalendarPolicy()])
        #expect(input.minutesWorked == 300)
        #expect(input.voluntaryCashCents == 0)
        #expect(input.voluntaryCreditCents == 0)
        #expect(input.gratuityFeesCents == 0)
    }

    @Test("an unreadable receipt payload is reported, never repaired")
    func unreadableReceiptIsReported() {
        let readable = ShiftRecord(
            workDate: instant(2026, 9, 28),
            creditTipsCents: 5_000,
            receiptMetrics: ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 500)
        )
        let broken = ShiftRecord(workDate: instant(2026, 9, 29), creditTipsCents: 5_000)
        // The measured production shape: the server's fold copied a
        // fractional gratuity through, and `gratuityFeesCents: Int?` will
        // not decode it, so the WHOLE payload fails.
        broken.setRawReceiptPayload(Data(#"{"gratuityFeesCents":1234.6,"earningsSchemaVersion":2}"#.utf8))
        #expect(broken.receiptPayloadIsUnreadable)

        let output = ShiftInputAdapter.adapt([readable, broken], calendars: [mondayCalendarPolicy()])

        #expect(output.unreadableReceiptShiftIDs == [broken.id])
        #expect(output.inputs.count == 2)
        #expect(output.inputs[0].gratuityFeesCents == 500)
        #expect(output.inputs[1].gratuityFeesCents == 0, "an undecodable payload contributes no gratuity")
        // And the raw bytes are untouched: the server's generated column is
        // authoritative, so the device never rewrites the payload.
        #expect(broken.rawReceiptPayload != nil)
    }

    @Test("the work day comes from the frozen payroll zone, not the device's")
    func workDayUsesTheFrozenZone() {
        // 2026-09-29 00:30 in New York is still 2026-09-28 in Honolulu and
        // already 2026-09-29 in Tokyo. The policy's zone decides.
        let record = ShiftRecord(workDate: instant(2026, 9, 29, hour: 0, zone: payroll)
            .addingTimeInterval(30 * 60))

        let newYork = ShiftInputAdapter.input(from: record, calendars: [mondayCalendarPolicy()])
        let honolulu = ShiftInputAdapter.input(
            from: record,
            calendars: [mondayCalendarPolicy(zone: TimeZone(identifier: "Pacific/Honolulu")!)]
        )

        #expect(newYork.workDay == CivilDay(year: 2026, month: 9, day: 29))
        #expect(honolulu.workDay == CivilDay(year: 2026, month: 9, day: 28))
    }

    @Test("a historical shift keeps the zone of the policy in effect on its own day")
    func historicalShiftUsesTheOlderPolicysZone() {
        // The user moved from Honolulu to New York effective Mon 2026-09-28.
        // A shift worked on 2026-09-01 belongs to the Honolulu policy, so
        // its 20:30 HST punch is still September 1 and not September 2.
        let calendars = [
            mondayCalendarPolicy(
                from: CivilDay(year: 2025, month: 12, day: 29),
                zone: TimeZone(identifier: "Pacific/Honolulu")!,
                id: "AAAAAAAA-0000-4000-8000-000000000002"
            ),
            mondayCalendarPolicy(from: CivilDay(year: 2026, month: 9, day: 28)),
        ]
        let record = ShiftRecord(workDate: instant(
            2026, 9, 1, hour: 20, zone: TimeZone(identifier: "Pacific/Honolulu")!
        ).addingTimeInterval(30 * 60))

        let input = ShiftInputAdapter.input(from: record, calendars: calendars)
        #expect(input.workDay == CivilDay(year: 2026, month: 9, day: 1))
        // Under the LATEST policy's zone alone it would read as September 2,
        // which is the bug this two-step lookup exists to avoid.
        #expect(CivilDay(record.workDate, in: payroll) == CivilDay(year: 2026, month: 9, day: 2))
    }

    @Test("with no calendar policy at all the device zone is the only fallback")
    func noPolicyFallsBackToTheDevice() {
        let record = ShiftRecord(workDate: instant(2026, 9, 28, zone: .current))
        let input = ShiftInputAdapter.input(from: record, calendars: [])
        #expect(input.workDay == CivilDay(record.workDate, in: .current))
    }

    @Test("an unset shift period adapts to nil, and lunch to lunch")
    func periodTags() {
        let none = ShiftRecord(workDate: instant(2026, 9, 28))
        let lunch = ShiftRecord(workDate: instant(2026, 9, 28), shiftPeriod: .lunch)
        let calendars = [mondayCalendarPolicy()]
        #expect(ShiftInputAdapter.input(from: none, calendars: calendars).period == nil)
        #expect(ShiftInputAdapter.input(from: lunch, calendars: calendars).period == ShiftPeriodTag.lunch)
    }
}

@Suite("PaycheckInputAdapter")
@MainActor
struct PaycheckInputAdapterTests {
    /// P1's rule: the ±100c correction is a PROPOSAL. Feeding the repaired
    /// figure into the engine would make it silently agree with its own
    /// guess, and the stub would no longer be what the person entered.
    @Test("the observed tips line is carried verbatim, not reconciled")
    func observedTipsAreVerbatim() {
        let record = PaycheckRecord(
            periodStart: instant(2026, 9, 21),
            periodEnd: instant(2026, 10, 4),
            paidTipsCents: 10_000
        )
        record.regularWagesCents = 11_320
        record.overtimeWagesCents = 3_396
        record.gratuityCents = 0
        record.grossPayCents = 24_766

        // The record itself infers a 50c repair, exactly as P1 describes.
        #expect(record.reconciledPaidTipsCents == 10_050)

        let input = PaycheckInputAdapter.inputs(from: [record], payrollTimeZone: payroll)[0]
        #expect(input.paidTipsCents == 10_000, "observedPaidTips is exactly as entered")
        #expect(input.paidTipsCents != 10_050, "the proposal is never applied by the adapter")
        #expect(input.periodStart == CivilDay(year: 2026, month: 9, day: 21))
        #expect(input.periodEnd == CivilDay(year: 2026, month: 10, day: 4))
        #expect(input.regularWagesCents == 11_320)
        #expect(input.grossPayCents == 24_766)
    }
}
