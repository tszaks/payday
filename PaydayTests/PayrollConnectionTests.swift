import Foundation
import PaydayCore
import SwiftData
import Testing
@testable import Payday

/// The fake server. `duringPaystubs` runs while a pay stub request is in
/// flight, which is where an account switch or deletion can land.
private final class FakePayrollAPI: PayrollConnectAPI, @unchecked Sendable {
    var paystubs: [PayrollStatement] = []
    var linkStatus = "done"
    var paystubCalls = 0
    var forgetError: Error?
    var forgetHangs = false
    var forgetCalls = 0
    var duringPaystubs: (@MainActor () -> Void)?

    private var links: [PayrollLink] {
        [PayrollLink(linkID: "link-1", status: linkStatus, providerID: "toast", providerName: "Toast",
                     employerName: nil, updatedAt: nil, refreshAvailableAt: nil)]
    }

    func status() async throws -> PayrollStatus {
        if let statusError { throw statusError }
        return PayrollStatus(environment: .sandbox, links: links)
    }
    var bridgeTokenLinkIDs: [String?] = []
    var bridgeTokenError: Error?
    var statusError: Error?
    func bridgeToken(linkID: String?) async throws -> PayrollBridgeToken {
        bridgeTokenLinkIDs.append(linkID)
        if let bridgeTokenError { throw bridgeTokenError }
        return PayrollBridgeToken(environment: .sandbox, bridgeToken: "t")
    }
    func exchange(publicToken: String) async throws -> PayrollLink { links[0] }
    func paystubs(since: String?) async throws -> PayrollPaystubs {
        paystubCalls += 1
        if let duringPaystubs { await duringPaystubs() }
        // The server lists every link but reads only `done` ones.
        return PayrollPaystubs(environment: .sandbox, links: links, paystubs: linkStatus == "done" ? paystubs : [])
    }
    func refresh(linkID: String) async throws {}
    func disconnect(linkID: String) async throws {}
    func forget() async throws {
        forgetCalls += 1
        if forgetHangs {
            // Truv not answering. Ignores cancellation on purpose, as a
            // stuck connection may.
            let until = Date().addingTimeInterval(30)
            while Date() < until { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }
        }
        if let forgetError { throw forgetError }
    }
}

@Suite("Payroll connection")
@MainActor
struct PayrollConnectionTests {
    let zone = PaydayTestZone.newYork
    let context: ModelContext
    let url = FileManager.default.temporaryDirectory.appending(path: "payroll-ledger-\(UUID().uuidString).json")
    let alice = UUID()
    let bob = UUID()

    init() throws {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    var scope: PayrollImportScope {
        let zone = zone
        let calculator = PayPeriodCalculator(
            payrollTimeZone: zone,
            schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: CivilDay(iso: "2026-10-25")!.date(in: zone), payDelayDays: 5))
        return PayrollImportScope(jobs: [], calculator: { _ in calculator })
    }

    func stub(_ id: String) -> PayrollStatement {
        PayrollStatement(
            sourceID: id, linkID: "link-1", providerName: "Toast", employerName: nil,
            payDate: "2026-10-30", periodStart: "2026-10-12", periodEnd: "2026-10-25",
            grossPayCents: 162_998, netPayCents: 120_150, hours: "80.00",
            regularCents: 150_000, overtimeCents: 12_998,
            earnings: [PayStubLine(name: "Regular", category: "regular", cents: 150_000)],
            deductions: [])
    }

    /// A delete with no sync side effects, for tests.
    let plainDelete: @MainActor (UUID, ModelContext) throws -> Void = { id, context in
        let record = try context.fetch(FetchDescriptor<PaycheckRecord>(predicate: #Predicate { $0.id == id })).first
        if let record { context.delete(record) }
        try context.save()
    }

    func paychecks() throws -> Int { try context.fetchCount(FetchDescriptor<PaycheckRecord>()) }

    @Test("another account signing in sees none of the last account's preview, and cannot import it")
    func accountSwitchClearsPreview() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakePayrollAPI()
        api.paystubs = [stub("s1")]
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: url))
        connection.prepare(userID: alice)
        await connection.loadPreview(context: context, scope: scope)
        #expect(connection.preview?.newCount == 1)

