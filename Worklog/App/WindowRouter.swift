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

    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    /// Set by AppServices; `showSession(_:)` switches to the session's profile so History can show it.
    @ObservationIgnored weak var profiles: ProfileStore?

    init() {}

    /// Called by RootView, MenuBarLabelView and MenuBarPanelView in .onAppear with @Environment(\.openWindow).
    /// - Parameter openSettings: Deprecated and ignored. Settings is a page of the main window now (there is no
    ///   Settings scene); the parameter remains only so older call sites still compile.
    func register(openWindow: OpenWindowAction, openSettings: OpenSettingsAction? = nil) {
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

    /// Selects the session's profile first when it is live, non-archived and not current (History is scoped to the
    /// current profile); then .history + selectedSessionID = session.persistentModelID (and brings the main window
    /// forward).
    func showSession(_ session: WorkSession) {
        guard ModelLiveness.isLive(session) else { return }
        if let profile = ModelLiveness.live(session.profile), !profile.isArchived,
           let profiles, profiles.activeProfileID != profile.uuid {
            profiles.select(profile)
        }
        selection = .history
        selectedSessionID = session.persistentModelID
        showMainWindow()
    }

    /// selection = .today; showMainWindow(); noteFocusRequest += 1
    func requestNoteFocus() {
        selection = .today
        showMainWindow()
        noteFocusRequest += 1
    }

    /// selection = .today; showMainWindow(); splitRequest += 1
    func requestSplit() {
        selection = .today
        showMainWindow()
        splitRequest += 1
    }

    /// selection = .today; showMainWindow(); discardRequest += 1
    func requestDiscard() {
        selection = .today
        showMainWindow()
        discardRequest += 1
    }
}
