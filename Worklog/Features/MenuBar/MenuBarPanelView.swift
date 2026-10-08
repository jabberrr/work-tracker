import AppKit
import SwiftData
import SwiftUI

/// Content of the `MenuBarExtra` (`.window` style, 320 pt wide): live status and controls, inline split,
/// quick note, last takeaway, today's total, overlay toggle and app rows.
///
/// Profiles: everything here follows the *panel profile*, the running session's profile while active, else the
/// quick start profile (`ProfileStore.quickStartProfile`, Settings ▸ Profiles). Start, the label picker, the
/// takeaway and today's total all use it; a `ProfileBadge` names it when there are 2 or more profiles.
@MainActor
struct MenuBarPanelView: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(WindowRouter.self) private var router
    @Environment(OverlayPanelController.self) private var overlay
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    @State private var isSplitting = false
    @State private var startLabel: WorkLabel?
    @State private var didLoadDefaults = false
    /// The quick start profile `startLabel` was chosen for (the panel may be closed when it changes).
    @State private var startLabelProfileID: UUID?

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let session = engine.activeSession, LiveModelGuard.isUsable(session) {
                    activeSection
                } else {
                    idleSection
                }
            }
            .padding(theme.spacingL)

            infoSection

            rule
            menuRows
                .padding(.horizontal, theme.spacingS)
                .padding(.vertical, theme.spacingS)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .themedPanelBackground()
        .onAppear(perform: onAppear)
        .onChange(of: engine.isActive) { _, isActive in
            if !isActive { isSplitting = false }
        }
        .onChange(of: profiles.quickStartProfileID) { _, _ in
            resetStartLabel()
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func onAppear() {
        router.register(openWindow: openWindow)
        let profileID = profiles.quickStartProfileID
        if !didLoadDefaults || startLabelProfileID != profileID {
            didLoadDefaults = true
            resetStartLabel()
        } else if startLabel.map({ !LiveStartChoice.isUsable($0, in: profileID) }) ?? true {
            // Never loaded (no labels yet at first open), or deleted/merged/archived/re-scoped in Settings since.
            resetStartLabel()
        }
    }

    private func resetStartLabel() {
        startLabelProfileID = profiles.quickStartProfileID
        startLabel = engine.defaultLabel(for: profiles.quickStartProfile)
    }

    /// Running session's profile while active, else the quick start profile.
    private var panelProfileID: UUID? {
        engine.isActive ? engine.activeSessionProfileID : profiles.quickStartProfileID
    }

    // MARK: Active

    private var activeSection: some View {
        let isPaused = engine.isPaused
        return VStack(alignment: .leading, spacing: theme.spacingM) {
            HStack(spacing: theme.spacingS) {
                LiveDot(isPaused: isPaused)
                Text(isPaused ? "Paused" : "Running")
                    .font(theme.captionFont.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize()
                if profiles.hasMultipleProfiles {
                    ProfileBadge(profile: engine.activeSessionProfile, size: .small)
                        .frame(maxWidth: 96, alignment: .leading)
                        .fixedSize()
                }
                Spacer(minLength: theme.spacingS)
                LabelBadge(label: engine.currentLabel, size: .small)
            }

            if engine.isActiveSessionOnAnotherMac {
                LiveOtherMacHint()
            }

            LiveClock(isTicking: !isPaused) { date in
                VStack(alignment: .leading, spacing: theme.spacingXS) {
                    TimerText(engine.elapsed(at: date), style: .large, isPaused: isPaused)
                    HStack(spacing: theme.spacingXS) {
                        Text(focusText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("· segment \(engine.currentSegmentElapsed(at: date).formattedClock)")
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityElement(children: .combine)
                }
            }

            if let reason = engine.autoPauseReason, isPaused {
                Text(reason == .sleep ? "Paused while your Mac slept." : "Paused when Worklog quit.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.warning)
            }

            HStack(spacing: theme.spacingS) {
                Button {
                    engine.togglePause()
                } label: {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(QuietButtonStyle())
                .help(isPaused ? "Resume" : "Pause")

                Button {
                    isSplitting.toggle()
                } label: {
                    Label("Split", systemImage: "scissors")
                }
                .buttonStyle(QuietButtonStyle())
                .help("Split segment")

                Spacer(minLength: 0)

                Button(action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Stop")
                .accessibilityLabel("Stop session")
            }
            .controlSize(.small)

            if isSplitting {
                LiveSegmentForm(mode: .split, style: .inline) { isSplitting = false }
                    .padding(theme.spacingM)
                    .background(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                        .fill(theme.textPrimary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                        .strokeBorder(theme.separator, lineWidth: 1))
            }

            LiveQuickNoteField(prompt: "Quick note…")
        }
    }

    private var focusText: String {
        let focus = engine.currentSegment?.focus.trimmed ?? ""
        if !focus.isEmpty { return focus }
        return engine.currentLabel?.name ?? "No focus"
    }

    private func stop() {
        _ = engine.stop()
        isSplitting = false
        // The review sheet lives in the main window.
        if engine.pendingEndSession != nil {
            router.showMainWindow()
        }
    }

    // MARK: Idle

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            HStack(spacing: theme.spacingS) {
                Image(systemName: "timer")
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                Text("Not tracking")
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
            }
            if engine.pendingEndSession != nil {
                HStack(spacing: theme.spacingS) {
                    Text("Session waiting for review.")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Review…") { router.showMainWindow() }
                        .buttonStyle(QuietButtonStyle())
                        .controlSize(.small)
                        .help("Review session")
                }
            }
            HStack(spacing: theme.spacingS) {
                if profiles.hasMultipleProfiles {
                    // Ideal width, capped: a long name truncates instead of squeezing the picker.
                    ProfileBadge(profile: profiles.quickStartProfile, size: .small)
                        .frame(maxWidth: 80, alignment: .leading)
                        .fixedSize()
                }
                LabelPicker(selection: $startLabel, includeNone: true, title: "Label",
                            profileID: profiles.quickStartProfileID)
                    .labelsHidden()
                    .controlSize(.small)
                Spacer(minLength: 0)
                Button(action: startSession) {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.small)
                .help("Start session")
            }
        }
    }

    private func startSession() {
        // The picked label may have been deleted, merged or archived in Settings since it was chosen.
        let profile = profiles.quickStartProfile
        _ = engine.start(label: LiveStartChoice.label(startLabel, engine: engine, profile: profile),
                         profile: profile)
    }

    // MARK: Takeaway + today

    @ViewBuilder
    private var infoSection: some View {
        let profileID = panelProfileID
        let takeaway = settings.menuBarShowLastTakeaway ? engine.takeaway(for: profileID) : nil
        rule
        VStack(alignment: .leading, spacing: theme.spacingM) {
            if let takeaway {
                LiveTakeawayView(takeaway: takeaway, lineLimit: 3, showsTitle: false, isCompact: true)
            }
            LiveTodaySessionsQuery { sessions in
                MenuBarTodayRow(sessions: sessions, scope: ProfileScope(profileID: profileID))
            }
        }
        .padding(.horizontal, theme.spacingL)
        .padding(.vertical, theme.spacingM)
    }

    // MARK: Menu-like rows

    private var menuRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: theme.spacingS) {
                    Toggle("Show overlay", isOn: Binding(
                        get: { settings.overlayEnabled },
                        set: { $0 ? overlay.show() : overlay.hide() }
                    ))
                    .toggleStyle(.checkbox)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                    if let hint = shortcuts.displayString(for: .toggleOverlay) {
                        shortcutHint(hint)
                    }
                }
                if settings.overlayEnabled && settings.overlayHideWhenIdle && !engine.isActive {
                    // Hidden while idle: say so, or the toggle looks broken.
                    Text("Appears when a session starts")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, theme.spacingL + theme.spacingXS)
                }
            }
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingXS + 1)
            .help("Show overlay")

            menuRow("Open Worklog", systemImage: "macwindow", hint: nil) {
                router.showMainWindow()
            }
            menuRow("Settings…", systemImage: "gearshape", hint: "⌘,") {
                router.showSettings()
            }
            menuRow("Quit Worklog", systemImage: "power", hint: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
    }

    private func menuRow(_ title: String, systemImage: String, hint: String?,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: theme.spacingS) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                if let hint {
                    shortcutHint(hint)
                }
            }
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingXS + 1)
        }
        .buttonStyle(LiveHoverRowStyle(hoverOpacity: 0.06))
        .accessibilityLabel(title)
    }

    private func shortcutHint(_ text: String) -> some View {
        Text(text)
            .font(theme.monoFont)
            .foregroundStyle(theme.textTertiary)
            .accessibilityHidden(true)
    }
}

/// "Today 2h 15m of 4h" + goal meter, live while running. Counts only sessions in `scope` (the panel profile).
@MainActor
private struct MenuBarTodayRow: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    private let sessions: [WorkSession]
    private let scope: ProfileScope

    init(sessions: [WorkSession], scope: ProfileScope) {
        self.sessions = sessions
        self.scope = scope
    }

    var body: some View {
        LiveClock(isTicking: engine.isRunning) { date in
            let total = LiveDayMath.totalToday(sessions, active: engine.activeSession, now: date, scope: scope)
            let goal = LiveDayMath.goalSeconds(settings)
            VStack(alignment: .leading, spacing: theme.spacingXS) {
                HStack(spacing: theme.spacingXS) {
                    Image(systemName: "target")
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                    Text("Today")
                        .foregroundStyle(theme.textSecondary)
                    Text(total.formattedShort)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                    if goal > 0 {
                        Text("of \(goal.formattedShort)")
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(theme.calloutFont)
                .accessibilityElement(children: .combine)
                if goal > 0 {
                    ProportionBar(parts: [.init(value: total, color: theme.accent, label: "Today")], total: goal)
                        .accessibilityLabel("Daily goal progress")
                }
            }
        }
    }
}
