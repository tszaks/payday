import Foundation
import SwiftData

/// The replaceable on-device cache shared by the app, widget, and App
/// Intents. Supabase owns the durable account data; every process opens this
/// same App Group file with CloudKit disabled.
enum SharedModelContainer {
    private struct Resolution {
        let container: ModelContainer
        let didFallBackToMemory: Bool
    }

    /// ONE entity list, read by both `ModelContainer(for:)` calls below.
    ///
    /// The two calls used to enumerate their entities separately, which is a
    /// list that can drift: an entity added to the on-disk container and
    /// forgotten in the in-memory fallback makes a damaged cache fail to open
    /// at all instead of degrading to read-only.
    ///
    /// Adding `ShiftRecord` here is a SwiftData lightweight migration. No
    /// `VersionedSchema`, no `SchemaMigrationPlan`.
    ///
    /// **Downgrade is destructive and silent, and it is an ordinary path.**
    /// Measured 2026-09-17 on real SwiftData: a build whose schema omits
    /// `ShiftRecord` opens this same store file successfully — no throw, no
    /// in-memory fallback, no `openingFailed` — and Core Data purges every row
    /// of the omitted entity ("Persistent History has to be truncated due to
    /// the following entities being removed"). `TipEntry` and `PaycheckRecord`
    /// rows survive untouched. Re-upgrading finds zero shifts and a complete
    /// tip history. TestFlight installs of an older build, a second device on
    /// an older version, and a restore that lands an old binary all reach that
    /// state through no sync event at all.
    ///
    /// The device may never derive a shift (design 6.1), so the only repair is
    /// a forced server baseline, and the recovery has exactly ONE home:
    /// `PaydaySyncState.shiftCacheRequiresBaseline(localShiftIDs:pendingShiftDeletionIDs:checkpoint:)`
    /// (design 7.4, slice S7), driven by the sync leg's step 6 (design 7.5,
    /// slice S8). It is checkpoint-sourced on purpose. `checkpoint.shiftIDs`
    /// lives in `AppGroup.defaults`, which a SwiftData entity purge does not
    /// touch, so it survives the downgrade and still demands a baseline for an
    /// account whose shifts are all NATIVE and whose `TipEntry` count is zero
    /// — the one wiped-cache case with no legacy leg to fall back on. Any
    /// detector inferred from "converted account + zero shifts + some legacy
    /// rows" misses exactly that case, and a second durable home for the fact
    /// lets the reader consult one copy while the sync leg clears the other.
    /// S7 owes `aDowngradeThatPurgesShiftRecordsForcesABaselinePullAndNeverShowsZero`
    /// over a converted account with shifts and ZERO `TipEntry` rows.
    static let schema = Schema([TipEntry.self, PaycheckRecord.self, ShiftRecord.self])

    private static let resolution: Resolution = {
        let url = AppGroup.containerURL.appendingPathComponent("Payday.sqlite")
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        do {
            return Resolution(
                container: try ModelContainer(for: schema, configurations: configuration),
                didFallBackToMemory: false
            )
        } catch {
            // A damaged or temporarily unavailable cache must never crash the
            // app or invite writes into a replacement file. Keep SwiftData's
            // environment valid with an in-memory container, then let the app
            // show a read-only recovery screen instead of RootView.
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return Resolution(
                    container: try ModelContainer(for: schema, configurations: fallback),
                    didFallBackToMemory: true
                )
            } catch {
                // The in-memory schema has no external failure mode. If this
                // fails too, the compiled model itself is invalid.
                preconditionFailure("Payday's SwiftData model could not be constructed.")
            }
        }
    }()

    static var shared: ModelContainer { resolution.container }

    /// AUTOSAVE OFF. This is what makes `ShiftCommands`' atomicity real rather
    /// than claimed: with autosave on, a run-loop save landing between a
    /// mutation and a throw persists a partial change that `rollback()` cannot
    /// undo, so "one logical shift saves atomically" would be false however
    /// carefully the commands were written.
    ///
    /// IT LANDS IN THE SAME SLICE AS THE WRITE PATHS, DELIBERATELY. Every
    /// SwiftUI write path in this app depended on autosave and several never
    /// called `save()` at all: the paycheck sheet's save and delete, the
    /// backfill sheet's save, and LogTipSheet's saveNew, live edit, zero-row
    /// prune and delete. Turning this off before those were converted would
    /// have silently stopped persisting logged shifts, paychecks and live
    /// field edits -- and stopped firing `ModelContext.didSave`, which is what
    /// queues a sync, so nothing would have synced either. An earlier plan
    /// landed this flag several slices early; any build cut in that window
    /// loses money.
    ///
    /// A separate main-actor call rather than part of `shared`, because
    /// `mainContext` is main-actor isolated and `shared` is reachable from the
    /// widget process off the main actor. Called first thing in
    /// `PaydayApp.init`, before any view can obtain the context.
    @MainActor
    static func disableMainContextAutosave() {
        resolution.container.mainContext.autosaveEnabled = false
    }

    static var openingFailed: Bool { resolution.didFallBackToMemory }
}
