import Testing
import Foundation
import SwiftData
@testable import Payday

/// A gregorian calendar in the payroll zone.
private func logCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
    logCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func logShiftID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}

/// $10.00/hr confirmed since the distant past, workweek starting SUNDAY
/// (weekday 1). Sunday-start is what puts five 10-hour days Sun–Thu into ONE
/// 50-hour week, so the threshold is already crossed before the draft is typed.
private func sundayStartPolicies(rateCents: Int = 1_000) -> CompensationPolicies {
    CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("log/rate/\(rateCents)"),
            effectiveFrom: .distantPast,
            hourlyRateCents: rateCents,
            provenance: .confirmed
        )],
        calendars: [PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("log/calendar/1"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 1,
            payrollTimeZone: PaydayTestZone.payroll
        )]
    )
}

/// Sun 2026-08-30 through Thu 2026-09-03: 10h, 10h, 10h, **6h**, 10h, all
/// tagged LUNCH, $10.00 of credit tips each. Thirty-six hours sit before the
/// draft's Wednesday slot and fifty-six in the whole Sunday-start workweek, so
/// the 40-hour threshold falls INSIDE the draft.
///
/// Three properties of this shape are load-bearing, and each one was measured
/// rather than assumed:
///
/// 1. **The week is in the PAST.** `ShiftCommands.create` clamps a shift's
///    date with `min(date, .now)` because a shift can never be logged for the
///    future, and `ShiftDraftPreview.draftInput` restates that clamp so the
///    preview values what the save will write. A fixture dated next month
///    collapses BOTH sides onto today, into an empty workweek — the first cut
///    of this suite read 22883 == 22883 with straight-time wages and looked
///    green.
/// 2. **The existing shifts are LUNCH and the draft is DINNER.** The ledger
///    orders a workweek by (work day, period rank, recordedAt, id) and lunch
///    ranks before dinner, so the draft lands AFTER Wednesday's own shift and
///    still has Thursday after it. Dropping the tags sorts the draft first
///    (untagged ranks last), puts it entirely under the threshold, and the
///    test stops measuring overtime.
/// 3. **Wednesday is 6h, not 10h.** At 10h the cumulative reaches exactly 2400
///    minutes before the draft and the draft is entirely overtime. At 6h the
///    threshold cuts the draft in half, which is the case a per-shift
///    calculation cannot reproduce at all.
private func weekOfFiftyHours() -> [ShiftRecord] {
    [
        (2026, 8, 30, 1, 10.0), (2026, 8, 31, 2, 10.0), (2026, 9, 1, 3, 10.0),
        (2026, 9, 2, 4, 6.0), (2026, 9, 3, 5, 10.0)
    ].map { year, month, day, index, hours in
        ShiftRecord(
            id: logShiftID(index),
            workDate: at(year, month, day),
            shiftPeriod: .lunch,
            creditTipsCents: 1_000,
            hoursWorked: hours,
            recordedAt: at(year, month, day, hour: 23)
        )
    }
}

/// The draft: Wednesday 2026-09-02's DINNER shift, mid-week, straddling the
/// 40-hour threshold with Thursday still to come after it.
/// Mid-week matters — the ledger allocates a workweek in canonical order, so a
/// shift inserted between Tuesday and Wednesday takes part of the overtime the
/// later shifts would otherwise have carried, and the cumulative rounding
/// re-slices around it. A draft appended at the END of the week could not see
/// that and would pass a weaker test.
private enum Draft {
    static let date = at(2026, 9, 2)
    static let recordedAt = at(2026, 9, 2, hour: 23, minute: 30)
    static let cashCents = 10_000
    static let creditCents = 8_000
    static let tipOutCents = 1_500
    /// 6h 23m, the hours label the sheet's own comments use, and deliberately
    /// not a whole number: 383 minutes is where a rate that rounds and a rate
    /// that truncates disagree.
    static let hoursWorked = 383.0 / 60
}

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int) -> Date {
    logCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@MainActor
private func makeContext() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: ShiftRecord.self, configurations: config)
    return ModelContext(container)
}

