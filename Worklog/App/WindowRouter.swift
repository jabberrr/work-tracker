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
    /// Settings tab to select (a `SettingsTab` rawValue, e.g. "data", "account"). Set by `showSettings(tab:)`;
    /// SettingsView reads it (onAppear / onChange) and sets it back to nil.
    var settingsTabRequest: String? = nil
    /// True while the main window's RootView is on screen (RootView reports open/close).
    private(set) var isMainWindowOpen = false

    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var openSettingsAction: OpenSettingsAction?

    init() {}

    /// Called by RootView, MenuBarLabelView and MenuBarPanelView in .onAppear with @Environment(\.openWindow) and
    /// @Environment(\.openSettings). A nil `openSettings` keeps a previously registered one.
    func register(openWindow: OpenWindowAction, openSettings: OpenSettingsAction? = nil) {
        openWindowAction = openWindow
        if let openSettings { openSettingsAction = openSettings }
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

    /// Activates the app and opens the Settings scene via the registered `OpenSettingsAction` (macOS 14); falls back
    /// to the responder-chain actions when no SwiftUI scene has registered one yet.
    func showSettings() {
        NSApp.activate()
        if let openSettingsAction {
            openSettingsAction()
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
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

    /// .history + selectedSessionID = session.persistentModelID (and brings the main window forward).
    func showSession(_ session: WorkSession) {
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
}
