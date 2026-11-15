import SwiftUI
import UIKit

/// Shows the lock in a window of its own, above the app's window.
///
/// The lock cannot live inside the app's view tree. A sheet, an alert or a
/// menu the app has open is presented above that whole tree, so a lock
/// layered anywhere in it would leave the sheet, and any amount on it,
/// readable on top of the lock; and swapping the content out for the lock
/// throws away whatever was open, half-typed amounts included. A window at a
/// higher level covers every presentation of the app's window and leaves
/// the tree under it alone.
///
/// The window is made as the scene stops being active (`standBy`) and only
/// uncovered when the lock arms. The system takes the app switcher's
/// snapshot as the scene reaches the background, and a hosting controller
/// made at that moment has not drawn yet: the snapshot would show the app
/// through an empty window. One made a moment earlier, while the scene can
/// still draw, is ready. Its own opaque background covers the app even if
/// the lock's view is not.
@MainActor
final class AppLockWindow {
    /// Above alerts, and so above every presentation of the app's window.
    private static let level = UIWindow.Level.alert + 1

    private var window: UIWindow?
    private var lockGate: UIHostingController<LockWindowContent>?
    /// Whether the window is up as the lock, rather than standing by unseen.
    private var isUp = false
    /// The scene of the signed-in content, while that content is in a
    /// window. Nil otherwise, so the lock never covers the welcome flow.
    private weak var scene: UIWindowScene?
    /// The view that reported `scene`. When one signed-in screen replaces
    /// another, the old view can leave its window after the new one has
    /// arrived, and its leaving must not take the lock down.
    private weak var anchor: AnyObject?
    private weak var previousKeyWindow: UIWindow?
    private var lockController: AppLockController?
    private var preferencesStore: UserPreferencesStore?
    private var observers: [NSObjectProtocol] = []
    /// The windows under the lock that it hides from assistive technology,
    /// each with the value it had, so taking the lock down gives it back.
    private var coveredWindows: [CoveredWindow] = []

    private struct CoveredWindow {
        weak var window: UIWindow?
        let wasHidden: Bool
    }

    /// Makes the lock's window, unseen, as the scene stops being active, so
    /// that it has drawn by the time the lock arms. Only with the lock
    /// setting on: without it nothing will arm.
    func standBy() {
        guard window == nil, let scene, let lockController, let preferencesStore,
              preferencesStore.isFaceIDLockEnabled else { return }
        makeWindow(in: scene, lockController: lockController, preferencesStore: preferencesStore)
    }

    /// Puts the lock up or takes it down to match the controller, and takes
    /// down a window that stood by for a lock that did not arm. It acts at
    /// once rather than on a later update, so the backgrounding handler can
    /// call it before the system takes the app switcher's snapshot.
    func update() {
        if let scene, let lockController, let preferencesStore, lockController.isLocked {
            show(in: scene, lockController: lockController, preferencesStore: preferencesStore)
        } else {
            hide()
        }
    }

    /// Called by `appLockWindow` as the signed-in content gets a window and
    /// as it leaves it. `anchor` is the view reporting.
    func attach(_ anchor: AnyObject, to scene: UIWindowScene?, lockController: AppLockController, preferencesStore: UserPreferencesStore) {
        if scene == nil {
            guard self.anchor === anchor else { return }
            self.anchor = nil
        } else {
            self.anchor = anchor
        }
        self.scene = scene
        self.lockController = lockController
        self.preferencesStore = preferencesStore
        update()
    }

    /// The lock's window, in place above the app but unseen: clear, deaf to
    /// touches and hidden from assistive technology until `show` uncovers it.
    private func makeWindow(in scene: UIWindowScene, lockController: AppLockController, preferencesStore: UserPreferencesStore) {
        let lockGate = UIHostingController(rootView: LockWindowContent(
            lockController: lockController,
            preferencesStore: preferencesStore,
            sceneIsActive: scene.activationState == .foregroundActive
        ))
        let window = UIWindow(windowScene: scene)
        window.windowLevel = Self.level
        window.overrideUserInterfaceStyle = Self.interfaceStyle(for: preferencesStore.appearance)
        window.backgroundColor = UIColor(PaydayColor.background)
        window.alpha = 0
        window.isUserInteractionEnabled = false
        window.accessibilityElementsHidden = true
        window.accessibilityViewIsModal = true
        window.rootViewController = lockGate
        window.isHidden = false
        window.layoutIfNeeded()
        self.window = window
        self.lockGate = lockGate
    }

