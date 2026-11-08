import Foundation
import PaydayCore
import SwiftData

/// Pay stubs from a connected payroll account -> `PaycheckRecord`s.
///
/// The importer writes what the stub says into the fields a person would
/// have typed from the same paper stub, through the same commit boundary the
/// paycheck sheet uses, so an imported paycheck syncs and reconciles exactly
/// like a typed one. It computes nothing for display: the one sum it makes is
/// the stub's tax lines into `taxesCents`, and that sum is made on the server
/// (`taxes_cents`).
///
/// ## The rule that matters most
///
/// An imported stub never makes a second paycheck for a period the person
/// already has. Before creating, it looks for a paycheck of the same job that
/// is not already tied to another stub, in this order:
///
/// 1. the same period: start and end on the same civil days;
/// 2. the same pay period on the person's own grid, the way the Periods list
///    pairs a paycheck with a period (`HistoryEarnings.paycheck`: its
///    `periodEnd` falls inside the period that holds the stub's end);
/// 3. the same net pay, with its period end within one stub-period of the
///    pay date.
///
/// A match is FILLED, never overwritten: only fields that are nil there take
/// the stub's value. `paidTipsCents` is never touched on a match, because it
/// cannot be nil and a 0 there may be the person's own figure.
enum PayrollImporter {
    /// The database's own limits (`paycheck_records` CHECKs: every cents
    /// column >= 0, `integer` width, `period_end >= period_start`). A value
    /// outside them would make the row's upload fail forever, so it is
    /// dropped (left nil, unknown) rather than written.
    static let representableCents: ClosedRange<Int> = 0...Int(Int32.max)

    /// A user edit moves `modifiedAt` to "now"; a sync round trip can move it
    /// by under a millisecond (the wire format is millisecond ISO). One second
    /// separates the two with room to spare.
    static let editTolerance: TimeInterval = 1

    struct Fields: Equatable {
        var periodStart: Date
        var periodEnd: Date
        var jobName: String?
        var paidTipsCents: Int
        var grossPayCents: Int?
        var netPayCents: Int?
        var regularWagesCents: Int?
        var overtimeWagesCents: Int?
        var gratuityCents: Int?
        var taxesCents: Int?
    }

    /// The fields a match takes from the stub: only those empty on the
    /// record. All nil means the match gains nothing.
    struct Fill: Equatable {
        var grossPayCents: Int?
        var netPayCents: Int?
        var regularWagesCents: Int?
        var overtimeWagesCents: Int?
        var gratuityCents: Int?
        var taxesCents: Int?

        var isEmpty: Bool {
            [grossPayCents, netPayCents, regularWagesCents, overtimeWagesCents, gratuityCents, taxesCents]
                .allSatisfy { $0 == nil }
        }
    }

    enum Action: Equatable {
        case create(Fields)
        case merge(recordID: UUID, fill: Fill)
        /// In the ledger already: imported before, or imported and then
        /// deleted by the person. Either way, not again.
        case alreadyImported
    }

    struct Item: Equatable {
        let statement: PayrollStatement
        let action: Action
    }

    struct Outcome: Equatable {
        var created = 0
        var merged = 0
        var unchanged = 0
    }

    // MARK: - Job and period

    /// Nil (the primary job) unless the stub's employer name is one of the
    /// person's jobs, compared trimmed and case-insensitively. A provider
    /// name ("Toast") is a payroll company, not a job, and is never matched.
    /// No job is ever created here.
    static func jobTag(for statement: PayrollStatement, jobs: [JobPolicy]) -> String? {
        guard let key = ShiftRole.key(statement.employerName) else { return nil }
        return jobs.first { ShiftRole.key($0.name) == key }?.tag
    }

    /// The period the paycheck is saved against: the stub's own dates as
    /// civil days in the job's payroll zone, or, when the stub has none (or
    /// impossible ones), the job's pay period that the pay date pays for.
    static func period(for statement: PayrollStatement, calculator: PayPeriodCalculator) -> PayPeriod? {
        let zone = calculator.payrollTimeZone
        guard let payDay = CivilDay(iso: statement.payDate) else { return nil }
        if let start = statement.periodStart.flatMap(CivilDay.init(iso:)),
           let end = statement.periodEnd.flatMap(CivilDay.init(iso:)),
           start <= end {
            return PayPeriod(start: start.date(in: zone), end: end.date(in: zone))
        }
        // The pay date lands `payDelayDays` after the period's last day, so
        // the period it pays for is the one holding that last day.
        let lastWorkedDay = payDay.adding(days: -calculator.schedule.resolvedPayDelayDays)
        return calculator.period(containing: lastWorkedDay.date(in: zone))
    }