/// The draft the sheet previews, built as the `ShiftInput` the save writes —
/// the only shape `ShiftDraftPreview` speaks since the flip. A NEW shift, so
/// `normalizeEarnings` is false: `ShiftCommands.create` stores the fields raw.
@MainActor
private func standardDraftInput(
    policies: CompensationPolicies = sundayStartPolicies()
) -> ShiftInput? {
    ShiftDraftPreview.draftInput(
        date: Draft.date,
        cashCents: Draft.cashCents,
        creditCents: Draft.creditCents,
        recordedAt: Draft.recordedAt,
        shiftID: logShiftID(99),
        hoursWorked: Draft.hoursWorked,
        tipOutCents: Draft.tipOutCents,
        salesCents: 0,
        shiftPeriod: .dinner,
        clockIn: nil,
        clockOut: nil,
        serverCount: nil,
        receiptMetrics: nil,
        normalizeEarnings: false,
        policies: policies
    )
}

/// The facts the sheet renders for a draft, over a record history. `draft` is
/// the caller's own `ShiftInput` — pass nil for the untouched-sheet case.
@MainActor
private func draftFacts(
    records: [ShiftRecord] = weekOfFiftyHours(),
    policies: CompensationPolicies = sundayStartPolicies(),
    draft: ShiftInput?,
    hoursWorked: Double? = Draft.hoursWorked,
    shiftID: UUID = logShiftID(99),
    windowed: Bool = true
) -> LogShiftFacts {
    let snapshot = ShiftDraftPreview.snapshot(
        draft: draft,
        records: records,
        policies: policies,
        payrollTimeZone: PaydayTestZone.payroll,
        windowed: windowed
    )
    return LogShiftFacts(
        snapshot: snapshot,
        draftID: shiftID,
        date: Draft.date,
        shiftPeriod: .dinner,
        clockIn: nil,
        clockOut: nil,
        hoursWorked: hoursWorked,
        calendar: logCalendar(),
        now: Draft.recordedAt
    )
}

/// The common case: the standard draft's facts.
@MainActor
private func draftFacts(
    records: [ShiftRecord] = weekOfFiftyHours(),
    policies: CompensationPolicies = sundayStartPolicies(),
    hoursWorked: Double? = Draft.hoursWorked,
    shiftID: UUID = logShiftID(99),
    windowed: Bool = true
) -> LogShiftFacts {
    draftFacts(
        records: records,
        policies: policies,
        draft: standardDraftInput(policies: policies),
        hoursWorked: hoursWorked,
        shiftID: shiftID,
        windowed: windowed
    )
}

/// The saved-history snapshot, built the way `DashboardEarnings` builds it —
/// the adapter is the single boundary now that the bridge is gone.
@MainActor
private func savedSnapshot(
    records: [ShiftRecord],
    policies: CompensationPolicies,
    asOf: Date
) -> EarningsSnapshot? {
    let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
    return try? EarningsSnapshot.build(EarningsInputs(
        shifts: adapted.inputs,
        rates: policies.rates,
        calendars: policies.calendars,
        asOf: CivilDay(asOf, in: PaydayTestZone.payroll),
        unreadableReceiptShiftIDs: adapted.unreadableReceiptShiftIDs
    ))
}

