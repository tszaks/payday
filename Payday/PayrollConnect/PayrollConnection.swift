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
    /// Moves on every account change and on account deletion. Work that
    /// awaited the network checks it before writing anything, so an answer
    /// for the previous account can never land in the next one, or in a
    /// store that was just erased.
    private var generation = 0
    /// Set when the ledger file exists but could not be read. Imports stop
    /// until it reads again; importing against an empty ledger would bring
    /// every stub in a second time.
    private(set) var ledgerUnreadable = false
    /// Set when the last ledger write failed. The in-memory ledger is then
    /// the only record of what was imported: it is kept (never reloaded over
    /// from the older file), every later write retries the save, and no
    /// import runs until a save succeeds.
    private(set) var ledgerUnsaved = false
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
    /// Links that exist but Truv has not finished with (syncing, or waiting
    /// for a new sign-in).
    var waitingLinks: [PayrollLink] { status?.links.filter { !$0.isConnected } ?? [] }

    /// Hours and deduction lines for the stubs imported so far, newest
    /// first. `PaycheckRecord` has no fields for these, so they live here.
    var importedStubs: [(sourceID: String, entry: PayrollImportLedger.Entry)] {
        ledger.entries.map { ($0.key, $0.value) }.sorted { $0.entry.payDate > $1.entry.payDate }
    }

    // MARK: - Ledger

    /// Loads the ledger for the signed-in account. Call before any action.
    func prepare(userID: UUID?) {
        if userID != ledger.userID {
            // Another account: nothing of the last one's may stay on screen
            // or be importable, and its in-flight work must not land here.
            forgetSession()
        } else if isWorking {
            // Mid-import the in-memory ledger is ahead of the file; reloading
            // would throw that away.
            return
        } else if ledgerUnsaved {
            // Same: the file is behind. Try to catch it up instead.
            saveLedger()
            return
        }
        do {
            ledger = try store.load().scoped(to: userID)
            ledgerUnreadable = false
        } catch {
            ledger = PayrollImportLedger(userID: userID)
            ledgerUnreadable = true
        }
    }

    /// Account deletion: forget everything in memory and stop in-flight work
    /// from writing. The file is erased by `PayrollImportLedgerStore.erase`.
    func reset() {
        forgetSession()
        ledger = PayrollImportLedger()
        ledgerUnreadable = false
        ledgerUnsaved = false
    }

    private func forgetSession() {
        // The previous account's unsaved ledger cannot be written into the
        // next account's file. What it held is recoverable: an imported
        // paycheck's id is derived from its stub (`PayrollImporter.recordID`).
        ledgerUnsaved = false
        generation += 1
        status = nil
        preview = nil
        pendingStatements = []
        message = nil
        isWorking = false
    }

    /// False when the file could not be written; `message` then says so and
    /// `ledgerUnsaved` holds further imports until a save succeeds.
    @discardableResult
    private func saveLedger() -> Bool {
        guard !ledgerUnreadable else { return false }
        do {
            try store.save(ledger)
            ledgerUnsaved = false
            return true
        } catch {
            ledgerUnsaved = true
            message = Self.unsavedMessage
            return false
        }
    }

    static let unsavedMessage = "Payday couldn't save its import record, so it stopped importing. Imported paychecks are safe; try again."

    /// Before a write: catches the file up if an earlier save failed. False
    /// while it still cannot be saved.
    private func ledgerWritable() -> Bool {
        if ledgerUnsaved { saveLedger() }
        return !ledgerUnsaved
    }

    /// A link that exists but is not ready (still syncing, or waiting for a
    /// new sign-in) is still a connection: imports keep checking it, and it
    /// is read again once Truv marks it done. Only no link at all is off.
    static func hasConnection(_ links: [PayrollLink]) -> Bool {
        !links.isEmpty
    }

    // MARK: - Status and connect

    func refreshStatus() async {
        let started = generation
        do {
            let status = try await api.status()
            guard generation == started else { return }
            self.status = status
            ledger.hasConnection = Self.hasConnection(status.links)
            saveLedger()
        } catch {
            guard generation == started else { return }
            message = Self.describe(error)
        }
    }

    /// A Truv Bridge token for the sign-in screen, or nil with `message` set.
    func bridgeToken() async -> String? {
        let started = generation
        isWorking = true
        defer { if generation == started { isWorking = false } }
        do {
            let token = try await api.bridgeToken()
            return generation == started ? token.bridgeToken : nil
        } catch {
            if generation == started { message = Self.describe(error) }
            return nil
        }
    }

    /// Bridge finished: confirm the link on the server, then fetch a preview.
    /// Nothing is imported until the person taps Import.
    func finishConnect(publicToken: String, context: ModelContext, scope: PayrollImportScope) async {
        let started = generation
        isWorking = true
        defer { if generation == started { isWorking = false } }
        do {
            _ = try await api.exchange(publicToken: publicToken)
        } catch {
            if generation == started { message = Self.describe(error) }
            return
        }
        guard generation == started else { return }
        await refreshStatus()
        guard generation == started else { return }
        ledger.importConfirmed = false
        saveLedger()
        await loadPreview(context: context, scope: scope)
    }

    // MARK: - Preview and import

    func loadPreview(context: ModelContext, scope: PayrollImportScope) async {
        let started = generation
        isWorking = true
        defer { if generation == started { isWorking = false } }
        do {
            let result = try await api.paystubs(since: nil)
            guard generation == started else { return }
            pendingStatements = result.paystubs
            let records = try context.fetch(FetchDescriptor<PaycheckRecord>())
            preview = Self.preview(of: PayrollImporter.plan(
                statements: result.paystubs, records: records, ledger: ledger,
                jobs: scope.jobs, calculator: scope.calculator))
        } catch {
            if generation == started { message = Self.describe(error) }
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
    /// imports. With an empty preview it only turns them on, so a connection
    /// made before the first stub exists still picks that stub up.
    func confirmImport(context: ModelContext, scope: PayrollImportScope, onWrite: () -> Void = {}) {
        guard !ledgerUnreadable else {
            message = "Payday couldn't read its import record. Nothing was imported."
            return
        }
        guard ledgerWritable() else { return }
        do {
            let outcome = try PayrollImporter.apply(
                statements: pendingStatements, in: context, ledger: &ledger,
                jobs: scope.jobs, calculator: scope.calculator, now: now())
            ledger.importConfirmed = true
            preview = nil
            pendingStatements = []
            if saveLedger() { message = Self.summary(of: outcome) }
            if outcome.created + outcome.merged > 0 { onWrite() }
        } catch {
            message = "Couldn't save. Nothing was imported."
        }
    }

    /// App open and pull-to-refresh. Runs only after the first import was
    /// confirmed; `force` skips the six-hour spacing (pull-to-refresh).
    func importIfDue(context: ModelContext, scope: PayrollImportScope, force: Bool = false, onWrite: () -> Void = {}) async {
        guard ledger.importConfirmed, ledger.hasConnection, !ledgerUnreadable, !isWorking else { return }
        guard ledgerWritable() else { return }
        let now = now()
        if !force, let last = ledger.lastAutomaticAttemptAt, now.timeIntervalSince(last) < Self.automaticInterval {
            return
        }
        ledger.lastAutomaticAttemptAt = now
        saveLedger()
        let started = generation
        isWorking = true
        defer { if generation == started { isWorking = false } }
        do {
            let result = try await api.paystubs(since: nil)
            // Signed out, switched account or deleted it while waiting: this
            // answer belongs to nobody here now.
            guard generation == started else { return }
            status = PayrollStatus(environment: result.environment, links: result.links)
            ledger.hasConnection = Self.hasConnection(result.links)
            let outcome = try PayrollImporter.apply(
                statements: result.paystubs, in: context, ledger: &ledger,
                jobs: scope.jobs, calculator: scope.calculator, now: now)
            saveLedger()
            if outcome.created + outcome.merged > 0 { onWrite() }
        } catch {
            // Quiet on app open: the next attempt is six hours away and the
            // connection screen shows the last sync time.
            if force, generation == started { message = Self.describe(error) }
        }
    }

    /// "Check for new paystubs": asks Truv to read the payroll account again.
    /// The new stubs arrive a few minutes later and come in on the next
    /// import.
    func requestRefresh(link: PayrollLink) async {
        let started = generation
        isWorking = true
        defer { if generation == started { isWorking = false } }
        do {
            try await api.refresh(linkID: link.linkID)
            guard generation == started else { return }
            message = "Checking. New pay stubs show up in a few minutes."
            await refreshStatus()
        } catch let error as PayrollConnectError where error.code == "refresh_throttled" {
            if generation == started {
                message = "Payday checked this payroll in the last day. New pay stubs still come in on their own."
            }
        } catch {
            if generation == started { message = Self.describe(error) }
        }
    }

    func disconnect(link: PayrollLink) async {
        let started = generation
        isWorking = true
        defer { if generation == started { isWorking = false } }
        do {
            try await api.disconnect(linkID: link.linkID)
            guard generation == started else { return }
            message = "Disconnected. Imported paychecks stay."
            preview = nil
            pendingStatements = []
            await refreshStatus()
        } catch {
            if generation == started { message = Self.describe(error) }
        }
    }

    /// How long account deletion waits for Truv. Deletion never waits on
    /// a payroll provider longer than this.
    static let forgetTimeout: Duration = .seconds(5)

    /// Account deletion, before the account itself goes: asks the server to
    /// delete the person's Truv user, its links and the data Truv read.
    /// Best effort: true when the server confirmed it, false on any failure
    /// or after `timeout`, and account deletion goes ahead either way.
    /// Known limit: when Truv is down at that moment, the Truv user stays.
    func forgetRemote(timeout: Duration = PayrollConnection.forgetTimeout) async -> Bool {
        let api = api
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let work = Task {
                let done = (try? await api.forget()) != nil
                once.resume(done)
            }
            Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                once.resume(false)
            }
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

/// Resumes a continuation once, whichever of two racing tasks gets there
/// first (the request or the timeout).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
