import AuthenticationServices
import SwiftUI

/// The last stage of the intro, and the only place Payday asks anyone to sign
/// in.
///
/// Before this existed, `PaydayCloudGate` owned a separate `PaydaySignInView`
/// for its signed-out branch, which meant the app had TWO front doors: the
/// welcome screen on a first launch, and a bare mark-plus-Apple-button screen
/// for everybody else. Signing out to look at the intro landed on the plainer
/// one — Tyler, 2026-09-14: "shouldn't that be the default welcome screen if
/// you aren't signed in anywhere?"
///
/// It should. So the flow now ends here rather than handing off, the gate
/// renders the whole flow for its signed-out state, and there is nothing
/// plainer to fall through to.
struct OnboardingAccountView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True when the quiz ran ahead of this screen, so the copy can say
    /// "you're one tap from" rather than introducing the app a second time.
    let didCompleteQuiz: Bool
    let onAuthorize: ((authorization: Result<ASAuthorization, Error>, nonce: String)) -> Void

    @State private var nonce = PaydayAppleNonce.make()
    @State private var hasAppeared = false

    private var title: String {
        didCompleteQuiz ? "One tap and it's yours." : "Welcome back."
    }

    private var subtitle: String {
        didCompleteQuiz
            ? "Your account keeps every shift safe, so a lost phone never costs you the record."
            : "Sign in and every shift you've logged comes back."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: PaydaySpacing.md)

            Image("BrandMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 68, height: 68)
                .foregroundStyle(PaydayColor.primary)
                .accessibilityHidden(true)
                .padding(.bottom, PaydaySpacing.xl)

            VStack(spacing: PaydaySpacing.sm) {
                Text(title)
                    .font(PaydayFont.displayMedium)
                    .foregroundStyle(PaydayColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: PaydaySpacing.md)
        }
        .padding(.horizontal, PaydaySpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        .safeAreaInset(edge: .bottom) {
            SignInWithAppleButton(.continue) { request in
                // A fresh nonce per attempt. Reusing one across a cancelled
                // and then completed attempt would let the same assertion be
                // presented twice.
                nonce = PaydayAppleNonce.make()
                request.requestedScopes = [.email, .fullName]
                request.nonce = PaydayAppleNonce.sha256(nonce)
            } onCompletion: { result in
                onAuthorize((result, nonce))
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(Capsule())
            .padding(.horizontal, PaydaySpacing.md)
            .padding(.bottom, PaydaySpacing.p40)
            .opacity(reduceMotion || hasAppeared ? 1 : 0)
            .animation(reduceMotion ? nil : PaydayAnimation.entrance.delay(0.08), value: hasAppeared)
        }
        .onAppear { hasAppeared = true }
    }
}

#Preview("after the quiz") {
    OnboardingAccountView(didCompleteQuiz: true, onAuthorize: { _ in })
}

#Preview("returning") {
    OnboardingAccountView(didCompleteQuiz: false, onAuthorize: { _ in })
}