        connection.prepare(userID: bob)
        #expect(connection.preview == nil)
        #expect(connection.status == nil)
        connection.confirmImport(context: context, scope: scope)
        #expect(try paychecks() == 0, "Alice's stubs never land in Bob's paychecks")
    }

    @Test("an import in flight when the account is deleted writes nothing, paychecks or ledger")
    func deletionStopsInFlightImport() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakePayrollAPI()
        api.paystubs = [stub("s1")]
        let store = PayrollImportLedgerStore(url: url)
        let connection = PayrollConnection(api: api, store: store)
        connection.prepare(userID: alice)
        await connection.refreshStatus()
        await connection.loadPreview(context: context, scope: scope)
        connection.confirmImport(context: context, scope: scope)
        #expect(try paychecks() == 1)
        #expect(connection.ledger.hasConnection && connection.ledger.importConfirmed)
        var reachedNetwork = false

        // A new stub is posted; the app-open import is waiting on the
        // network when the person deletes their account.
        api.paystubs = [stub("s1"), stub("s2")]
        try context.delete(model: PaycheckRecord.self)
        try context.save()
        api.duringPaystubs = {
            reachedNetwork = true
            connection.reset()
            try? store.erase()
        }
        await connection.importIfDue(context: context, scope: scope, force: true)
        #expect(reachedNetwork, "the deletion landed mid-request")
        #expect(try paychecks() == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path), "the ledger is not written back")
        #expect(connection.ledger == PayrollImportLedger())
        #expect(connection.isWorking == false)
    }

    @Test("an empty first preview can still turn on automatic imports")
    func emptyPreviewCanConfirm() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakePayrollAPI()
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: url))
        connection.prepare(userID: alice)
        await connection.refreshStatus()
        await connection.loadPreview(context: context, scope: scope)
        #expect(connection.preview?.isEmpty == true)
        connection.confirmImport(context: context, scope: scope)
        #expect(connection.ledger.importConfirmed)

        // The first stub, posted later, comes in on its own.
        api.paystubs = [stub("s1")]
        await connection.importIfDue(context: context, scope: scope, force: true)
        #expect(try paychecks() == 1)
    }

    @Test("account deletion asks the server to forget payroll, best effort, and never waits long")
    func forgetIsBestEffort() async throws {
        let api = FakePayrollAPI()
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: url))
        #expect(await connection.forgetRemote())
        #expect(api.forgetCalls == 1)

        api.forgetError = PayrollConnectError(status: 502, code: "truv_forbidden", message: "no")
        #expect(await connection.forgetRemote() == false, "a refusal is reported, not thrown")
        api.forgetError = PayrollConnectError.offline
        #expect(await connection.forgetRemote() == false)

        // Truv hangs: deletion goes ahead after the timeout, not after Truv.
        api.forgetError = nil
        api.forgetHangs = true
        let clock = ContinuousClock()
        let started = clock.now
        let finished = await connection.forgetRemote(timeout: .milliseconds(200))
        #expect(finished == false)
        #expect(clock.now - started < .seconds(3))
    }

    @Test("signing out or switching account mid-request drops the answer")
    func previousAccountsAnswerIsDropped() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        for leave in ["sign out", "switch"] {
            let api = FakePayrollAPI()
            api.paystubs = [stub("s1")]
            let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: url))
            connection.prepare(userID: alice)
            await connection.refreshStatus()
            api.duringPaystubs = {
                if leave == "sign out" { connection.reset() } else { connection.prepare(userID: bob) }
            }
            await connection.loadPreview(context: context, scope: scope)
            #expect(connection.preview == nil, "\(leave): Alice's stubs are not shown")
            connection.confirmImport(context: context, scope: scope)
            #expect(try paychecks() == 0, "\(leave): and cannot be imported")
            #expect(connection.status == nil)
            #expect(connection.isWorking == false)
        }
    }

    @Test("a link that is not ready yet keeps the connection on, and is read once it is")
    func waitingLinkKeepsConnection() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakePayrollAPI()
        api.paystubs = [stub("s1")]
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: url))
        connection.prepare(userID: alice)
        await connection.refreshStatus()
        await connection.loadPreview(context: context, scope: scope)
        connection.confirmImport(context: context, scope: scope)

        api.linkStatus = "pending"
        await connection.importIfDue(context: context, scope: scope, force: true)
        #expect(connection.ledger.hasConnection, "syncing is not disconnected")
        #expect(connection.waitingLinks.count == 1)
        await connection.refreshStatus()
        #expect(connection.ledger.hasConnection)

        api.linkStatus = "done"
        api.paystubs = [stub("s1"), stub("s2")]
        let callsBefore = api.paystubCalls
        await connection.importIfDue(context: context, scope: scope, force: true)
        #expect(api.paystubCalls == callsBefore + 1, "still checked")
        #expect(try paychecks() == 2)
    }

    @Test("a ledger that cannot be saved is kept in memory, reported, and stops imports until it saves")
    func unsavedLedgerBlocksImports() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let api = FakePayrollAPI()
        api.paystubs = [stub("s1")]
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: folder.appending(path: "ledger.json")))
        connection.prepare(userID: alice)
        await connection.refreshStatus()
        await connection.loadPreview(context: context, scope: scope)
        #expect(connection.ledgerUnsaved == false)
        // Now the disk refuses: a file where the ledger's folder should be.
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        connection.confirmImport(context: context, scope: scope)
        #expect(try paychecks() == 1, "the paycheck itself saved")
        #expect(connection.ledgerUnsaved)
        #expect(connection.message == PayrollConnection.unsavedMessage, "not replaced by a success line")
        #expect(connection.ledger.entries["s1"] != nil, "kept in memory")

        // Coming back to the app does not reload the older file over it.
        connection.prepare(userID: alice)
        #expect(connection.ledger.entries["s1"] != nil)

        // No import runs while it cannot be saved.
        api.paystubs = [stub("s1"), stub("s2")]
        let callsBefore = api.paystubCalls
        await connection.importIfDue(context: context, scope: scope, force: true)
        #expect(api.paystubCalls == callsBefore)
        #expect(try paychecks() == 1)

        // Once it can be saved, the next import saves it first, then runs.
        try FileManager.default.removeItem(at: folder)
        await connection.importIfDue(context: context, scope: scope, force: true)
        #expect(connection.ledgerUnsaved == false)
        #expect(try paychecks() == 2)
        let saved = try PayrollImportLedgerStore(url: folder.appending(path: "ledger.json")).load()
        #expect(Set(saved.entries.keys) == ["s1", "s2"])
    }

    @Test("payroll not set up on the server: the screen says so and offers no Connect; it clears when it works")
    func notConfiguredIsShownPlainly() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakePayrollAPI()
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: url))
        connection.prepare(userID: alice)
        for code in ["not_configured", "truv_not_configured"] {
            api.statusError = PayrollConnectError(status: 503, code: code, message: "Payroll connection is not set up.")
            await connection.refreshStatus()
            #expect(connection.isUnavailable, "\(code)")
            #expect(connection.message == PayrollConnection.unavailableMessage)
        }
        api.statusError = PayrollConnectError(status: 502, code: "truv_unavailable", message: "Payroll is not answering right now.")
        connection.message = nil
        await connection.refreshStatus()
        #expect(connection.message == "Payroll is not answering right now.", "an outage is not 'not set up'")

        api.statusError = nil
        await connection.refreshStatus()
        #expect(connection.isUnavailable == false)

        api.bridgeTokenError = PayrollConnectError(status: 503, code: "not_configured", message: "x")
        #expect(await connection.bridgeToken() == nil)
        #expect(connection.isUnavailable)
        connection.prepare(userID: bob)
        #expect(connection.isUnavailable == false, "not carried to another account")
    }

    @Test("a link that needs a new sign-in offers Reconnect, which opens Bridge on that same link")
    func reconnectOpensTheSameLink() async throws {
        let states: [(String?, Bool)] = [
            ("done", false), ("new", false), ("login", false), ("mfa", false), ("parse", false),
            ("full_parse", false), ("pending", false), (nil, false),
            ("login_error", true), ("mfa_error", true), ("account_locked", true), ("error", true), ("no_data", true),
        ]
        for (status, needs) in states {
            let link = PayrollLink(linkID: "l", status: status, providerID: nil, providerName: "Toast",
                                   employerName: nil, updatedAt: nil, refreshAvailableAt: nil)
            #expect(link.needsSignIn == needs, "\(status ?? "nil")")
        }

        let api = FakePayrollAPI()
        api.linkStatus = "login_error"
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: url))
        connection.prepare(userID: alice)
        await connection.refreshStatus()
        let broken = try #require(connection.waitingLinks.first)
        #expect(broken.needsSignIn)
        #expect(connection.ledger.hasConnection, "a broken link is still a connection")
        #expect(await connection.bridgeToken(reconnecting: broken) == "t")
        #expect(await connection.bridgeToken() == "t")
        #expect(api.bridgeTokenLinkIDs == ["link-1", nil])
        try? FileManager.default.removeItem(at: url)
    }

    @Test("clean-up shows for any known link, ready or not, and for imported paychecks with no link left")
    func cleanupControlsDoNotNeedAReadyLink() {
        func link(_ status: String) -> PayrollLink {
            PayrollLink(linkID: status, status: status, providerID: nil, providerName: "Toast",
                        employerName: nil, updatedAt: nil, refreshAvailableAt: nil)
        }
        #expect(PayrollConnectionView.showsManageSection(links: [link("login_error")], createdCount: 0))
        #expect(PayrollConnectionView.showsManageSection(links: [link("parse")], createdCount: 0))
        #expect(PayrollConnectionView.showsManageSection(links: [], createdCount: 3), "disconnected, paychecks remain")
        #expect(!PayrollConnectionView.showsManageSection(links: [], createdCount: 0))
    }

    @Test("Remove imported saves 'imports off' before deleting; if that save fails, nothing is deleted")
    func removalSavesImportsOffFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "ledger.json")
        let api = FakePayrollAPI()
        api.paystubs = [stub("s1")]
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: file))
        connection.prepare(userID: alice)
        await connection.refreshStatus()
        await connection.loadPreview(context: context, scope: scope)
        connection.confirmImport(context: context, scope: scope)
        #expect(try paychecks() == 1)
        #expect(try PayrollImportLedgerStore(url: file).load().importConfirmed)

        // The disk refuses: Remove does nothing, and says so.
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        connection.removeImported(context: context, delete: plainDelete)
        #expect(try paychecks() == 1, "nothing deleted while 'imports off' can't be saved")
        #expect(connection.message == PayrollConnection.unsavedMessage)

        try FileManager.default.removeItem(at: folder)
        connection.removeImported(context: context, delete: plainDelete)
        #expect(try paychecks() == 0)
        #expect(try PayrollImportLedgerStore(url: file).load().importConfirmed == false)
    }

    @Test("the preview flags weekly stubs under a biweekly schedule")
    func previewFlagsFrequentStubs() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakePayrollAPI()
        var week1 = stub("w1")
        week1 = PayrollStatement(
            sourceID: "w1", linkID: "link-1", providerName: "Toast", employerName: nil,
            payDate: "2026-10-23", periodStart: "2026-10-12", periodEnd: "2026-10-18",
            grossPayCents: 80_000, netPayCents: 60_000, hours: "40.00", regularCents: 80_000, overtimeCents: 0,
            earnings: week1.earnings, deductions: [])
        let week2 = PayrollStatement(
            sourceID: "w2", linkID: "link-1", providerName: "Toast", employerName: nil,
            payDate: "2026-10-30", periodStart: "2026-10-19", periodEnd: "2026-10-25",
            grossPayCents: 80_000, netPayCents: 60_000, hours: "40.00", regularCents: 80_000, overtimeCents: 0,
            earnings: week1.earnings, deductions: [])
        api.paystubs = [week1, week2]
        let connection = PayrollConnection(api: api, store: PayrollImportLedgerStore(url: url))
        connection.prepare(userID: alice)
        await connection.loadPreview(context: context, scope: scope)
        #expect(connection.preview?.paysMoreOftenThanSchedule == true)
        #expect(connection.preview?.newCount == 2, "each stub is still its own paycheck")

        api.paystubs = [stub("s1")]
        await connection.loadPreview(context: context, scope: scope)
        #expect(connection.preview?.paysMoreOftenThanSchedule == false)
    }

    @Test("erasing the ledger file: gone is success, and a missing file is not an error")
    func ledgerErase() throws {
        let store = PayrollImportLedgerStore(url: url)
        try store.erase()
        try store.save(PayrollImportLedger(userID: alice))
        try store.erase()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