    static func fields(
        for statement: PayrollStatement,
        jobs: [JobPolicy],
        calculator: (String?) -> PayPeriodCalculator
    ) -> Fields? {
        let job = jobTag(for: statement, jobs: jobs)
        guard let period = period(for: statement, calculator: calculator(job)) else { return nil }
        return Fields(
            periodStart: period.start,
            periodEnd: period.end,
            jobName: ShiftRole.normalized(job),
            paidTipsCents: representable(statement.tipsCents) ?? 0,
            grossPayCents: representable(statement.grossPayCents),
            netPayCents: representable(statement.netPayCents),
            regularWagesCents: representable(statement.regularCents),
            overtimeWagesCents: representable(statement.overtimeCents),
            gratuityCents: representable(statement.gratuityCents),
            taxesCents: representable(statement.taxesCents)
        )
    }

    static func representable(_ cents: Int?) -> Int? {
        guard let cents, representableCents.contains(cents) else { return nil }
        return cents
    }

    // MARK: - Plan

    /// What importing `statements` would do, without doing it. The preview
    /// shows this, and `apply` performs exactly this.
    static func plan(
        statements: [PayrollStatement],
        records: [PaycheckRecord],
        ledger: PayrollImportLedger,
        jobs: [JobPolicy],
        calculator: (String?) -> PayPeriodCalculator
    ) -> [Item] {
        // Records already tied to a stub (made by one, or merged with one)
        // are never matched again: one stub per paycheck. Two stubs from the
        // same payroll are told apart by their ids, never by period.
        var claimed = Set(ledger.entries.values.map(\.recordID))
        var seen: Set<String> = []
        var items: [Item] = []
        let ordered = statements.sorted { ($0.payDate, $0.sourceID) < ($1.payDate, $1.sourceID) }
        for statement in ordered {
            guard seen.insert(statement.sourceID).inserted else { continue }
            if ledger.entries[statement.sourceID] != nil {
                items.append(Item(statement: statement, action: .alreadyImported))
                continue
            }
            guard let fields = fields(for: statement, jobs: jobs, calculator: calculator) else { continue }
            let candidates = records.filter {
                !claimed.contains($0.id) && ShiftRole.key($0.jobName) == ShiftRole.key(fields.jobName)
            }
            if let match = match(fields, statement: statement, in: candidates, calculator: calculator(fields.jobName)) {
                claimed.insert(match.id)
                items.append(Item(statement: statement, action: .merge(recordID: match.id, fill: fill(match, from: fields))))
            } else {
                items.append(Item(statement: statement, action: .create(fields)))
            }
        }
        return items
    }

    private static func match(
        _ fields: Fields,
        statement: PayrollStatement,
        in candidates: [PaycheckRecord],
        calculator: PayPeriodCalculator
    ) -> PaycheckRecord? {
        let zone = calculator.payrollTimeZone
        let start = CivilDay(fields.periodStart, in: zone)
        let end = CivilDay(fields.periodEnd, in: zone)
        let stable: (PaycheckRecord, PaycheckRecord) -> Bool = {
            ($0.periodEnd, $0.id.uuidString) < ($1.periodEnd, $1.id.uuidString)
        }
        // 1. Same period, day for day.
        if let exact = candidates.filter({
            CivilDay($0.periodStart, in: zone) == start && CivilDay($0.periodEnd, in: zone) == end
        }).min(by: stable) {
            return exact
        }
        // 2. Same period on the person's grid.
        let grid = calculator.period(containing: fields.periodEnd)
        if let sameGrid = candidates.filter({ $0.periodEnd >= grid.start && $0.periodEnd <= grid.end }).min(by: stable) {
            return sameGrid
        }
        // 3. Same net, close to the pay date.
        guard let net = fields.netPayCents, let payDay = CivilDay(iso: statement.payDate) else { return nil }
        let periodDays = CivilDay.daysBetween(start, end) + 1
        return candidates.filter {
            $0.netPayCents == net && abs(CivilDay.daysBetween(CivilDay($0.periodEnd, in: zone), payDay)) <= periodDays
        }.min(by: stable)
    }

    private static func fill(_ record: PaycheckRecord, from fields: Fields) -> Fill {
        Fill(
            grossPayCents: record.grossPayCents == nil ? fields.grossPayCents : nil,
            netPayCents: record.netPayCents == nil ? fields.netPayCents : nil,
            regularWagesCents: record.regularWagesCents == nil ? fields.regularWagesCents : nil,
            overtimeWagesCents: record.overtimeWagesCents == nil ? fields.overtimeWagesCents : nil,
            gratuityCents: record.gratuityCents == nil ? fields.gratuityCents : nil,
            taxesCents: record.taxesCents == nil ? fields.taxesCents : nil
        )
    }

    // MARK: - Apply

