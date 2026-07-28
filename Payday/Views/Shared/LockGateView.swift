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

            Image("IslandMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 44)
                .foregroundStyle(PaydayColor.primary)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1 : 0.94))
                .padding(.bottom, PaydaySpacing.p20)

            Text("Payday is locked")
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
                .padding(.bottom, PaydaySpacing.p4)

            Text("Your tips stay private.")
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
                .padding(.bottom, PaydaySpacing.p30)

            Button {
                Task { await lockController.unlock() }
            } label: {
                HStack(spacing: PaydaySpacing.p8) {
                    Image(systemName: "faceid")
                    Text("Unlock")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, PaydaySpacing.p8)
            }
            .buttonStyle(.glassProminent)
            .tint(PaydayColor.primary)

            Spacer()
            Spacer()
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
