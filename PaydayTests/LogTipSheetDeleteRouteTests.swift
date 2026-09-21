import Foundation
import SwiftData
import Testing
@testable import Payday

/// The sheet-level half of the delete witness, and it covers a failure the
/// command-level witness structurally cannot.
///
/// When `.editShift` was added, `LogTipSheet.delete()` consumed `target`
/// through `if case .edit(let entry) = target`, which does not oblige the
/// compiler and does not match a record. The sheet dismissed having deleted
/// nothing. `ShiftCommands.delete` was never wrong, it was never CALLED.
/// The command being right and the call site reaching it are two different
/// facts.
///
/// So the routing is asserted as a value. `.none` for an editing target is
/// itself the bug, and that is the assertion — not "the command works".
/// Since the flip, `.editShift` is the only editing target, and `.none`
/// remains correct only for `.new`.
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

    /// The only target for which `.none` is correct: there is nothing to
    /// delete yet. Asserted so the enum's case is pinned as "new only"
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
        context.insert(record)
        try context.save()

        let editingTargets: [TipEntrySheetTarget] = [.editShift(record)]
        for target in editingTargets {
            let route = LogTipSheet(target: target).deleteRoute
            #expect(route != .none, "\(target.id) routes to none, so its delete does nothing")
        }
    }
}
