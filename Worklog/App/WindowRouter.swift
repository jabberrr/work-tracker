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

    @ObservationIgnored private var openWindowAction: OpenWindowAction?

    init() {}

    /// Called by RootView and MenuBarLabelView in .onAppear with @Environment(\.openWindow).
    func register(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    /// NSApp.activate(ignoringOtherApps: true) + openWindow(id: WindowID.main) (brings an existing Window to front).
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let openWindowAction {
            openWindowAction(id: WindowID.main)
        } else if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            // openWindow not registered yet (no scene has appeared): fall back to any existing main window.
            window.makeKeyAndOrderFront(nil)
        } else {
            Log.ui.error("showMainWindow: no openWindow action registered and no window to show")
        }
    }

    /// Activate + NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil).
    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
