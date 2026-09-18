import Foundation

/// Whether a sheet editing a LEGACY `TipEntry` is on screen right now.
///
/// It exists for exactly one job: `ShiftReadAuthority.resolve` will not
/// promote an account to the new representation while such a sheet is open,
/// so no legacy-edit sheet can straddle the flip. That function's header
/// carries the reasoning, including why promotion defers and demotion never
/// does.
///
/// A count rather than a flag, because two can be on screen at once -- a day
/// detail sheet presenting a log sheet over itself is a real path -- and the
/// first one to dismiss must not clear a hold the second still needs.
///
/// Deliberately NOT observable and deliberately not stored. Nothing renders
/// from it; it is read once per sync pass at the moment a promotion is being
/// decided. Making it `@Observable` would invite a view to key off it, and a
/// view that re-renders when a sheet opens elsewhere is a different kind of
/// bug. It is also process-local and resets on launch, which is correct: a
/// sheet cannot survive a launch, so a persisted hold could only ever be a
/// stale one that blocked the flip forever.
@MainActor
enum LegacyEditSheetPresence {
    private static var openCount = 0

    /// Read by `PaydaySyncService` when it is about to promote.
    static var isPresented: Bool { openCount > 0 }

    /// Paired with `end()` from a sheet's `onAppear`/`onDisappear`. Balanced
    /// by the view lifecycle rather than by a `defer`, because the interval
    /// being protected is the sheet being VISIBLE, not a function's scope.
    static func begin() {
        openCount += 1
    }

    static func end() {
        // Clamped rather than asserted. An unbalanced `end()` is possible if
        // SwiftUI ever delivers `onDisappear` without a matching `onAppear`,
        // and the failure mode of going negative is far worse than the one
        // being guarded against: a negative count reads as "no sheet open"
        // forever after, which silently disables the whole deferral.
        openCount = max(0, openCount - 1)
    }

    #if DEBUG
    /// Test-only reset, so one suite's unbalanced case cannot leak into the
    /// next suite's promotion decision.
    static func resetForTesting() {
        openCount = 0
    }
    #endif
}
