import Testing
import Foundation
import SwiftData
@testable import Payday

private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: d))!
}

@MainActor
private func makeContext() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: TipEntry.self, PaycheckRecord.self, configurations: config)
    return ModelContext(container)
}

@Suite("ShiftWriter.insertShift")
@MainActor
struct ShiftWriterTests {
    @Test("cash and credit together produce two entries sharing one non-nil shiftID")
    func cashAndCreditShareOneShiftID() throws {
        let context = try makeContext()
        let entries = ShiftWriter.insertShift(into: context, date: day(2026, 7, 1), cashCents: 5000, creditCents: 3000)

        #expect(entries.count == 2)
        let cash = entries.first { $0.kind == .cash }
        let credit = entries.first { $0.kind == .credit }
        #expect(cash?.amountCents == 5000)
        #expect(credit?.amountCents == 3000)
        #expect(cash?.shiftID != nil)
        #expect(cash?.shiftID == credit?.shiftID)
    }

    @Test("cash-only produces exactly one entry")
    func cashOnlyProducesOneEntry() throws {
        let context = try makeContext()
        let entries = ShiftWriter.insertShift(into: context, date: day(2026, 7, 1), cashCents: 5000, creditCents: 0)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .cash)
        #expect(entries.first?.amountCents == 5000)
    }

    @Test("credit-only produces exactly one entry")
    func creditOnlyProducesOneEntry() throws {
        let context = try makeContext()
        let entries = ShiftWriter.insertShift(into: context, date: day(2026, 7, 1), cashCents: 0, creditCents: 4200)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .credit)
        #expect(entries.first?.amountCents == 4200)
    }

    @Test("tip-out lands on the canonical entry (credit preferred) and never on both")
    func tipOutLandsOnCanonicalEntryOnly() throws {
        let context = try makeContext()
        let entries = ShiftWriter.insertShift(into: context, date: day(2026, 7, 1), cashCents: 5000, creditCents: 3000, tipOutCents: 1500)

        let cash = entries.first { $0.kind == .cash }
        let credit = entries.first { $0.kind == .credit }
        #expect(credit?.tipOutCents == 1500)
        #expect(cash?.tipOutCents == nil)
    }

    @Test("tip-out lands on the sole entry when there's no credit row")
    func tipOutLandsOnSoleCashEntry() throws {
        let context = try makeContext()
        let entries = ShiftWriter.insertShift(into: context, date: day(2026, 7, 1), cashCents: 5000, creditCents: 0, tipOutCents: 800)

        #expect(entries.first?.tipOutCents == 800)
    }

    @Test("date is normalized to startOfDay")
    func dateNormalizedToStartOfDay() throws {
        let context = try makeContext()
        let withTime = Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: day(2026, 7, 1))!
        let entries = ShiftWriter.insertShift(into: context, date: withTime, cashCents: 5000, creditCents: 0)

        #expect(entries.first?.date == day(2026, 7, 1))
    }

    @Test("a future date is clamped to today")
    func futureDateClampedToToday() throws {
        let context = try makeContext()
        let future = Calendar.current.date(byAdding: .day, value: 30, to: .now)!
        let entries = ShiftWriter.insertShift(into: context, date: future, cashCents: 5000, creditCents: 0)

        #expect(entries.first?.date == Calendar.current.startOfDay(for: .now))
    }

    @Test("two inserts for the same day mint distinct shiftIDs — an emergent double")
    func sameDayInsertsGetDistinctShiftIDs() throws {
        let context = try makeContext()
        let first = ShiftWriter.insertShift(into: context, date: day(2026, 7, 1), cashCents: 5000, creditCents: 0)
        let second = ShiftWriter.insertShift(into: context, date: day(2026, 7, 1), cashCents: 6000, creditCents: 0)

        #expect(first.first?.shiftID != nil)
        #expect(second.first?.shiftID != nil)
        #expect(first.first?.shiftID != second.first?.shiftID)
    }

    @Test("recordedAt is respected as passed")
    func recordedAtIsRespected() throws {
        let context = try makeContext()
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = ShiftWriter.insertShift(into: context, date: day(2026, 7, 1), cashCents: 5000, creditCents: 0, recordedAt: recordedAt)

        #expect(entries.first?.recordedAt == recordedAt)
    }
}
