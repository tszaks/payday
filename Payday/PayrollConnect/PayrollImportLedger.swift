import Foundation
import PaydayCore

/// What "Connect payroll" remembers on this device, and nothing it syncs.
///
/// The paycheck itself is an ordinary `PaycheckRecord` that syncs like one
/// typed by hand. This ledger only says which pay stub became (or was merged
/// into) which record, so that:
///
/// - re-importing is idempotent: a stub already here is never imported again,
///   even after the person deletes the paycheck it made (a delete is a
///   decision, and the next import must not undo it);
/// - "Remove imported paychecks" can tell an imported record from one the
///   person typed, and an imported record from one they since edited;
/// - the connection screen can show hours and deduction lines, which
///   `PaycheckRecord` has no fields for and which this feature must not add.
///
/// It is keyed to the account: another account signing in on this phone
/// starts from an empty ledger rather than inheriting a map to someone else's
/// records.
struct PayrollImportLedger: Codable, Equatable {
    enum Origin: String, Codable {
        /// The import made this record.
        case created
        /// The record existed (typed or scanned); the import only filled
        /// fields that were empty. Never removed by "Remove imported".
        case merged
    }

    struct Entry: Codable, Equatable {
        var recordID: UUID
        var origin: Origin
        /// The record's `modifiedAt` right after the import wrote it. A later
        /// value means someone edited it.
        var recordModifiedAt: Date
        var linkID: String
        var payDate: String
        var hours: String?
        var deductions: [PayStubLine]
    }

    var userID: UUID?
    /// Pay stub id (Truv statement id) -> what happened to it.
    var entries: [String: Entry] = [:]
    /// The person has seen a preview and tapped Import. Until then nothing is
    /// written, and automatic imports do not run.
    var importConfirmed = false
    var lastSyncedAt: Date?
    var lastAutomaticAttemptAt: Date?
    /// Whether the last status said a link is connected, so app-open imports
    /// can skip the network for someone who never connected.
    var hasConnection = false

    /// Records this feature made that still carry its values.
    var createdCount: Int {
        entries.values.filter { $0.origin == .created }.count
    }

    /// The ledger after the account changed: a fresh one for `userID`.
    func scoped(to userID: UUID?) -> PayrollImportLedger {
        guard self.userID != userID else { return self }
        return PayrollImportLedger(userID: userID)
    }
}

/// Reads and writes the ledger as one small JSON file in Application Support.
/// The App Group is not used: the widget never reads it.
struct PayrollImportLedgerStore {
    let url: URL

    static let shared = PayrollImportLedgerStore(
        url: URL.applicationSupportDirectory.appending(path: "PayrollImportLedger.json")
    )

    /// An empty ledger when there is no file yet. A file that exists but
    /// cannot be read THROWS rather than reading as empty: an empty ledger
    /// forgets every stub already imported, and the next import would then
    /// treat each of them as new.
    func load() throws -> PayrollImportLedger {
        guard FileManager.default.fileExists(atPath: url.path()) else { return PayrollImportLedger() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PayrollImportLedger.self, from: data)
    }

    func save(_ ledger: PayrollImportLedger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Throws when the file is still there afterwards. No file is success.
    func erase() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
