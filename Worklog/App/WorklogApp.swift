import SwiftData
import SwiftUI

@main @MainActor
struct WorklogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        Window("Worklog", id: WindowID.main) {
            RootView().withAppServices(services)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
        // Explicit: the window's minimum is the root's 900 × 600 (with `.automatic`, a child's oversized minimum
        // could grow the window). Settings is a page of this window (no Settings scene; see WorklogCommands).
        .windowResizability(.contentMinSize)
        .commands { WorklogCommands(services: services) }

        MenuBarExtra(isInserted: Bindable(services.settings).showMenuBarExtra) {
            MenuBarPanelView().withAppServices(services)
        } label: {
            MenuBarLabelView().withAppServices(services)
        }
        .menuBarExtraStyle(.window)
    }
}
