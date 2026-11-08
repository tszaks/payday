import Foundation
import Observation
import PaydayCore
import SwiftData

/// What an import needs to know about the person's setup: their jobs, and
/// each job's pay-period calendar. Built from the live stores at the call
/// site so the importer itself reads no global state.
struct PayrollImportScope {
    let jobs: [JobPolicy]
    let calculator: (String?) -> PayPeriodCalculator

    @MainActor
    init(policyStore: PolicyStore, scheduleStore: PayScheduleStore) {
        let policies = policyStore.policies
        let schedule = scheduleStore.schedule
        self.jobs = policies.jobs
        self.calculator = { PolicyStore.calculator(forJob: $0, policies: policies, primarySchedule: schedule) }
    }

    init(jobs: [JobPolicy], calculator: @escaping (String?) -> PayPeriodCalculator) {
        self.jobs = jobs
        self.calculator = calculator
    }
}

/// "Connect payroll", the state behind the connection screen and the
/// automatic re-import. One per app, like `DeferredPaycheckRemoval`.
///
/// Every write to paychecks goes through `PayrollImporter`; this type only
/// sequences network calls, keeps the preview, and saves the ledger.
@MainActor
@Observable
final class PayrollConnection {
    static let shared = PayrollConnection()

    /// App-open imports run at most this often. Payroll changes once per pay
    /// period; a few checks a day finds a new stub the day it posts.
    static let automaticInterval: TimeInterval = 6 * 60 * 60

    /// What the preview shows before anything is written.
    struct Preview: Equatable {
        let newCount: Int
        let filledCount: Int
        let firstPayDate: String?
        let lastPayDate: String?
        /// Newest first, a handful, for the person to recognize.
        let rows: [PayrollStatement]

        var isEmpty: Bool { newCount == 0 && filledCount == 0 }
    }

    private(set) var status: PayrollStatus?
    private(set) var ledger = PayrollImportLedger()
    private(set) var preview: Preview?
    private(set) var isWorking = false
    /// One line for the screen: the last thing that went wrong, or what a
    /// finished action did.
    var message: String?

    private var pendingStatements: [PayrollStatement] = []
    /// Set when the ledger file exists but could not be read. Imports stop
    /// until it reads again; importing against an empty ledger would bring
    /// every stub in a second time.
    private(set) var ledgerUnreadable = false
    private let api: PayrollConnectAPI
    private let store: PayrollImportLedgerStore
    private let now: () -> Date

    init(
        api: PayrollConnectAPI = PayrollConnectService(),
        store: PayrollImportLedgerStore = .shared,
        now: @escaping () -> Date = { .now }
    ) {
        self.api = api
        self.store = store
        self.now = now
    }

    var environment: PayrollEnvironment? { status?.environment }
    var connectedLinks: [PayrollLink] { status?.links.filter(\.isConnected) ?? [] }
    var isConnected: Bool { !connectedLinks.isEmpty }

    /// Hours and deduction lines for the stubs imported so far, newest
    /// first. `PaycheckRecord` has no fields for these, so they live here.
    var importedStubs: [(sourceID: String, entry: PayrollImportLedger.Entry)] {
        ledger.entries.map { ($0.key, $0.value) }.sorted { $0.entry.payDate > $1.entry.payDate }
    }

    // MARK: - Ledger

    /// Loads the ledger for the signed-in account. Call before any action.
    func prepare(userID: UUID?) {
        // Mid-import the in-memory ledger is ahead of the file; reloading
        // would throw that away.
        guard !isWorking else { return }
        do {
            ledger = try store.load().scoped(to: userID)
            ledgerUnreadable = false
        } catch {
            ledgerUnreadable = true
        }
    }

    private func saveLedger() {
        guard !ledgerUnreadable else { return }
        do {
            try store.save(ledger)
        } catch {
            message = "Payday couldn't save what it imported. Imported paychecks are safe."
        }
    }

    // MARK: - Status and connect

    func refreshStatus() async {
        do {
            let status = try await api.status()
            self.status = status
            ledger.hasConnection = status.links.contains(where: \.isConnected)
            saveLedger()
        } catch {
            message = Self.describe(error)
        }
    }

    /// A Truv Bridge token for the sign-in screen, or nil with `message` set.
    func bridgeToken() async -> String? {
        isWorking = true
        defer { isWorking = false }
        do {
            let token = try await api.bridgeToken()
            return token.bridgeToken
        } catch {
            message = Self.describe(error)
            return nil
        }
    }

