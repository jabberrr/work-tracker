import SwiftData
import SwiftUI

/// Main window content: Welcome gate, sidebar navigation, storage banners and the end-of-session sheet.
struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WindowRouter.self) private var router
    @Environment(SessionEngine.self) private var engine
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    @State private var localStoreBannerDismissed = false

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
        )) { session in
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
        .onAppear { router.register(openWindow: openWindow) }
    }

    // MARK: - Split view

    private var mainSplitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                storageBanner
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .themedBackground(.background)
        }
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { router.selection },
            set: { newValue in
                if let newValue { router.selection = newValue }
            }
        )
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)

            if engine.isActive {
                miniStatusRow
                    .padding(.horizontal, theme.spacingS)
                    .padding(.bottom, theme.spacingS)
            }

            Divider()
            sidebarFooter
                .padding(.horizontal, theme.spacingM)
                .padding(.vertical, theme.spacingS)
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
        .help("Show the running session")
        .accessibilityLabel(engine.isPaused ? "Session paused" : "Session running")
        .accessibilityHint("Shows the Today page")
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
        HStack(spacing: theme.spacingS) {
            Image(systemName: auth.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            Text(accountName)
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .help("Settings")
            .accessibilityLabel("Settings")
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
        }
    }

    @ViewBuilder
    private var storageBanner: some View {
        switch persistence.storeMode {
        case .cloudKit:
            EmptyView()
        case .localOnly(let reason):
            if !localStoreBannerDismissed {
                InlineBanner(
                    "iCloud sync is off (\(reason)). Your data is stored on this Mac only.",
                    systemImage: "icloud.slash",
                    style: .info,
                    onDismiss: { localStoreBannerDismissed = true }
                )
                .padding([.horizontal, .top], theme.spacingL)
            }
        case .inMemory(let reason):
            if reason != "Preview" {
                InlineBanner(
                    "Worklog couldn't open its data store, so changes won't be saved. \(reason)",
                    systemImage: "exclamationmark.triangle.fill",
                    style: .error,
                    actionTitle: "Restore from backup…",
                    action: { router.showSettings() }
                )
                .padding([.horizontal, .top], theme.spacingL)
            }
        }
    }
}