/// Definition of Done #5, on the one screen where a person sees the same shift
/// valued twice within a second: **the number the Log Shift header shows
/// before saving is the number the shift's own row shows after saving.**
///
/// The header used to be
/// `WageEstimate.shiftTotalCents(...) + separatedGratuityFeesCents`, which is
/// `cash + credit − tipOut + roundCents(rate × hours)`. Wave 0 had already
/// moved `ShiftDayRow` onto the ledger, so the disagreement below was live:
/// the header quoted straight time and the row an hour later quoted the
/// workweek allocation, on a week the person had already taken over forty
/// hours.
@Suite("Log Shift: the pre-save header equals the saved row")
@MainActor
struct LogShiftPreSaveParityTests {
    @Test("the drafted total equals the saved shift's own row, to the cent, mid-week in an overtime week")
    func draftTotalEqualsSavedRow() throws {
        let history = weekOfFiftyHours()
        let policies = sundayStartPolicies()

        // BEFORE the save: what the header renders.
        let facts = draftFacts(records: history, policies: policies)
        let headerCents = try #require(facts.total.cents)

        // THE SAVE, through the real writer, into a real context.
        let context = try makeContext()
        let saved = try ShiftCommands.create(
            in: context,
            workDate: Draft.date,
            shiftPeriod: .dinner,
            cashTipsCents: Draft.cashCents,
            creditTipsCents: Draft.creditCents,
            tipOutCents: Draft.tipOutCents,
            hoursWorked: Draft.hoursWorked,
            recordedAt: Draft.recordedAt
        )

        // AFTER the save: what `ShiftDayRow` renders on Dashboard, off the
        // adapted snapshot of the whole history including the new record.
        let afterSnapshot = try #require(savedSnapshot(
            records: history + [saved],
            policies: policies,
            asOf: at(2026, 9, 10)
        ))
        let row = ShiftDayRowFacts(
            snapshot: afterSnapshot,
            shiftID: saved.id,
            day: Draft.date,
            period: .dinner,
            dayHasMultipleShifts: true
        )
        let rowCents = try #require(row.amount.cents)

        #expect(headerCents == rowCents)
        // Both labels come from the same constructor over the same
        // completeness, so the words agree too, not just the digits.
        #expect(facts.total.label == row.amount.label)

        // The measured numbers, stated so a regression names itself. Cash
        // $100 + credit $80 − tip-out $15 = $165.00 of non-wage earnings, plus
        // 383 minutes the THRESHOLD CUT IN HALF: 240 of them at straight time
        // ($40.00) and 143 at time and a half ($35.75), $75.75 of wages.
        // MEASURED, not derived here — no per-shift formula produces this
        // split, which is the point.
        #expect(headerCents == 24_075)

        // What the old header said: the same tips plus all 383 minutes at
        // STRAIGHT time, $63.83. $11.92 short, on a real shift, in the largest
        // type on the screen, a second before the row underneath it said
        // $240.75.
        let legacyHeaderCents = WageEstimate.shiftTotalCents(
            cashCents: Draft.cashCents,
            creditCents: Draft.creditCents,
            tipOutCents: Draft.tipOutCents,
            wageCentsPerHour: 1_000,
            hoursWorked: Draft.hoursWorked
        )
        #expect(legacyHeaderCents == 22_883)
        #expect(rowCents - legacyHeaderCents == 1_192)
        #expect(legacyHeaderCents != rowCents, "the superseded straight-time header")
    }

    @Test("the preview's draft input is the same input the save produces, field for field")
    func previewInputMatchesTheSavedInput() throws {
        let policies = sundayStartPolicies()
        let context = try makeContext()
        let saved = try ShiftCommands.create(
            in: context,
            workDate: Draft.date,
            shiftPeriod: .dinner,
            cashTipsCents: Draft.cashCents,
            creditTipsCents: Draft.creditCents,
            tipOutCents: Draft.tipOutCents,
            hoursWorked: Draft.hoursWorked,
            recordedAt: Draft.recordedAt
        )
        let savedInput = try #require(ShiftInputAdapter.input(
            from: saved,
            calendars: policies.calendars
        ))
        var previewInput = try #require(standardDraftInput(policies: policies))

        // The id is the ONE field that legitimately differs: the save mints
        // its own. Everything the ledger values a shift on has to be equal, so
        // aligning the id and comparing whole is the check — a new field on
        // `ShiftInput` is then covered without this test being edited.
        previewInput.id = savedInput.id
        #expect(previewInput == savedInput)
    }
}

@Suite("Log Shift adapter: the four rules")
@MainActor
struct LogShiftFactsTests {
    @Test("no snapshot renders no currency and no rate, never $0.00")
    func unbackedRendersNoCurrency() {
        let facts = LogShiftFacts(
            snapshot: nil,
            draftID: logShiftID(99),
            date: Draft.date,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            hoursWorked: Draft.hoursWorked,
            calendar: logCalendar(),
            now: Draft.recordedAt
        )
        #expect(facts.isUnbacked)
        #expect(facts.total.isUnavailable)
        #expect(facts.total.text == nil)
        #expect(facts.total.cents == nil)
        // Rule 4's sharp edge, one layer down: no "$0/hr" under a headline
        // that has no amount.
        #expect(facts.hourlyRateText == nil)
        // The hours caption is presentation and survives — it is a duration,
        // not a currency figure — but it carries no wages clause.
        #expect(facts.hoursCaption == "6h 23m")
    }

