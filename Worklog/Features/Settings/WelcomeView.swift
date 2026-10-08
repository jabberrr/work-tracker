import AuthenticationServices
import SwiftUI

/// First-launch / signed-out gate shown full-window by RootView while `auth.needsWelcome` (state == .signedOut).
/// Sign in with Apple, or continue as a guest; both keep local storage and iCloud sync working.
/// Also offers a first pick of the visual theme (the same swatches as Settings ▸ Appearance).
@MainActor
struct WelcomeView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PersistenceController.self) private var persistence
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

                Button("Continue as Guest") { auth.continueWithoutSigningIn() }
                    .buttonStyle(QuietButtonStyle())
            }

            themePicker

            VStack(spacing: theme.spacingS) {
                Text(storageLine)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !Entitlements.hasSignInWithApple {
                    Text("Sign in with Apple isn’t available in this build.")
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

    // MARK: Storage copy

    /// Where data goes, derived from how the store actually opened at this launch.
    private var storageLine: String {
        switch persistence.storeMode {
        case .cloudKit:
            return "Your data syncs with iCloud either way."
        case .localOnly:
            if !Entitlements.hasCloudKit {
                return "Your data is saved on this Mac."
            }
            return persistence.cloudSyncRequestedAtLaunch
                ? "iCloud isn’t available, so your data stays on this Mac."
                : "Your data stays on this Mac until you turn on iCloud sync."
        case .inMemory(let reason):
            return reason == "Preview"
                ? "Preview, so nothing is saved."
                : "Your data couldn’t be opened. Recover it in Settings."
        }
    }

    // MARK: Theme

    /// Compact first pick of the theme; changes apply immediately and can be revisited in Settings ▸ Appearance.
    private var themePicker: some View {
        VStack(spacing: theme.spacingS) {
            Text("Pick a look")
                .font(theme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            ThemeSwatchRow()
        }
    }
}
