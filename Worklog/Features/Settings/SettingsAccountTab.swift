import AppKit
import AuthenticationServices
import SwiftUI

/// Account: Sign in with Apple state, sign in / out, where data is stored (iCloud vs. this Mac only) and the
/// live iCloud sync status (`SyncMonitor`).
@MainActor
struct SettingsAccountTab: View {
    @Environment(AuthService.self) private var auth
    @Environment(AppSettings.self) private var settings
    @Environment(PersistenceController.self) private var persistence
    @Environment(SyncMonitor.self) private var sync
    @Environment(WindowRouter.self) private var router
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
                SettingsFootnote("Signing in doesn’t move your data, and signing out deletes nothing.")
            }

            Section("Storage") {
                storageStatusRow
                if let mismatch = persistence.environmentMismatch, !persistence.isInMemory {
                    HStack(spacing: theme.spacingS) {
                        SettingsFootnote("Move it to iCloud \(mismatch.build.rawValue), use the data already there, or keep it on this Mac.")
                        Spacer()
                        Button("Move to iCloud \(mismatch.build.rawValue)\u{2026}") {
                            router.showSettings(tab: SettingsTab.data.rawValue)
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }
                if SettingsRecovery.isNeeded(persistence) {
                    HStack {
                        Spacer()
                        Button("Recover…") { router.showSettings(tab: SettingsTab.data.rawValue) }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
                if persistence.storeMode == .cloudKit {
                    syncActivityRow
                    if let error = sync.lastErrorDescription {
                        InlineBanner(error, systemImage: "exclamationmark.icloud", style: .warning)
                    }
                }
                Toggle("Sync with iCloud", isOn: $settings.iCloudSyncEnabled)
                    .disabled(!Entitlements.hasCloudKit)
                if needsRelaunch {
                    // Quit (not relaunch): a second instance must not open the same store while this one
                    // is still saving and backing up on its way out.
                    InlineBanner("Reopen Worklog to apply this change.",
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
            Text("Your data stays on this Mac and in iCloud.")
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
        case .signedIn: return auth.email ?? "Signed in with Apple."
        case .guest: return "Using Worklog without an account."
        case .signedOut: return "Sign in or continue as a guest."
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
            if AuthService.isSignInAvailable {
                SignInWithAppleButton(.signIn,
                                      onRequest: { request in auth.configure(request) },
                                      onCompletion: { result in auth.handleSignInResult(result) })
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(width: 220, height: 32)
                    .accessibilityLabel("Sign in with Apple")
            } else {
                SettingsFootnote("Sign in with Apple isn’t available in this build. iCloud sync uses this Mac’s Apple Account.")
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
            return "Synced through your private iCloud database (\(persistence.buildEnvironment.rawValue))."
        case .localOnly(let reason):
            return "\(reason)."
        case .inMemory(let reason):
            return reason == "Preview"
                ? "Nothing is written to disk."
                : "\(reason) Changes won’t be saved."
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
                if let line = iCloudAccountLine {
                    Text(line)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// The iCloud account state as `SyncMonitor` sees it (CKContainer.accountStatus). nil when there is nothing
    /// useful to say (sync off for this launch, status not checked).
    private var iCloudAccountLine: String? {
        if !Entitlements.hasCloudKit {
            return "iCloud isn’t available in this build."
        }
        switch sync.accountStatus {
        case .unknown:
            return persistence.storeMode == .cloudKit ? "Checking iCloud…" : nil
        case .available:
            return "This Mac is signed in to iCloud."
        case .noAccount:
            return "This Mac isn’t signed in to iCloud."
        case .restricted:
            return "iCloud is restricted on this Mac."
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable."
        case .couldNotDetermine:
            return "Couldn’t check the iCloud account."
        }
    }

    // MARK: Sync activity

    /// "Syncing…" / "Last synced 2 minutes ago" / "Waiting for the first download from iCloud". Re-rendered every
    /// 30 s so the relative time stays current.
    private var syncActivityRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: theme.spacingS) {
                if sync.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: sync.lastErrorDescription == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                        .foregroundStyle(sync.lastErrorDescription == nil ? theme.textSecondary : theme.warning)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                }
                Text(syncActivityText(now: context.date))
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func syncActivityText(now: Date) -> String {
        if sync.isSyncing {
            return sync.hasCompletedFirstImport ? "Syncing…" : "Downloading your data from iCloud…"
        }
        if let last = sync.lastSyncDate {
            // Never "in 2 seconds" when the clocks disagree slightly.
            let shown = min(last, now)
            return "Last synced \(shown.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
        }
        return sync.hasCompletedFirstImport ? "Up to date" : "Waiting for the first sync with iCloud…"
    }

    /// True when the toggle differs from what this launch used (it's read once at launch). Never while the store
    /// couldn't be opened — recovery is offered in the Data tab instead — nor when sync was turned off while the
    /// store is local-only anyway (iCloud environment mismatch: nothing changes at the next launch).
    private var needsRelaunch: Bool {
        guard !persistence.isInMemory else { return false }
        if persistence.environmentMismatch != nil && !settings.iCloudSyncEnabled { return false }
        return settings.iCloudSyncEnabled != persistence.cloudSyncRequestedAtLaunch
    }

    private var syncExplanation: String {
        "Uses this Mac’s iCloud account and applies the next time Worklog opens."
    }
}
