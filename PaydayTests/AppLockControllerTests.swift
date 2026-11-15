import Foundation
import LocalAuthentication
import Testing
@testable import Payday

/// The Face ID lock's own rules, with the system prompt replaced by a stub
/// that counts how often it is asked and answers as told.
@Suite("App lock: arming and the automatic prompt")
@MainActor
struct AppLockControllerTests {
    @MainActor
    final class Prompt {
        var count = 0
        var answer = AppLockController.PromptOutcome.refused
    }

    private func controller(_ prompt: Prompt) -> AppLockController {
        AppLockController(authenticate: {
            prompt.count += 1
            return prompt.answer
        })
    }

    /// A store on its own defaults. Building one mirrors the lock setting
    /// into the shared app group, so the shared value is put back at once.
    private func preferences(lockEnabled: Bool) throws -> UserPreferencesStore {
        let suite = "com.szakacsmedia.payday.applock.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let wasLocked = PaydayAuthorizationState.isAppLockEnabled
        let store = UserPreferencesStore(defaults: defaults, wageDefaults: defaults)
        store.isFaceIDLockEnabled = lockEnabled
        PaydayAuthorizationState.setAppLockEnabled(wasLocked)
        return store
    }

    @Test("arming locks only when the lock is on")
    func armsOnlyWhenEnabled() throws {
        let off = controller(Prompt())
        off.armIfEnabled(try preferences(lockEnabled: false))
        #expect(!off.isLocked)

        let on = controller(Prompt())
        on.armIfEnabled(try preferences(lockEnabled: true))
        #expect(on.isLocked)
        #expect(on.failedAttempts == 0)
    }

    @Test("no prompt while in the background; one prompt when the scene becomes active")
    func promptsOnActiveNotInBackground() async throws {
        let prompt = Prompt()
        let lock = controller(prompt)
        lock.armIfEnabled(try preferences(lockEnabled: true))

        await lock.unlockAutomatically(sceneIsActive: false)
        #expect(prompt.count == 0)
        #expect(lock.failedAttempts == 0)

        prompt.answer = .unlocked
        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 1)
        #expect(!lock.isLocked)
    }

    @Test("a cancelled prompt does not reopen on its own; the button and the next return still prompt")
    func noPromptLoop() async throws {
        let prompt = Prompt()
        let lock = controller(prompt)
        let preferences = try preferences(lockEnabled: true)
        lock.armIfEnabled(preferences)

        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 1)
        #expect(lock.isLocked)
        #expect(lock.failedAttempts == 1)

        // The prompt took the scene to inactive and back to active.
        await lock.unlockAutomatically(sceneIsActive: false)
        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 1)

        // The Unlock button always asks.
        await lock.unlock()
        #expect(prompt.count == 2)
        #expect(lock.failedAttempts == 2)

        // Back to the background and to the front again: one new prompt.
        lock.armIfEnabled(preferences)
        #expect(lock.failedAttempts == 0)
        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 3)
    }

    @Test("no automatic prompt when the app is not locked")
    func noPromptWhenUnlocked() async {
        let prompt = Prompt()
        let lock = controller(prompt)
        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 0)
    }

    @Test("a prompt the system took away does not use up the automatic offer or count as a failure")
    func systemCancelOffersAgain() async throws {
        let prompt = Prompt()
        let lock = controller(prompt)
        lock.armIfEnabled(try preferences(lockEnabled: true))
        prompt.answer = .cancelledBySystem

        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 1)
        #expect(lock.isLocked)
        #expect(lock.failedAttempts == 0)

        // The next activation offers again; the system cancelling once more
        // costs nothing either.
        await lock.unlockAutomatically(sceneIsActive: false)
        #expect(prompt.count == 1)
        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 2)
        #expect(lock.failedAttempts == 0)

        prompt.answer = .unlocked
        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 3)
        #expect(!lock.isLocked)
    }

    @Test("a system-cancelled Unlock tap is not a failure; the person's own cancel is, and is not offered again")
    func onlyThePersonsAnswerCounts() async throws {
        let prompt = Prompt()
        let lock = controller(prompt)
        lock.armIfEnabled(try preferences(lockEnabled: true))

        prompt.answer = .cancelledBySystem
        await lock.unlock()
        #expect(lock.failedAttempts == 0)

        prompt.answer = .refused
        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 2)
        #expect(lock.failedAttempts == 1)
        await lock.unlockAutomatically(sceneIsActive: false)
        await lock.unlockAutomatically(sceneIsActive: true)
        #expect(prompt.count == 2)
    }

    @Test("only the system's own cancels count as a prompt the person never saw",
          arguments: [
            (LAError.Code.systemCancel, AppLockController.PromptOutcome.cancelledBySystem),
            (.appCancel, .cancelledBySystem),
            (.notInteractive, .cancelledBySystem),
            (.userCancel, .refused),
            (.userFallback, .refused),
            (.authenticationFailed, .refused),
            (.biometryLockout, .refused),
            (.passcodeNotSet, .refused),
          ])
    func classifiesTheSystemsAnswer(_ code: LAError.Code, _ expected: AppLockController.PromptOutcome) {
        #expect(AppLockController.outcome(of: LAError(code)) == expected)
    }

    @Test("an error that is not LocalAuthentication's keeps the person out")
    func unknownErrorIsRefused() {
        #expect(AppLockController.outcome(of: CocoaError(.featureUnsupported)) == .refused)
    }
}
