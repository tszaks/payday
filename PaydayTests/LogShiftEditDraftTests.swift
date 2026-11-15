import Foundation
import SwiftData
import Testing
@testable import Payday

/// The Edit Shift sheet writes its record only when the person changed
/// something.
///
/// It used to write every field back on every close, with a fresh
/// `modifiedAt`, so merely opening a shift and tapping Done uploaded it, and
/// the server (last write wins) could replace a newer edit made on another
/// phone with this phone's older copy. The sheet now compares the draft it
/// would write with the one it seeded (or last wrote) and skips an equal one.
///
/// What is covered here: the draft type, its seeding from a record, its
/// stored-form rules, and `ShiftCommands.update` driven by it. What is covered
/// by reading only: that `LogTipSheet.commitLiveEdit` returns before
/// `ShiftCommands.update` when `editDraft == committedDraft`, and that
/// `handleSheetAppear` takes `committedDraft` from `editDraft` — both need a
/// live view.
@Suite("LogShiftEditDraft")
@MainActor
struct LogShiftEditDraftTests {

    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
    private static let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: day)!
    private static let clockIn = Calendar.current.date(byAdding: .hour, value: 17, to: day)!
    private static let clockOut = Calendar.current.date(byAdding: .hour, value: 23, to: day)!

    private static let metrics = ShiftReceiptMetrics(
        earningsSchemaVersion: 2,
        guestCount: 14,
        tableCount: 6,
        gratuityFeesCents: 1_800,
        totalAmountCents: 98_000
    )

    /// Every field the sheet writes holds a value.
    private static func fullFields() -> LogShiftEditDraft.Fields {
        LogShiftEditDraft.Fields(
            cashCents: 5_000,
            creditCents: 12_000,
            receiptMetrics: metrics,
            date: day,
            note: "Patio was slammed",
            hoursWorked: 6.5,
            tipOutCents: 1_500,
            tipShareInCents: 2_000,
            roleName: "Bar",
            jobName: "Catering",
            salesCents: 80_000,
            shiftPeriod: .dinner,
            clockIn: clockIn,
            clockOut: clockOut,
            serverCount: 5
        )
    }

    /// An ordinary night: money, hours and a period, nothing else.
    private static func plainFields() -> LogShiftEditDraft.Fields {
        LogShiftEditDraft.Fields(
            cashCents: 4_200,
            creditCents: 9_000,
            receiptMetrics: nil,
            date: day,
            note: "",
            hoursWorked: 5,
            tipOutCents: 0,
            tipShareInCents: 0,
            roleName: nil,
            jobName: nil,
            salesCents: 0,
            shiftPeriod: .lunch,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil
        )
    }

    /// Every optional empty, in the form the sheet's controls hold "empty".
    private static func emptyFields() -> LogShiftEditDraft.Fields {
        LogShiftEditDraft.Fields(
            cashCents: 0,
            creditCents: 0,
            receiptMetrics: nil,
            date: day,
            note: "",
            hoursWorked: nil,
            tipOutCents: 0,
            tipShareInCents: 0,
            roleName: nil,
            jobName: nil,
            salesCents: 0,
            shiftPeriod: nil,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil
        )
    }

    /// A saved record holding `fields` as the sheet would write them.
    private func record(
        writing fields: LogShiftEditDraft.Fields,
        in context: ModelContext
    ) throws -> ShiftRecord {
        let record = ShiftRecord(workDate: Self.dayBefore, recordedAt: Self.day)
        context.insert(record)
        LogShiftEditDraft(fields).apply(to: record)
        try context.save()
        return record
    }

    // MARK: - Open and close writes nothing

    /// The property the fix rests on: a record written from a draft seeds a
    /// sheet whose draft is that same draft, so an untouched sheet compares
    /// equal and skips the write.
    @Test(
        "a draft written to a record seeds an equal draft",
        arguments: ["plain", "every optional set", "nil optionals"]
    )
    func writtenDraftSeedsAnEqualDraft(shape: String) throws {
        let fields = switch shape {
        case "plain": Self.plainFields()
        case "every optional set": Self.fullFields()
        default: Self.emptyFields()
        }
        let context = try context()
        let written = LogShiftEditDraft(fields)
        let record = try record(writing: fields, in: context)

        let seeded = LogShiftEditDraft(LogShiftEditDraft.Fields(record: record))

        #expect(seeded == written)
    }

    /// A record created by the log sheet or by sync, never by this draft,
    /// with optionals stored nil: still seeds a draft that writes it back
    /// unchanged.
    @Test("a record with nil optionals seeds a draft that writes it back unchanged")
    func nilOptionalRecordRoundTrips() throws {
        let context = try context()
        let record = ShiftRecord(workDate: Self.day, cashTipsCents: 4_200, recordedAt: Self.day)
        context.insert(record)
        try context.save()

        let seeded = LogShiftEditDraft(LogShiftEditDraft.Fields(record: record))

        #expect(seeded.tipOutCents == nil)
        #expect(seeded.tipShareInCents == nil)
        #expect(seeded.salesCents == nil)
        #expect(seeded.note == nil)
        #expect(seeded.receiptMetrics == nil)
        #expect(seeded.workDate == record.workDate)
        #expect(LogShiftEditDraft(LogShiftEditDraft.Fields(record: record)) == seeded)
    }

    // MARK: - Every field counts

    /// One case per value `apply(to:)` writes. A change to any one of them
    /// must make the drafts unequal, or that edit would be dropped on close.
    @Test("each single field change makes the drafts unequal")
    func eachFieldChangeIsADifference() {
        let base = Self.fullFields()
        let cases: [(String, (inout LogShiftEditDraft.Fields) -> Void)] = [
            ("cashCents", { $0.cashCents = 5_100 }),
            ("creditCents", { $0.creditCents = 12_100 }),
            ("receiptMetrics", { $0.receiptMetrics = ShiftReceiptMetrics(earningsSchemaVersion: 2, guestCount: 15) }),
            ("workDate", { $0.date = Self.dayBefore }),
            ("note", { $0.note = "Patio" }),
            ("hoursWorked", { $0.hoursWorked = 7 }),
            ("tipOutCents", { $0.tipOutCents = 1_600 }),
            ("tipShareInCents", { $0.tipShareInCents = 2_100 }),
            ("roleName", { $0.roleName = "Floor" }),
            ("jobName", { $0.jobName = nil }),
            ("salesCents", { $0.salesCents = 81_000 }),
            ("shiftPeriod", { $0.shiftPeriod = .lunch }),
            ("clockIn", { $0.clockIn = Self.dayBefore }),
            ("clockOut", { $0.clockOut = nil }),
            ("serverCount", { $0.serverCount = 6 })
        ]
        let original = LogShiftEditDraft(base)

        // A field added to the draft without a case here fails this line.
        #expect(cases.map(\.0) == Mirror(reflecting: original).children.compactMap(\.label))

        for (name, change) in cases {
            var changed = base
            change(&changed)
            #expect(LogShiftEditDraft(changed) != original, "a change to \(name) compares equal, so it would never be written")
        }
    }

    // MARK: - Stored-form rules

    @Test("a tip-out, tip share or sales of 0 is the stored nil")
    func zeroAmountsAreNil() throws {
        let context = try context()
        let record = ShiftRecord(workDate: Self.day, recordedAt: Self.day)
        let storedZero = ShiftRecord(workDate: Self.day, tipOutCents: 0, salesCents: 0, tipShareInCents: 0, recordedAt: Self.day)
        context.insert(record)
        context.insert(storedZero)
        try context.save()

        var fields = LogShiftEditDraft.Fields(record: record)
        fields.tipOutCents = 0
        fields.tipShareInCents = 0
        fields.salesCents = 0
        let draft = LogShiftEditDraft(fields)

        #expect(draft.tipOutCents == nil)
        #expect(draft.tipShareInCents == nil)
        #expect(draft.salesCents == nil)
        #expect(draft == LogShiftEditDraft(LogShiftEditDraft.Fields(record: record)))
        #expect(draft == LogShiftEditDraft(LogShiftEditDraft.Fields(record: storedZero)))
    }

    @Test("an empty note is the stored nil")
    func emptyNoteIsNil() throws {
        let context = try context()
        var empty = Self.fullFields()
        empty.note = ""
        let record = try record(writing: empty, in: context)
        let storedEmpty = ShiftRecord(workDate: Self.day, note: "")

        #expect(LogShiftEditDraft(empty).note == nil)
        #expect(record.note == nil)
        #expect(LogShiftEditDraft(LogShiftEditDraft.Fields(record: record)) == LogShiftEditDraft(empty))
        #expect(LogShiftEditDraft(LogShiftEditDraft.Fields(record: storedEmpty)).note == nil)
    }

    @Test("a role or job with spaces equals its normalised form")
    func roleIsNormalised() {
        var padded = Self.fullFields()
        padded.roleName = "  Bar  "
        padded.jobName = " Catering\n"
        var blank = Self.fullFields()
        blank.roleName = "   "
        blank.jobName = ""
        var none = Self.fullFields()
        none.roleName = nil
        none.jobName = nil

        #expect(LogShiftEditDraft(padded) == LogShiftEditDraft(Self.fullFields()))
        #expect(LogShiftEditDraft(padded).roleName == "Bar")
        #expect(LogShiftEditDraft(blank) == LogShiftEditDraft(none))
    }

    @Test("the work day is stored as the start of the day")
    func workDateIsStartOfDay() {
        var evening = Self.fullFields()
        evening.date = Self.clockOut

        #expect(LogShiftEditDraft(evening).workDate == Self.day)
        #expect(LogShiftEditDraft(evening) == LogShiftEditDraft(Self.fullFields()))
    }

    // MARK: - At the record

    /// The fault, at the record. An untouched open-and-close compares the
    /// sheet's draft with the one it seeded; equal means `commitLiveEdit`
    /// returns before `ShiftCommands.update`, so the record keeps its
    /// `modifiedAt` and the store has nothing to save or upload.
    @Test("an untouched sheet's draft equals its seed, so nothing is written")
    func untouchedSheetWritesNothing() throws {
        let context = try context()
        let record = try record(writing: Self.fullFields(), in: context)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        record.touch(stamp)
        try context.save()

        // What the sheet seeds, and what it would write if closed untouched.
        let committed = LogShiftEditDraft(LogShiftEditDraft.Fields(record: record))
        let atClose = LogShiftEditDraft(LogShiftEditDraft.Fields(record: record))

        #expect(atClose == committed, "equal drafts are what make commitLiveEdit skip the write")
        #expect(record.modifiedAt == stamp)
        #expect(!context.hasChanges)
    }

    /// The mirror: one field changed compares unequal, and writing that draft
    /// through `ShiftCommands.update` lands the change and advances the clock.
    @Test("one changed field compares unequal and is written")
    func changedFieldIsWritten() throws {
        let context = try context()
        let record = try record(writing: Self.fullFields(), in: context)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        record.touch(stamp)
        try context.save()

        let committed = LogShiftEditDraft(LogShiftEditDraft.Fields(record: record))
        var fields = LogShiftEditDraft.Fields(record: record)
        fields.cashCents = 12_000
        let edited = LogShiftEditDraft(fields)
        #expect(edited != committed)

        try ShiftCommands.update(record, in: context) { edited.apply(to: $0) }

        #expect(record.cashTipsCents == 12_000)
        #expect(record.modifiedAt > stamp)
        #expect(LogShiftEditDraft(LogShiftEditDraft.Fields(record: record)) == edited)
    }

    /// Why the sheet compares with what it SEEDED and not with the record at
    /// close: a sync pass can update the record while the sheet is open. The
    /// untouched sheet still holds its seed, so it skips the write and the
    /// newer record stands. Compared with the record instead, the seed would
    /// look like an edit and overwrite the newer value.
    @Test("a record updated by sync while the sheet is open is not overwritten by an untouched sheet")
    func syncedRecordIsNotOverwritten() throws {
        let context = try context()
        let record = try record(writing: Self.fullFields(), in: context)
        let committed = LogShiftEditDraft(LogShiftEditDraft.Fields(record: record))
        let atClose = committed

        // Another phone's edit arrives through sync.
        record.applyEarnings(cashCents: 12_000, creditCents: record.creditTipsCents, metrics: record.receiptMetrics, metricsOwner: .credit)
        try context.save()

        #expect(atClose == committed)
        #expect(atClose != LogShiftEditDraft(LogShiftEditDraft.Fields(record: record)),
                "comparing with the record at close would rewrite the older seed")
        #expect(record.cashTipsCents == 12_000)
    }
}
