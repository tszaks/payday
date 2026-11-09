import SwiftUI
@preconcurrency import TruvSDK

/// Truv Bridge, Truv's own sign-in screen, hosted in SwiftUI. The person
/// searches their employer or payroll provider and signs in there; Payday
/// never sees the password. On success Bridge hands back a one-time public
/// token, which only the server can exchange.
struct TruvBridgeView: UIViewControllerRepresentable {
    let token: String
    let onSuccess: @MainActor (String) -> Void
    let onClose: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess, onClose: onClose)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        TruvBridgeController(token: token, delegate: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    /// The SDK's delegate protocol is not actor-isolated, so this hops to
    /// the main actor with only the token string, never the SDK's types.
    final class Coordinator: TruvDelegate, @unchecked Sendable {
        private let onSuccess: @MainActor (String) -> Void
        private let onClose: @MainActor () -> Void
        /// Bridge sends `onClose` after `onSuccess`; only the first counts.
        private var finished = false

        init(onSuccess: @escaping @MainActor (String) -> Void, onClose: @escaping @MainActor () -> Void) {
            self.onSuccess = onSuccess
            self.onClose = onClose
        }

        func onEvent(_ event: TruvEvent) {
            switch event {
            case .onSuccess(let payload):
                let publicToken = payload?.publicToken
                Task { @MainActor in self.finish(publicToken: publicToken) }
            case .onClose:
                Task { @MainActor in self.finish(publicToken: nil) }
            default:
                break
            }
        }

        @MainActor
        private func finish(publicToken: String?) {
            guard !finished else { return }
            finished = true
            if let publicToken, !publicToken.isEmpty {
                onSuccess(publicToken)
            } else {
                onClose()
            }
        }
    }
}
