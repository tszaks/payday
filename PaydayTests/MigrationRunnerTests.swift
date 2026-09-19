import Testing
import Foundation
import SwiftData
@testable import Payday

private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: d))!
}

private func time(_ year: Int, _ month: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: d, hour: hour, minute: minute))!
}

@MainActor
private func makeContext() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: TipEntry.self, PaycheckRecord.self, configurations: config)
    return ModelContext(container)
}

@Suite("Migration: shiftID backfill")
@MainActor
struct MigrationRunnerTests {
    @Test("legacy rows get one shiftID per calendar day")
    func oneIDPerDay() throws {
        let context = try makeContext()
        // Two rows on July 1 (a cash+credit night) and one on July 2, all legacy (nil id).
        context.insert(TipEntry(date: day(2026, 7, 1), amountCents: 5000, kind: .cash))
        context.insert(TipEntry(date: day(2026, 7, 1), amountCents: 3000, kind: .credit))
        context.insert(TipEntry(date: day(2026, 7, 2), amountCents: 4000, kind: .cash))
        try context.save()

        MigrationRunner.backfillShiftIDs(in: context)

        let all = try context.fetch(FetchDescriptor<TipEntry>())
        #expect(all.allSatisfy { $0.shiftID != nil })
        let july1 = all.filter { Calendar.current.isDate($0.date, inSameDayAs: day(2026, 7, 1)) }
        let july2 = all.filter { Calendar.current.isDate($0.date, inSameDayAs: day(2026, 7, 2)) }
        // Both July 1 rows share one id; July 2 has its own.
        #expect(Set(july1.map { $0.shiftID }).count == 1)
        #expect(july1.first?.shiftID != july2.first?.shiftID)
    }

    /// **PR 7's gate applied to the upgrade path: no lost, duplicated or
    /// altered records.**
    ///
    /// The tests around this one check the transformation RULES -- one id
    /// per day, coalescing, hour recomputation. None of them checks the
    /// property a person would actually notice, which is that the money
    /// still adds up afterwards. A backfill that dropped a row, or ran a
    /// day's cash through twice, would satisfy every rule above and still
    /// be the worst possible bug in a tips app.
    ///
    /// Asserted as CONSERVATION rather than as a list of expected values:
    /// the total before must equal the total after, and the multiset of
    /// (date, cents, kind) must be untouched. A hand-typed expectation
    /// would only re-state what the code did.
    @Test("the upgrade conserves every row and every cent")
    func upgradeConservesRowsAndMoney() throws {
        let context = try makeContext()
        // A realistic legacy store: cash+credit nights, a lone cash night, a
        // duplicate amount on the same day (which must NOT be deduplicated),
        // a zero row, and a punch-backed row.
        let rows = [
            TipEntry(date: day(2026, 7, 1), amountCents: 5_000, kind: .cash),
            TipEntry(date: day(2026, 7, 1), amountCents: 3_000, kind: .credit),
            TipEntry(date: day(2026, 7, 1), amountCents: 3_000, kind: .credit),
            TipEntry(date: day(2026, 7, 2), amountCents: 4_000, kind: .cash),
            TipEntry(date: day(2026, 7, 3), amountCents: 0, kind: .cash),
            TipEntry(date: day(2026, 7, 4), amountCents: 12_345, kind: .credit)
        ]
        rows.forEach { context.insert($0) }
        try context.save()

        func fingerprint() throws -> [String] {
            try context.fetch(FetchDescriptor<TipEntry>())
                .map { "\(Int($0.date.timeIntervalSince1970))|\($0.amountCents)|\($0.kind.rawValue)" }
                .sorted()
        }
        let before = try fingerprint()
        let centsBefore = try context.fetch(FetchDescriptor<TipEntry>())
            .reduce(0) { $0 + $1.amountCents }
        #expect(centsBefore == 27_345, "the fixture must be what this test thinks it is")

        MigrationRunner.backfillShiftIDs(in: context)
        MigrationRunner.recomputeExactHours(in: context)

        let after = try fingerprint()
        let centsAfter = try context.fetch(FetchDescriptor<TipEntry>())
            .reduce(0) { $0 + $1.amountCents }

        #expect(after.count == before.count, "no row lost and none duplicated")
        #expect(after == before, "no row's date, amount or kind altered")
        #expect(centsAfter == centsBefore, "not one cent moved")

        // The two identical credit rows on July 1 are a real shape -- two
        // tables closed out at the same amount -- and collapsing them would
        // silently halve that night.
        let july1Credits = try context.fetch(FetchDescriptor<TipEntry>())
            .filter { Calendar.current.isDate($0.date, inSameDayAs: day(2026, 7, 1)) && $0.kind == .credit }
        #expect(july1Credits.count == 2, "identical rows are distinct shifts' worth of money")
    }

