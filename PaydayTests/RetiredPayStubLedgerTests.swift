import Foundation
import Testing
@testable import Payday

/// A device that ran a 1.0.5 TestFlight build may hold the pay stub import
/// ledger. Account deletion must remove it, and must not fail when the
/// device never had one.
@Suite("Account deletion removes the retired pay stub ledger")
@MainActor
struct RetiredPayStubLedgerTests {
    @Test("the file is removed, and a missing file is not an error")
    func removesFileAndToleratesMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "PayrollImportLedger.json")
        try Data(#"{"entries":{}}"#.utf8).write(to: url)

        try PaydayAccountEraser.removeRetiredPayStubLedger(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path()))

        try PaydayAccountEraser.removeRetiredPayStubLedger(at: url)
    }

    @Test("the path is the one the 1.0.5 builds wrote")
    func pathMatchesOldBuilds() {
        #expect(PaydayAccountEraser.retiredPayStubLedgerURL
            == URL.applicationSupportDirectory.appending(path: "PayrollImportLedger.json"))
    }
}