    @Test("a draft with no hours logged is headed 'Known so far', never 'Total'")
    func partialDraftIsNeverATotal() throws {
        let draft = ShiftDraftPreview.draftInput(
            date: Draft.date,
            cashCents: Draft.cashCents,
            creditCents: Draft.creditCents,
            recordedAt: Draft.recordedAt,
            shiftID: logShiftID(99),
            hoursWorked: nil,
            tipOutCents: 0,
            salesCents: 0,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil,
            receiptMetrics: nil,
            normalizeEarnings: false,
            policies: sundayStartPolicies()
        )
        let facts = draftFacts(draft: draft, hoursWorked: nil)

        #expect(facts.total.label == "Known so far")
        #expect(facts.total.mayBeCalledATotal == false)
        #expect(facts.total.caption == "wages missing for 1 shift")
        // The figure itself is the tips, honestly labelled: $180.00, no wage.
        #expect(facts.total.cents == 18_000)
        #expect(facts.hoursCaption == nil)
        #expect(facts.includesNonTipIncome == false)
    }

    @Test("a complete draft with a tip-out reads 'You kept', with the wages in the caption")
    func completeDraftWithTipOut() throws {
        let facts = draftFacts()
        #expect(facts.total.label == "You kept")
        #expect(facts.total.caption == nil)
        #expect(facts.includesNonTipIncome == true)
        // $75.75 of wages for 383 minutes, 240 regular and 143 overtime — the
        // caption and the header are now one number's parts. The old caption
        // was base rate only and read "$63.83 wages" under a $228.83 header,
        // and neither figure was the one the saved row would show.
        #expect(facts.hoursCaption == "6h 23m · $75.75 wages")
    }

    @Test("an assumed rate carries its caption instead of reading like a fact")
    func assumedRateCarriesItsCaption() throws {
        let assumed = CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("log/rate/assumed"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 1_000,
                provenance: .assumedFromLegacySetting
            )],
            calendars: sundayStartPolicies().calendars
        )
        let facts = draftFacts(policies: assumed)
        #expect(facts.total.caption == "Wages estimated from your current rate")
    }

    @Test("the $/hr line is the engine's hourlyRate, not the view's Double division")
    func hourlyRateIsTheEnginesRate() throws {
        let facts = draftFacts()
        // MetricID.hourlyRate: coveredComponents.earnedIncome × 60 ÷ minutes,
        // integer half-up. 24075 × 60 ÷ 383 = 3771.5… → 3772c = "$38/hr".
        #expect(facts.hourlyRateText == "$38/hr")

        // What the view used to print: Double(total) / hours, over the
        // straight-time total it also held. A different number from a
        // different basis, rounded a different way.
        let legacyTotal = WageEstimate.shiftTotalCents(
            cashCents: Draft.cashCents,
            creditCents: Draft.creditCents,
            tipOutCents: Draft.tipOutCents,
            wageCentsPerHour: 1_000,
            hoursWorked: Draft.hoursWorked
        )
        let legacyRate = Int((Double(legacyTotal) / Draft.hoursWorked).rounded())
        #expect(legacyRate == 3_585)
        #expect(Money.wholeDollarString(fromCents: legacyRate) == "$36")
    }

    @Test("the draft's minutes are the engine's minutes, so the caption and the wage describe one shift")
    func draftMinutesAreTheEngineMinutes() throws {
        let snapshot = try #require(ShiftDraftPreview.snapshot(
            draft: standardDraftInput(),
            records: weekOfFiftyHours(),
            policies: sundayStartPolicies(),
            payrollTimeZone: PaydayTestZone.payroll
        ))
        let valuation = try #require(snapshot.valuation(logShiftID(99)))
        #expect(draftFacts().draftMinutes == valuation.minutesWorked)
        #expect(valuation.minutesWorked == 383)
    }

    @Test("the belief line's tip-out is the ledger's, and drops entirely without a valuation")
    func beliefLineReadsTheLedgersTipOut() throws {
        #expect(draftFacts().beliefLine == "Today · Dinner · $15 tipped out")

        let unbacked = LogShiftFacts(
            snapshot: nil,
            draftID: logShiftID(99),
            date: Draft.date,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            hoursWorked: Draft.hoursWorked,
            calendar: logCalendar(),
            now: Draft.recordedAt
        )
        #expect(unbacked.beliefLine == "Today · Dinner")
    }

    @Test("editing a shift substitutes it rather than appending a second copy of it")
    func editingSubstitutesRatherThanAppends() throws {
        // The trap: substitute under the wrong id and the shift being edited
        // exists TWICE in its own workweek, which doubles the week's hours and
        // pushes everything after it into overtime while the person was only
        // changing a tip amount.
        let history = weekOfFiftyHours()
        let editedID = logShiftID(3)   // the stored Tuesday shift
        let draft = ShiftDraftPreview.draftInput(
            date: at(2026, 9, 1),
            cashCents: 0,
            creditCents: 2_000,        // was 1000: the one edit
            recordedAt: at(2026, 9, 1, hour: 23),
            shiftID: editedID,
            hoursWorked: 10,
            tipOutCents: 0,
            salesCents: 0,
            shiftPeriod: .lunch,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil,
            receiptMetrics: nil,
            normalizeEarnings: true,   // an edit: commitLiveEdit's fold runs
            policies: sundayStartPolicies()
        )
        let snapshot = try #require(ShiftDraftPreview.snapshot(
            draft: draft,
            records: history,
            policies: sundayStartPolicies(),
            payrollTimeZone: PaydayTestZone.payroll
        ))

        // Five shifts, not six.
        #expect(snapshot.shifts.count == 5)
        // The week is still 46 hours, so still exactly 6 overtime hours:
        // 40 × $10 + 6 × $15 = $490.00 of wages. Append instead of substitute
        // and it becomes 56 hours and $640.00, from editing one tip amount.
        let week = snapshot.range(DayRange(
            start: CivilDay(year: 2026, month: 8, day: 30),
            end: CivilDay(year: 2026, month: 9, day: 5)
        ), asOf: CivilDay.distantFuture)
        #expect(week.knownComponents.wagesCents == 49_000)
        // And the edit landed: $20.00 of credit on that shift, not $10.00.
        let edited = try #require(snapshot.valuation(editedID))
        #expect(edited.components.voluntaryCreditCents == 2_000)
    }

    @Test("the facts carry the stamp of the dataset they were computed from")
    func factsCarryTheirStamp() throws {
        let facts = draftFacts()
        let stamp = try #require(facts.stamp)
        // Rule 3: the stamp, not a hand-written Key. A second build over the
        // same inputs is the same dataset by digest, which is what makes two
        // surfaces' disagreement diffable.
        #expect(facts.isUnbacked == false)
        #expect(stamp.digest == draftFacts().stamp?.digest)
        // And a different draft is a different dataset.
        let otherDraft = ShiftDraftPreview.draftInput(
            date: Draft.date,
            cashCents: Draft.cashCents + 100,
            creditCents: Draft.creditCents,
            recordedAt: Draft.recordedAt,
            shiftID: logShiftID(99),
            hoursWorked: Draft.hoursWorked,
            tipOutCents: Draft.tipOutCents,
            salesCents: 0,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil,
            receiptMetrics: nil,
            normalizeEarnings: false,
            policies: sundayStartPolicies()
        )
        #expect(draftFacts(draft: otherDraft).stamp?.digest != stamp.digest)
    }
}

