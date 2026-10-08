import AppKit
import Observation
import SwiftData
import SwiftUI

/// Navigation state for the main window plus "bring the window forward" helpers usable from the menu bar,
/// the overlay and commands (even after the main window was closed).
@MainActor @Observable
final class WindowRouter {
    var selection: SidebarItem = .today
    /// History's list selection (HistoryView binds its List selection to this).
    var selectedSessionID: PersistentIdentifier? = nil
    /// Incremented on each request; LiveSessionView observes with .onChange and focuses the note field / opens split UI.
    private(set) var noteFocusRequest: Int = 0
    private(set) var splitRequest: Int = 0
    /// Incremented by `requestDiscard()`; the Today page observes it and runs its discard flow (with confirmation
    /// when Settings asks for it).
    private(set) var discardRequest: Int = 0
    /// Settings tab to select (a `SettingsTab` rawValue, e.g. "data", "account"). Set by `showSettings(tab:)`;
    /// SettingsView reads it (onAppear / onChange) and sets it back to nil.
    var settingsTabRequest: String? = nil
    /// True while the main window's RootView is on screen (RootView reports open/close).
    private(set) var isMainWindowOpen = false
    /// Sheets presented inside the main window other than the review sheet (History's Split sheet, the image viewer,
    /// New Profile…). While > 0, RootView holds the review sheet back (a window shows one sheet at a time) and
    /// presents it when the count returns to 0. Each such sheet calls `childSheetDidAppear()` in onAppear and
    /// `childSheetDidDisappear()` in onDisappear.
    private(set) var presentedChildSheets: Int = 0
    /// Bumped by `requestReview()`; RootView briefly holds the review sheet back and re-presents it (the same
    /// nil → session toggle as the Settings hold), so a review that SwiftUI dropped shows up again.
    private(set) var reviewRequest: Int = 0
    /// Bumped by `showSession(_:)`; HistoryView clears its filters and search when it changes, so the session shows.
    private(set) var historyFilterResetRequest: Int = 0

    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    /// Set by AppServices; `showSession(_:)` switches to the session's profile so History can show it.
    @ObservationIgnored weak var profiles: ProfileStore?
    /// Set by AppServices. While `auth.needsWelcome` (Welcome is on screen) the Today requests (note focus, split,
    /// discard) are dropped: they would otherwise fire later, after sign-in, when Today first appears.
    @ObservationIgnored weak var auth: AuthService?

    init() {}

    /// Called by RootView, MenuBarLabelView and MenuBarPanelView in .onAppear with @Environment(\.openWindow).
    func register(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    /// NSApp.activate() + openWindow(id: WindowID.main) (brings an existing Window to front).
    func showMainWindow() {
        if NSApp.activationPolicy() != .regular {
            // Dock icon hidden while the main window was closed: become a regular app again before showing it.
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        if let openWindowAction {
            openWindowAction(id: WindowID.main)
        } else if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            // openWindow not registered yet (no scene has appeared): fall back to any existing main window.
            window.makeKeyAndOrderFront(nil)
        } else {
            Log.ui.error("showMainWindow: no openWindow action registered and no window to show")
        }
    }

    /// selection = .settings; showMainWindow(). Settings is a page in the main window's detail column; this also
    /// reopens the main window when it was closed.
    func showSettings() {
        selection = .settings
        showMainWindow()
    }

    /// settingsTabRequest = tab; showSettings(). `tab` is a SettingsTab rawValue ("data", "account", …).
    func showSettings(tab: String) {
        settingsTabRequest = tab
        showSettings()
    }

    // MARK: - Dock icon

    /// RootView appeared (main window opened): show the Dock icon again.
    func mainWindowDidOpen(hideDockIconWhenClosed: Bool) {
        isMainWindowOpen = true
        applyActivationPolicy(hideDockIconWhenClosed: hideDockIconWhenClosed)
    }

    /// RootView disappeared (main window closed): hide the Dock icon if the setting asks for it.
    func mainWindowDidClose(hideDockIconWhenClosed: Bool) {
        isMainWindowOpen = false
        // The window's sheets are gone with it; never let a missed onDisappear hold the review back forever.
        presentedChildSheets = 0
        applyActivationPolicy(hideDockIconWhenClosed: hideDockIconWhenClosed)
    }

    /// .accessory while the main window is closed and the setting is on; .regular otherwise.
    func applyActivationPolicy(hideDockIconWhenClosed: Bool) {
        let target: NSApplication.ActivationPolicy = (hideDockIconWhenClosed && !isMainWindowOpen) ? .accessory : .regular
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular && isMainWindowOpen {
            NSApp.activate()
        }
    }

    /// selection = item; showMainWindow()
    func show(_ item: SidebarItem) {
        selection = item
        showMainWindow()
    }

    /// Selects the session's (effective) profile first when it is live, non-archived and not current (History is
    /// scoped to the current profile); then .history + selectedSessionID = session.persistentModelID (and brings the
    /// main window forward). Bumps `historyFilterResetRequest` so History's filters and search can't hide the row.
    func showSession(_ session: WorkSession) {
        guard ModelLiveness.isLive(session) else { return }
        if let profile = ProfileOps.effectiveProfile(of: session), !profile.isArchived,
           let profiles, profiles.activeProfileID != profile.uuid {
            profiles.select(profile)
        }
        historyFilterResetRequest += 1
        selection = .history
        selectedSessionID = session.persistentModelID
        showMainWindow()
    }

    // MARK: - Today requests

    /// True while Welcome is on screen (see `auth`).
    private var isWelcomeShowing: Bool { auth?.needsWelcome ?? false }

    /// selection = .today; showMainWindow(); noteFocusRequest += 1. While Welcome is on screen it only shows the
    /// window (selection and the counter are left alone, so nothing fires after sign-in).
    func requestNoteFocus() {
        showMainWindow()
        guard !isWelcomeShowing else { return }
        selection = .today
        noteFocusRequest += 1
    }

    /// selection = .today; showMainWindow(); splitRequest += 1. While Welcome is on screen: window only.
    func requestSplit() {
        showMainWindow()
        guard !isWelcomeShowing else { return }
        selection = .today
        splitRequest += 1
    }

    /// selection = .today; showMainWindow(); discardRequest += 1. While Welcome is on screen: window only.
    func requestDiscard() {
        showMainWindow()
        guard !isWelcomeShowing else { return }
        selection = .today
        discardRequest += 1
    }

    // MARK: - Stop and review

    /// The single stop path (menu bar, overlay, Session menu): stops the session; when a review is pending
    /// (`engine.pendingEndSession`, i.e. the review sheet is on in Settings), brings the main window forward so the
    /// sheet is seen. With the review off, the window is left alone.
    func stopSession(_ engine: SessionEngine) {
        engine.stop()
        if engine.pendingEndSession != nil {
            showMainWindow()
        }
    }

    /// "Review…" (menu bar, overlay): brings the main window forward and re-presents a pending review: leaves
    /// Settings (its pages present their own sheets) and bumps `reviewRequest`, which makes RootView toggle the
    /// sheet's item nil → session. With nothing pending it only shows the window.
    func requestReview() {
        showMainWindow()
        if selection == .settings, !isWelcomeShowing {
            selection = .today
        }
        reviewRequest += 1
    }

    // MARK: - Child sheets

    /// A sheet in the main window appeared (see `presentedChildSheets`).
    func childSheetDidAppear() {
        presentedChildSheets += 1
    }

    /// A sheet in the main window disappeared. Never goes below 0.
    func childSheetDidDisappear() {
        presentedChildSheets = max(0, presentedChildSheets - 1)
    }
}
