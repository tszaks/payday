import Foundation

/// The identity of one computed `EarningsSnapshot`: which inputs it came
/// from, which engine computed it, as of which day, and when.
///
/// Every `Facts` struct in the app drops its own cache key in favour of this
/// one (Design 2, "Facts structs to thin adapters"). Two screens showing the
/// same stamp are showing the same dataset by construction; two screens
/// showing different stamps have a diff a person can read, rather than an
/// argument about who is right.
///
/// `engineVersion` and `asOf` are DERIVED from `manifest`, not stored again.
/// The manifest already hashes both of them into `digest`, so a second copy
/// on this type could disagree with the fingerprint the rest of the system
/// compares — and the copy is what a reader would believe.
public struct SnapshotStamp: Hashable, Codable, Sendable {
    /// Monotonic within one process, from `EarningsStore`. It orders
    /// computations, never datasets: a second device's generation 2 says
    /// nothing about this device's generation 7. Cross-device ordering is
    /// `serverDatasetRevision`.
    public let generation: UInt64

    /// The manifest summary: five digests, four counts, `engineVersion` and
    /// `asOf`, and none of the input rows themselves.
    public let manifest: InputManifest.Summary

    public let computedAt: Date

    /// Set only when the snapshot was computed from a fully synced dataset,
    /// i.e. the local manifest digest equalled the sync checkpoint's synced
    /// digest (Design 3). Nil means "this device has local changes the
    /// server has not seen", which is exactly when a snapshot must NOT be
    /// uploaded. Design 3 wires the writer; PR 4 only carries the field.
    public let serverDatasetRevision: Int64?

    public init(
        generation: UInt64,
        manifest: InputManifest.Summary,
        computedAt: Date,
        serverDatasetRevision: Int64? = nil
    ) {
        self.generation = generation
        self.manifest = manifest
        self.computedAt = computedAt
        self.serverDatasetRevision = serverDatasetRevision
    }

    /// `CompensationLedger.engineVersion` of the engine that produced the
    /// snapshot, straight off the manifest it hashed.
    public var engineVersion: Int { manifest.engineVersion }

    /// The cutoff every query on this snapshot clamps to by default. Nil
    /// only for a manifest built without one, which a snapshot never is;
    /// a nil here means "do not clamp" rather than "clamp to nothing".
    public var asOf: CivilDay? { manifest.asOf }

    /// The full input digest, the one value two consumers compare to prove
    /// they are looking at the same dataset.
    public var digest: String { manifest.digest }
}