/// The preview runs on every keystroke, so its cost is an interactive budget
/// and not a render-once one. Same wall-clock caveat as
/// `RenderFactsPerformanceTests`: this guards against an algorithmic
/// regression, not against a busy machine.
@Suite("Log Shift preview stays inside a per-keystroke budget")
@MainActor
struct LogShiftPreviewPerformanceTests {
    static let budgetScale: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 4

    @Test("one preview over a 10,000-shift history stays inside a per-keystroke budget")
    func previewOverATenThousandShiftHistory() throws {
        let calendar = logCalendar()
        let start = try #require(calendar.date(from: DateComponents(year: 2016, month: 1, day: 1)))
        let records = (0..<10_000).map { index in
            ShiftRecord(
                id: logShiftID(1_000 + index),
                workDate: calendar.date(byAdding: .day, value: index, to: start) ?? start,
                cashTipsCents: index.isMultiple(of: 2) ? 4_000 + index : 0,
                creditTipsCents: index.isMultiple(of: 2) ? 0 : 4_000 + index,
                hoursWorked: index.isMultiple(of: 2) ? 8 : nil,
                recordedAt: calendar.date(byAdding: .day, value: index, to: start)
            )
        }

        let began = Date()
        let facts = draftFacts(records: records)
        let elapsed = Date().timeIntervalSince(began)

        #expect(facts.total.cents != nil)
        // 0.05s is deliberately an order of magnitude below the 0.5s the
        // render-once facts get: this path runs per KEYSTROKE, and SwiftUI
        // evaluates a body more than once per change. What is left is the O(n)
        // `ShiftInputAdapter` pass over every record, which runs before the
        // window can be applied because a record's work day is already
        // resolved. A regression here means the window stopped working, not
        // that the machine is busy.
        #expect(
            elapsed < 0.05 * Self.budgetScale,
            "Log Shift preview took \(elapsed) seconds over \(records.count) records against a 0.05s budget scaled x\(Self.budgetScale)"
        )
    }

    @Test("the reveal's whole-history snapshot stays inside a per-save budget")
    func revealSnapshotOverATenThousandShiftHistory() throws {
        // `LogTipSheet.revealHistorySnapshot()` deliberately does NOT take the
        // workweek window: the reveal compares tonight against every prior
        // shift, and an all-time record lives outside this week almost by
        // definition, so a window would leave most of the comparison set on
        // `StatsEngine`'s scalar fallback. It is affordable because it runs
        // ONCE PER SAVE rather than per keystroke — a budget two orders of
        // magnitude looser than the one above, and it is bounded here so a
        // future change cannot quietly move this cost onto a keystroke.
        let calendar = logCalendar()
        let start = try #require(calendar.date(from: DateComponents(year: 2016, month: 1, day: 1)))
        let records = (0..<10_000).map { index in
            ShiftRecord(
                id: logShiftID(1_000 + index),
                workDate: calendar.date(byAdding: .day, value: index, to: start) ?? start,
                cashTipsCents: index.isMultiple(of: 2) ? 4_000 + index : 0,
                creditTipsCents: index.isMultiple(of: 2) ? 0 : 4_000 + index,
                hoursWorked: index.isMultiple(of: 2) ? 8 : nil,
                recordedAt: calendar.date(byAdding: .day, value: index, to: start)
            )
        }

        let began = Date()
        let snapshot = ShiftDraftPreview.snapshot(
            draft: standardDraftInput(),
            records: records,
            policies: sundayStartPolicies(),
            payrollTimeZone: PaydayTestZone.payroll,
            windowed: false
        )
        // The dictionary `StatsEngine` is seeded with, so the budget covers
        // everything the save path actually does, not just the ledger pass.
        let valued = snapshot.map { snap in
            Dictionary(
                snap.shifts.map { ($0.id, $0.components.earnedIncomeCents) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let elapsed = Date().timeIntervalSince(began)

        #expect(valued?.count == 10_001)
        #expect(
            elapsed < 0.6 * Self.budgetScale,
            "the reveal's whole-history snapshot took \(elapsed) seconds over \(records.count) records against a 0.6s budget scaled x\(Self.budgetScale)"
        )
    }
}

/// The preview feeds the ledger only the draft's own WORKWEEK, because it runs
/// on every keystroke and the whole history measured at 0.245s. That is only
/// safe if it changes no answer, so this suite is the measurement rather than
/// the argument.
@Suite("The workweek window changes no figure")
@MainActor
struct LogShiftPreviewWindowTests {
    @Test("the windowed preview and the whole-history preview give the identical figure")
    func windowedEqualsWholeHistory() throws {
        // Four years of shifts BEFORE the fixture week, so the window is
        // throwing away 1,500 records rather than none. Deliberately not
        // overlapping it: the first cut of this test ran the noise from
        // 2024-01-01 for 1,500 consecutive days, which reached into September
        // 2026 and added nine hours to the fixture week itself. The two sides
        // still agreed (26075 == 26075, which is the claim), but the figure
        // was no longer the one the parity suite measures, and a test whose
        // fixture leaks into another suite's week is a test that will disagree
        // with it later for no reason anyone can see.
        let calendar = logCalendar()
        let anchor = try #require(calendar.date(from: DateComponents(year: 2022, month: 1, day: 1)))
        let noise = (0..<1_500).map { index in
            ShiftRecord(
                id: logShiftID(5_000 + index),
                workDate: calendar.date(byAdding: .day, value: index, to: anchor) ?? anchor,
                shiftPeriod: .dinner,
                creditTipsCents: 3_000 + index,
                hoursWorked: 9,
                recordedAt: calendar.date(byAdding: .day, value: index, to: anchor)
            )
        }
        let history = weekOfFiftyHours() + noise

        let windowed = draftFacts(records: history, windowed: true)
        let whole = draftFacts(records: history, windowed: false)

        #expect(windowed.total.cents == whole.total.cents)
        #expect(windowed.total.label == whole.total.label)
        #expect(windowed.total.caption == whole.total.caption)
        #expect(windowed.hourlyRateText == whole.hourlyRateText)
        #expect(windowed.hoursCaption == whole.hoursCaption)
        #expect(windowed.draftMinutes == whole.draftMinutes)
        #expect(windowed.includesNonTipIncome == whole.includesNonTipIncome)
        // The noise records sit on their own days, so the fixture week's own
        // allocation is unchanged and the figure is still the measured one.
        #expect(windowed.total.cents == 24_075)
        // The stamps DO differ, and that is correct rather than a defect: they
        // are digests of different input sets. The claim being pinned is that
        // the draft's own figure is a function of its workweek, not that the
        // two snapshots are the same dataset.
        #expect(windowed.stamp?.digest != whole.stamp?.digest)
    }

    @Test("the window is the calendar policy's workweek, effective-dated")
    func windowFollowsTheEffectiveDatedPolicy() throws {
        let wednesday = CivilDay(year: 2026, month: 9, day: 2)
        // Sunday-start: Sun 8/30 through Sat 9/5.
        let sunday = try #require(ShiftDraftPreview.workweek(containing: wednesday, policies: sundayStartPolicies()))
        #expect(sunday.start == CivilDay(year: 2026, month: 8, day: 30))
        #expect(sunday.end == CivilDay(year: 2026, month: 9, day: 5))

        // Monday-start: Mon 8/31 through Sun 9/6. A different week for the same
        // day, which is why the weekday can never be a per-screen scalar.
        let mondayStart = CompensationPolicies(
            rates: sundayStartPolicies().rates,
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("log/calendar/2"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.payroll
            )]
        )
        let monday = try #require(ShiftDraftPreview.workweek(containing: wednesday, policies: mondayStart))
        #expect(monday.start == CivilDay(year: 2026, month: 8, day: 31))
        #expect(monday.end == CivilDay(year: 2026, month: 9, day: 6))
    }

    @Test("no calendar policy means no window, and the engine says so rather than guessing")
    func noCalendarPolicyMeansNoWindow() throws {
        let rateOnly = CompensationPolicies(rates: sundayStartPolicies().rates, calendars: [])
        #expect(ShiftDraftPreview.workweek(containing: CivilDay(year: 2026, month: 9, day: 2), policies: rateOnly) == nil)

        // And the figure it produces is the honest one: no workweek to
        // allocate into, so no wage — never a wage invented from a default.
        let facts = draftFacts(policies: rateOnly)
        #expect(facts.total.cents == 16_500)
        #expect(facts.hoursCaption == "6h 23m")
    }
}

