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
    /// Consecutive failed/cancelled unlock attempts since locking — the
    /// gate's button reads "Unlock" until Face ID has genuinely failed,
    /// then offers "Use Passcode" (the system's own auth sheet handles the
    /// actual passcode entry after biometric failures). Resets on lock/arm
    /// and on success.
    private(set) var failedAttempts = 0

    func armIfEnabled(_ preferencesStore: UserPreferencesStore) {
        guard preferencesStore.isFaceIDLockEnabled else { return }
        isLocked = true
        failedAttempts = 0
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
            if success {
                isLocked = false
                failedAttempts = 0
            } else {
                failedAttempts += 1
            }
        } catch {
            // Stays locked; the button lets them retry, and after enough
            // failures it reads "Use Passcode" — the system sheet itself
            // offers passcode entry once biometrics have failed.
            failedAttempts += 1
        }
    }
}
