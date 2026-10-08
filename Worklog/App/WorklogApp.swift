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
        // The window's minimum follows the content's minimum size. That stays 900 × 600 only because RootView's
        // detail (and HistoryView's columns) are wrapped in 0-minimum frames, so a page's minimum can't reach the
        // window. Settings is a page of this window (no Settings scene; see WorklogCommands).
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
