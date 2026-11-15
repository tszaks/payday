import Testing
import Foundation
@testable import Payday

/// A noted shift is still a shift.
///
/// This suite used to assert that a shift NOTE aged out of narration on its
/// own 30-day clock, shorter than the 180-day facts window. Both the notes
/// and the narration that read them are gone: `InsightsFacts.notes` had
/// exactly two readers, `InsightsFactsCopy` and `InsightsService`'s prompt,
/// and PR 5 group 2.7 deleted both. What survives from the original
/// regression is the half that is still observable — a shift carrying a note
/// counts toward the facts window like any other.
@Suite("Insights note recency")
@MainActor
struct InsightsNoteRecencyTests {
    /// The note lives on the stored shift; the engine reads the shift
    /// through `StatsRecordAdapter`, as Insights does.
    private func record(_ day: Int, note: String?, cents: Int = 20000) -> TipRecord {
        let shift = ShiftRecord(
            workDate: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: day))!,
            creditTipsCents: cents,
            note: note
        )
        let calendars = [PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("noterecency/calendar"), effectiveFrom: .distantPast,
            workweekStartWeekday: 1, payrollTimeZone: PaydayTestZone.payroll)]
        return StatsRecordAdapter.tipRecords(from: [shift], calendars: calendars, payrollTimeZone: PaydayTestZone.payroll)[0]
    }

    @Test("a shift with a note is counted like any other shift in the facts window")
    func notedShiftStillCounts() {
        let asOf = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 8, day: 5))!
        var records = (10...20).map { record($0, note: nil) }
        records.append(record(17, note: "Toast error carried lunch tips into dinner"))
        let facts = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records).insightsFacts(referenceDate: asOf)
        #expect(facts?.shiftCount == records.count)

        // Still inside the 180-day facts window a month later.
        let laterAsOf = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let laterFacts = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records).insightsFacts(referenceDate: laterAsOf)
        #expect(laterFacts?.shiftCount == records.count)
    }
}
