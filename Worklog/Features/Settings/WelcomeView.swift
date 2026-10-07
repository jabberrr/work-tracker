import AuthenticationServices
import SwiftUI

/// First-launch / signed-out gate shown full-window by RootView while `auth.needsWelcome` (state == .signedOut).
/// Sign in with Apple, or continue as a guest; both keep local storage and iCloud sync working.
struct WelcomeView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    init() {}

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(theme.spacingXXL)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .themedBackground()
    }

    private var content: some View {
        VStack(spacing: theme.spacingXL) {
            VStack(spacing: theme.spacingM) {
                Text("Worklog")
                    .font(theme.largeTitleFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Track focused work, split it as your attention moves, and keep what you learned.")
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: theme.spacingM) {
                SignInWithAppleButton(.signIn,
                                      onRequest: { request in auth.configure(request) },
                                      onCompletion: { result in auth.handleSignInResult(result) })
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(width: 260, height: 36)
                    .accessibilityLabel("Sign in with Apple")

                Button("Continue without signing in") { auth.continueWithoutSigningIn() }
                    .buttonStyle(QuietButtonStyle())
                    .help("Use Worklog as a guest. You can sign in later in Settings ▸ Account.")
            }

            VStack(spacing: theme.spacingS) {
                Text("Your data syncs with iCloud on this Mac’s Apple Account either way.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !Entitlements.hasSignInWithApple {
                    Text("Sign in with Apple isn’t configured for this build — continue without signing in.")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 420)

            if let error = auth.lastError {
                InlineBanner(error, style: .error, onDismiss: { auth.lastError = nil })
                    .frame(maxWidth: 460)
            }
        }
    }
}