    /// Bridge finished: confirm the link on the server, then fetch a preview.
    /// Nothing is imported until the person taps Import.
    func finishConnect(publicToken: String, context: ModelContext, scope: PayrollImportScope) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await api.exchange(publicToken: publicToken)
        } catch {
            message = Self.describe(error)
            return
        }
        await refreshStatus()
        ledger.importConfirmed = false
        saveLedger()
        await loadPreview(context: context, scope: scope)
    }

    // MARK: - Preview and import

    func loadPreview(context: ModelContext, scope: PayrollImportScope) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await api.paystubs(since: nil)
            pendingStatements = result.paystubs
            let records = try context.fetch(FetchDescriptor<PaycheckRecord>())
            preview = Self.preview(of: PayrollImporter.plan(
                statements: result.paystubs, records: records, ledger: ledger,
                jobs: scope.jobs, calculator: scope.calculator))
        } catch {
            message = Self.describe(error)
        }
    }

    static func preview(of items: [PayrollImporter.Item]) -> Preview {
        var newCount = 0
        var filledCount = 0
        var touched: [PayrollStatement] = []
        for item in items {
            switch item.action {
            case .create:
                newCount += 1
                touched.append(item.statement)
            case .merge(_, let fill):
                if !fill.isEmpty {
                    filledCount += 1
                    touched.append(item.statement)
                }
            case .alreadyImported:
                break
            }
        }
        let byDate = touched.sorted { $0.payDate > $1.payDate }
        return Preview(
            newCount: newCount,
            filledCount: filledCount,
            firstPayDate: byDate.last?.payDate,
            lastPayDate: byDate.first?.payDate,
            rows: Array(byDate.prefix(4))
        )
    }

    /// The Import button: writes the previewed stubs and turns on automatic
    /// imports.
    func confirmImport(context: ModelContext, scope: PayrollImportScope, onWrite: () -> Void = {}) {
        guard !ledgerUnreadable else {
            message = "Payday couldn't read its import record. Nothing was imported."
            return
        }
        do {
            let outcome = try PayrollImporter.apply(
                statements: pendingStatements, in: context, ledger: &ledger,
                jobs: scope.jobs, calculator: scope.calculator, now: now())
            ledger.importConfirmed = true
            saveLedger()
            preview = nil
            pendingStatements = []
            message = Self.summary(of: outcome)
            if outcome.created + outcome.merged > 0 { onWrite() }
        } catch {
            message = "Couldn't save. Nothing was imported."
        }
    }

    /// App open and pull-to-refresh. Runs only after the first import was
    /// confirmed; `force` skips the six-hour spacing (pull-to-refresh).
    func importIfDue(context: ModelContext, scope: PayrollImportScope, force: Bool = false, onWrite: () -> Void = {}) async {
        guard ledger.importConfirmed, ledger.hasConnection, !ledgerUnreadable, !isWorking else { return }
        let now = now()
        if !force, let last = ledger.lastAutomaticAttemptAt, now.timeIntervalSince(last) < Self.automaticInterval {
            return
        }
        ledger.lastAutomaticAttemptAt = now
        saveLedger()
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await api.paystubs(since: nil)
            status = PayrollStatus(environment: result.environment, links: result.links)
            ledger.hasConnection = result.links.contains(where: \.isConnected)
            let outcome = try PayrollImporter.apply(
                statements: result.paystubs, in: context, ledger: &ledger,
                jobs: scope.jobs, calculator: scope.calculator, now: now)
            saveLedger()
            if outcome.created + outcome.merged > 0 { onWrite() }
        } catch {
            // Quiet on app open: the next attempt is six hours away and the
            // connection screen shows the last sync time.
            if force { message = Self.describe(error) }
        }
    }

    /// "Check for new paystubs": asks Truv to read the payroll account again.
    /// The new stubs arrive a few minutes later and come in on the next
    /// import.
    func requestRefresh(link: PayrollLink) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.refresh(linkID: link.linkID)
            message = "Checking. New pay stubs show up in a few minutes."
            await refreshStatus()
        } catch let error as PayrollConnectError where error.code == "refresh_throttled" {
            message = "Payday checked this payroll in the last day. New pay stubs still come in on their own."
        } catch {
            message = Self.describe(error)
        }
    }

    func disconnect(link: PayrollLink) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.disconnect(linkID: link.linkID)
            message = "Disconnected. Imported paychecks stay."
            preview = nil
            pendingStatements = []
            await refreshStatus()
        } catch {
            message = Self.describe(error)
        }
    }

    func removeImported(context: ModelContext, onWrite: () -> Void = {}) {
        guard !ledgerUnreadable else {
            message = "Payday couldn't read its import record. Nothing was removed."
            return
        }
        defer { saveLedger() }
        do {
            let removed = try PayrollImporter.removeImported(in: context, ledger: &ledger)
            message = removed == 0
                ? "Nothing to remove. Paychecks you edited stay."
                : "Removed \(removed == 1 ? "1 paycheck" : "\(removed) paychecks")."
            if removed > 0 { onWrite() }
        } catch {
            message = "Couldn't remove every paycheck. Try again."
        }
    }

    /// A recorded paycheck settles that period's payday reminder, as it does
    /// from the paycheck sheet. Reads the store, since the caller's @Query
    /// may not have caught up with the save yet.
    static func rescheduleReminders(context: ModelContext, preferencesStore: UserPreferencesStore, scheduleStore: PayScheduleStore) {
        let shifts = (try? context.fetch(FetchDescriptor<ShiftRecord>())) ?? []
        let paychecks = ((try? context.fetch(FetchDescriptor<PaycheckRecord>())) ?? []).hidingPendingRemoval()
        PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, shiftRecords: shifts, paycheckRecords: paychecks)
    }

    // MARK: - Copy

    static func summary(of outcome: PayrollImporter.Outcome) -> String {
        switch (outcome.created, outcome.merged) {
        case (0, 0): return "No new pay stubs."
        case (let created, 0): return "Imported \(created == 1 ? "1 paycheck" : "\(created) paychecks")."
        case (0, let merged): return "Matched \(merged == 1 ? "1 paycheck" : "\(merged) paychecks") you already had."
        case (let created, let merged):
            return "Imported \(created == 1 ? "1 paycheck" : "\(created) paychecks"), matched \(merged) you already had."
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? PayrollConnectError)?.message ?? PayrollConnectError.offline.message
    }
}
