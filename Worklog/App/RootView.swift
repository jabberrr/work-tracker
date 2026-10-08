import SwiftData
import SwiftUI

/// Main window content: Welcome gate, sidebar navigation (Settings is a detail page reached from the footer gear),
/// storage/sync banners and the end-of-session sheet. Before sign-in, Settings (⌘, or Welcome's "Settings…")
/// replaces Welcome full-window with a Back button.
@MainActor
struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WindowRouter.self) private var router
    @Environment(SessionEngine.self) private var engine
    @Environment(ProfileStore.self) private var profiles
    @Environment(PersistenceController.self) private var persistence
    @Environment(AppSettings.self) private var settings
    @Environment(SyncMonitor.self) private var sync
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The sync error text the user dismissed (or that timed out); a different error shows again.
    @State private var dismissedSyncError: String?
    /// True while the end-of-session sheet is on screen (so later navigation to Settings can't hide it).
    @State private var isEndSheetVisible = false
    /// Briefly holds back the end-of-session sheet while Settings (and any sheet it presented) is closed for it.
    @State private var holdEndSheet = false
    /// The sidebar's inline profile list (owned here so a click elsewhere in the sidebar can collapse it).
    @State private var isProfileListExpanded = false
    /// The sidebar column's measured height (drives the profile list's height limit).
    @State private var sidebarHeight: CGFloat = 0

    var body: some View {
        // Read here (not only inside the Binding) so observation re-renders on pendingEndSession / selection.
        let endSession = endSheetSession
        return Group {
            if auth.needsWelcome {
                if router.selection == .settings {
                    welcomeSettings
                } else {
                    WelcomeView()
                }
            } else {
                mainSplitView
            }
        }
        .sheet(item: Binding(
            get: { endSession },
            set: { if $0 == nil { engine.completeReview() } }
        ), onDismiss: {
            isEndSheetVisible = false
            // Phase 2 of discarding from the end sheet: delete only once the sheet's views are gone.
            engine.finishPendingDiscard()
        }) { session in
            EndSessionSheet(session: session)
                .onAppear { isEndSheetVisible = true }
        }
        .onChange(of: engine.pendingEndSession?.uuid) { _, newValue in
            // Settings pages present their own sheets in this window, which would block the review sheet:
            // leave Settings first and present the review once its sheets are gone.
            guard newValue != nil, router.selection == .settings, !isEndSheetVisible else { return }
            holdEndSheet = true
            router.selection = .today
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                holdEndSheet = false
            }
        }
        .onChange(of: router.selection) { _, _ in
            collapseProfileList()
        }
        .onChange(of: auth.needsWelcome) {
            collapseProfileList()
            // Passing Welcome (signed in / guest) from its Settings starts on Today; signing out from Settings
            // shows Welcome rather than its Settings page.
            if router.selection == .settings {
                router.selection = .today
            }
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

    /// The review sheet's item. Not presented while Settings is on screen (until the sheet is up, see the
    /// `pendingEndSession` onChange) or while `holdEndSheet` is set.
    private var endSheetSession: WorkSession? {
        guard let session = engine.pendingEndSession else { return nil }
        if isEndSheetVisible { return session }
        if holdEndSheet || router.selection == .settings { return nil }
        return session
    }

    // MARK: - Welcome ▸ Settings

    /// Settings before sign-in: full-window, with Back to Welcome.
    private var welcomeSettings: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    router.selection = .today
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(QuietButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.spacingXL)
            .padding(.top, theme.spacingL)
            SettingsView()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .themedBackground(.background)
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
        // Dismiss layer while the inline profile list is open: a click anywhere in the List area only collapses it
        // (like a menu). Applied BEFORE safeAreaInset, so it covers the List region above the inset, never the
        // switcher, the mini status row or the footer.
        .overlay {
            if isProfileListExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { collapseProfileList() }
                    .accessibilityHidden(true)
            }
        }
        // Pinned to the bottom of the sidebar column (not a VStack sibling), so it can't be pushed off-screen.
        // Order: mini status row (while active) → profile switcher (always: it's where profiles are created; its
        // inline list grows the inset upward) → footer (never moves).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if engine.isActive {
                    miniStatusRow
                        .padding(.horizontal, theme.spacingS)
                        .padding(.vertical, theme.spacingS)
                }
                Divider()
                ProfileSwitcher(isExpanded: $isProfileListExpanded,
                                maxMenuHeight: ProfileSwitcher.menuHeightLimit(sidebarHeight: sidebarHeight))
                    .padding(.horizontal, theme.spacingS)
                    .padding(.vertical, theme.spacingXS)
                Divider()
                sidebarFooter
                    .padding(.horizontal, theme.spacingM)
                    .padding(.vertical, theme.spacingS)
            }
            .background(theme.color(for: .sidebar))
        }
        // Measurement only (a background never affects layout): the list's height limit is a fraction of the
        // measured sidebar, so the inset can't grow the window's minimum size or push the footer off-screen.
        // onAppear/onChange (not onGeometryChange, which needs macOS 15).
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { sidebarHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in sidebarHeight = height }
            }
        }
        .themedBackground(.sidebar)
    }

    /// Collapses the inline profile list (no animation under Reduce Motion). No-op while collapsed.
    private func collapseProfileList() {
        guard isProfileListExpanded else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            isProfileListExpanded = false
        }
    }

    // MARK: - Mini status row

    private var miniStatusRow: some View {
        Button {
            collapseProfileList()
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
                if showsSessionProfile {
                    ProfileBadge(profile: engine.activeSessionProfile, size: .small)
                        .layoutPriority(-1)
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

    /// The running session belongs to another profile than the current one (only with 2+ profiles).
    private var showsSessionProfile: Bool {
        guard profiles.hasMultipleProfiles, let sessionProfileID = engine.activeSessionProfileID else { return false }
        return sessionProfileID != profiles.activeProfileID
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
                collapseProfileList()
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
                collapseProfileList()
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
                message: "iCloud sync failed; changes kept on this Mac.",
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
