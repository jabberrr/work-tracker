import AppKit
import Foundation

/// C1c: only one Worklog process may open the store. Called from `WorklogApp.init()` before `AppServices.shared`
/// (and so the store) is created.
///
/// - Another instance with the same bundle id is running → it is brought to the front and this process exits
///   without opening anything.
/// - A relaunch (`PersistenceController.relaunchApp()` passes `relaunchArgument`) first waits up to 30 s for the old
///   instance to finish quitting (it still saves and backs up), then continues; if it is still running, the old
///   one is activated and this one exits.
/// - Skipped under XCTest and SwiftUI previews.
enum SingleInstanceGuard {
    static let relaunchArgument = "-worklogRelaunch"
    private static let relaunchWait: TimeInterval = 30

    @MainActor
    static func enforce() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
        guard !others.isEmpty else { return }

        if ProcessInfo.processInfo.arguments.contains(relaunchArgument) {
            let pids = others.map(\.processIdentifier)
            let deadline = Date.now.addingTimeInterval(relaunchWait)
            while pids.contains(where: isAlive) && Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard pids.contains(where: isAlive) else { return }
            Log.persistence.error("Relaunch: the previous instance is still running; not opening the store twice")
        } else {
            Log.persistence.info("Worklog is already running; activating it")
        }
        if let other = others.first(where: { isAlive($0.processIdentifier) }) {
            activate(other)
        }
        exit(0)
    }

    /// True while a process with `pid` exists (signal 0 only checks; EPERM still means it exists).
    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Brings the running instance to the front (and its main window back, through `applicationShouldHandleReopen`).
    /// Waits briefly for LaunchServices so the request isn't lost when this process exits.
    @MainActor
    private static func activate(_ other: NSRunningApplication) {
        // Same copy of the app (e.g. `open -n`): opening its URL could resolve to this process, so activate directly.
        guard let url = other.bundleURL, url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else {
            other.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }
}
