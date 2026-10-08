import AppKit
import CoreData
import Foundation
import Observation
import Security
import SwiftData

enum StoreMode: Equatable {
    case cloudKit
    case localOnly(reason: String)   // e.g. "iCloud sync disabled", "iCloud isn't configured for this build", "CloudKit unavailable: <err>"
    case inMemory(reason: String)    // store failed to open; data NOT persisted — UI must warn + offer recovery
}

/// Errors from the recovery helpers.
enum StoreRecoveryError: LocalizedError {
    case storeIsOpen, nothingToMove, moveFailed(String), markerWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .storeIsOpen:
            "The data store is in use and can't be moved aside."
        case .nothingToMove:
            "There is no data store file to move aside."
        case .moveFailed(let reason):
            "The damaged data store couldn't be moved aside: \(reason)"
        case .markerWriteFailed(let reason):
            "The recovery couldn't be scheduled: \(reason)"
        }
    }
}

/// Contents of `AppConstants.pendingRestoreURL`.
struct PendingRestore: Codable, Equatable {
    /// Absolute path of the backup to import at the next launch; nil = start with a fresh store (CloudKit re-downloads).
    var backupPath: String?
    var createdAt: Date
}

@MainActor @Observable
final class PersistenceController {
    let container: ModelContainer
    let storeMode: StoreMode
    /// The `cloudSyncEnabled` value this launch tried to honour (false for any in-memory store).
    let cloudSyncRequestedAtLaunch: Bool
    /// CloudKit container identifier (from the entitlements, else `AppConstants.cloudKitContainerID`).
    let cloudKitContainerIdentifier: String
    /// Shown once (RootView info banner) after a recovery/restore performed at launch; the banner's dismiss sets nil.
    var launchNotice: String? = nil

    var mainContext: ModelContext { container.mainContext }
    var isSyncingWithICloud: Bool { storeMode == .cloudKit }
    var isInMemory: Bool {
        if case .inMemory = storeMode { return true }
        return false
    }
    /// In-memory because the on-disk store failed to open (not a preview/test container).
    var isRecoveryMode: Bool {
        if case .inMemory = storeMode { return !isPreview }
        return false
    }
    /// `<AppSupport>/Worklog/Recovered` — damaged stores, pre-upgrade snapshots, unsaved in-memory data.
    var recoveredFolderURL: URL { AppConstants.recoveredURL }

    private let isPreview: Bool

    private static let lastLaunchedVersionKey = "persistence.lastLaunchedAppVersion"
    private static let preOpenPrefix = "PreOpen-"
    private static let preOpenSnapshotsKept = 2

