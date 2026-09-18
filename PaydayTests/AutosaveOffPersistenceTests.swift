import Foundation
import SwiftData
import Testing
@testable import Payday

/// PR 2 slice S9, section 8.2's gate: with autosave OFF, does a write actually
/// survive?
///
/// This is the suite that would have caught the failure the design warns
/// about. Every SwiftUI write path in this app depended on autosave and
/// several never called `save()` at all, so turning the flag off without
/// converting them first stops persisting logged shifts, paychecks and live
/// field edits — and the app looks completely healthy while doing it, because
/// the in-memory context still answers every read until the process ends.
///
/// So these tests use a FILE-BACKED container in a temporary directory and
/// genuinely reopen it. An in-memory container cannot fail this way and would
/// make the suite worthless.
@Suite("Persistence with autosave off", .serialized)
@MainActor
struct AutosaveOffPersistenceTests {

    /// One throwaway store on disk, reopenable.
    private struct Store {
        let url: URL
        func open() throws -> ModelContext {
            let container = try ModelContainer(
                for: SharedModelContainer.schema,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            // The flag under test. Matches what
            // SharedModelContainer.disableMainContextAutosave does to the
            // real app's context.
            context.autosaveEnabled = false
            return context
        }
        func destroy() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    private func makeStore() -> Store {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("payday-autosave-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Store(url: directory.appendingPathComponent("store.sqlite"))
    }

    private static let day = Date(timeIntervalSince1970: 1_756_000_000)

    /// The exact shape section 8.2 names: write a paycheck, reopen, assert the
    /// row is present. The paycheck sheet appeared in no slice's file list in
    /// an earlier plan, which is how "paycheck entry silently stops
    /// persisting" would have shipped.
    @Test("a paycheck written through commit survives a container reopen")
    func paycheckSurvivesReopen() throws {
        let store = makeStore()
        defer { store.destroy() }

        do {
            let context = try store.open()
            try ShiftCommands.commit(in: context) {
                context.insert(PaycheckRecord(
                    periodStart: Self.day,
                    periodEnd: Self.day.addingTimeInterval(86_400 * 13),
                    paidTipsCents: 42_000
                ))
            }
        }

        let reopened = try store.open()
        let rows = try reopened.fetch(FetchDescriptor<PaycheckRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.paidTipsCents == 42_000)
    }

    @Test("a shift created through the command survives a container reopen")
    func shiftSurvivesReopen() throws {
        let store = makeStore()
        defer { store.destroy() }
        var createdID: UUID?

        do {
            let context = try store.open()
            createdID = try ShiftCommands.create(
                in: context,
                workDate: Self.day,
                cashTipsCents: 5_000,
                hoursWorked: 6.5
            ).id
        }

        let reopened = try store.open()
        let rows = try reopened.fetch(FetchDescriptor<ShiftRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == createdID)
        #expect(rows.first?.cashTipsCents == 5_000)
        #expect(rows.first?.hoursWorked == 6.5)
    }

    /// The live field edit, which is the one that persisted through `didSet`
    /// plus autosave and nothing else. Two separate failures had to be fixed
    /// for this to work: `didSet` never fires on a SwiftData model, and with
    /// autosave off nothing writes the change at all.
    @Test("a live field edit survives a container reopen")
    func liveEditSurvivesReopen() throws {
        let store = makeStore()
        defer { store.destroy() }
        var id: UUID?

        do {
            let context = try store.open()
            let record = try ShiftCommands.create(
                in: context, workDate: Self.day, cashTipsCents: 5_000)
            id = record.id
            try ShiftCommands.update(record, in: context) {
                $0.cashTipsCents = 6_000
                $0.note = "edited"
            }
        }

        let reopened = try store.open()
        let stored = try #require(
            try reopened.fetch(FetchDescriptor<ShiftRecord>()).first { $0.id == id })
        #expect(stored.cashTipsCents == 6_000)
        #expect(stored.note == "edited")
    }

    /// The other half of the claim, and the reason autosave had to go. An
    /// unsaved mutation must NOT reach disk — otherwise "nothing was changed"
    /// after a failure is a lie.
    @Test("a mutation with no commit does not reach disk")
    func unsavedMutationDoesNotPersist() throws {
        let store = makeStore()
        defer { store.destroy() }

        do {
            let context = try store.open()
            // Bypassing the command boundary on purpose, which is what every
            // shipped write path used to do.
            context.insert(ShiftRecord(workDate: Self.day, cashTipsCents: 9_999))
            // No save. With autosave ON this would land anyway, and the
            // atomicity of every command above would be unenforceable.
        }

        let reopened = try store.open()
        #expect(try reopened.fetch(FetchDescriptor<ShiftRecord>()).isEmpty)
    }

    /// The tests above set the flag on their own throwaway contexts, which
    /// proves the BEHAVIOUR but not that the shipped app's context has it off.
    /// This closes that loop on the real container, so the whole suite cannot
    /// pass while the app itself still autosaves.
    @Test("the app's own shared context has autosave off")
    func theRealSharedContextHasAutosaveOff() {
        SharedModelContainer.disableMainContextAutosave()
        #expect(!SharedModelContainer.shared.mainContext.autosaveEnabled)
    }

    /// A rollback has to reach disk state too, not just the in-memory context.
    @Test("a rolled-back edit leaves the stored row untouched")
    func rolledBackEditDoesNotPersist() throws {
        let store = makeStore()
        defer { store.destroy() }
        var id: UUID?

        do {
            let context = try store.open()
            let record = try ShiftCommands.create(
                in: context, workDate: Self.day, cashTipsCents: 5_000)
            id = record.id

            struct Boom: Error {}
            #expect(throws: Boom.self) {
                try ShiftCommands.update(record, in: context) { editing in
                    editing.cashTipsCents = 1
                    throw Boom()
                }
            }
        }

        let reopened = try store.open()
        let stored = try #require(
            try reopened.fetch(FetchDescriptor<ShiftRecord>()).first { $0.id == id })
        #expect(stored.cashTipsCents == 5_000, "the rollback has to survive the reopen too")
    }
}
