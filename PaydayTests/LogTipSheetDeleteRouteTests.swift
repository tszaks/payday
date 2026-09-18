import Foundation
import SwiftData
import Testing
@testable import Payday

/// The sheet-level half of gate 2's delete witness, and it covers a failure
/// the command-level witness structurally cannot.
///
/// When `.editShift` was added, `LogTipSheet.delete()` consumed `target`
/// through `if case .edit(let entry) = target`, which does not oblige the
/// compiler and does not match a record. The sheet dismissed having deleted
/// nothing. `FlipGate2WitnessTests.deleteRemovesAndEnqueues` passed the whole
/// time, correctly: `ShiftCommands.delete` was never wrong, it was never
/// CALLED. The command being right and the call site reaching it are two
/// different facts.
///
/// So the routing is asserted as a value. `.none` for an editing target is
/// itself the bug, and that is the assertion — not "the command works".
@Suite("LogTipSheet delete route")
@MainActor
struct LogTipSheetDeleteRouteTests {

    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static let day = Date(timeIntervalSince1970: 1_756_000_000)

    /// The regression. A record-backed sheet must route to the record path,
    /// and specifically must NOT route to `.none`, which is what silently
    /// dismissed without deleting.
    @Test("a record-backed sheet routes its delete to the record path")
    func recordTargetRoutesToTheRecord() throws {
        let context = try context()
        let record = ShiftRecord(
            workDate: Self.day, cashTipsCents: 4_200, hoursWorked: 6.5,
            recordedAt: Self.day
        )
        context.insert(record)
        try context.save()

        let sheet = LogTipSheet(target: .editShift(record))

        #expect(sheet.deleteRoute == .record(record))
        #expect(sheet.deleteRoute != .none,
                "`.none` here is the silent no-op: the sheet closes and nothing is deleted")
    }

    @Test("a legacy-backed sheet still routes to the legacy path")
    func legacyTargetRoutesToTheEntry() throws {
        let context = try context()
        let entry = TipEntry(date: Self.day, amountCents: 4_200, kind: .cash, shiftID: UUID())
        context.insert(entry)
        try context.save()

        let sheet = LogTipSheet(target: .edit(entry))
        #expect(sheet.deleteRoute == .legacy(entry))
    }

    /// The only target for which `.none` is correct: there is nothing to
    /// delete yet. Asserted so the enum's third case is pinned as "new only"
    /// rather than as a catch-all that a future case could fall into.
    @Test("a new sheet has nothing to delete, and that is the only correct none")
    func newTargetRoutesToNone() {
        let sheet = LogTipSheet(target: .new(defaultDate: Self.day))
        #expect(sheet.deleteRoute == .none)
    }

    /// Every editing target routes somewhere real. This is the assertion that
    /// survives a FUTURE case being added: a new editing representation that
    /// forgets its delete branch fails here rather than shipping a sheet that
    /// closes without deleting.
    @Test("no editing target ever routes to none")
    func noEditingTargetRoutesToNone() throws {
        let context = try context()
        let record = ShiftRecord(workDate: Self.day, cashTipsCents: 1, recordedAt: Self.day)
        let entry = TipEntry(date: Self.day, amountCents: 1, kind: .cash, shiftID: UUID())
        context.insert(record)
        context.insert(entry)
        try context.save()

        let editingTargets: [TipEntrySheetTarget] = [.editShift(record), .edit(entry)]
        for target in editingTargets {
            let route = LogTipSheet(target: target).deleteRoute
            #expect(route != .none, "\(target.id) routes to none, so its delete does nothing")
        }
    }
}
