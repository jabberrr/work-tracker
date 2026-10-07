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
        .commands { WorklogCommands(services: services) }

        Settings {
            SettingsView().withAppServices(services)
        }

        MenuBarExtra(isInserted: Bindable(services.settings).showMenuBarExtra) {
            MenuBarPanelView().withAppServices(services)
        } label: {
            MenuBarLabelView().withAppServices(services)
        }
        .menuBarExtraStyle(.window)
    }
}
