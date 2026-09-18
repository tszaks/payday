import Foundation

/// Turns stored `ShiftRecord`s into the engine's `ShiftInput`s: the one
/// crossing from SwiftData into PaydayCore.
///
/// Main actor because `ShiftRecord` is a `@Model` and is not `Sendable`.
/// Everything downstream of this call is a value type, which is what lets
/// `EarningsStore` build a snapshot off the main thread.
///
/// It reads each record's receipt payload exactly ONCE. `ShiftRecord
/// .receiptMetrics` decodes JSON on every access and
/// `receiptPayloadIsUnreadable` decodes again, so the naive spelling costs
/// three decodes per shift on every rebuild.
@MainActor
enum ShiftInputAdapter {
    /// The inputs, plus the shifts whose receipt payload would not decode.
    struct Output {
        var inputs: [ShiftInput]
        /// Records with a payload present that will not decode. Their
        /// gratuity therefore reads as zero, exactly as
        /// `ShiftRecord.nonWageEarningsCents` already reads it, and the ids
        /// travel with the snapshot so Data health can name them instead of
        /// the number being quietly low. Never repaired here: the server's
        /// generated `gratuity_fees_cents` is authoritative and rewriting a
        /// decoded copy would push a zero over it.
        var unreadableReceiptShiftIDs: [UUID]
    }

    /// One input per record.
    ///
    /// `calendars` supplies the FROZEN payroll time zone each work day is a
    /// civil day in. The zone lives on the calendar policy in effect on that
    /// day, and picking the policy needs the day, so this resolves in two
    /// steps: read the day in the latest policy's zone, then re-read it in
    /// the zone of the policy in effect on that day. A zone change moves a
    /// timestamp by hours, never by more than a day, so the second read is
    /// the answer. With no policies at all (a first launch before the
    /// migration) it falls back to the device zone, the single moment the
    /// app is allowed to consult it.
    static func adapt(_ records: [ShiftRecord], calendars: [PayrollCalendarPolicy]) -> Output {
        let latestZone = calendars.last?.payrollTimeZone ?? .current
        var inputs: [ShiftInput] = []
        var unreadable: [UUID] = []
        inputs.reserveCapacity(records.count)

        for record in records {
            // One decode per record, reused for gratuity and for the
            // unreadable check.
            let metrics = record.receiptMetrics
            if metrics == nil, record.rawReceiptPayload != nil {
                unreadable.append(record.id)
            }

            let provisional = CivilDay(record.workDate, in: latestZone)
            let zone = policy(in: calendars, onOrBefore: provisional)?.payrollTimeZone ?? latestZone
            let workDay = zone == latestZone ? provisional : CivilDay(record.workDate, in: zone)

            inputs.append(ShiftInput(
                id: record.id,
                workDay: workDay,
                period: tag(for: record.shiftPeriod),
                recordedAt: record.recordedAt,
                // Voluntary by construction: `ShiftRecord` stores v2
                // earnings only, so the v1 gratuity fold already happened
                // once, at the deriver (Design 0).
                voluntaryCashCents: record.cashTipsCents,
                voluntaryCreditCents: record.creditTipsCents,
                gratuityFeesCents: metrics?.employeeGratuityFeesCents ?? 0,
                // nil and 0 stay different facts all the way in: the ledger
                // treats nil as 0 cents, and nothing else re-derives it.
                tipOutCents: record.tipOutCents,
                minutesWorked: record.hoursWorked.map(WorkedMinutes.minutes(fromHours:))
            ))
        }

        return Output(inputs: inputs, unreadableReceiptShiftIDs: unreadable)
    }

    /// The `inputs(from:calendars:)` spelling Design 2 names, for callers
    /// that do not care about unreadable payloads.
    static func inputs(from records: [ShiftRecord], calendars: [PayrollCalendarPolicy]) -> [ShiftInput] {
        adapt(records, calendars: calendars).inputs
    }

    /// One record's input, for a sheet previewing a single draft.
    static func input(from record: ShiftRecord, calendars: [PayrollCalendarPolicy]) -> ShiftInput {
        adapt([record], calendars: calendars).inputs[0]
    }

    /// The last calendar policy effective on or before `day`. Same rule as
    /// `CompensationPolicies.calendar(on:)`, which takes a whole
    /// `CompensationPolicies`; this one takes the array the adapter is given.
    private static func policy(
        in calendars: [PayrollCalendarPolicy],
        onOrBefore day: CivilDay
    ) -> PayrollCalendarPolicy? {
        calendars
            .sorted { ($0.effectiveFrom, $0.id.uuidString) < ($1.effectiveFrom, $1.id.uuidString) }
            .last { $0.effectiveFrom <= day }
    }

    private static func tag(for period: ShiftPeriod?) -> ShiftPeriodTag? {
        switch period {
        case .lunch: return .lunch
        case .dinner: return .dinner
        case nil: return nil
        }
    }
}

/// Turns stored `PaycheckRecord`s into `PaycheckInput`s.
@MainActor
enum PaycheckInputAdapter {
    static func inputs(from records: [PaycheckRecord], payrollTimeZone: TimeZone) -> [PaycheckInput] {
        records.map { record in
            PaycheckInput(
                id: record.id,
                periodStart: CivilDay(record.periodStart, in: payrollTimeZone),
                periodEnd: CivilDay(record.periodEnd, in: payrollTimeZone),
                // `paidTipsCents`, NOT `reconciledPaidTipsCents`.
                // `MetricID.observedPaidTips` is "exactly as entered"; the
                // ±100c repair is a proposal a person accepts in the entry
                // sheet, and feeding the repaired value in here would make
                // the engine quietly agree with its own correction.
                paidTipsCents: record.paidTipsCents,
                grossPayCents: record.grossPayCents,
                netPayCents: record.netPayCents,
                regularWagesCents: record.regularWagesCents,
                overtimeWagesCents: record.overtimeWagesCents,
                gratuityCents: record.gratuityCents,
                taxesCents: record.taxesCents
            )
        }
    }
}
