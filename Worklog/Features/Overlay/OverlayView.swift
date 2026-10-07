import AppKit
import SwiftData
import SwiftUI

/// Content of the floating, non-activating overlay panel (hosted by CORE's `OverlayPanelController`, which
/// also applies opacity, level, spaces and visibility). 300 pt wide, 220 pt in compact mode; height is intrinsic.
/// Every section follows its `settings.overlayShow…` toggle.
///
/// Focus: the panel is borderless + `.nonactivatingPanel`, `canBecomeKey == true` and
/// `becomesKeyOnlyIfNeeded == true`, so clicking a text field makes it key (typing works) without
/// activating Worklog; buttons work without taking key status.
@MainActor
struct OverlayView: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(WindowRouter.self) private var router
    @Environment(OverlayPanelController.self) private var overlay
    @Environment(\.theme) private var theme
    /// For the idle Start button's "Start · <default label>" (no fetch in `body`).
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]

    @State private var isSplitting = false
    @FocusState private var noteFocused: Bool

    init() {}

    private var isCompact: Bool { settings.overlayCompact }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? theme.spacingXS + 2 : theme.spacingS) {
            if let session = engine.activeSession, LiveModelGuard.isUsable(session) {
                if isCompact {
                    compactActive
                } else {
                    regularActive
                }
            } else {
                idle
            }
        }
        .padding(isCompact ? theme.spacingS : theme.spacingM)
        .frame(width: isCompact ? 220 : 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .themedPanelBackground(cornerRadius: theme.radiusL)
        .onChange(of: engine.isActive) { _, isActive in
            if !isActive { isSplitting = false }
        }
    }

    // MARK: Regular

    @ViewBuilder
    private var regularActive: some View {
        let isPaused = engine.isPaused

        HStack(spacing: theme.spacingS) {
            LiveDot(isPaused: isPaused)
            if settings.overlayShowLabel {
                LabelBadge(label: engine.currentLabel, size: .small)
            } else {
                statusText(isPaused: isPaused)
            }
            Spacer(minLength: theme.spacingXS)
            closeButton
        }

        if engine.isActiveSessionOnAnotherMac {
            LiveOtherMacHint()
        }

        if settings.overlayShowTimer {
            LiveClock(isTicking: !isPaused) { date in
                TimerText(engine.elapsed(at: date), style: .large, isPaused: isPaused)
            }
        }

        if settings.overlayShowSegmentFocus {
            LiveClock(isTicking: !isPaused) { date in
                HStack(spacing: theme.spacingXS) {
                    Text(focusText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("· seg \(engine.currentSegmentElapsed(at: date).formattedClock)")
                        .monospacedDigit()
                        .fixedSize()
                }
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
                .accessibilityElement(children: .combine)
            }
        }

        if hasControlsRow {
            HStack(spacing: theme.spacingXS) {
                controlButtons(size: 26)
                Spacer(minLength: theme.spacingXS)
                if settings.overlayShowTodayTotal {
                    todayTotal
                }
            }
        }

        splitForm

        if settings.overlayShowNoteField {
            LiveQuickNoteField(prompt: "Note…", isFocused: $noteFocused)
        }

        if settings.overlayShowLastTakeaway, let takeaway = engine.lastTakeaway {
            LiveTakeawayView(takeaway: takeaway, lineLimit: 2, showsTitle: false, isCompact: true)
        }
    }

    // MARK: Compact

    @ViewBuilder
    private var compactActive: some View {
        let isPaused = engine.isPaused

        HStack(spacing: theme.spacingXS) {
            LiveDot(isPaused: isPaused, size: 7)
            if settings.overlayShowTimer {
                LiveClock(isTicking: !isPaused) { date in
                    TimerText(engine.elapsed(at: date), style: .compact, isPaused: isPaused)
                }
            } else if settings.overlayShowLabel {
                LabelBadge(label: engine.currentLabel, size: .small)
            } else {
                statusText(isPaused: isPaused)
            }
            Spacer(minLength: theme.spacingXS)
            controlButtons(size: 22)
            closeButton
        }

        if settings.overlayShowSegmentFocus || (settings.overlayShowLabel && settings.overlayShowTimer) {
            Text(compactSecondLine)
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(compactSecondLine)
        }

        if settings.overlayShowTodayTotal {
            todayTotal
        }

        splitForm

        if settings.overlayShowNoteField {
            LiveQuickNoteField(prompt: "Note…", isCompact: true, isFocused: $noteFocused)
        }

        if settings.overlayShowLastTakeaway, let takeaway = engine.lastTakeaway {
            LiveTakeawayView(takeaway: takeaway, lineLimit: 1, showsTitle: false, isCompact: true)
        }
    }

    private var compactSecondLine: String {
        let focus = engine.currentSegment?.focus.trimmed ?? ""
        let labelName = engine.currentLabel?.name ?? "Unlabeled"
        if settings.overlayShowLabel && settings.overlayShowTimer {
            return focus.isEmpty || !settings.overlayShowSegmentFocus ? labelName : "\(labelName) · \(focus)"
        }
        return focus.isEmpty ? labelName : focus
    }

    // MARK: Idle

    @ViewBuilder
    private var idle: some View {
        HStack(spacing: theme.spacingS) {
            Image(systemName: "timer")
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
            Text("Not tracking")
                .font(isCompact ? theme.calloutFont.weight(.medium) : theme.headlineFont)
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: theme.spacingXS)
            closeButton
        }

        if settings.overlayShowLastTakeaway, let takeaway = engine.lastTakeaway {
            LiveTakeawayView(takeaway: takeaway, lineLimit: isCompact ? 2 : 4, showsTitle: !isCompact, isCompact: true)
        }

        if settings.overlayShowTodayTotal {
            todayTotal
        }

        if engine.pendingEndSession != nil || settings.overlayShowControls {
            HStack(spacing: theme.spacingS) {
                if engine.pendingEndSession != nil {
                    Button("Review…") { router.showMainWindow() }
                        .buttonStyle(QuietButtonStyle())
                        .help("Review the session you just finished")
                }
                Spacer(minLength: 0)
                if settings.overlayShowControls {
                    let startLabel = LiveStartChoice.defaultLabel(in: labels, settings: settings)
                    Button(action: start) {
                        Label(startTitle(startLabel), systemImage: "play.fill")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .help(startLabel.map { "Start a session with “\($0.name)” (the default label)" }
                          ?? "Start a session")
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Pieces

    private func startTitle(_ label: WorkLabel?) -> String {
        guard let name = label?.name.nilIfBlank else { return "Start" }
        return "Start · \(name)"
    }

    private func start() {
        _ = engine.start(label: engine.defaultLabel())
    }

    private var hasControlsRow: Bool {
        settings.overlayShowControls || settings.overlayShowSplitButton || settings.overlayShowTodayTotal
    }

    @ViewBuilder
    private func controlButtons(size: CGFloat) -> some View {
        let isPaused = engine.isPaused
        if settings.overlayShowControls {
            Button {
                engine.togglePause()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(IconButtonStyle(size: size))
            .accessibilityLabel(isPaused ? "Resume" : "Pause")
            .help(isPaused ? "Resume" : "Pause")
        }
        if settings.overlayShowSplitButton {
            Button(action: toggleSplit) {
                Image(systemName: "scissors")
            }
            .buttonStyle(IconButtonStyle(size: size))
            .accessibilityLabel("Split segment")
            .help("Split segment: start a new one now")
        }
        if settings.overlayShowControls {
            Button(action: stop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(IconButtonStyle(size: size))
            .accessibilityLabel("Stop session")
            .help("Stop and review the session")
        }
    }

    @ViewBuilder
    private var splitForm: some View {
        if isSplitting {
            LiveSegmentForm(mode: .split, style: isCompact ? .inlineCompact : .inline) { isSplitting = false }
                .padding(isCompact ? theme.spacingS : theme.spacingM)
                .background(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                    .fill(theme.textPrimary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1))
        }
    }

    private var closeButton: some View {
        Button {
            overlay.hide()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(IconButtonStyle(size: 18))
        .foregroundStyle(theme.textTertiary)
        .accessibilityLabel("Hide overlay")
        .help("Hide overlay (⌘⇧O)")
    }

    private var todayTotal: some View {
        LiveTodaySessionsQuery { sessions in
            OverlayTodayTotal(sessions: sessions)
        }
    }

    private func statusText(isPaused: Bool) -> some View {
        Text(isPaused ? "Paused" : "Running")
            .font(theme.captionFont.weight(.medium))
            .foregroundStyle(theme.textSecondary)
    }

    private var focusText: String {
        let focus = engine.currentSegment?.focus.trimmed ?? ""
        if !focus.isEmpty { return focus }
        return engine.currentLabel?.name ?? "No focus"
    }

    private func toggleSplit() {
        isSplitting.toggle()
        if isSplitting {
            // Make the (non-activating) panel key so the split form's focus field takes typing right away.
            // This does not activate Worklog.
            NSApp.windows.first(where: { $0 is OverlayPanel })?.makeKey()
        }
    }

    private func stop() {
        isSplitting = false
        _ = engine.stop()
        // The review sheet lives in the main window.
        if engine.pendingEndSession != nil {
            router.showMainWindow()
        }
    }
}

/// "Today 2h 15m" (live while running).
@MainActor
private struct OverlayTodayTotal: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(\.theme) private var theme
    private let sessions: [WorkSession]

    init(sessions: [WorkSession]) {
        self.sessions = sessions
    }

    var body: some View {
        LiveClock(isTicking: engine.isRunning) { date in
            let total = LiveDayMath.totalToday(sessions, active: engine.activeSession, now: date)
            HStack(spacing: 3) {
                Image(systemName: "target")
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                Text("Today \(total.formattedShort)")
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }
            .font(theme.captionFont)
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Today, \(DesignSystemDurationSpeech.spoken(total))")
        }
    }
}
