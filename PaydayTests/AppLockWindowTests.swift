import SwiftUI
import Testing
import UIKit
@testable import Payday

/// The lock's own window, put up in the test host's real scene. Serialized
/// because every test counts the lock windows in that one scene.
@Suite("App lock: the lock window above the app", .serialized)
@MainActor
struct AppLockWindowTests {
    @MainActor
    final class Prompt {
        var count = 0
    }

    /// Counts how often the probe below appears and disappears, so a test can
    /// tell a view that stayed on screen from one that was rebuilt.
    @MainActor
    final class Lifecycle {
        var appeared = 0
        var disappeared = 0
    }

    @MainActor
    @Observable
    final class Presence {
        var isPresent = true
    }

    /// Stands in for the signed-in content, wired the way RootView wires it.
    private struct Probe: View {
        let lifecycle: Lifecycle
        let presence: Presence
        let lockWindow: AppLockWindow
        let lockController: AppLockController

        var body: some View {
            if presence.isPresent {
                Text("Signed-in content")
                    .onAppear { lifecycle.appeared += 1 }
                    .onDisappear { lifecycle.disappeared += 1 }
                    .appLockWindow(lockWindow, lockController: lockController)
            }
        }
    }

    private func scene() throws -> UIWindowScene {
        try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }

    private func lockWindows(in scene: UIWindowScene) -> [UIWindow] {
        scene.windows.filter { $0.windowLevel > .alert && !$0.isHidden && $0.alpha > 0 }
    }

    /// The lock's window while it stands by: in place, and unseen.
    private func standbyWindows(in scene: UIWindowScene) -> [UIWindow] {
        scene.windows.filter { $0.windowLevel > .alert && !$0.isHidden && $0.alpha == 0 }
    }

    /// A store on its own defaults. Building one mirrors the lock setting
    /// into the shared app group, so the shared value is put back at once.
    private func preferences(lockEnabled: Bool = false, appearance: AppAppearance = .system) throws -> UserPreferencesStore {
        let suite = "com.szakacsmedia.payday.applockwindow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(appearance.rawValue, forKey: AppGroup.appearanceKey)
        let wasLocked = PaydayAuthorizationState.isAppLockEnabled
        let store = UserPreferencesStore(defaults: defaults, wageDefaults: defaults)
        store.isFaceIDLockEnabled = lockEnabled
        PaydayAuthorizationState.setAppLockEnabled(wasLocked)
        return store
    }

    private func lockedController(_ prompt: Prompt = Prompt(), answer: AppLockController.PromptOutcome = .refused) -> AppLockController {
        let controller = AppLockController(authenticate: {
            prompt.count += 1
            return answer
        })
        controller.isLocked = true
        return controller
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test("the lock goes up above alerts, takes the key window and is modal for VoiceOver; a second update adds nothing")
    func showsAboveEverything() throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = lockedController()
        defer { lock.isLocked = false; lockWindow.update() }

        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences())
        let shown = lockWindows(in: scene)
        #expect(shown.count == 1)
        let window = try #require(shown.first)
        #expect(window.windowLevel > .alert)
        #expect(window.isKeyWindow)
        #expect(window.accessibilityViewIsModal)
        #expect(window.backgroundColor?.cgColor.alpha == 1)

