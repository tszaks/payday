import SwiftUI

/// Full-screen cover shown whenever AppLockController.isLocked is true.
/// Triggers Face ID/Touch ID automatically on appear; the button is a
/// manual retry, not the primary path.
struct LockGateView: View {
    let lockController: AppLockController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "faceid")
                .font(PaydayFont.iconXL)
                .foregroundStyle(PaydayColor.primary)
            Text("Payday is locked")
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
            Button("Unlock") {
                Task { await lockController.unlock() }
            }
            .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-DebugForceLock") { return }
            #endif
            await lockController.unlock()
        }
    }
}
