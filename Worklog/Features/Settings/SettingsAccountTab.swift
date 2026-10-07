import AppKit
import AuthenticationServices
import SwiftUI

/// Account: Sign in with Apple state, sign in / out, and where data is stored (iCloud vs. this Mac only).
struct SettingsAccountTab: View {
    @Environment(AuthService.self) private var auth
    @Environment(AppSettings.self) private var settings
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var confirmsSignOut = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Account") {
                accountStatusRow
                if let error = auth.lastError {
                    InlineBanner(error, style: .error, onDismiss: { auth.lastError = nil })
                }
                accountActions
                SettingsFootnote("Sign in with Apple identifies you in Worklog. It doesn’t move or upload your data, and signing out never deletes anything.")
            }

            Section("Sync and storage") {
                storageStatusRow
                Toggle("Sync with iCloud", isOn: $settings.iCloudSyncEnabled)
                    .disabled(!Entitlements.hasCloudKit)
                if needsRelaunch {
                    InlineBanner("Quit and reopen Worklog to apply this change.",
                                 systemImage: "arrow.clockwise", style: .warning,
                                 actionTitle: "Quit Worklog", action: { NSApp.terminate(nil) })
                }
                SettingsFootnote(syncExplanation)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out of Worklog?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { auth.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your sessions stay on this Mac and in iCloud. You can sign in again or continue as a guest.")
        }
    }

    // MARK: Account

    private var accountTitle: String {
        switch auth.state {
        case .signedIn: return auth.displayName ?? "Signed in with Apple"
        case .guest: return "Guest"
        case .signedOut: return "Not signed in"
        case .unknown: return "Checking…"
        }
    }

    private var accountDetail: String {
        switch auth.state {
        case .signedIn: return auth.email ?? "Your Apple ID is connected to Worklog."
        case .guest: return "Using Worklog without an account. Everything works the same."
        case .signedOut: return "Sign in with Apple or continue as a guest."
        case .unknown: return ""
        }
    }

    private var accountStatusRow: some View {
        HStack(spacing: theme.spacingM) {
            Image(systemName: auth.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 28 * theme.textScale))
                .foregroundStyle(auth.isSignedIn ? theme.accent : theme.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(accountTitle)
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)
                if !accountDetail.isEmpty {
                    Text(accountDetail)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var accountActions: some View {
        switch auth.state {
        case .signedIn:
            HStack {
                Spacer()
                Button("Sign Out…") { confirmsSignOut = true }
                    .buttonStyle(QuietButtonStyle())
            }
        case .guest, .signedOut, .unknown:
            VStack(alignment: .leading, spacing: theme.spacingS) {
                SignInWithAppleButton(.signIn,
                                      onRequest: { request in auth.configure(request) },
                                      onCompletion: { result in auth.handleSignInResult(result) })
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(width: 220, height: 32)
                    .accessibilityLabel("Sign in with Apple")
                if !Entitlements.hasSignInWithApple {
                    SettingsFootnote("Sign in with Apple isn’t configured for this build. You can keep using Worklog as a guest.")
                }
            }
        }
    }

    // MARK: Storage

    private var storageIcon: String {
        switch persistence.storeMode {
        case .cloudKit: return "icloud"
        case .localOnly: return "icloud.slash"
        case .inMemory: return "exclamationmark.triangle.fill"
        }
    }

    private var storageTitle: String {
        switch persistence.storeMode {
        case .cloudKit: return "Syncing with iCloud"
        case .localOnly: return "Saving to this Mac only"
        case .inMemory(let reason): return reason == "Preview" ? "Preview data" : "Not saving"
        }
    }

    private var storageDetail: String {
        switch persistence.storeMode {
        case .cloudKit:
            return "Sessions sync through the iCloud account this Mac is signed in to (your private iCloud database)."
        case .localOnly(let reason):
            return "\(reason). Your data is safe on this Mac and in local backups."
        case .inMemory(let reason):
            return reason == "Preview"
                ? "Nothing is written to disk."
                : "\(reason) Changes made now are lost when Worklog quits. Restore a backup in the Data tab."
        }
    }

    private var storageTint: Color {
        switch persistence.storeMode {
        case .cloudKit: return theme.success
        case .localOnly: return theme.textSecondary
        case .inMemory: return theme.danger
        }
    }

    private var storageStatusRow: some View {
        HStack(alignment: .top, spacing: theme.spacingM) {
            Image(systemName: storageIcon)
                .font(.system(size: 20 * theme.textScale))
                .foregroundStyle(storageTint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(storageTitle)
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)
                Text(storageDetail)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(iCloudAccountLine)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var iCloudAccountLine: String {
        if !Entitlements.hasCloudKit {
            return "This build isn’t set up for iCloud (no CloudKit entitlement)."
        }
        return FileManager.default.ubiquityIdentityToken != nil
            ? "This Mac is signed in to iCloud."
            : "This Mac isn’t signed in to iCloud (System Settings ▸ Apple Account)."
    }

    /// True when the toggle differs from what this launch used (it's read once at launch).
    private var needsRelaunch: Bool {
        let launchedWithSync: Bool
        switch persistence.storeMode {
        case .cloudKit: launchedWithSync = true
        case .localOnly(let reason): launchedWithSync = reason != "iCloud sync disabled"
        case .inMemory: return false
        }
        return settings.iCloudSyncEnabled != launchedWithSync
    }

    private var syncExplanation: String {
        "iCloud sync uses this Mac’s iCloud account whether or not you sign in with Apple. "
            + "When iCloud isn’t available, Worklog keeps everything on this Mac and syncs nothing. "
            + "The setting applies the next time Worklog opens."
    }
}
