import AppKit
import Foundation
import Observation

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
        observeDockIconSetting()
    }

    /// Applies "Hide Dock icon when main window closed" as soon as it is toggled. RootView applies it when the main
    /// window opens/closes, so nothing is applied at launch (avoids a Dock icon flicker before the window appears).
    private func observeDockIconSetting() {
        let settings = services.settings
        withObservationTracking {
            _ = settings.hideDockIconWhenClosed
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.services.router.applyActivationPolicy(hideDockIconWhenClosed: self.services.settings.hideDockIconWhenClosed)
                self.observeDockIconSetting()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        services.engine.prepareForTermination()
        services.backups.backupNow(reason: .onQuit)
        return .terminateNow
    }

    /// Everything is saved and backed up by now (`applicationShouldTerminate`). AppKit calls `exit()` after this, and
    /// `exit()`'s teardown handlers can pull the store out from under CloudKit mirroring while it is still saving on
    /// its own queue: "This NSPersistentStoreCoordinator has no persistent stores (unknown). It cannot perform a save
    /// operation." Registered last, this handler runs first and ends the process before that teardown starts.
    /// (Saved data is safe either way: SQLite commits are durable, and pending sync work resumes at the next launch.)
    func applicationWillTerminate(_ notification: Notification) {
        atexit {
            fflush(stdout)
            fflush(stderr)
            _exit(EXIT_SUCCESS)
        }
    }

    /// M4: after an iCloud account change, warn once if the store lost most of its sessions.
    func applicationDidBecomeActive(_ notification: Notification) {
        services.checkDataShrinkage()
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