    /// Order of attempts:
    /// 1. If `cloudSyncEnabled && Entitlements.hasCloudKit`: on-disk store at `AppConstants.storeURL` with
    ///    `cloudKitDatabase: .private(<container id>)` → .cloudKit. (No iCloud-Drive `ubiquityIdentityToken` gate:
    ///    CloudKit handles a signed-out account itself and resumes when the user signs in; see `SyncMonitor`.)
    /// 2. Otherwise, or if (1) throws: same URL with `cloudKitDatabase: .none` → .localOnly(reason)
    /// 3. If (2) throws: in-memory → .inMemory(reason). The on-disk store is never deleted; the user can move it aside
    ///    with `quarantineStore()` (Recover… flow).
    /// Before opening, when the app version changed since the last launch, the store files are copied to
    /// `Recovered/PreOpen-<stamp>/` (the last 2 snapshots are kept) so a bad migration can be undone by hand.
    /// `inMemory: true` (previews/tests) goes straight to 3 with reason "Preview".
    init(cloudSyncEnabled: Bool, inMemory: Bool = false) {
        let schema = WorklogSchema.schema
        let containerID = Entitlements.cloudKitContainerIdentifier
        cloudKitContainerIdentifier = containerID
        isPreview = inMemory

        if inMemory {
            container = PersistenceController.makeInMemoryContainer(schema: schema)
            storeMode = .inMemory(reason: "Preview")
            cloudSyncRequestedAtLaunch = false
            return
        }

        PersistenceController.snapshotStoreIfAppVersionChanged()

        let storeURL = AppConstants.storeURL
        let localReason: String

        // 1. CloudKit
        if !cloudSyncEnabled {
            localReason = "iCloud sync disabled"
        } else if !Entitlements.hasCloudKit {
            localReason = "iCloud isn't configured for this build"
        } else {
            #if DEBUG
            if PersistenceController.wantsCloudKitSchemaInitialization {
                PersistenceController.initializeCloudKitSchema(containerIdentifier: containerID)
            }
            #endif
            do {
                let config = ModelConfiguration("Worklog", schema: schema, url: storeURL,
                                                cloudKitDatabase: .private(containerID))
                container = try ModelContainer(for: schema, configurations: [config])
                storeMode = .cloudKit
                cloudSyncRequestedAtLaunch = cloudSyncEnabled
                Log.persistence.info("Opened store with CloudKit sync")
                return
            } catch {
                localReason = "CloudKit unavailable: \(error.localizedDescription)"
                Log.persistence.error("CloudKit store failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. Local-only on-disk store (cloudKitDatabase MUST be explicit .none; .automatic would enable CloudKit).
        do {
            let config = ModelConfiguration("Worklog", schema: schema, url: storeURL, cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, configurations: [config])
            storeMode = .localOnly(reason: localReason)
            cloudSyncRequestedAtLaunch = cloudSyncEnabled
            Log.persistence.info("Opened local-only store: \(localReason, privacy: .public)")
            return
        } catch {
            Log.persistence.fault("Local store failed to open: \(error.localizedDescription, privacy: .public)")
            // 3. In-memory. The on-disk store is left untouched for recovery.
            container = PersistenceController.makeInMemoryContainer(schema: schema)
            storeMode = .inMemory(reason: "The data store couldn't be opened: \(error.localizedDescription)")
            cloudSyncRequestedAtLaunch = false
        }
    }

    // MARK: - Recovery

    /// Moves Worklog.store, -wal, -shm and .Worklog_SUPPORT/ (whichever exist) to `Recovered/Store-<UTC stamp>/` and
    /// returns that folder. Never deletes anything. Only allowed while running on the in-memory fallback (the on-disk
    /// store is then not open); throws `.storeIsOpen` otherwise.
    func quarantineStore() throws -> URL {
        guard isRecoveryMode else { throw StoreRecoveryError.storeIsOpen }
        let fileManager = FileManager.default
        let existing = AppConstants.storeFileURLs.filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !existing.isEmpty else { throw StoreRecoveryError.nothingToMove }
        let folder = Self.uniqueFolder(named: "Store-\(AppConstants.fileTimestamp())")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in existing {
                try fileManager.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
            }
        } catch {
            Log.persistence.error("Quarantine failed: \(error.localizedDescription, privacy: .public)")
            throw StoreRecoveryError.moveFailed(error.localizedDescription)
        }
        Log.persistence.info("Moved damaged store aside to \(folder.lastPathComponent, privacy: .public)")
        return folder
    }

    /// Writes `<AppSupport>/Worklog/pending-restore.json`. At the next launch `AppServices` imports `backupURL`
    /// (merge when CloudKit is on, replace otherwise) before seeding; nil = start fresh (CloudKit re-downloads data).
    static func scheduleRecovery(backupURL: URL?) throws {
        let marker = PendingRestore(backupPath: backupURL?.path(percentEncoded: false), createdAt: .now)
        do {
            let data = try ExportArchive.makeEncoder(pretty: true).encode(marker)
            try data.write(to: AppConstants.pendingRestoreURL, options: .atomic)
        } catch {
            throw StoreRecoveryError.markerWriteFailed(error.localizedDescription)
        }
    }

    /// The pending recovery marker, if any (nil when missing or unreadable).
    static func pendingRecovery() -> PendingRestore? {
        guard let data = try? Data(contentsOf: AppConstants.pendingRestoreURL) else { return nil }
        return try? ExportArchive.makeDecoder().decode(PendingRestore.self, from: data)
    }

    /// Removes the pending recovery marker.
    static func clearPendingRecovery() {
        let url = AppConstants.pendingRestoreURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.persistence.error("Couldn't remove recovery marker: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Launches a new instance of the app, then terminates this one.
    static func relaunchApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                Log.persistence.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - CloudKit schema (DEBUG only)

    #if DEBUG
    /// Launch argument that pushes the complete schema to the CloudKit **Development** environment before the store
    /// opens (run once from Xcode after a model change, then deploy the schema to Production in the CloudKit Console —
    /// see README "Before shipping a model change"). Lightweight sync only creates record types and fields for values
    /// that were actually saved, so without this a never-used field (e.g. an optional relationship) can be missing in
    /// Production.
    static let initializeCloudKitSchemaArgument = "-initializeCloudKitSchema"

    static var wantsCloudKitSchemaInitialization: Bool {
        ProcessInfo.processInfo.arguments.contains(initializeCloudKitSchemaArgument)
    }

    /// Loads the SwiftData model into a throwaway NSPersistentCloudKitContainer (empty store in a temporary folder, so
    /// the real store is never touched) and calls `initializeCloudKitSchema()`. Errors are logged, never fatal.
    static func initializeCloudKitSchema(containerIdentifier: String) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "WorklogSchemaInit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try autoreleasepool {
                guard let model = NSManagedObjectModel.makeManagedObjectModel(for: WorklogSchema.models) else {
                    Log.persistence.error("CloudKit schema: couldn't build the managed object model")
                    return
                }
                let description = NSPersistentStoreDescription(url: folder.appending(path: "Schema.store"))
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: containerIdentifier)
                description.shouldAddStoreAsynchronously = false
                let container = NSPersistentCloudKitContainer(name: "WorklogSchema", managedObjectModel: model)
                container.persistentStoreDescriptions = [description]
                var loadError: Error?
                container.loadPersistentStores { _, error in loadError = error }
                if let loadError { throw loadError }
                try container.initializeCloudKitSchema(options: [])
                for store in container.persistentStoreCoordinator.persistentStores {
                    try container.persistentStoreCoordinator.remove(store)
                }
            }
            Log.persistence.info("CloudKit schema initialized in the Development environment")
        } catch {
            Log.persistence.error("CloudKit schema initialization failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    // MARK: - Private

    private static func makeInMemoryContainer(schema: Schema) -> ModelContainer {
        let config = ModelConfiguration("WorklogMemory", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // An in-memory store can only fail if the schema itself is invalid — a programming error the app
            // cannot run without. There is no meaningful recovery.
            preconditionFailure("Worklog: in-memory ModelContainer failed: \(error)")
        }
    }

    /// Copies the store files to `Recovered/PreOpen-<stamp>/` when the app version differs from the last launch
    /// (APFS clones, so this is cheap). Keeps the newest `preOpenSnapshotsKept` snapshots. Records the version first so a
    /// launch that keeps failing doesn't replace the good snapshot with copies of the broken store.
    private static func snapshotStoreIfAppVersionChanged() {
        let defaults = UserDefaults.standard
        let version = AppConstants.appVersion
        let previous = defaults.string(forKey: lastLaunchedVersionKey)
        guard previous != version else { return }
        defaults.set(version, forKey: lastLaunchedVersionKey)

        let fileManager = FileManager.default
        let existing = AppConstants.storeFileURLs.filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !existing.isEmpty else { return }     // first launch: nothing to protect
        let folder = uniqueFolder(named: "\(preOpenPrefix)\(AppConstants.fileTimestamp())")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in existing {
                try fileManager.copyItem(at: url, to: folder.appending(path: url.lastPathComponent))
            }
            Log.persistence.info("Pre-upgrade snapshot \(folder.lastPathComponent, privacy: .public) (from \(previous ?? "unknown", privacy: .public) to \(version, privacy: .public))")
        } catch {
            Log.persistence.error("Pre-upgrade snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
        prunePreOpenSnapshots()
    }

    private static func prunePreOpenSnapshots() {
        let fileManager = FileManager.default
        let folders = ((try? fileManager.contentsOfDirectory(at: AppConstants.recoveredURL, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(preOpenPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }     // UTC stamps sort chronologically
        for folder in folders.dropFirst(preOpenSnapshotsKept) {
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                Log.persistence.error("Couldn't remove old snapshot \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func uniqueFolder(named name: String) -> URL {
        let base = AppConstants.recoveredURL
        var url = base.appending(path: name, directoryHint: .isDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = base.appending(path: "\(name)-\(counter)", directoryHint: .isDirectory)
            counter += 1
        }
        return url
    }
}

enum Entitlements {
    /// Uses SecTaskCreateFromSelf + SecTaskCopyValueForEntitlement.
    static func has(_ key: String) -> Bool {
        guard let value = value(for: key) else { return false }
        if let flag = value as? Bool { return flag }
        if let array = value as? [Any] { return !array.isEmpty }
        if let string = value as? String { return !string.isEmpty }
        return true
    }

    /// Raw entitlement value for `key`, or nil.
    static func value(for key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    static var hasCloudKit: Bool { has("com.apple.developer.icloud-services") }    // "com.apple.developer.icloud-services"
    static var hasSignInWithApple: Bool { has("com.apple.developer.applesignin") } // "com.apple.developer.applesignin"
    /// True when signed with a team (the data-protection keychain needs an application identifier).
    static var hasApplicationIdentifier: Bool {
        has("com.apple.application-identifier") || has("application-identifier")
    }

    /// First entry of "com.apple.developer.icloud-container-identifiers", else `AppConstants.cloudKitContainerID`.
    static var cloudKitContainerIdentifier: String {
        if let identifiers = value(for: "com.apple.developer.icloud-container-identifiers") as? [String],
           let first = identifiers.first(where: { !$0.isEmpty }) {
            return first
        }
        return AppConstants.cloudKitContainerID
    }
}