/// The P0 wave 1 review found by execution: a shift that carries HOURS but no
/// money is a real persisted shape, and the preview refused it.
///
/// `ShiftCommands.create` saves a wage-only shift fine — hours alone are
/// `hasSomethingToSave` — and the record sits on disk holding every
/// shift-level detail at zero cents. The preview's substance rule now matches
/// the save's: hours, punches or receipt metrics all make a draft worth
/// valuing. Before that match the sheet's whole preview snapshot was nil and
/// its header rendered the unavailable placeholder over a shift Dashboard was
/// showing at $100.00.
@Suite("Log Shift: a shift with hours and no money still has a figure")
@MainActor
struct LogShiftZeroMoneyDraftTests {
    /// Wed 2026-09-02, ten hours, no tips: what the save writes for a
    /// wage-only shift, in the only stored shape since the flip.
    private static let savedID = logShiftID(7)

    private static func savedShift() -> [ShiftRecord] {
        [ShiftRecord(
            id: savedID,
            workDate: at(2026, 9, 2),
            shiftPeriod: .dinner,
            hoursWorked: 10,
            recordedAt: at(2026, 9, 2, hour: 23)
        )]
    }

    /// The draft the Edit sheet holds for that shift: both money fields at
    /// zero, the hours still there.
    @MainActor
    private static func zeroMoneyDraft() -> ShiftInput? {
        ShiftDraftPreview.draftInput(
            date: at(2026, 9, 2),
            cashCents: 0,
            creditCents: 0,
            recordedAt: at(2026, 9, 2, hour: 23),
            shiftID: savedID,
            hoursWorked: 10,
            tipOutCents: 0,
            salesCents: 0,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil,
            receiptMetrics: nil,
            normalizeEarnings: true,   // an edit: commitLiveEdit's fold runs
            policies: sundayStartPolicies()
        )
    }

