import AppKit
import Foundation

/// App lifecycle hooks: launch wiring, quit handling (auto-pause + backup) and reopen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices { AppServices.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.themeManager.applyAppearance()
        NSApp.registerForRemoteNotifications()       // CloudKit silent pushes for SwiftData sync
        services.engine.startObservingSystemEvents()
        services.backups.startScheduling()
        let auth = services.auth
        Task { await auth.checkCredentialState() }
        services.overlay.applicationDidFinishLaunching()   // shows the overlay if settings.overlayEnabled
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        services.engine.prepareForTermination()
        services.backups.backupNow(reason: .onQuit)
        return .terminateNow
    }

    /// The menu bar extra keeps the app alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            services.router.showMainWindow()
        }
        return true
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Log.persistence.info("Registered for remote notifications")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected without the aps-environment entitlement (e.g. WorklogLocal.entitlements).
        Log.persistence.info("Remote notifications unavailable: \(error.localizedDescription, privacy: .public)")
    }
}
