import Foundation
import PaydayCore
import Supabase

/// Owns the one `SnapshotUploader` and turns a synchronous publish into the
/// asynchronous upload it needs.
///
/// A separate type rather than a closure in `PaydayApp` for one reason:
/// `SnapshotUploader` is STATEFUL -- it remembers the last
/// (revision, digest) it sent so an unchanged document is not re-sent on
/// every republication. A closure capturing a fresh uploader each time
/// would defeat that, and a closure capturing one long-lived uploader is
/// the same thing as this type with the ownership hidden.
///
/// `Task` rather than `await` at the call site because the publish point is
/// the one writer of `EarningsStore.state`, and making a UI state write
/// wait on a network round trip is how a snapshot publication becomes a
/// dropped frame.
@MainActor
final class SnapshotPublisher {
    static let shared = SnapshotPublisher()

    private let uploader = SnapshotUploader()
    private let repository: PaydayRemoteRepository

    init(repository: PaydayRemoteRepository = PaydayRemoteRepository(client: PaydaySupabase.client)) {
        self.repository = repository
    }

    func publish(_ snapshot: EarningsSnapshot) {
        guard let userID = PaydaySyncState.registeredUserID else { return }
        Task { @MainActor [uploader, repository] in
            _ = await uploader.publish(snapshot, for: userID) {
                revision, engineVersion, asOf, digest, payload in
                try await repository.upsertEarningsSnapshot(
                    revision: revision,
                    engineVersion: engineVersion,
                    asOf: asOf?.iso,
                    manifestDigest: digest,
                    payload: payload
                )
            }
        }
    }
}
