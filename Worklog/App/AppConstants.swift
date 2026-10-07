import Foundation

enum AppConstants {
    static let appName = "Worklog"
    static let bundleID = "com.example.worklog"                 // CHANGE ME (also project.yml)
    static let cloudKitContainerID = "iCloud.com.example.worklog" // CHANGE ME (also entitlements)
    static let backupFolderName = "Backups"

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

    /// CFBundleShortVersionString of the running app ("0" if missing).
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func ensureDirectory(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.persistence.error("Couldn't create directory \(url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum WindowID {
    static let main = "main"
}
