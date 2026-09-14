import Foundation

/// The one place that answers "is this device currently allowed to show or
/// change Payday's financial data?", in storage every Payday process can read.
///
/// Why this exists. Authorization used to be enforced only inside `RootView`'s
/// view hierarchy — but the widget extension and the App Intents never
/// traverse it. Both open the shared App Group store directly, in their own
/// processes. A security review on 2026-09-14 found three separate
/// consequences of that single gap:
///
/// - an explicit sign-out that a cold restart silently undid, because the
///   cached-session fallback could not tell "the JWT needs a refresh" from
///   "this person deliberately left";
/// - Lock Screen widgets rendering earnings for a signed-out or app-locked
///   device;
/// - background financial intents reading and writing with no gate at all.
///
/// Three patches at three call sites would have left the same hole open for
/// the next entry point, so the policy lives here instead.
enum PaydayAuthorizationState {
    private static let explicitSignOutKey = "com.szakacsmedia.payday.explicitlySignedOut"
    private static let appLockEnabledKey = "com.szakacsmedia.payday.appLockEnabledShared"

    // MARK: - Explicit sign-out

    /// Set the instant someone asks to sign out, and cleared only by a fresh
    /// successful authentication. This is precisely the distinction the
    /// cached-session fallback in `PaydayCloudGate` could not make on its own:
    /// an absent session because the network is down, versus an absent session
    /// because the person asked to leave.
    static var isExplicitlySignedOut: Bool {
        AppGroup.defaults.bool(forKey: explicitSignOutKey)
    }

    /// Recorded BEFORE the remote sign-out call, so a failed or interrupted
    /// network round trip cannot leave the device in a state that still reads
    /// as signed in.
    static func markExplicitlySignedOut() {
        AppGroup.defaults.set(true, forKey: explicitSignOutKey)
    }

    static func clearExplicitSignOut() {
        AppGroup.defaults.removeObject(forKey: explicitSignOutKey)
    }

    // MARK: - App lock

    /// Mirror of `UserPreferencesStore.isFaceIDLockEnabled`, which lives in
    /// the app's own defaults where no other process can see it.
    ///
    /// A widget cannot know whether the app is locked *at this moment*. But
    /// someone who turned the lock on has said their earnings require
    /// authentication, and a Lock Screen widget printing the period total
    /// contradicts that regardless of what the app process is doing. So the
    /// conservative reading is the correct one: lock enabled means no ambient
    /// disclosure.
    static var isAppLockEnabled: Bool {
        AppGroup.defaults.bool(forKey: appLockEnabledKey)
    }

    static func setAppLockEnabled(_ enabled: Bool) {
        AppGroup.defaults.set(enabled, forKey: appLockEnabledKey)
    }

    // MARK: - The two questions
    //
    // Each is a pure predicate plus a thin accessor that reads shared
    // storage, so the policy itself is unit-testable without touching
    // UserDefaults — the same split as PaydaySyncState.canRegister.

    /// For surfaces that act on request — App Intents, Shortcuts, Siri.
    static var allowsFinancialAccess: Bool {
        allowsFinancialAccess(isExplicitlySignedOut: isExplicitlySignedOut)
    }

    static func allowsFinancialAccess(isExplicitlySignedOut: Bool) -> Bool {
        !isExplicitlySignedOut
    }

    /// For ambient surfaces that render with no authentication step of their
    /// own and may be visible on a locked device: home and Lock Screen
    /// widgets, StandBy, accessories.
    static var allowsAmbientDisclosure: Bool {
        allowsAmbientDisclosure(
            isExplicitlySignedOut: isExplicitlySignedOut,
            isAppLockEnabled: isAppLockEnabled
        )
    }

    static func allowsAmbientDisclosure(
        isExplicitlySignedOut: Bool,
        isAppLockEnabled: Bool
    ) -> Bool {
        !isExplicitlySignedOut && !isAppLockEnabled
    }

    // MARK: - Teardown

    /// Account deletion wipes the device, so the shared policy goes with it.
    /// Deliberately NOT a sign-out: there is no account left to return to.
    static func reset() {
        AppGroup.defaults.removeObject(forKey: explicitSignOutKey)
        AppGroup.defaults.removeObject(forKey: appLockEnabledKey)
    }
}
