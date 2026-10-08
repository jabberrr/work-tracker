import SwiftData
import SwiftUI

/// Main window content: Welcome gate, sidebar navigation (Settings is a detail page reached from the footer gear),
/// storage/sync banners and the end-of-session sheet.
@MainActor
struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WindowRouter.self) private var router
    @Environment(SessionEngine.self) private var engine
    @Environment(PersistenceController.self) private var persistence
    @Environment(AppSettings.self) private var settings
    @Environment(SyncMonitor.self) private var sync
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    /// The sync error text the user dismissed (or that timed out); a different error shows again.
    @State private var dismissedSyncError: String?

    var body: some View {
        Group {
            if auth.needsWelcome {
                WelcomeView()
            } else {
                mainSplitView
            }
        }
        .sheet(item: Binding(
            get: { engine.pendingEndSession },
            set: { if $0 == nil { engine.completeReview() } }
        ), onDismiss: {
            // Phase 2 of discarding from the end sheet: delete only once the sheet's views are gone.
            engine.finishPendingDiscard()
        }) { session in
            EndSessionSheet(session: session)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { engine.lastError != nil },
            set: { if !$0 { engine.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
        .onAppear {
            router.register(openWindow: openWindow)
            router.mainWindowDidOpen(hideDockIconWhenClosed: settings.hideDockIconWhenClosed)
        }
        .onDisappear {
            router.mainWindowDidClose(hideDockIconWhenClosed: settings.hideDockIconWhenClosed)
        }
        .task(id: sync.lastErrorDescription) {
            // Sync errors are often transient: show the banner briefly, then hide it (Settings ▸ Account keeps it).
            guard let error = sync.lastErrorDescription else { return }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            dismissedSyncError = error
        }
    }

    // MARK: - Split view

    private var mainSplitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            // Min-size barrier: every frame here has an explicit 0 minimum, so no page's (data-dependent) minimum
            // size can propagate to the split view and grow or move the window.
            VStack(spacing: 0) {
                bannerStack
                detail
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .themedBackground(.background)
        }
    }

    /// The List's selection. nil while Settings (not a List row) is shown, so no row stays highlighted.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { router.selection == .settings ? nil : router.selection },
            set: { newValue in
                if let newValue { router.selection = newValue }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(SidebarItem.primaryItems) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        // Pinned to the bottom of the sidebar column (not a VStack sibling), so it can't be pushed off-screen.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if engine.isActive {
                    miniStatusRow
                        .padding(.horizontal, theme.spacingS)
                        .padding(.vertical, theme.spacingS)
                }
                Divider()
                sidebarFooter
                    .padding(.horizontal, theme.spacingM)
                    .padding(.vertical, theme.spacingS)
            }
            .background(theme.color(for: .sidebar))
        }
        .themedBackground(.sidebar)
    }

    // MARK: - Mini status row

    private var miniStatusRow: some View {
        Button {
            router.selection = .today
        } label: {
            HStack(spacing: theme.spacingS) {
                Image(systemName: engine.isPaused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(engine.isPaused ? theme.timerPaused : theme.timerRunning)
                    .accessibilityHidden(true)
                miniTimer
                Spacer(minLength: theme.spacingXS)
                if engine.isActiveSessionOnAnotherMac {
                    Image(systemName: "laptopcomputer")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .help("Running on another Mac")
                        .accessibilityLabel("Running on another Mac")
                }
                LabelBadge(label: engine.currentLabel, size: .small)
            }
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingS)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                    .fill(theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show session")
        .accessibilityLabel(engine.isPaused ? "Session paused" : "Session running")
        .accessibilityHint("Shows Today.")
    }

    @ViewBuilder
    private var miniTimer: some View {
        if engine.isPaused {
            timerText(engine.elapsed())
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                timerText(engine.elapsed(at: context.date))
            }
        }
    }

    private func timerText(_ interval: TimeInterval) -> some View {
        TimerText(interval, style: .compact, isPaused: engine.isPaused)
            .monospacedDigit()
            .accessibilityLabel("Elapsed time")
            .accessibilityValue(interval.formattedShort)
    }

    // MARK: - Footer

    private var sidebarFooter: some View {
        let isShowingSettings = router.selection == .settings
        return HStack(spacing: theme.spacingS) {
            Button {
                router.showSettings(tab: "account")
            } label: {
                HStack(spacing: theme.spacingS) {
                    Image(systemName: auth.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityHidden(true)
                    Text(accountName)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Account")
            .accessibilityLabel("Account")
            .accessibilityValue(accountName)

            Spacer(minLength: 0)

            Button {
                router.selection = .settings
            } label: {
                if isShowingSettings {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(theme.accent)
                } else {
                    Image(systemName: "gearshape")      // IconButtonStyle: textSecondary, textPrimary on hover
                }
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityAddTraits(isShowingSettings ? .isSelected : [])
        }
    }

    private var accountName: String {
        switch auth.state {
        case .signedIn:
            return auth.displayName ?? auth.email ?? "Signed in with Apple"
        case .guest, .signedOut, .unknown:
            return "Guest"
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch router.selection {
        case .today: LiveSessionView()
        case .history: HistoryView()
        case .learning: LearningView()
        case .stats: StatsView()
        case .settings: SettingsView()
        }
    }

    // MARK: - Banners

    private struct BannerItem: Identifiable {
        let id: String
        let message: String
        let systemImage: String
        let style: BannerStyle
        var help: String? = nil
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
        var onDismiss: (() -> Void)? = nil
    }

    /// At most two banners (DESIGN §8), most important first.
    private var bannerStack: some View {
        let items = Array(banners.prefix(2))
        return VStack(spacing: theme.spacingS) {
            ForEach(items) { item in
                InlineBanner(
                    item.message,
                    systemImage: item.systemImage,
                    style: item.style,
                    actionTitle: item.actionTitle,
                    action: item.action,
                    onDismiss: item.onDismiss
                )
                .help(item.help ?? "")
            }
        }
        .padding([.horizontal, .top], items.isEmpty ? 0 : theme.spacingL)
    }

    private var banners: [BannerItem] {
        var items: [BannerItem] = []

        if case .inMemory(let reason) = persistence.storeMode, reason != "Preview" {
            items.append(BannerItem(
                id: "inMemory",
                message: "Your data couldn\u{2019}t be opened. Changes won\u{2019}t be saved.",
                systemImage: "exclamationmark.triangle.fill",
                style: .error,
                help: reason,
                actionTitle: "Restore\u{2026}",
                action: { router.showSettings(tab: "data") }
            ))
        }

        if let error = sync.lastErrorDescription, error != dismissedSyncError {
            items.append(BannerItem(
                id: "syncError",
                message: "iCloud sync problem. Changes are saved on this Mac.",
                systemImage: "exclamationmark.icloud",
                style: .warning,
                help: error,
                actionTitle: "Details\u{2026}",
                action: { router.showSettings(tab: "account") },
                onDismiss: { dismissedSyncError = error }
            ))
        }

        if let notice = persistence.launchNotice {
            items.append(BannerItem(
                id: "launchNotice",
                message: notice,
                systemImage: "info.circle.fill",
                style: .info,
                onDismiss: { persistence.launchNotice = nil }
            ))
        }

        if let notice = engine.handoffNotice {
            items.append(BannerItem(
                id: "handoff",
                message: notice,
                systemImage: "arrow.left.arrow.right",
                style: .info,
                onDismiss: { engine.clearHandoffNotice() }
            ))
        }

        if case .localOnly(let reason) = persistence.storeMode,
           persistence.cloudSyncRequestedAtLaunch,                 // not shown when the user turned sync off
           settings.dismissedLocalOnlyBannerReason != reason {
            items.append(BannerItem(
                id: "localOnly",
                message: "Saving to this Mac only \u{2014} \(Self.bannerReason(reason)).",
                systemImage: "icloud.slash",
                style: .info,
                help: reason,
                actionTitle: "Details\u{2026}",
                action: { router.showSettings(tab: "account") },
                onDismiss: { settings.dismissedLocalOnlyBannerReason = reason }
            ))
        }
        return items
    }

    /// The reason as a sentence fragment: raw error text after ":" goes to the tooltip / Account tab, a trailing
    /// period is dropped, and a plain first word is lowercased ("Not signed in to iCloud" → "not signed in to iCloud").
    private static func bannerReason(_ reason: String) -> String {
        var text = reason.trimmed
        if let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon]).trimmed
        }
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty else { return "iCloud isn\u{2019}t available" }
        let firstWord = text.prefix(while: { !$0.isWhitespace })
        let isPlainWord = firstWord.dropFirst().allSatisfy { !$0.isUppercase }
        if isPlainWord, let first = text.first, first.isUppercase {
            text = first.lowercased() + text.dropFirst()
        }
        return text
    }
}