    @Test("backfill is idempotent and deterministic across runs")
    func idempotentAndDeterministic() throws {
        let context = try makeContext()
        context.insert(TipEntry(date: day(2026, 7, 1), amountCents: 5000, kind: .cash))
        try context.save()

        MigrationRunner.backfillShiftIDs(in: context)
        let firstRun = try context.fetch(FetchDescriptor<TipEntry>()).first?.shiftID
        MigrationRunner.backfillShiftIDs(in: context)
        let secondRun = try context.fetch(FetchDescriptor<TipEntry>()).first?.shiftID
        #expect(firstRun != nil)
        #expect(firstRun == secondRun)
        // The id matches the shared day-derived id both grouping paths use.
        #expect(firstRun == ShiftDays.deterministicShiftID(for: day(2026, 7, 1)))
    }

    @Test("a nil sibling coalesces onto a day's existing id rather than forking it")
    func coalescesOntoExistingID() throws {
        let context = try makeContext()
        let existing = UUID()
        context.insert(TipEntry(date: day(2026, 7, 1), amountCents: 5000, kind: .cash, shiftID: existing))
        context.insert(TipEntry(date: day(2026, 7, 1), amountCents: 3000, kind: .credit))
        try context.save()

        MigrationRunner.backfillShiftIDs(in: context)

        let all = try context.fetch(FetchDescriptor<TipEntry>())
        #expect(all.allSatisfy { $0.shiftID == existing })
    }
}

@Suite("Migration: exact-hours recompute")
@MainActor
struct MigrationRunnerExactHoursTests {
    @Test("a punch-backed shift stored with legacy quarter-rounded hours gets recomputed exactly")
    func recomputesPunchBackedShift() throws {
        let context = try makeContext()
        // Legacy row: 10:04 AM-4:27 PM (383 minutes) was stored quarter-rounded
        // to 6.5h before this rule existed; recompute should land on 6.3833...h.
        let entry = TipEntry(
            date: day(2026, 7, 1), amountCents: 5000, kind: .credit,
            hoursWorked: 6.5,
            clockIn: time(2026, 7, 1, 10, 4), clockOut: time(2026, 7, 1, 16, 27)
        )
        context.insert(entry)
        try context.save()

        MigrationRunner.recomputeExactHours(in: context)

        let all = try context.fetch(FetchDescriptor<TipEntry>())
        #expect(abs((all.first?.hoursWorked ?? 0) - 383.0 / 60.0) < 0.0001)
    }

    @Test("manual hours with no punches are left exactly as entered")
    func manualHoursUntouched() throws {
        let context = try makeContext()
        let entry = TipEntry(date: day(2026, 7, 1), amountCents: 5000, kind: .credit, hoursWorked: 6.5)
        context.insert(entry)
        try context.save()

        MigrationRunner.recomputeExactHours(in: context)

        let all = try context.fetch(FetchDescriptor<TipEntry>())
        #expect(all.first?.hoursWorked == 6.5)
    }

    @Test("recompute is idempotent across repeated runs")
    func idempotent() throws {
        let context = try makeContext()
        let entry = TipEntry(
            date: day(2026, 7, 1), amountCents: 5000, kind: .credit,
            hoursWorked: 6.5,
            clockIn: time(2026, 7, 1, 10, 4), clockOut: time(2026, 7, 1, 16, 27)
        )
        context.insert(entry)
        try context.save()

        MigrationRunner.recomputeExactHours(in: context)
        let firstRun = try context.fetch(FetchDescriptor<TipEntry>()).first?.hoursWorked
        MigrationRunner.recomputeExactHours(in: context)
        let secondRun = try context.fetch(FetchDescriptor<TipEntry>()).first?.hoursWorked
        #expect(firstRun == secondRun)
    }

    @Test("an overnight punch still wraps and recomputes correctly")
    func overnightPunch() throws {
        let context = try makeContext()
        // 10:00 PM-2:13 AM wraps across midnight: 253 minutes = 4.2166...h.
        let entry = TipEntry(
            date: day(2026, 7, 1), amountCents: 5000, kind: .credit,
            hoursWorked: 4.25,
            clockIn: time(2026, 7, 1, 22, 0), clockOut: time(2026, 7, 1, 2, 13)
        )
        context.insert(entry)
        try context.save()

        MigrationRunner.recomputeExactHours(in: context)

        let all = try context.fetch(FetchDescriptor<TipEntry>())
        #expect(abs((all.first?.hoursWorked ?? 0) - 253.0 / 60.0) < 0.0001)
    }
}
