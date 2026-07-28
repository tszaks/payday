import SwiftUI

/// Full-screen cover shown whenever AppLockController.isLocked is true.
/// Triggers Face ID/Touch ID automatically on appear; the button is a
/// manual retry, not the primary path. Composed like Apple's own locked
/// surfaces (a locked note, a hidden album): the app's mark carrying
/// identity, the state named plainly, one line saying why the lock
/// exists, one action. The mark breathes in once on appear — a single
/// calm entrance, no loops.
struct LockGateView: View {
    let lockController: AppLockController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // The system app-lock grammar (Tyler's reference: GitHub's
            // lock screen): the mark centered, "Unlock Payday" as the only
            // text, Face ID firing on its own — and one full-width
            // fallback button anchored at the bottom, nothing mid-screen.
            Image("BrandMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 72)
                .foregroundStyle(PaydayColor.primary)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1 : 0.94))
                .padding(.bottom, PaydaySpacing.p20)

            Text("Unlock Payday")
                .font(PaydayFont.displayMedium)
                .foregroundStyle(PaydayColor.textPrimary)

            Spacer()

            Button {
                Task { await lockController.unlock() }
            } label: {
                Text(lockController.failedAttempts >= 2 ? "Use Passcode" : "Unlock")
                    .font(PaydayFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PaydaySpacing.p4)
            }
            .buttonStyle(.glassProminent)
            .tint(PaydayColor.primary)
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.bottom, PaydaySpacing.p16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                hasAppeared = true
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-DebugForceLock") { return }
            #endif
            await lockController.unlock()
        }
    }
}
