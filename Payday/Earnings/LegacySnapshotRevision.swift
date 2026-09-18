import Combine
import Foundation
import SwiftUI

/// When a screen that builds its own `LegacySnapshotBridge` snapshot has to
/// build the next one.
///
/// ## Why this exists at all
///
/// PR 5's adapter contract (`SnapshotFacts.swift`, rule 3) deletes every
/// screen's hand-written `XFactsKey` — "a hand-maintained list of
/// dependencies, and a hand-maintained list is a list with something missing
/// from it" — in favour of `SnapshotStamp`, whose `digest` is a SHA-256 over
/// every input that can move a number. That works because the screen is
/// supposed to be HANDED a snapshot by `EarningsStore`, which rebuilds it
/// when an input changes. A screen reading `earningsStore.snapshot` needs no
/// trigger of its own.
///
/// Until PR 2 slice S7 lands, `earningsStore.snapshot` is empty on a real
/// device and a wave-1 screen builds its own through `LegacySnapshotBridge`
/// (see that type's header). MEASURED on the iPhone 17 Pro simulator,
/// 2026-09-18: `LegacySnapshotBridge.snapshot(entries:)` costs **41.7 ms over
/// 1,000 shifts, 113.2 ms over 3,000 and 307.4 ms over 10,000**, so it cannot
/// run once per `body` evaluation — tapping the hero drawer would re-value
/// the whole ledger. The screen has to cache it, and a cache needs an
/// invalidation signal.
///
/// ## And why it is not a second hand-maintained list
///
/// The signal is `EarningsStore.triggerNames` itself, merged: the exact four
/// notifications the app's own snapshot owner rebuilds on. There is no
/// second opinion here about what can move an input, which is the whole
/// complaint rule 3 is making. A screen using this is subscribed to the same
/// set `EarningsStore` is, so a fifth trigger added there reaches this screen
/// with no edit.
///
/// The facts cache still keys on `stamp.digest` per rule 3. This only decides
/// when the SNAPSHOT is rebuilt; the digest then decides whether the rebuild
/// actually changed the dataset, and an unchanged digest reuses the facts.
///
/// **Delete this when S7 lands.** The replacement is `earningsStore.snapshot`
/// and no revision counter at all.
enum LegacySnapshotRevision {
    /// One publisher carrying every `EarningsStore` rebuild trigger.
    ///
    /// Built per call rather than held in a `static let`: a merged
    /// `NotificationCenter.Publisher` is not `Sendable`, and the only honest
    /// way to hold one in global storage would be to claim otherwise.
    /// Constructing it is four dictionary lookups.
    static func publisher() -> Publishers.MergeMany<NotificationCenter.Publisher> {
        Publishers.MergeMany(
            EarningsStore.triggerNames.map {
                NotificationCenter.default.publisher(for: $0.0)
            }
        )
    }
}

extension View {
    /// Bumps `revision` whenever anything `EarningsStore` rebuilds on fires,
    /// so a screen holding a cached `LegacySnapshotBridge` snapshot knows the
    /// cached one is stale.
    ///
    /// Replaces the `@State private var dataRevision` + single
    /// `ModelContext.didSave` observer each screen carried: that one saw a
    /// SwiftData save and nothing else, so a queued policy change or a
    /// midnight rollover left the screen serving figures computed under the
    /// old inputs.
    func legacySnapshotRevision(_ revision: Binding<Int>) -> some View {
        onReceive(LegacySnapshotRevision.publisher()) { _ in
            revision.wrappedValue &+= 1
        }
    }
}
