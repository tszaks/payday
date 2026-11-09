import CryptoKit
import Foundation
import PaydayCore
import SwiftData

/// Pay stubs from a connected payroll account -> `PaycheckRecord`s.
///
/// The importer writes what the stub says into the fields a person would
/// have typed from the same paper stub, through the same commit boundary the
/// paycheck sheet uses, so an imported paycheck syncs and reconciles exactly
/// like a typed one. It computes nothing itself: what the stub's lines mean
/// (tips, gratuity, taxes) comes from `PayStubFigures` in PaydayCore.
///
/// ## The rule that matters most
///
/// An imported stub never makes a second paycheck for a period the person
/// already has. Before creating, it looks for a paycheck of the same job that
/// is not already tied to another stub, in this order:
///
/// 0. the paycheck this same stub made before, on this or another device:
///    its id is derived from the account and the stub (`recordID`);
/// 1. the same period: start and end on the same civil days;
/// 2. the same pay period on the person's own grid;
/// 3. the same net pay, near the pay date.
///
/// Each of 1-3 runs over the whole batch before the next (`MatchStep`).
/// When two stubs could take the same paycheck in one step, the paycheck
/// goes to the stub whose net (then gross) it already holds (`Evidence`);
/// date order breaks only a tie that the amounts leave.
/// Steps 2 and 3 also need the two periods to share at least one day. Two
/// weekly checks inside one biweekly grid period are two paychecks, and a
/// typed check for one week must never take the other week's stub.
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

    /// The id a paycheck made from this stub gets: the same on every device
    /// signed in to the account, so two phones importing the same new stub
    /// at once upload one row (the upsert is keyed on id), and a phone that
    /// lost its ledger recognizes the paychecks it made. A name-based UUID
    /// (RFC 9562 version 8 layout) over SHA-256.
    static func recordID(sourceID: String, userID: UUID?) -> UUID {
        let key = "payday.payroll-import|\(userID?.uuidString.lowercased() ?? "")|\(sourceID)"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func fields(
        for statement: PayrollStatement,
        jobs: [JobPolicy],
        calculator: (String?) -> PayPeriodCalculator
    ) -> Fields? {
        let job = jobTag(for: statement, jobs: jobs)
        guard let period = period(for: statement, calculator: calculator(job)) else { return nil }
        let figures = statement.figures
        return Fields(
            periodStart: period.start,
            periodEnd: period.end,
            jobName: ShiftRole.normalized(job),
            paidTipsCents: representable(figures.paidTipsCents) ?? 0,
            grossPayCents: representable(statement.grossPayCents),
            netPayCents: representable(statement.netPayCents),
            regularWagesCents: representable(statement.regularCents),
            overtimeWagesCents: representable(statement.overtimeCents),
            gratuityCents: representable(figures.gratuityCents),
            taxesCents: representable(figures.taxesCents)
        )
    }

    static func representable(_ cents: Int?) -> Int? {
        guard let cents, representableCents.contains(cents) else { return nil }
        return cents
    }

    // MARK: - Plan

    /// The three ways a stub can find a paycheck the person already has,
    /// strongest first. Each runs over the WHOLE batch before the next one
    /// starts, so a weaker match can never take a paycheck that a stronger
    /// one (possibly a later stub's) would have taken. With a steady wage
    /// every stub has the same net, and an amount-only match made first
    /// would give one period's paycheck to the period before it.
    enum MatchStep: CaseIterable {
        /// Start and end on the same civil days.
        case samePeriod
        /// The same pay period on the person's grid, the way the Periods
        /// list pairs a paycheck with a period (`HistoryEarnings.paycheck`:
        /// its `periodEnd` falls inside the period that holds the stub's
        /// end), and sharing at least one day with the stub.
        case sameGrid
        /// The same net pay, a period end within one stub-period of the pay
        /// date, and at least one day shared with the stub.
        case sameNet
    }

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
        let present = Set(records.map(\.id))
        var seen: Set<String> = []
        var decided: [String: Action] = [:]
        var open: [(statement: PayrollStatement, fields: Fields)] = []
        let ordered = statements
            .sorted { ($0.payDate, $0.sourceID) < ($1.payDate, $1.sourceID) }
            .filter { seen.insert($0.sourceID).inserted }

        for statement in ordered {
            if ledger.entries[statement.sourceID] != nil {
                decided[statement.sourceID] = .alreadyImported
                continue
            }
            // Made by this stub before, on this phone (ledger since lost) or on
            // another one. Already here: record it, change nothing. Marked
            // merged, not created, because whether the person edited it since
            // is unknown, and "Remove imported" deletes only what it knows
            // is untouched.
            let ownID = recordID(sourceID: statement.sourceID, userID: ledger.userID)
            if present.contains(ownID), !claimed.contains(ownID) {
                claimed.insert(ownID)
                decided[statement.sourceID] = .merge(recordID: ownID, fill: Fill())
                continue
            }
            guard let fields = fields(for: statement, jobs: jobs, calculator: calculator) else { continue }
            open.append((statement, fields))
        }

        for step in MatchStep.allCases {
            // Every (stub, paycheck) pair this step allows, then the best
            // pairs first. When two stubs could take one paycheck (two weekly
            // stubs inside one biweekly grid period), the paycheck goes to
            // the stub whose amounts it already holds, not to the earlier one.
            var pairs: [(order: Int, statement: PayrollStatement, fields: Fields, record: PaycheckRecord)] = []
            for (order, (statement, fields)) in open.enumerated() where decided[statement.sourceID] == nil {
                let candidates = records.filter {
                    !claimed.contains($0.id) && ShiftRole.key($0.jobName) == ShiftRole.key(fields.jobName)
                }
                for record in matches(fields, statement: statement, step: step, in: candidates, calculator: calculator(fields.jobName)) {
                    pairs.append((order, statement, fields, record))
                }
            }
            pairs.sort { a, b in
                let ea = Evidence(a.record, a.fields), eb = Evidence(b.record, b.fields)
                if ea != eb { return ea > eb }
                if a.order != b.order { return a.order < b.order }
                return (a.record.periodEnd, a.record.id.uuidString) < (b.record.periodEnd, b.record.id.uuidString)
            }
            for pair in pairs where decided[pair.statement.sourceID] == nil && !claimed.contains(pair.record.id) {
                claimed.insert(pair.record.id)
                decided[pair.statement.sourceID] = .merge(recordID: pair.record.id, fill: fill(pair.record, from: pair.fields))
            }
        }

        return ordered.compactMap { statement in
            if let action = decided[statement.sourceID] { return Item(statement: statement, action: action) }
            guard let fields = open.first(where: { $0.statement.sourceID == statement.sourceID })?.fields else { return nil }
            return Item(statement: statement, action: .create(fields))
        }
    }

    /// How strongly a paycheck's own amounts say it is this stub: the same
    /// net pay first, then the same gross. Compared only to break a tie
    /// between pairs a step already allows; it never makes a match.
    struct Evidence: Comparable {
        let sameNet: Bool
        let sameGross: Bool

        init(_ record: PaycheckRecord, _ fields: Fields) {
            sameNet = record.netPayCents != nil && record.netPayCents == fields.netPayCents
            sameGross = record.grossPayCents != nil && record.grossPayCents == fields.grossPayCents
        }

        static func < (a: Evidence, b: Evidence) -> Bool {
            (a.sameNet ? 1 : 0, a.sameGross ? 1 : 0) < (b.sameNet ? 1 : 0, b.sameGross ? 1 : 0)
        }
    }

    /// The paychecks `step` allows this stub to take.
    private static func matches(
        _ fields: Fields,
        statement: PayrollStatement,
        step: MatchStep,
        in candidates: [PaycheckRecord],
        calculator: PayPeriodCalculator
    ) -> [PaycheckRecord] {
        let zone = calculator.payrollTimeZone
        let start = CivilDay(fields.periodStart, in: zone)
        let end = CivilDay(fields.periodEnd, in: zone)
        // Past an exact match the dates differ, so the two periods must at
        // least share a day: adjacent weekly checks are different paychecks.
        let overlapping = candidates.filter {
            CivilDay($0.periodStart, in: zone) <= end && CivilDay($0.periodEnd, in: zone) >= start
        }
        switch step {
        case .samePeriod:
            return candidates.filter {
                CivilDay($0.periodStart, in: zone) == start && CivilDay($0.periodEnd, in: zone) == end
            }
        case .sameGrid:
            let grid = calculator.period(containing: fields.periodEnd)
            return overlapping.filter { $0.periodEnd >= grid.start && $0.periodEnd <= grid.end }
        case .sameNet:
            guard let net = fields.netPayCents, let payDay = CivilDay(iso: statement.payDate) else { return [] }
            let periodDays = CivilDay.daysBetween(start, end) + 1
            return overlapping.filter {
                $0.netPayCents == net && abs(CivilDay.daysBetween(CivilDay($0.periodEnd, in: zone), payDay)) <= periodDays
            }
        }
    }

    /// True when two or more stubs for one job fall in the same pay period
    /// of that job's schedule: the payroll pays more often than the schedule
    /// set in Payday (weekly stubs, biweekly schedule). Each stub still
    /// becomes its own paycheck; the preview says so, so the person can fix
    /// their pay schedule. Only dates are compared here, no amounts.
    static func paysMoreOftenThanSchedule(
        statements: [PayrollStatement],
        jobs: [JobPolicy],
        calculator: (String?) -> PayPeriodCalculator
    ) -> Bool {
        var seen: Set<String> = []
        for statement in statements {
            guard let fields = fields(for: statement, jobs: jobs, calculator: calculator) else { continue }
            let grid = calculator(fields.jobName).period(containing: fields.periodEnd)
            let key = "\(ShiftRole.key(fields.jobName) ?? "")|\(grid.start.timeIntervalSince1970)"
            if !seen.insert(key).inserted { return true }
        }
        return false
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
            // Nothing to write, but the check itself succeeded: "Last
            // synced" means the last time Payday read the payroll.
            outcome.unchanged = items.count
            ledger.lastSyncedAt = now
            return outcome
        }

        try ShiftCommands.commit(in: context) {
            for item in items {
                switch item.action {
                case .alreadyImported:
                    outcome.unchanged += 1
                case .create(let fields):
                    let record = PaycheckRecord(
                        id: recordID(sourceID: item.statement.sourceID, userID: ledger.userID),
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
        // Off FIRST: if a deletion below fails part way, the ones already
        // gone must not come back on the next automatic import. The next
        // import is a previewed one again.
        ledger.importConfirmed = false
        var removed = 0
        for id in removable.sorted(by: { $0.uuidString < $1.uuidString }) {
            try delete(id, context)
            removed += 1
            for (sourceID, entry) in ledger.entries where entry.recordID == id {
                ledger.entries[sourceID] = nil
            }
        }
        return removed
    }
}
