import AppKit
import SwiftData
import SwiftUI

/// Content of the floating, non-activating overlay panel (hosted by `OverlayPanelController`, which also applies
/// opacity, level, spaces and visibility). Renders `settings.overlayGrid` through `OverlayContent` in `.live`
/// mode: 300 pt wide, 220 pt compact; height is intrinsic (`fixedSize(vertical:)`) so the panel's sizingOptions
/// follow the content as elements appear and disappear.
///
/// Focus: the panel is borderless + `.nonactivatingPanel`, `canBecomeKey == true` and
/// `becomesKeyOnlyIfNeeded == true`, so clicking a text field makes it key (typing works) without
/// activating Worklog; buttons work without taking key status. Esc / Return in the note field and closing the
/// split form give key status back (`OverlayPanelController.releaseKeyFocus()`).
///
/// Profiles: like the menu bar, everything follows the *panel profile*: the running session's profile while
/// active, else the quick start profile. Start, the takeaway and today's total use it; the header names it when
/// there are 2 or more profiles.
@MainActor
struct OverlayView: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(WindowRouter.self) private var router
    @Environment(OverlayPanelController.self) private var overlay
    @Environment(ProfileStore.self) private var profiles
    /// For the idle Start button's "Start · <default label>" in the quick start profile (no fetch in `body`).
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]

    @State private var isSplitting = false
    @FocusState private var noteFocused: Bool

    init() {}

    var body: some View {
        // The query keeps its content's identity at midnight, so a half-typed note or open split form survives.
        LiveTodaySessionsQuery { sessions in
            LiveTicker(isTicking: engine.isRunning) { date in
                OverlayContent(
                    grid: settings.overlayGrid,
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
        let quickStart = profiles.quickStartProfile
        let startLabel = LiveStartChoice.defaultLabel(in: labels, profile: quickStart, settings: settings)
        guard let session = engine.activeSession, ModelLiveness.isLive(session) else {
            let scope = ProfileScope(profileID: profiles.quickStartProfileID)
            let profile = OverlayDisplayData.profileFields(quickStart, showsProfile: profiles.hasMultipleProfiles)
            return OverlayDisplayData(
                status: .idle, label: nil, elapsed: 0, segmentElapsed: 0,
                todayTotal: LiveDayMath.totalToday(sessions, active: engine.activeSession, now: date, scope: scope),
                focus: "",
                takeaway: engine.takeaway(for: profiles.quickStartProfileID), startLabel: startLabel,
                hasPendingReview: engine.pendingEndSession != nil, isOnAnotherMac: false,
                profileName: profile.name, profileColorHex: profile.colorHex
            )
        }
        let profileID = engine.activeSessionProfileID
        let scope = ProfileScope(profileID: profileID)
        let profile = OverlayDisplayData.profileFields(engine.activeSessionProfile,
                                                       showsProfile: profiles.hasMultipleProfiles)
        return OverlayDisplayData(
            status: engine.isPaused ? .paused : .running,
            label: engine.currentLabel,
            elapsed: engine.elapsed(at: date),
            segmentElapsed: engine.currentSegmentElapsed(at: date),
            todayTotal: LiveDayMath.totalToday(sessions, active: session, now: date, scope: scope),
            focus: engine.currentSegment?.focus.trimmed ?? "",
            takeaway: engine.takeaway(for: profileID),
            startLabel: startLabel,
            hasPendingReview: engine.pendingEndSession != nil,
            isOnAnotherMac: engine.isActiveSessionOnAnotherMac,
            profileName: profile.name,
            profileColorHex: profile.colorHex,
            longSessionHours: LiveLongSessionRule.warningHours(engine: engine, settings: settings, now: date)
        )
    }

    // MARK: Actions

    private var actions: OverlayActions {
        OverlayActions(
            hide: { overlay.hide() },
            togglePause: { engine.togglePause() },
            toggleSplit: { toggleSplit() },
            endSplit: { endSplit() },
            stop: { stop() },
            start: { start() },
            review: { router.requestReview() },
            releaseKey: { overlay.releaseKeyFocus() },
            keepGoing: { keepGoing() }
        )
    }

    /// Same label the button names (`defaultLabel(in:profile:settings:)` mirrors the engine's rule).
    private func start() {
        let profile = profiles.quickStartProfile
        _ = engine.start(label: engine.defaultLabel(for: profile), profile: profile)
    }

    private func toggleSplit() {
        isSplitting.toggle()
        if isSplitting {
            // Make the (non-activating) panel key so the split form's focus field takes typing right away.
            // This does not activate Worklog.
            overlay.makePanelKey()
        } else {
            overlay.releaseKeyFocus()
        }
    }

    /// Split committed or cancelled: close the form and hand the keyboard back.
    private func endSplit() {
        isSplitting = false
        overlay.releaseKeyFocus()
    }

    /// The single stop path (brings the main window forward when a review is pending).
    private func stop() {
        isSplitting = false
        overlay.releaseKeyFocus()
        router.stopSession(engine)
    }

    private func keepGoing() {
        guard let session = ModelLiveness.live(engine.activeSession) else { return }
        engine.dismissLongSessionWarning(for: session)
    }
}