    /// Imports `statements` into `context` in one transaction, then records
    /// what happened in `ledger`. The ledger moves only after the save
    /// succeeded: a failed save leaves both the store and the ledger as they
    /// were, so the next attempt sees the same stubs as new.
    @MainActor
    @discardableResult
    static func apply(
        statements: [PayrollStatement],
        in context: ModelContext,
        ledger: inout PayrollImportLedger,
        jobs: [JobPolicy],
        calculator: (String?) -> PayPeriodCalculator,
        now: Date = .now
    ) throws -> Outcome {
        let records = try context.fetch(FetchDescriptor<PaycheckRecord>())
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = plan(statements: statements, records: records, ledger: ledger, jobs: jobs, calculator: calculator)
        var outcome = Outcome()
        var written: [(PayrollStatement, PaycheckRecord, PayrollImportLedger.Origin)] = []

        guard items.contains(where: { $0.action != .alreadyImported }) else {
            outcome.unchanged = items.count
            return outcome
        }

        try ShiftCommands.commit(in: context) {
            for item in items {
                switch item.action {
                case .alreadyImported:
                    outcome.unchanged += 1
                case .create(let fields):
                    let record = PaycheckRecord(
                        periodStart: fields.periodStart,
                        periodEnd: fields.periodEnd,
                        paidTipsCents: fields.paidTipsCents,
                        grossPayCents: fields.grossPayCents,
                        netPayCents: fields.netPayCents,
                        regularWagesCents: fields.regularWagesCents,
                        overtimeWagesCents: fields.overtimeWagesCents,
                        gratuityCents: fields.gratuityCents,
                        taxesCents: fields.taxesCents
                    )
                    record.jobName = fields.jobName
                    record.touch(at: now)
                    context.insert(record)
                    written.append((item.statement, record, .created))
                    outcome.created += 1
                case .merge(let recordID, let fill):
                    guard let record = byID[recordID] else { continue }
                    if !fill.isEmpty {
                        if let value = fill.grossPayCents { record.grossPayCents = value }
                        if let value = fill.netPayCents { record.netPayCents = value }
                        if let value = fill.regularWagesCents { record.regularWagesCents = value }
                        if let value = fill.overtimeWagesCents { record.overtimeWagesCents = value }
                        if let value = fill.gratuityCents { record.gratuityCents = value }
                        if let value = fill.taxesCents { record.taxesCents = value }
                        // An edit to a record that may already be synced: it
                        // uploads only if this clock moves.
                        record.touch(at: now)
                    }
                    written.append((item.statement, record, .merged))
                    outcome.merged += 1
                }
            }
        }

        for (statement, record, origin) in written {
            ledger.entries[statement.sourceID] = PayrollImportLedger.Entry(
                recordID: record.id,
                origin: origin,
                recordModifiedAt: record.modifiedAt,
                linkID: statement.linkID,
                payDate: statement.payDate,
                hours: statement.hours,
                deductions: statement.deductions
            )
        }
        ledger.lastSyncedAt = now
        return outcome
    }

    // MARK: - Remove imported

    /// The records "Remove imported paychecks" deletes: made by the import
    /// AND unchanged since. A record the person edited, a record they typed,
    /// and a typed record the import only filled in are all left alone.
    static func removableRecordIDs(records: [PaycheckRecord], ledger: PayrollImportLedger) -> Set<UUID> {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: Set<UUID> = []
        for entry in ledger.entries.values where entry.origin == .created {
            guard let record = byID[entry.recordID] else { continue }
            if abs(record.modifiedAt.timeIntervalSince(entry.recordModifiedAt)) <= editTolerance {
                result.insert(record.id)
            }
        }
        return result
    }

    /// Deletes the removable records through the normal delete path (row
    /// first, then the server deletion queue), and forgets their stubs so a
    /// later, previewed import can bring them back. Returns how many went.
    /// Edited records keep their ledger entry: they are still imported ones.
    @MainActor
    static func removeImported(
        in context: ModelContext,
        ledger: inout PayrollImportLedger,
        delete: @MainActor (UUID, ModelContext) throws -> Void = DeferredPaycheckRemoval.commitDelete(id:in:)
    ) throws -> Int {
        let records = try context.fetch(FetchDescriptor<PaycheckRecord>())
        let removable = removableRecordIDs(records: records, ledger: ledger)
        var removed = 0
        for id in removable.sorted(by: { $0.uuidString < $1.uuidString }) {
            try delete(id, context)
            removed += 1
            for (sourceID, entry) in ledger.entries where entry.recordID == id {
                ledger.entries[sourceID] = nil
            }
        }
        // Nothing comes back on its own after this: the next import is a
        // previewed one again.
        ledger.importConfirmed = false
        return removed
    }
}
