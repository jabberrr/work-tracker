import AppKit
import SwiftData
import SwiftUI

/// Content of the floating, non-activating overlay panel (hosted by `OverlayPanelController`, which also applies
/// opacity, level, spaces and visibility). Renders `settings.overlayLayout` through `OverlayContent` in `.live`
/// mode: 300 pt wide, 220 pt compact; height is intrinsic (`fixedSize(vertical:)`) so the panel's sizingOptions
/// follow the content as elements appear and disappear.
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
    /// For the idle Start button's "Start · <default label>" (no fetch in `body`).
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]

    @State private var isSplitting = false
    @FocusState private var noteFocused: Bool

    init() {}

    var body: some View {
        LiveTodaySessionsQuery { sessions in
            OverlayTicker(isTicking: engine.isRunning) { date in
                OverlayContent(
                    layout: settings.overlayLayout,
                    data: liveData(sessions: sessions, at: date),
                    isCompact: settings.overlayCompact,
                    mode: .live,
                    isSplitting: isSplitting,
                    noteFocus: $noteFocused,
                    actions: actions
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: engine.isActive) { _, isActive in
            if !isActive { isSplitting = false }
        }
    }

    // MARK: Data

    private func liveData(sessions: [WorkSession], at date: Date) -> OverlayDisplayData {
        let startLabel = LiveStartChoice.defaultLabel(in: labels, settings: settings)
        let todayTotal = LiveDayMath.totalToday(sessions, active: engine.activeSession, now: date)
        guard let session = engine.activeSession, LiveModelGuard.isUsable(session) else {
            return OverlayDisplayData(
                status: .idle, label: nil, elapsed: 0, segmentElapsed: 0, todayTotal: todayTotal, focus: "",
                takeaway: engine.lastTakeaway, startLabel: startLabel,
                hasPendingReview: engine.pendingEndSession != nil, isOnAnotherMac: false
            )
        }
        return OverlayDisplayData(
            status: engine.isPaused ? .paused : .running,
            label: engine.currentLabel,
            elapsed: engine.elapsed(at: date),
            segmentElapsed: engine.currentSegmentElapsed(at: date),
            todayTotal: todayTotal,
            focus: engine.currentSegment?.focus.trimmed ?? "",
            takeaway: engine.lastTakeaway,
            startLabel: startLabel,
            hasPendingReview: engine.pendingEndSession != nil,
            isOnAnotherMac: engine.isActiveSessionOnAnotherMac
        )
    }

    // MARK: Actions

    private var actions: OverlayActions {
        OverlayActions(
            hide: { overlay.hide() },
            togglePause: { engine.togglePause() },
            toggleSplit: { toggleSplit() },
            endSplit: { isSplitting = false },
            stop: { stop() },
            start: { start() },
            review: { router.showMainWindow() }
        )
    }

    private func start() {
        _ = engine.start(label: engine.defaultLabel())
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

/// Re-renders once per second while `isTicking`, and keeps the same view identity when ticking starts or stops
/// (a branch between a TimelineView and plain content would reset the note field and split form on pause).
/// While paused or idle it passes the current date on each re-render.
@MainActor
private struct OverlayTicker<Content: View>: View {
    private let isTicking: Bool
    private let content: (Date) -> Content

    init(isTicking: Bool, @ViewBuilder content: @escaping (Date) -> Content) {
        self.isTicking = isTicking
        self.content = content
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !isTicking)) { context in
            content(isTicking ? context.date : Date())
        }
    }
}