    @Test("a draft carrying only hours still has substance: the preview does not refuse it")
    func hoursOnlyDraftStillHasAnInput() throws {
        let input = try #require(Self.zeroMoneyDraft())
        #expect(input.minutesWorked == 600)
        #expect(input.voluntaryCashCents == 0)
        #expect(input.voluntaryCreditCents == 0)
        #expect(input.id == Self.savedID)
        #expect(input.period == .dinner)
    }

    @Test("the Edit sheet's header equals the Dashboard row for the SAME saved shift at $0 of tips")
    func editHeaderEqualsDashboardRowAtZeroTips() throws {
        let history = Self.savedShift()
        let policies = sundayStartPolicies()

        // Dashboard's own row, off the adapter's snapshot — the surface that
        // was already right.
        let historySnapshot = try #require(savedSnapshot(
            records: history,
            policies: policies,
            asOf: at(2026, 9, 10)
        ))
        let row = ShiftDayRowFacts(
            snapshot: historySnapshot,
            shiftID: Self.savedID,
            day: at(2026, 9, 2),
            period: .dinner,
            dayHasMultipleShifts: false
        )

        // The Edit sheet, over the same history, with the same shift as its
        // draft.
        let facts = draftFacts(
            records: history,
            policies: policies,
            draft: Self.zeroMoneyDraft(),
            hoursWorked: 10,
            shiftID: Self.savedID
        )

        // Ten hours at $10.00/hr in a ten-hour week: $100.00 of wages, no
        // tips, no overtime. MEASURED on both surfaces.
        #expect(facts.total.cents == 10_000)
        #expect(row.amount.cents == 10_000)
        #expect(facts.total.cents == row.amount.cents)
        #expect(facts.total.label == row.amount.label)
        #expect(facts.total.text == row.amount.text)
        // And the rest of the sheet reads rather than going blank.
        #expect(facts.hoursCaption == "10h · $100.00 wages")
        #expect(facts.hourlyRateText == "$10/hr")
        #expect(facts.isUnbacked == false)
    }

    @Test("an untouched sheet still renders no currency: an inferred period is not substance")
    func untouchedSheetStillHasNoFigure() throws {
        // What a brand-new sheet holds a beat after it opens: nothing typed,
        // no punches, and a shiftPeriod already INFERRED from the clock.
        // Neither `shiftPeriod` nor `salesCents` can move a cents figure, so
        // neither counts as substance — otherwise this sheet would open with
        // "$0.00 / Total", a zero standing in for "nothing entered yet".
        let input = ShiftDraftPreview.draftInput(
            date: at(2026, 9, 2),
            cashCents: 0,
            creditCents: 0,
            recordedAt: at(2026, 9, 2, hour: 23),
            shiftID: logShiftID(8),
            hoursWorked: nil,
            tipOutCents: 0,
            salesCents: 4_000,
            shiftPeriod: .dinner,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil,
            receiptMetrics: nil,
            normalizeEarnings: false,
            policies: sundayStartPolicies()
        )
        #expect(input == nil)

        let facts = draftFacts(draft: nil, hoursWorked: nil, shiftID: logShiftID(8))
        #expect(facts.isUnbacked)
        #expect(facts.total.text == nil)
        #expect(facts.total.cents == nil)
    }

    @Test("a live shift ended with punches and no tips typed reads its wages, not a placeholder")
    func endingALiveShiftWithNoTipsReadsItsWages() throws {
        // PROBE D2's shape: `LiveShiftEndModeResolver` seeds the punches and
        // the hours, and the person has not typed a tip yet. The pre-migration
        // header showed $100.00 here; before this fix it showed the
        // unavailable placeholder.
        let draft = ShiftDraftPreview.draftInput(
            date: at(2026, 9, 2),
            cashCents: 0,
            creditCents: 0,
            recordedAt: at(2026, 9, 2, hour: 23),
            shiftID: logShiftID(9),
            hoursWorked: 10,
            tipOutCents: 0,
            salesCents: 0,
            shiftPeriod: nil,
            clockIn: at(2026, 9, 2, hour: 13, minute: 0),
            clockOut: at(2026, 9, 2, hour: 23, minute: 0),
            serverCount: nil,
            receiptMetrics: nil,
            normalizeEarnings: false,
            policies: sundayStartPolicies()
        )
        let facts = draftFacts(records: [], draft: draft, hoursWorked: 10, shiftID: logShiftID(9))
        #expect(facts.total.cents == 10_000)
        #expect(facts.total.text != nil)
    }
}
