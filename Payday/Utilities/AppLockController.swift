import Foundation
import LocalAuthentication

/// Face ID/Touch ID gate over the app when it returns from the background —
/// the same idea as Notes' lock. Arms the instant the app backgrounds (so
/// there's no gap where a locked screen shows unlocked content), not on
/// return; RootView presents LockGateView as a full-screen cover whenever
/// isLocked is true.
@MainActor
@Observable
final class AppLockController {
    var isLocked = false

    func armIfEnabled(_ preferencesStore: UserPreferencesStore) {
        guard preferencesStore.isFaceIDLockEnabled else { return }
        isLocked = true
    }

    /// Face ID/Touch ID with device-passcode fallback, matching Notes.
    /// No enrolled biometrics or passcode at all means the device itself
    /// has no lock screen — fails open rather than stranding someone
    /// outside their own tips with no way back in.
    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Payday")
            if success { isLocked = false }
        } catch {
            // Stays locked; the Unlock button lets them retry.
        }
    }
}
