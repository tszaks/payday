import Foundation
import PaydayCore

/// Publishes the engine's answer to the server, and refuses to when it
/// cannot prove the answer describes data the server already holds.
///
/// ## The one precondition, and why it is the device's to check
///
/// Uploading requires `Checkpoint.syncedDatasetRevision` to be non-nil,
/// which means "no local change since the last clean sync pass". That is a
/// fact only this device can assert.
///
/// It is tempting to lean on the server instead: `upsert_earnings_snapshot`
/// already rejects a stamp that is not the current revision, so why check
/// anything here? Because the case that matters slips through it. A local
/// write that has NOT yet been pushed leaves the server's revision unmoved,
/// so a snapshot computed from those unsynced rows carries a stamp the
/// server still considers current and the RPC ACCEPTS it. The server cannot
/// see work it has not received. The check has to be here.
///
/// ## Why `stale_input` is not an error
///
/// It is the ordinary outcome of racing a write from another device: our
/// stamp was current when we read it and is not any more. Nothing is wrong,
/// nothing needs logging as a failure, and retrying immediately would only
/// lose the race again. The next clean sync re-arms the watermark and the
/// next publication tries with a current one.
@MainActor
final class SnapshotUploader {

    enum Outcome: Equatable {
        case uploaded(revision: Int64)
        /// No clean sync is known, so nothing may be claimed about the
        /// server's dataset. The common case on a device with unsent work.
        case skippedNoCleanSync
        /// Already sent this exact document at this exact revision.
        case skippedUnchanged
        /// The server moved on. Ordinary, not a failure.
        case stale
        case failed
    }

    /// In memory rather than in the checkpoint, deliberately. Its only job is
    /// to stop re-sending an identical payload on every republication within
    /// a session; a process restart re-sending once is harmless and
    /// self-limiting, and persisting it would add a durable field whose
    /// staleness could SUPPRESS a needed upload -- a worse failure than one
    /// redundant request.
    private var lastUploaded: (revision: Int64, digest: String)?

    init() {}

    /// `upload` is injected so the decision logic is testable without a
    /// network or a session, the same seam as `applyShiftAuthorityLeg` and
    /// `applyDatasetRevisionLeg`.
    ///
    /// Returns the verdict rather than swallowing it, so a caller that wants
    /// to log or surface "your figures are published" can, and so the tests
    /// assert on a value instead of on a side effect.
    func publish(
        _ snapshot: EarningsSnapshot,
        for userID: UUID,
        upload: (_ revision: Int64, _ engineVersion: Int, _ asOf: CivilDay?,
                 _ digest: String, _ payload: Data) async throws -> String
    ) async -> Outcome {
        guard let revision = PaydaySyncState.snapshot(for: userID).syncedDatasetRevision else {
            return .skippedNoCleanSync
        }

        let document = SnapshotDocument(snapshot)
        let digest = document.manifestDigest

        if let last = lastUploaded, last.revision == revision, last.digest == digest {
            return .skippedUnchanged
        }

        let payload: Data
        do {
            payload = try JSONEncoder().encode(document)
        } catch {
            // A document that cannot encode is a programming error, not a
            // network one, and must not be reported as `stale`.
            return .failed
        }

        do {
            let verdict = try await upload(
                revision, document.engineVersion, document.asOf, digest, payload)
            switch verdict {
            case "accepted":
                lastUploaded = (revision, digest)
                return .uploaded(revision: revision)
            case "stale_input":
                // Do NOT record it as uploaded, and do NOT clear the
                // watermark: the watermark is about local cleanliness, which
                // a losing race says nothing about. The next sync will
                // refresh it.
                return .stale
            default:
                // An unrecognised verdict is a contract change, not a
                // success. Treating an unknown string as accepted is how a
                // future server rename would silently stop publishing.
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
