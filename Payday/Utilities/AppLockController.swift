import Foundation
import LocalAuthentication

/// Face ID/Touch ID gate over the app when it returns from the background —
/// the same idea as Notes' lock. Arms the instant the app backgrounds (so
/// there's no gap where a locked screen shows unlocked content), not on
/// return; AppLockWindow shows LockGateView in a window above the signed-in
/// content whenever isLocked is true.
@MainActor
@Observable
final class AppLockController {
    var isLocked = false
    /// Consecutive failed/person-cancelled unlock attempts since locking — the
    /// gate's button reads "Unlock" until Face ID has genuinely failed,
    /// then offers "Use Passcode" (the system's own auth sheet handles the
    /// actual passcode entry after biometric failures). Resets on lock/arm
    /// and on success.
    private(set) var failedAttempts = 0
    /// Whether the gate has offered its automatic prompt since the lock was
    /// last armed. The prompt itself takes the scene to inactive and back to
    /// active, so without this a cancelled prompt would reopen on its own.
    private var hasOfferedAutomaticUnlock = false
    private let authenticate: @MainActor () async -> PromptOutcome

    /// What one unlock prompt came to.
    enum PromptOutcome {
        /// Authenticated, or the device has no lock to authenticate with.
        case unlocked
        /// The person cancelled the prompt or did not get through it.
        case refused
        /// The system took the prompt away before the person could answer
        /// it, as when the app leaves the front while the prompt opens.
        case cancelledBySystem
    }

    init(authenticate: @escaping @MainActor () async -> PromptOutcome = AppLockController.authenticateDeviceOwner) {
        self.authenticate = authenticate
    }

    func armIfEnabled(_ preferencesStore: UserPreferencesStore) {
        guard preferencesStore.isFaceIDLockEnabled else { return }
        isLocked = true
        failedAttempts = 0
        hasOfferedAutomaticUnlock = false
    }

    @discardableResult
    func unlock() async -> PromptOutcome {
        let outcome = await authenticate()
        switch outcome {
        case .unlocked:
            isLocked = false
            failedAttempts = 0
        case .refused:
            // Stays locked; the button lets them retry, and after enough
            // failures it reads "Use Passcode" — the system sheet itself
            // offers passcode entry once biometrics have failed.
            failedAttempts += 1
        case .cancelledBySystem:
            // Nobody saw the prompt, so nothing was attempted.
            break
        }
        return outcome
    }

    /// The prompt the gate offers without a tap: once each time the app
    /// comes to the front locked. It waits for an active scene because the
    /// gate goes up while the app is in the background, where nobody can see
    /// the prompt.
    func unlockAutomatically(sceneIsActive: Bool) async {
        guard isLocked, sceneIsActive, !hasOfferedAutomaticUnlock else { return }
        hasOfferedAutomaticUnlock = true
        // A prompt the system took away was never seen, so the next time the
        // app comes to the front offers it again.
        if await unlock() == .cancelledBySystem {
            hasOfferedAutomaticUnlock = false
        }
    }

    /// Face ID/Touch ID with device-passcode fallback, matching Notes.
    /// No enrolled biometrics or passcode at all means the device itself
    /// has no lock screen — fails open rather than stranding someone
    /// outside their own tips with no way back in.
    private static func authenticateDeviceOwner() async -> PromptOutcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unlocked }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Payday") ? .unlocked : .refused
        } catch {
            return outcome(of: error)
        }
    }

    /// Only the cancels that come from the system or the app itself; every
    /// answer the person gave, a lockout included, keeps them out.
    nonisolated static func outcome(of error: any Error) -> PromptOutcome {
        switch (error as? LAError)?.code {
        case .systemCancel, .appCancel, .notInteractive: .cancelledBySystem
        default: .refused
        }
    }
}
