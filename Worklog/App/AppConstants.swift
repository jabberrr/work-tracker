import Foundation

enum AppConstants {
    static let appName = "Worklog"
    static let bundleID = "app.dabora.worktracker"                 // CHANGE ME (also BUNDLE_ID in scripts/generate_xcodeproj.py)
    static let cloudKitContainerID = "iCloud.app.dabora.worktracker" // CHANGE ME (also entitlements)
    static let backupFolderName = "Backups"
    /// Folder (inside applicationSupportURL) for quarantined/damaged stores, pre-upgrade snapshots and unsaved data.
    static let recoveredFolderName = "Recovered"

    /// URL.applicationSupportDirectory/Worklog (created if missing). Inside the sandbox container when sandboxed.
    static var applicationSupportURL: URL {
        let url = URL.applicationSupportDirectory.appending(path: appName, directoryHint: .isDirectory)
        ensureDirectory(url)
        return url
    }

    /// applicationSupportURL/Backups (created if missing).
    static var backupsURL: URL {
        let url = applicationSupportURL.appending(path: backupFolderName, directoryHint: .isDirectory)
        ensureDirectory(url)
        return url
    }

    /// applicationSupportURL/Worklog.store
    static var storeURL: URL {
        applicationSupportURL.appending(path: "Worklog.store", directoryHint: .notDirectory)
    }

    /// applicationSupportURL/Recovered (NOT created on access; created when something is written there).
    static var recoveredURL: URL {
        applicationSupportURL.appending(path: recoveredFolderName, directoryHint: .isDirectory)
    }

    /// applicationSupportURL/pending-restore.json — written by `PersistenceController.scheduleRecovery(backupURL:)`,
    /// consumed by `AppServices` at the next launch.
    static var pendingRestoreURL: URL {
        applicationSupportURL.appending(path: "pending-restore.json", directoryHint: .notDirectory)
    }

    /// The store file plus SQLite/SwiftData companions (-wal, -shm and the external-storage folder `.Worklog_SUPPORT`).
    static var storeFileURLs: [URL] {
        let store = storeURL
        let directory = store.deletingLastPathComponent()
        let name = store.lastPathComponent
        let stem = store.deletingPathExtension().lastPathComponent
        return [
            store,
            directory.appending(path: name + "-wal", directoryHint: .notDirectory),
            directory.appending(path: name + "-shm", directoryHint: .notDirectory),
            directory.appending(path: ".\(stem)_SUPPORT", directoryHint: .isDirectory),
        ]
    }

    /// "2026-10-07T14-03-22Z" (UTC, filename-safe).
    static func fileTimestamp(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }

    /// Creates `url` (and parents) if missing.
    static func makeDirectory(_ url: URL) {
        ensureDirectory(url)
    }

    /// CFBundleShortVersionString of the running app ("0" if missing).
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func ensureDirectory(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.persistence.error("Couldn't create directory \(url.path(percentEncoded: false), privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum WindowID {
    static let main = "main"
}