        lockWindow.update()
        #expect(lockWindows(in: scene).count == 1)
        #expect(lockWindows(in: scene).first === window)
    }

    @Test("unlocking takes the window down, releases it and gives the key window back, any number of times")
    func hidesAndReleases() async throws {
        let scene = try scene()
        let appWindow = UIWindow(windowScene: scene)
        appWindow.rootViewController = UIViewController()
        appWindow.makeKeyAndVisible()
        defer { appWindow.isHidden = true }
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = lockedController()
        let preferences = try preferences()

        for _ in 0..<3 {
            lock.isLocked = true
            lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: preferences)
            weak let shown = lockWindows(in: scene).first
            weak let content = shown?.rootViewController
            #expect(shown != nil)
            #expect(content != nil)

            lock.isLocked = false
            lockWindow.update()
            lockWindow.update()
            try await settle()
            #expect(lockWindows(in: scene).isEmpty)
            #expect(shown == nil)
            #expect(content == nil)
            #expect(appWindow.isKeyWindow)
        }
    }

    @Test("with no scene nothing goes up, and losing the scene takes the lock down")
    func needsTheSignedInScene() throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = lockedController()
        let preferences = try preferences()
        defer { lock.isLocked = false; lockWindow.update() }

        lockWindow.attach(anchor, to: nil, lockController: lock, preferencesStore: preferences)
        lockWindow.update()
        #expect(lockWindows(in: scene).isEmpty)

        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: preferences)
        #expect(lockWindows(in: scene).count == 1)

        lockWindow.attach(anchor, to: nil, lockController: lock, preferencesStore: preferences)
        #expect(lockWindows(in: scene).isEmpty)
    }

    @Test("a screen that leaves after its replacement arrived does not take the lock down")
    func survivesASwapOfTheContentUnderIt() throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let lock = lockedController()
        let preferences = try preferences()
        defer { lock.isLocked = false; lockWindow.update() }
        let leaving = NSObject()
        let arriving = NSObject()

        lockWindow.attach(leaving, to: scene, lockController: lock, preferencesStore: preferences)
        lockWindow.attach(arriving, to: scene, lockController: lock, preferencesStore: preferences)
        lockWindow.attach(leaving, to: nil, lockController: lock, preferencesStore: preferences)
        #expect(lockWindows(in: scene).count == 1)

        lockWindow.attach(arriving, to: nil, lockController: lock, preferencesStore: preferences)
        #expect(lockWindows(in: scene).isEmpty)
    }

    @Test("standing by makes the lock's window without showing it or touching the app")
    func standsByUnseen() throws {
        let scene = try scene()
        let field = UITextField()
        let appWindow = UIWindow(windowScene: scene)
        appWindow.rootViewController = UIViewController()
        appWindow.rootViewController?.view.addSubview(field)
        appWindow.makeKeyAndVisible()
        defer { appWindow.isHidden = true }
        try #require(field.becomeFirstResponder())
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = AppLockController(authenticate: { .refused })
        defer { lockWindow.update() }
        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences(lockEnabled: true))

        lockWindow.standBy()
        lockWindow.standBy()
        #expect(lockWindows(in: scene).isEmpty)
        #expect(standbyWindows(in: scene).count == 1)
        let waiting = try #require(standbyWindows(in: scene).first)
        #expect(!waiting.isKeyWindow)
        #expect(!waiting.isUserInteractionEnabled)
        #expect(waiting.accessibilityElementsHidden)
        #expect(appWindow.isKeyWindow)
        #expect(!appWindow.accessibilityElementsHidden)
        #expect(field.isFirstResponder)
        field.resignFirstResponder()
    }

    @Test("arming uncovers the window that stood by: the same window, opaque, key and readable")
    func uncoversTheWindowThatStoodBy() throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = AppLockController(authenticate: { .refused })
        defer { lock.isLocked = false; lockWindow.update() }
        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences(lockEnabled: true))

        lockWindow.standBy()
        let waiting = try #require(standbyWindows(in: scene).first)
        lock.isLocked = true
        lockWindow.update()

        #expect(standbyWindows(in: scene).isEmpty)
        #expect(lockWindows(in: scene).count == 1)
        let shown = try #require(lockWindows(in: scene).first)
        #expect(shown === waiting)
        #expect(shown.alpha == 1)
        #expect(shown.backgroundColor?.cgColor.alpha == 1)
        #expect(shown.isKeyWindow)
        #expect(shown.isUserInteractionEnabled)
        #expect(!shown.accessibilityElementsHidden)
    }

    @Test("a trip that never left the app takes the standby window down again and releases it")
    func standbyGoesWhenNothingArmed() async throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = AppLockController(authenticate: { .refused })
        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences(lockEnabled: true))

        lockWindow.standBy()
        weak let waiting = standbyWindows(in: scene).first
        #expect(waiting != nil)

        lockWindow.update()
        try await settle()
        #expect(standbyWindows(in: scene).isEmpty)
        #expect(waiting == nil)
    }

    @Test("nothing stands by with the lock setting off, or with no signed-in scene")
    func standsByOnlyForAnEnabledLock() throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = AppLockController(authenticate: { .refused })
        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences(lockEnabled: false))
        lockWindow.standBy()
        #expect(standbyWindows(in: scene).isEmpty)

        AppLockWindow().standBy()
        #expect(standbyWindows(in: scene).isEmpty)
    }

    @Test("a focused field gives up the keyboard when the lock goes up, and keeps what was typed")
    func resignsTheKeyboard() throws {
        let scene = try scene()
        let field = UITextField()
        let appWindow = UIWindow(windowScene: scene)
        appWindow.rootViewController = UIViewController()
        appWindow.rootViewController?.view.addSubview(field)
        appWindow.makeKeyAndVisible()
        defer { appWindow.isHidden = true }
        field.text = "4250"
        try #require(field.becomeFirstResponder())

        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = lockedController()
        defer { lock.isLocked = false; lockWindow.update() }
        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences())

        #expect(!field.isFirstResponder)
        #expect(field.text == "4250")
    }

    @Test("a field that takes focus under the lock does not bring the keyboard up over it")
    func keepsTheKeyboardDownWhileLocked() throws {
        let scene = try scene()
        let field = UITextField()
        let appWindow = UIWindow(windowScene: scene)
        appWindow.rootViewController = UIViewController()
        appWindow.rootViewController?.view.addSubview(field)
        appWindow.isHidden = false
        defer { appWindow.isHidden = true }

        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = lockedController()
        defer { lock.isLocked = false; lockWindow.update() }
        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences())

        try #require(field.becomeFirstResponder())
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        #expect(!field.isFirstResponder)

        // Once unlocked, focus is the app's own business again.
        lock.isLocked = false
        lockWindow.update()
        try #require(field.becomeFirstResponder())
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        #expect(field.isFirstResponder)
        field.resignFirstResponder()
    }

    @Test("the lock follows the app's own appearance setting", arguments: [AppAppearance.dark, .light])
    func followsAppearance(_ appearance: AppAppearance) async throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = lockedController()
        defer { lock.isLocked = false; lockWindow.update() }

        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences(appearance: appearance))
        let view = try #require(lockWindows(in: scene).first?.rootViewController?.view)
        let expected: UIUserInterfaceStyle = appearance == .dark ? .dark : .light
        try await wait { view.traitCollection.userInterfaceStyle == expected }
        #expect(view.traitCollection.userInterfaceStyle == expected)
    }

    @Test("the automatic prompt: once per activation, never while inactive, not again after a cancel")
    func promptsFromTheScenesActivation() async throws {
        let scene = try scene()
        let prompt = Prompt()
        let lock = lockedController(prompt)
        let preferences = try preferences(lockEnabled: true)
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        defer { lock.isLocked = false; lockWindow.update() }

        // The test host's scene is in the foreground and active.
        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: preferences)
        try await wait { prompt.count == 1 }
        #expect(prompt.count == 1)

        // The cancelled prompt took the scene to inactive and back.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await settle()
        #expect(prompt.count == 1)

        // A new trip to the background re-arms; nothing while inactive, one
        // prompt when the scene is active again.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        lock.armIfEnabled(preferences)
        try await settle()
        #expect(prompt.count == 1)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await wait { prompt.count == 2 }
        #expect(prompt.count == 2)
    }

    @Test("locking and unlocking leave the content under the lock on screen, never rebuilt")
    func keepsTheContentUnderTheLock() async throws {
        let scene = try scene()
        let lifecycle = Lifecycle()
        let presence = Presence()
        let lockWindow = AppLockWindow()
        let lock = AppLockController(authenticate: { .refused })
        defer { lock.isLocked = false; lockWindow.update() }
        let appWindow = UIWindow(windowScene: scene)
        appWindow.rootViewController = UIHostingController(rootView: Probe(
            lifecycle: lifecycle, presence: presence, lockWindow: lockWindow, lockController: lock
        ).environment(try preferences()))
        appWindow.isHidden = false
        defer { appWindow.isHidden = true }
        try await wait { lifecycle.appeared == 1 }
        #expect(lifecycle.appeared == 1)

        for _ in 0..<2 {
            lock.isLocked = true
            try await wait { lockWindows(in: scene).count == 1 }
            #expect(lockWindows(in: scene).count == 1)
            lock.isLocked = false
            try await wait { lockWindows(in: scene).isEmpty }
            #expect(lockWindows(in: scene).isEmpty)
        }
        #expect(lifecycle.appeared == 1)
        #expect(lifecycle.disappeared == 0)

        // Signing out removes the content; the lock goes with it.
        lock.isLocked = true
        try await wait { lockWindows(in: scene).count == 1 }
        presence.isPresent = false
        try await wait { lockWindows(in: scene).isEmpty }
        #expect(lifecycle.disappeared == 1)
        #expect(lockWindows(in: scene).isEmpty)
    }

    @Test("content that arrives already locked has the lock over it before its first frame")
    func coversContentFromItsFirstLayout() throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let lock = lockedController()
        defer { lock.isLocked = false; lockWindow.update() }
        let appWindow = UIWindow(windowScene: scene)
        appWindow.rootViewController = UIHostingController(rootView: Probe(
            lifecycle: Lifecycle(), presence: Presence(), lockWindow: lockWindow, lockController: lock
        ).environment(try preferences()))
        defer { appWindow.isHidden = true }

        appWindow.isHidden = false
        appWindow.layoutIfNeeded()
        #expect(lockWindows(in: scene).count == 1)
    }

    @Test("while the lock is up, assistive technology cannot reach the windows under it; afterwards each window has its own value back")
    func hidesTheWindowsUnderItFromAssistiveTechnology() throws {
        let scene = try scene()
        let appWindow = UIWindow(windowScene: scene)
        appWindow.rootViewController = UIViewController()
        appWindow.isHidden = false
        let alreadyHidden = UIWindow(windowScene: scene)
        alreadyHidden.rootViewController = UIViewController()
        alreadyHidden.accessibilityElementsHidden = true
        alreadyHidden.isHidden = false
        // Stands in for the keyboard's and the system's windows above the lock.
        let above = UIWindow(windowScene: scene)
        above.windowLevel = .alert + 2
        above.rootViewController = UIViewController()
        above.isHidden = false
        defer { [appWindow, alreadyHidden, above].forEach { $0.isHidden = true } }
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = lockedController()
        let preferences = try preferences()
        defer { lock.isLocked = false; lockWindow.update() }

        for _ in 0..<2 {
            lock.isLocked = true
            lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: preferences)
            let shown = try #require(lockWindows(in: scene).first { $0 !== above })
            #expect(appWindow.accessibilityElementsHidden)
            #expect(alreadyHidden.accessibilityElementsHidden)
            #expect(!above.accessibilityElementsHidden)
            #expect(!shown.accessibilityElementsHidden)

            lock.isLocked = false
            lockWindow.update()
            #expect(!appWindow.accessibilityElementsHidden)
            #expect(alreadyHidden.accessibilityElementsHidden)
            #expect(!above.accessibilityElementsHidden)
        }
    }

    @Test("a window that appears under the lock while it is up is hidden from assistive technology too, and given back on unlock")
    func hidesAWindowThatAppearsWhileLocked() throws {
        let scene = try scene()
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        let lock = lockedController()
        defer { lock.isLocked = false; lockWindow.update() }
        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences())

        let late = UIWindow(windowScene: scene)
        late.rootViewController = UIViewController()
        late.isHidden = false
        defer { late.isHidden = true }
        #expect(late.accessibilityElementsHidden)

        lock.isLocked = false
        lockWindow.update()
        #expect(!late.accessibilityElementsHidden)

        // Unlocked, a new window is the app's own business.
        let afterwards = UIWindow(windowScene: scene)
        afterwards.rootViewController = UIViewController()
        afterwards.isHidden = false
        defer { afterwards.isHidden = true }
        #expect(!afterwards.accessibilityElementsHidden)
    }

    @Test("a prompt the system keeps cancelling is offered once per activation, never in a loop")
    func systemCancelDoesNotLoop() async throws {
        let scene = try scene()
        let prompt = Prompt()
        let lock = lockedController(prompt, answer: .cancelledBySystem)
        let lockWindow = AppLockWindow()
        let anchor = NSObject()
        defer { lock.isLocked = false; lockWindow.update() }

        lockWindow.attach(anchor, to: scene, lockController: lock, preferencesStore: try preferences(lockEnabled: true))
        try await wait { prompt.count == 1 }
        try await settle()
        #expect(prompt.count == 1)

        // The next activation; each half gets its own update, as a real one does.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        try await settle()
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await wait { prompt.count == 2 }
        try await settle()
        #expect(prompt.count == 2)
    }
}
