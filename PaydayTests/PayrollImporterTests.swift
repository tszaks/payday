import Foundation
import PaydayCore
import SwiftData
import Testing
@testable import Payday

/// "Connect payroll": pay stubs -> paychecks. The rule these pin above all
/// others is that an import never makes a second paycheck for a period the
/// person already has, and never overwrites a figure they entered.
@Suite("Payroll importer")
@MainActor
struct PayrollImporterTests {
    let zone = PaydayTestZone.newYork
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    // MARK: - Fixtures

    let primary = JobPolicy(id: UUID(), name: "Main", schedule: nil, isPrimary: true)
    let cafe = JobPolicy(id: UUID(), name: "Cafe Rosa", schedule: nil, isPrimary: false)
    var jobs: [JobPolicy] { [primary, cafe] }

    func day(_ iso: String) -> Date { CivilDay(iso: iso)!.date(in: zone) }

    /// Bi-weekly, periods ending Sunday Oct 25 2026, paid five days later.
    var calculator: PayPeriodCalculator {
        PayPeriodCalculator(
            payrollTimeZone: zone,
            schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: day("2026-10-25"), payDelayDays: 5))
    }

    var scope: (String?) -> PayPeriodCalculator {
        let calculator = calculator
        return { _ in calculator }
    }

    func stub(
        _ id: String,
        pay: String = "2026-10-30",
        start: String? = "2026-10-12",
        end: String? = "2026-10-25",
        employer: String? = nil,
        gross: Int? = 162_998,
        net: Int? = 120_150,
        regular: Int? = 150_000,
        overtime: Int? = 12_998,
        tips: Int? = 0,
        gratuity: Int? = nil,
        taxes: Int? = 28_969,
        hours: String? = "80.00"
    ) -> PayrollStatement {
        PayrollStatement(
            sourceID: id, linkID: "link-1", providerName: "Toast", employerName: employer,
            payDate: pay, periodStart: start, periodEnd: end,
            grossPayCents: gross, netPayCents: net, hours: hours,
            regularCents: regular, overtimeCents: overtime,
            tipsCents: tips, gratuityCents: gratuity, declaredTipsCents: nil, taxesCents: taxes,
            deductions: [PayrollDeduction(name: "Federal", category: "federal", cents: 15_000)])
    }

    @discardableResult
    func manual(start: String, end: String, tips: Int = 0, job: String? = nil, configure: (PaycheckRecord) -> Void = { _ in }) throws -> PaycheckRecord {
        let record = PaycheckRecord(periodStart: day(start), periodEnd: day(end), paidTipsCents: tips)
        record.jobName = job
        configure(record)
        record.touch(at: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(record)
        try context.save()
        return record
    }

    func records() throws -> [PaycheckRecord] {
        try context.fetch(FetchDescriptor<PaycheckRecord>()).sorted { $0.periodEnd < $1.periodEnd }
    }

    @discardableResult
    func importing(_ statements: [PayrollStatement], into ledger: inout PayrollImportLedger, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> PayrollImporter.Outcome {
        try PayrollImporter.apply(statements: statements, in: context, ledger: &ledger, jobs: jobs, calculator: scope, now: now)
    }

    /// The `paycheck_records` CHECK constraints. A record that breaks one
    /// can never upload, so every record an import writes must pass.
    func satisfiesServerChecks(_ record: PaycheckRecord) -> Bool {
        let optional = [record.grossPayCents, record.netPayCents, record.regularWagesCents,
                        record.overtimeWagesCents, record.gratuityCents, record.taxesCents]
        let inRange = optional.allSatisfy { $0 == nil || (0...Int(Int32.max)).contains($0!) }
        let jobOK = record.jobName.map { (1...40).contains($0.unicodeScalars.count) } ?? true
        return record.paidTipsCents >= 0 && inRange && record.periodEnd >= record.periodStart && jobOK
    }

    // MARK: - Fresh and repeated import

    @Test("a fresh import writes the stub's fields onto a new paycheck")
    func freshImport() throws {
        var ledger = PayrollImportLedger()
        let outcome = try importing([stub("s1", tips: 41_235, gratuity: 5_510)], into: &ledger)
        #expect(outcome == .init(created: 1, merged: 0, unchanged: 0))
        let all = try records()
        #expect(all.count == 1)
        let record = try #require(all.first)
        #expect(record.periodStart == day("2026-10-12"))
        #expect(record.periodEnd == day("2026-10-25"))
        #expect(record.grossPayCents == 162_998)
        #expect(record.netPayCents == 120_150)
        #expect(record.regularWagesCents == 150_000)
        #expect(record.overtimeWagesCents == 12_998)
        #expect(record.taxesCents == 28_969)
        #expect(record.paidTipsCents == 41_235)
        #expect(record.gratuityCents == 5_510)
        #expect(record.jobName == nil)
        #expect(record.note == nil)
        #expect(satisfiesServerChecks(record))

        let entry = try #require(ledger.entries["s1"])
        #expect(entry.recordID == record.id)
        #expect(entry.origin == .created)
        #expect(entry.hours == "80.00")
        #expect(entry.deductions.count == 1)
        #expect(entry.recordModifiedAt == record.modifiedAt)
        #expect(ledger.lastSyncedAt != nil)
    }

    @Test("importing the same stubs again creates nothing")
    func idempotentReimport() throws {
        var ledger = PayrollImportLedger()
        let stubs = [stub("s1"), stub("s2", pay: "2026-11-13", start: "2026-10-26", end: "2026-11-08")]
        try importing(stubs, into: &ledger)
        let firstIDs = try records().map(\.id)
        let again = try importing(stubs, into: &ledger)
        #expect(again == .init(created: 0, merged: 0, unchanged: 2))
        #expect(try records().map(\.id) == firstIDs)
        // And a duplicate inside one batch is read once.
        var fresh = PayrollImportLedger()
        try context.delete(model: PaycheckRecord.self)
        try context.save()
        try importing([stub("s1"), stub("s1")], into: &fresh)
        #expect(try records().count == 1)
    }

    @Test("a paycheck the person deleted is not brought back by the next import")
    func deletedStaysDeleted() throws {
        var ledger = PayrollImportLedger()
        try importing([stub("s1")], into: &ledger)
        let record = try #require(try records().first)
        context.delete(record)
        try context.save()
        try importing([stub("s1")], into: &ledger)
        #expect(try records().isEmpty)
    }

    // MARK: - De-duplication

    @Test("a typed paycheck for the same period gets only its empty fields filled")
    func manualSamePeriodFilled() throws {
        let typed = try manual(start: "2026-10-12", end: "2026-10-25", tips: 0) {
            $0.netPayCents = 120_000 // the person's own figure, different from the stub
            $0.note = "paper stub"
        }
        let before = typed.modifiedAt
        var ledger = PayrollImportLedger()
        let outcome = try importing([stub("s1", tips: 9_999)], into: &ledger)
        #expect(outcome == .init(created: 0, merged: 1, unchanged: 0))
        let all = try records()
        #expect(all.count == 1, "no second paycheck for the period")
        #expect(typed.netPayCents == 120_000, "never overwritten")
        #expect(typed.paidTipsCents == 0, "tips are never touched on a match")
        #expect(typed.note == "paper stub")
        #expect(typed.grossPayCents == 162_998)
        #expect(typed.regularWagesCents == 150_000)
        #expect(typed.overtimeWagesCents == 12_998)
        #expect(typed.taxesCents == 28_969)
        #expect(typed.modifiedAt > before, "a filled record must upload")
        #expect(ledger.entries["s1"]?.origin == .merged)
        #expect(ledger.entries["s1"]?.recordID == typed.id)
    }

    @Test("values the person entered are never overwritten, field by field")
    func enteredValuesWin() throws {
        let typed = try manual(start: "2026-10-12", end: "2026-10-25", tips: 30_000) {
            $0.grossPayCents = 1
            $0.netPayCents = 2
            $0.regularWagesCents = 3
            $0.overtimeWagesCents = 4
            $0.gratuityCents = 5
            $0.taxesCents = 6
        }
        let before = typed.modifiedAt
        var ledger = PayrollImportLedger()
        try importing([stub("s1", tips: 1, gratuity: 700)], into: &ledger)
        #expect([typed.grossPayCents, typed.netPayCents, typed.regularWagesCents,
                  typed.overtimeWagesCents, typed.gratuityCents, typed.taxesCents] == [1, 2, 3, 4, 5, 6])
        #expect(typed.paidTipsCents == 30_000)
        #expect(typed.modifiedAt == before, "nothing filled, nothing to upload")
        #expect(try records().count == 1)
    }

    @Test("a typed paycheck in the same grid period matches even when its dates differ")
    func gridPeriodMatch() throws {
        // Typed with the grid's own dates shifted a day (Oct 13 - Oct 24):
        // still the Periods list's one row for Oct 12 - Oct 25.
        let typed = try manual(start: "2026-10-13", end: "2026-10-24")
        var ledger = PayrollImportLedger()
        try importing([stub("s1")], into: &ledger)
        #expect(try records().count == 1)
        #expect(typed.grossPayCents == 162_998)
    }

    @Test("same net close to the pay date matches when the periods disagree")
    func netMatch() throws {
        // Ends Oct 27, the next grid period, but carries the stub's net and
        // sits three days before its pay date.
        let typed = try manual(start: "2026-10-26", end: "2026-10-27") { $0.netPayCents = 120_150 }
        var ledger = PayrollImportLedger()
        try importing([stub("s1")], into: &ledger)
        #expect(try records().count == 1)
        #expect(typed.grossPayCents == 162_998)

        // A different net in that spot is a different paycheck.
        try context.delete(model: PaycheckRecord.self)
        try context.save()
        try manual(start: "2026-10-26", end: "2026-10-27") { $0.netPayCents = 99 }
        var other = PayrollImportLedger()
        try importing([stub("s1")], into: &other)
        #expect(try records().count == 2)
    }

    @Test("two stubs in one grid period are two paychecks, told apart by id")
    func importedNeverMergeIntoImported() throws {
        var ledger = PayrollImportLedger()
        // A weekly payroll on a bi-weekly grid: both stubs end inside Oct 12-25.
        try importing([
            stub("w1", pay: "2026-10-23", start: "2026-10-12", end: "2026-10-18", net: 60_000),
            stub("w2", pay: "2026-10-30", start: "2026-10-19", end: "2026-10-25", net: 61_000),
        ], into: &ledger)
        let all = try records()
        #expect(all.count == 2)
        #expect(all.map(\.netPayCents) == [60_000, 61_000])
    }

    @Test("one typed paycheck absorbs at most one stub")
    func oneStubPerPaycheck() throws {
        try manual(start: "2026-10-12", end: "2026-10-25")
        var ledger = PayrollImportLedger()
        try importing([
            stub("w1", pay: "2026-10-23", start: "2026-10-12", end: "2026-10-18", net: 60_000),
            stub("w2", pay: "2026-10-30", start: "2026-10-19", end: "2026-10-25", net: 61_000),
        ], into: &ledger)
        #expect(try records().count == 2)
        #expect(ledger.entries.values.filter { $0.origin == .merged }.count == 1)
        // And a later import does not merge into it again.
        try importing([stub("w3", pay: "2026-10-30", start: "2026-10-12", end: "2026-10-25", net: 1)], into: &ledger)
        #expect(try records().count == 3)
    }

    // MARK: - Mapping

    @Test("tips and gratuity map to their own fields; unknown tips are 0")
    func tipsAndGratuity() throws {
        var ledger = PayrollImportLedger()
        try importing([
            stub("a", pay: "2026-10-30", tips: 12_345, gratuity: 678),
            stub("b", pay: "2026-11-13", start: "2026-10-26", end: "2026-11-08", tips: nil, gratuity: nil),
        ], into: &ledger)
        let all = try records()
        #expect(all.map(\.paidTipsCents) == [12_345, 0])
        #expect(all.map(\.gratuityCents) == [678, nil])
    }

    @Test("missing period dates fall back to the pay period the pay date pays for")
    func missingPeriodFallback() throws {
        var ledger = PayrollImportLedger()
        // Paid Fri Oct 30 with a five-day delay: pays for the period ending
        // Oct 25, i.e. Oct 12 - Oct 25 on the grid.
        try importing([stub("s1", start: nil, end: nil)], into: &ledger)
        let record = try #require(try records().first)
        #expect(record.periodStart == day("2026-10-12"))
        #expect(record.periodEnd == day("2026-10-25"))

        // Impossible dates (end before start) fall back the same way.
        try context.delete(model: PaycheckRecord.self)
        try context.save()
        var other = PayrollImportLedger()
        try importing([stub("s2", start: "2026-10-25", end: "2026-10-12")], into: &other)
        let fallback = try #require(try records().first)
        #expect(fallback.periodStart == day("2026-10-12"))
        #expect(fallback.periodEnd == day("2026-10-25"))
        #expect(satisfiesServerChecks(fallback))
    }

    @Test("job: the employer name picks a job only on an exact match, never invents one")
    func jobMatching() throws {
        #expect(PayrollImporter.jobTag(for: stub("x", employer: "Cafe Rosa"), jobs: jobs) == "Cafe Rosa")
        #expect(PayrollImporter.jobTag(for: stub("x", employer: "  cafe rosa "), jobs: jobs) == "Cafe Rosa")
        #expect(PayrollImporter.jobTag(for: stub("x", employer: "Cafe Rosa LLC"), jobs: jobs) == nil)
        #expect(PayrollImporter.jobTag(for: stub("x", employer: "Main"), jobs: jobs) == nil, "the primary's tag is nil")
        #expect(PayrollImporter.jobTag(for: stub("x", employer: nil), jobs: jobs) == nil)
        #expect(PayrollImporter.jobTag(for: stub("x", employer: "Cafe Rosa"), jobs: []) == nil)

        // A typed paycheck for ANOTHER job in the same period is not a match.
        try manual(start: "2026-10-12", end: "2026-10-25", job: "Cafe Rosa")
        var ledger = PayrollImportLedger()
        try importing([stub("s1", employer: "Somewhere Else")], into: &ledger)
        let all = try records()
        #expect(all.count == 2)
        #expect(Set(all.map(\.jobName)) == [nil, "Cafe Rosa"])
        // ...and one for the SAME job is.
        try importing([stub("s2", employer: "Cafe Rosa")], into: &ledger)
        #expect(try records().count == 2)
        #expect(ledger.entries["s2"]?.origin == .merged)
    }

    @Test("values the server would refuse are dropped, never written")
    func serverChecksModelled() throws {
        var ledger = PayrollImportLedger()
        try importing([stub("neg", gross: -5, net: Int(Int32.max) + 1, regular: -1, overtime: 0, tips: -300, gratuity: -2, taxes: -9)], into: &ledger)
        let record = try #require(try records().first)
        #expect(satisfiesServerChecks(record))
        #expect(record.grossPayCents == nil)
        #expect(record.netPayCents == nil)
        #expect(record.regularWagesCents == nil)
        #expect(record.overtimeWagesCents == 0, "an observed zero stays a zero")
        #expect(record.paidTipsCents == 0)
        #expect(record.gratuityCents == nil)
        #expect(record.taxesCents == nil)
    }

    @Test("a stub with no readable pay date is skipped")
    func unreadablePayDate() throws {
        var ledger = PayrollImportLedger()
        let outcome = try importing([stub("bad", pay: "not-a-day", start: nil, end: nil)], into: &ledger)
        #expect(outcome == .init())
        #expect(try records().isEmpty)
        #expect(ledger.entries.isEmpty)
    }

    // MARK: - Remove imported

    @Test("remove imported deletes only untouched imports; edited, typed and filled stay")
    func removeImportedLeavesOthers() throws {
        let typed = try manual(start: "2026-08-17", end: "2026-08-30") // never matched
        let filled = try manual(start: "2026-10-12", end: "2026-10-25")  // matched by s-oct
        var ledger = PayrollImportLedger()
        try importing([
            stub("s-oct"),
            stub("s-nov", pay: "2026-11-13", start: "2026-10-26", end: "2026-11-08"),
            stub("s-sep", pay: "2026-09-18", start: "2026-08-31", end: "2026-09-13"),
        ], into: &ledger)
        ledger.importConfirmed = true
        let all = try records()
        #expect(all.count == 4)
        let untouched = try #require(all.first { $0.periodStart == day("2026-10-26") })
        let edited = try #require(all.first { $0.periodStart == day("2026-08-31") })
        edited.netPayCents = 1
        edited.touch(at: Date(timeIntervalSince1970: 1_800_000_500))
        try context.save()

        // A sync round trip moves modifiedAt by under a millisecond; that is
        // not an edit.
        untouched.modifiedAt = untouched.modifiedAt.addingTimeInterval(0.0004)
        try context.save()

        var deleted: [UUID] = []
        let removed = try PayrollImporter.removeImported(in: context, ledger: &ledger) { id, context in
            deleted.append(id)
            let record = try context.fetch(FetchDescriptor<PaycheckRecord>(predicate: #Predicate { $0.id == id })).first
            if let record { context.delete(record) }
            try context.save()
        }
        #expect(removed == 1)
        #expect(deleted == [untouched.id])
        let left = Set(try records().map(\.id))
        #expect(left == [typed.id, filled.id, edited.id])
        #expect(ledger.entries["s-nov"] == nil, "a removed stub may be imported again, after a preview")
        #expect(ledger.entries["s-sep"] != nil)
        #expect(ledger.entries["s-oct"]?.origin == .merged)
        #expect(ledger.importConfirmed == false, "nothing comes back without a preview")

        // A plain re-import (no preview) would bring s-nov back; the ledger
        // says so honestly, and nothing else duplicates.
        try importing([stub("s-oct"), stub("s-nov", pay: "2026-11-13", start: "2026-10-26", end: "2026-11-08")], into: &ledger)
        #expect(try records().count == 4)
    }

    // MARK: - Preview

    @Test("the preview counts what an import would do and writes nothing")
    func previewWritesNothing() throws {
        try manual(start: "2026-10-12", end: "2026-10-25")
        let items = PayrollImporter.plan(
            statements: [stub("s1"), stub("s2", pay: "2026-11-13", start: "2026-10-26", end: "2026-11-08")],
            records: try records(), ledger: PayrollImportLedger(), jobs: jobs, calculator: scope)
        let preview = PayrollConnection.preview(of: items)
        #expect(preview.newCount == 1)
        #expect(preview.filledCount == 1)
        #expect(preview.firstPayDate == "2026-10-30")
        #expect(preview.lastPayDate == "2026-11-13")
        #expect(try records().count == 1)
        #expect(try records().first?.grossPayCents == nil)
    }

    // MARK: - Ledger file

    @Test("the ledger is per account, and an unreadable file is not read as empty")
    func ledgerStore() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PayrollImportLedgerStore(url: url)
        #expect(try store.load() == PayrollImportLedger(), "no file yet is an empty ledger")

        let alice = UUID()
        var ledger = PayrollImportLedger(userID: alice)
        ledger.entries["s1"] = .init(recordID: UUID(), origin: .created, recordModifiedAt: .now,
                                     linkID: "l", payDate: "2026-10-30", hours: nil, deductions: [])
        try store.save(ledger)
        #expect(try store.load() == ledger)
        #expect(try store.load().scoped(to: alice) == ledger)
        #expect(try store.load().scoped(to: UUID()).entries.isEmpty, "another account starts empty")

        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
    }
}