    private func show(in scene: UIWindowScene, lockController: AppLockController, preferencesStore: UserPreferencesStore) {
        guard !isUp else { return }
        if window == nil {
            makeWindow(in: scene, lockController: lockController, preferencesStore: preferencesStore)
        }
        guard let window, let lockGate else { return }
        // The keyboard lives in a window above every app window, so a field
        // left focused would keep it up over the lock. Resigning keeps what
        // was typed in the field.
        endEditing(in: scene)
        lockGate.rootView.sceneIsActive = scene.activationState == .foregroundActive
        previousKeyWindow = scene.keyWindow
        window.alpha = 1
        window.isUserInteractionEnabled = true
        window.accessibilityElementsHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        isUp = true
        hideFromAssistiveTechnology(in: scene)
        observe(scene)
        UIAccessibility.post(notification: .screenChanged, argument: lockGate.view)
    }

    private func hide() {
        guard let window else { return }
        window.isHidden = true
        self.window = nil
        lockGate = nil
        guard isUp else { return }
        isUp = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for covered in coveredWindows {
            covered.window?.accessibilityElementsHidden = covered.wasHidden
        }
        coveredWindows = []
        previousKeyWindow?.makeKey()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// The window's own style, so its background is the app's before the
    /// lock's view has passed its appearance up.
    private static func interfaceStyle(for appearance: AppAppearance) -> UIUserInterfaceStyle {
        switch appearance {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// `queue: .main` runs each block on the main thread, which is what
    /// makes `assumeIsolated` true rather than hopeful.
    private func observe(_ scene: UIWindowScene) {
        let center = NotificationCenter.default
        observers = [
            // The lock's view cannot read `scenePhase`: in a hosting
            // controller of its own window it stays `.background` while the
            // scene is active. The scene's own notifications are the source.
            center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockGate?.rootView.sceneIsActive = true }
            },
            center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockGate?.rootView.sceneIsActive = false }
            },
            // A window the app or the system puts up for the app while locked.
            center.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scene = self.scene else { return }
                    self.hideFromAssistiveTechnology(in: scene)
                }
            },
            // A field that takes focus under the lock, such as the autofocused
            // amount on a Log Shift sheet a quick action opened, would bring
            // the keyboard up over the lock.
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scene = self.scene else { return }
                    self.endEditing(in: scene)
                }
            },
        ]
    }

    /// `accessibilityViewIsModal` on the lock only asks VoiceOver to skip
    /// the windows beside it; other assistive technology still reads them,
    /// open sheet and typed amounts included. Hiding their elements keeps
    /// what the lock covers out of reach. The keyboard's and the system's
    /// windows above the lock are not the app's to hide.
    private func hideFromAssistiveTechnology(in scene: UIWindowScene) {
        for appWindow in scene.windows where appWindow.windowLevel < Self.level
            && !coveredWindows.contains(where: { $0.window === appWindow }) {
            coveredWindows.append(CoveredWindow(window: appWindow, wasHidden: appWindow.accessibilityElementsHidden))
            appWindow.accessibilityElementsHidden = true
        }
    }

    /// Only the windows under the lock: the keyboard's own windows and any
    /// system window above the lock are not the app's to dismiss.
    private func endEditing(in scene: UIWindowScene) {
        for appWindow in scene.windows where appWindow.windowLevel < Self.level {
            appWindow.endEditing(true)
        }
    }
}

/// The lock as its window shows it, in the app's own appearance.
private struct LockWindowContent: View {
    let lockController: AppLockController
    let preferencesStore: UserPreferencesStore
    var sceneIsActive: Bool

    var body: some View {
        LockGateView(lockController: lockController, sceneIsActive: sceneIsActive)
            .paydayAppearance()
            .environment(preferencesStore)
    }
}

extension View {
    /// Puts the lock in a window above this view's window whenever
    /// `lockController` is locked, and takes it down when this view leaves
    /// the screen.
    func appLockWindow(_ lockWindow: AppLockWindow, lockController: AppLockController) -> some View {
        modifier(AppLockWindowModifier(lockWindow: lockWindow, lockController: lockController))
    }
}

private struct AppLockWindowModifier: ViewModifier {
    let lockWindow: AppLockWindow
    let lockController: AppLockController
    @Environment(UserPreferencesStore.self) private var preferencesStore

    func body(content: Content) -> some View {
        let preferencesStore = preferencesStore
        content
            .background(SceneAnchor { anchor, scene in
                lockWindow.attach(anchor, to: scene, lockController: lockController, preferencesStore: preferencesStore)
            })
            .onChange(of: lockController.isLocked) {
                lockWindow.update()
            }
    }
}

/// Reports the window scene of the view it sits in: when the view first
/// gets a window, which is before that window draws, and nil when the view
/// leaves it.
private struct SceneAnchor: UIViewRepresentable {
    let onSceneChange: (AnchorView, UIWindowScene?) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.onSceneChange = onSceneChange
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.onSceneChange = onSceneChange
    }

    final class AnchorView: UIView {
        var onSceneChange: ((AnchorView, UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onSceneChange?(self, window?.windowScene)
        }
    }
}
