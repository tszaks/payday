import Foundation
import Testing
@testable import Payday

/// PR 6 / 2.14 part 2b: the checkpoint remembers the server watermark, but
/// only from a pass that finished with nothing outstanding.
///
/// The value's meaning is a COINCIDENCE -- "at the instant I read this, the
/// server's dataset and mine agreed" -- so every test here is about when
/// that claim may be made and when it must be withdrawn, not about the
/// number itself.
@Suite("Dataset revision leg")
@MainActor
struct DatasetRevisionLegTests {

    private func freshUser() -> UUID {
        let id = UUID()
        PaydaySyncState.applySyncedDatasetRevision(nil, clean: false, for: id)
        return id
    }

    private func stored(_ id: UUID) -> Int64? {
        PaydaySyncState.snapshot(for: id).syncedDatasetRevision
    }

    @Test("a clean pass records the watermark it read")
    func cleanPassRecords() async {
        let id = freshUser()
        await PaydaySyncService.applyDatasetRevisionLeg(userID: id, clean: true) { 42 }
        #expect(stored(id) == 42)
    }

    /// The pass still had work outstanding, so nothing was observed to agree.
    /// Recording anyway would let the uploader stamp a snapshot with a
    /// watermark that this pass's own pending writes are about to invalidate.
    @Test("a dirty pass records nothing, and does not even read")
    func dirtyPassRecordsNothing() async {
        let id = freshUser()
        var fetched = false
        await PaydaySyncService.applyDatasetRevisionLeg(userID: id, clean: false) {
            fetched = true
            return 7
        }
        #expect(stored(id) == nil)
        #expect(!fetched, "a dirty pass has no reason to spend a round trip")
    }

    /// **The withdrawal case.** A previously good value must not survive a
    /// pass that ended dirty: it was true about a dataset that has since
    /// moved, and a watermark that silently stops being true is worse than
    /// none, because the reader cannot tell.
    @Test("a dirty pass CLEARS a previously recorded watermark")
    func dirtyPassClearsAnOldValue() async {
        let id = freshUser()
        await PaydaySyncService.applyDatasetRevisionLeg(userID: id, clean: true) { 9 }
        #expect(stored(id) == 9)

        await PaydaySyncService.applyDatasetRevisionLeg(userID: id, clean: false) { 10 }
        #expect(stored(id) == nil, "stale is worse than absent")
    }

    /// A failed read is not an instant at which anything was observed.
    /// Keeping the old value would let the device stamp an upload with a
    /// watermark it never saw.
    @Test("a failed read clears rather than keeps")
    func failedReadClears() async {
        struct ReadFailed: Error {}
        let id = freshUser()
        await PaydaySyncService.applyDatasetRevisionLeg(userID: id, clean: true) { 5 }
        #expect(stored(id) == 5)

        await PaydaySyncService.applyDatasetRevisionLeg(userID: id, clean: true) {
            throw ReadFailed()
        }
        #expect(stored(id) == nil)
    }

    /// Revision 0 is a real answer -- an account nothing has written for yet
    /// -- and must be stored rather than collapsed to "unknown". Storing nil
    /// here would make a brand-new account permanently unable to upload,
    /// because 0 is the only revision its snapshot can match.
    @Test("revision zero is recorded, not treated as absent")
    func zeroIsARealRevision() async {
        let id = freshUser()
        await PaydaySyncService.applyDatasetRevisionLeg(userID: id, clean: true) { 0 }
        #expect(stored(id) == 0)
        #expect(stored(id) != nil, "0 and nil are different answers")
    }

    /// **The window an uploader would otherwise fall into.**
    ///
    /// A local write breaks the "we agree" claim immediately, but the sync
    /// that notices is debounced two seconds and skipped entirely when the
    /// scene is inactive. In that gap the server's revision has not moved
    /// either -- the write has not reached it -- so
    /// `upsert_earnings_snapshot` would ACCEPT a snapshot computed from
    /// unsynced rows. The acceptance rule cannot catch this one; only the
    /// device knows it has unsent work.
    @Test("a local write withdraws the watermark immediately")
    func localWriteWithdrawsImmediately() async {
        let id = freshUser()
        await PaydaySyncService.applyDatasetRevisionLeg(userID: id, clean: true) { 77 }
        #expect(stored(id) == 77)

        PaydaySyncState.invalidateSyncedDatasetRevision(for: id)
        #expect(stored(id) == nil, "the claim is false the moment the write lands")
    }

    /// The production call site passes no account and relies on the
    /// registered one, so that path is exercised rather than assumed --
    /// a defaulted argument nobody tests is how a producer goes missing.
    @Test("the no-argument form uses the registered account")
    func noArgumentFormUsesRegisteredAccount() async {
        guard let registered = PaydaySyncState.registeredUserID else {
            // Nothing registered in this run; register one so the real path
            // is still covered rather than silently skipped.
            let fresh = UUID()
            guard PaydaySyncState.registerCurrentUser(fresh) else { return }
            await PaydaySyncService.applyDatasetRevisionLeg(userID: fresh, clean: true) { 3 }
            #expect(stored(fresh) == 3)
            PaydaySyncState.invalidateSyncedDatasetRevision()
            #expect(stored(fresh) == nil)
            return
        }
        await PaydaySyncService.applyDatasetRevisionLeg(userID: registered, clean: true) { 4 }
        #expect(stored(registered) == 4)
        PaydaySyncState.invalidateSyncedDatasetRevision()
        #expect(stored(registered) == nil)
    }

    /// Two accounts on one device must not share a watermark.
    @Test("the watermark is per account")
    func perAccount() async {
        let a = freshUser()
        let b = freshUser()
        await PaydaySyncService.applyDatasetRevisionLeg(userID: a, clean: true) { 11 }
        #expect(stored(a) == 11)
        #expect(stored(b) == nil)
    }
}
