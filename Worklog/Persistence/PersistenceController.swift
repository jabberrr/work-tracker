import AppKit
import CoreData
import CryptoKit
import Foundation
import Observation
import Security
import SwiftData

enum StoreMode: Equatable {
    case cloudKit
    case localOnly(reason: String)   // e.g. "iCloud sync disabled", "iCloud isn't configured for this build", "CloudKit unavailable: <err>"
    case inMemory(reason: String)    // store failed to open; data NOT persisted — UI must warn + offer recovery
}

/// The CloudKit environment a build syncs with: the signed `com.apple.developer.icloud-container-environment`
/// entitlement (Release: `WorklogRelease.entitlements` → Production; Debug: absent → Development).
enum CloudKitEnvironment: String, Codable, CaseIterable, Sendable {
    case development = "Development"
    case production = "Production"

    /// "Production" (case-insensitive) → .production; anything else → .development (CloudKit's default).
    init(entitlementValue: String) {
        self = entitlementValue.caseInsensitiveCompare("Production") == .orderedSame ? .production : .development
    }
}

/// The store last synced with another CloudKit environment than this build uses. It is opened local-only (never
/// silently switched); Settings ▸ Data offers "Move to iCloud <build>…" or "Keep Local Only".
struct EnvironmentMismatch: Equatable, Sendable {
    let store: CloudKitEnvironment
    let build: CloudKitEnvironment

    /// Short reason used as the local-only reason (no colon: RootView's banner cuts the text at one).
    var reason: String {
        "This data belongs to iCloud \(store.rawValue), not \(build.rawValue)"
    }
}

/// A completed "Move to iCloud <env>" (the old store files were moved aside at this launch, before opening).
/// `AppServices` restores the move's backup and shows the launch notice.
struct EnvironmentMove: Equatable {
    let from: CloudKitEnvironment
    let to: CloudKitEnvironment
    /// `Recovered/Env-<from>-<UTC stamp>/` holding the old store files; nil when there were none.
    let folder: URL?
}

/// How the on-disk store may be opened at launch (pure; unit-tested in `PersistenceGuardTests`).
enum StoreEnvironmentDecision: Equatable {
    /// Open with CloudKit; record this environment once the store opened.
    case openCloudKit(CloudKitEnvironment)
    /// The store synced with another environment: open local-only and offer the move.
    case localOnlyMismatch(EnvironmentMismatch)
    /// Sync is off (or the build has no iCloud entitlement): open local-only.
    case localOnly
}

/// Errors from the recovery helpers.
enum StoreRecoveryError: LocalizedError {
    case storeIsOpen, nothingToMove, moveFailed(String), markerWriteFailed(String), storeIsNewer

    var errorDescription: String? {
        switch self {
        case .storeIsOpen:
            "The data store is in use and can't be moved aside."
        case .nothingToMove:
            "There is no data store file to move aside."
        case .moveFailed(let reason):
            "The data store couldn't be moved aside: \(reason)"
        case .markerWriteFailed(let reason):
            "The recovery couldn't be scheduled: \(reason)"
        case .storeIsNewer:
            "This data was made by a newer version of Worklog."
        }
    }
}

/// Contents of `AppConstants.pendingRestoreURL`.
struct PendingRestore: Codable, Equatable {
    /// Absolute path of the backup to import at the next launch; nil = start with a fresh store (CloudKit re-downloads).
    var backupPath: String?
    var createdAt: Date
    /// "Move to iCloud <env>": the environment (raw value) to move to. The next launch moves the store files aside to
    /// `Recovered/Env-<old>-<stamp>/` BEFORE opening, then opens a fresh CloudKit store and restores `backupPath`.
    /// nil for a plain recovery. (Optional, so markers written by older builds still decode.)
    var environmentMove: String? = nil
}

@MainActor @Observable
final class PersistenceController {
    let container: ModelContainer
    let storeMode: StoreMode
    /// The `cloudSyncEnabled` value this launch tried to honour (false for any in-memory store).
    let cloudSyncRequestedAtLaunch: Bool
    /// CloudKit container identifier (from the entitlements, else `AppConstants.cloudKitContainerID`).
    let cloudKitContainerIdentifier: String
    /// The CloudKit environment of this build (`Entitlements.cloudKitEnvironment`).
    let buildEnvironment: CloudKitEnvironment
    /// Set when the store synced with another CloudKit environment (opened local-only; see `EnvironmentMismatch`).
    let environmentMismatch: EnvironmentMismatch?
    /// Set when this launch completed the first half of "Move to iCloud <env>" (old store moved aside).
    let environmentMove: EnvironmentMove?
    /// The store couldn't be opened because a newer Worklog changed its model: Recover is not offered (the store must
    /// not be moved aside); the user installs the newer version instead.
    let isStoreFromNewerVersion: Bool
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

    /// UserDefaults: the CloudKit environment the store syncs with ("Development"/"Production"), or
    /// `neverSyncedValue` for a store created local-only that never synced. Missing + store exists → Development
    /// (every store from before this key was written synced with Development).
    nonisolated static let cloudKitEnvironmentKey = "persistence.cloudKitEnvironment"
    nonisolated static let neverSyncedValue = "none"
    /// UserDefaults: `storeOpenKey` of the last launch (PreOpen snapshot trigger).
    private static let lastStoreOpenKeyKey = "persistence.lastStoreOpenKey"
    /// UserDefaults: the newest app version (CFBundleShortVersionString) that opened the store.
    private static let newestVersionOpenedKey = "persistence.newestAppVersionOpened"
    private static let preOpenPrefix = "PreOpen-"
    private static let preOpenSnapshotsKept = 2

    /// Order of steps (on-disk store):
    /// 0. PreOpen snapshot when `storeOpenKey` (version, build, configuration, CloudKit environment, model hash)
    ///    changed since the last launch.
    /// 1. A pending "Move to iCloud <env>" marker for this build's environment (sync on): the store files are moved
    ///    to `Recovered/Env-<old>-<stamp>/` and the recorded environment is cleared (`environmentMove`).
    /// 2. `environmentDecision`: CloudKit only when the store's recorded environment matches this build (or the store
    ///    is new / never synced); a mismatch opens local-only (`environmentMismatch`) — never a silent switch.
    /// 3. CloudKit: on-disk store at `AppConstants.storeURL` with `cloudKitDatabase: .private(<container id>)`
    ///    → .cloudKit, and the environment is recorded. (No iCloud-Drive `ubiquityIdentityToken` gate: CloudKit
    ///    handles a signed-out account itself and resumes when the user signs in; see `SyncMonitor`.)
    /// 4. Otherwise, or if (3) throws: same URL with `cloudKitDatabase: .none` → .localOnly(reason).
    /// 5. If (4) throws: in-memory → .inMemory(reason). When the store's model is incompatible and it looks newer
    ///    (`storeLooksNewer`), `isStoreFromNewerVersion` hides Recover. The on-disk store is never deleted; the user
    ///    can move it aside with `quarantineStore()` (Recover… flow).
    /// `inMemory: true` (previews/tests) goes straight to 5 with reason "Preview".
    init(cloudSyncEnabled: Bool, inMemory: Bool = false, defaults: UserDefaults = .standard) {
        let schema = WorklogSchema.schema
        let containerID = Entitlements.cloudKitContainerIdentifier
        let environment = Entitlements.cloudKitEnvironment
        cloudKitContainerIdentifier = containerID
        buildEnvironment = environment
        isPreview = inMemory

        if inMemory {
            container = PersistenceController.makeInMemoryContainer(schema: schema)
            storeMode = .inMemory(reason: "Preview")
            cloudSyncRequestedAtLaunch = false
            environmentMismatch = nil
            environmentMove = nil
            isStoreFromNewerVersion = false
            return
        }

        let opened = PersistenceController.openOnDisk(schema: schema, cloudSyncEnabled: cloudSyncEnabled,
                                                      containerID: containerID, environment: environment,
                                                      defaults: defaults)
        container = opened.container
        storeMode = opened.mode
        cloudSyncRequestedAtLaunch = opened.isInMemory ? false : cloudSyncEnabled
        environmentMismatch = opened.mismatch
        environmentMove = opened.move
        isStoreFromNewerVersion = opened.isNewer
        launchNotice = opened.notice
    }

    // MARK: - Opening

    private struct OpenResult {
        var container: ModelContainer
        var mode: StoreMode
        var mismatch: EnvironmentMismatch? = nil
        var move: EnvironmentMove? = nil
        var isNewer = false
        var notice: String? = nil
        var isInMemory: Bool {
            if case .inMemory = mode { return true }
            return false
        }
    }

    private static func openOnDisk(schema: Schema, cloudSyncEnabled: Bool, containerID: String,
                                   environment: CloudKitEnvironment, defaults: UserDefaults) -> OpenResult {
        snapshotStoreIfNeeded(environment: environment, defaults: defaults)

        let cloudKitWanted = cloudSyncEnabled && Entitlements.hasCloudKit
        var notice: String?
        var move: EnvironmentMove?
        if let marker = pendingRecovery(), let raw = marker.environmentMove {
            let target = CloudKitEnvironment(rawValue: raw)
            if target == environment && cloudKitWanted {
                let from = CloudKitEnvironment(rawValue: defaults.string(forKey: cloudKitEnvironmentKey) ?? "")
                    ?? .development
                do {
                    let folder = try moveStoreFilesAside(prefix: "Env-\(from.rawValue)")
                    defaults.removeObject(forKey: cloudKitEnvironmentKey)
                    move = EnvironmentMove(from: from, to: environment, folder: folder)
                    Log.persistence.info("Environment move: old store moved to \(folder?.lastPathComponent ?? "-", privacy: .public)")
                } catch {
                    clearPendingRecovery()
                    notice = "Couldn\u{2019}t move to iCloud \(environment.rawValue), so nothing changed. Try again in Settings \u{25B8} Data."
                    Log.persistence.error("Environment move failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                // Written for another environment, or sync is off now: keep the store as it is. The backup stays
                // in the Backups list.
                clearPendingRecovery()
                notice = "The move to iCloud \(raw) was skipped, so nothing changed."
                Log.persistence.info("Environment move skipped (build \(environment.rawValue, privacy: .public), sync wanted \(cloudKitWanted, privacy: .public))")
            }
        }

        let storeURL = AppConstants.storeURL
        let storeExisted = storeFilesExist()
        let recorded = defaults.string(forKey: cloudKitEnvironmentKey)
        let decision = environmentDecision(recorded: recorded, storeExists: storeExisted, build: environment,
                                           cloudKitWanted: cloudKitWanted)
        let localReason: String
        var mismatch: EnvironmentMismatch?

        switch decision {
        case .openCloudKit(let target):
            #if DEBUG
            if wantsCloudKitSchemaInitialization {
                initializeCloudKitSchema(containerIdentifier: containerID)
            }
            #endif
            do {
                let config = ModelConfiguration("Worklog", schema: schema, url: storeURL,
                                                cloudKitDatabase: .private(containerID))
                let container = try ModelContainer(for: schema, configurations: [config])
                defaults.set(target.rawValue, forKey: cloudKitEnvironmentKey)
                recordNewestVersionOpened(defaults: defaults)
                Log.persistence.info("Opened store with CloudKit sync (\(target.rawValue, privacy: .public))")
                return OpenResult(container: container, mode: .cloudKit, move: move, notice: notice)
            } catch {
                localReason = "CloudKit unavailable: \(error.localizedDescription)"
                Log.persistence.error("CloudKit store failed: \(error.localizedDescription, privacy: .public)")
            }
        case .localOnlyMismatch(let found):
            mismatch = found
            localReason = found.reason
            Log.persistence.warning("Store synced with \(found.store.rawValue, privacy: .public); this build uses \(found.build.rawValue, privacy: .public). Opening local-only.")
        case .localOnly:
            localReason = cloudSyncEnabled ? "iCloud isn't configured for this build" : "iCloud sync disabled"
        }

        // Local-only on-disk store (cloudKitDatabase MUST be explicit .none; .automatic would enable CloudKit).
        do {
            let config = ModelConfiguration("Worklog", schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            if recorded == nil && !storeExisted {
                // Created local-only: it never synced, so any environment may adopt it later.
                defaults.set(neverSyncedValue, forKey: cloudKitEnvironmentKey)
            }
            recordNewestVersionOpened(defaults: defaults)
            Log.persistence.info("Opened local-only store: \(localReason, privacy: .public)")
            return OpenResult(container: container, mode: .localOnly(reason: localReason), mismatch: mismatch,
                              move: move, notice: notice)
        } catch {
            Log.persistence.fault("Local store failed to open: \(error.localizedDescription, privacy: .public)")
            // In-memory. The on-disk store is left untouched for recovery.
            let newer = storeIsFromNewerVersion(at: storeURL, defaults: defaults)
            let reason = newer
                ? "This data was made by a newer version of Worklog."
                : "The data store couldn't be opened: \(error.localizedDescription)"
            return OpenResult(container: makeInMemoryContainer(schema: schema), mode: .inMemory(reason: reason),
                              move: move, isNewer: newer, notice: notice)
        }
    }

    /// C1b environment guard (pure). `recorded` is the `cloudKitEnvironmentKey` value.
    /// - sync not wanted → .localOnly
    /// - recorded == build → CloudKit; recorded "none" (never synced) or no store yet → CloudKit, adopting `build`
    /// - nothing recorded but a store exists → it synced with Development (every build before the guard did)
    /// - otherwise → .localOnlyMismatch (never switch environments silently)
    nonisolated static func environmentDecision(recorded: String?, storeExists: Bool, build: CloudKitEnvironment,
                                                cloudKitWanted: Bool) -> StoreEnvironmentDecision {
        guard cloudKitWanted else { return .localOnly }
        if recorded == neverSyncedValue { return .openCloudKit(build) }
        let storeEnvironment: CloudKitEnvironment
        if let recorded, let known = CloudKitEnvironment(rawValue: recorded) {
            storeEnvironment = known
        } else if storeExists {
            storeEnvironment = .development
        } else {
            return .openCloudKit(build)
        }
        if storeEnvironment == build { return .openCloudKit(build) }
        return .localOnlyMismatch(EnvironmentMismatch(store: storeEnvironment, build: build))
    }

    // MARK: - Recovery

    /// Moves Worklog.store, -wal, -shm and .Worklog_SUPPORT/ (whichever exist) to `Recovered/Store-<UTC stamp>/` and
    /// returns that folder. Never deletes anything. Only allowed while running on the in-memory fallback (the on-disk
    /// store is then not open); throws `.storeIsOpen` otherwise, and `.storeIsNewer` for a store a newer Worklog made.
    func quarantineStore() throws -> URL {
        guard isRecoveryMode else { throw StoreRecoveryError.storeIsOpen }
        guard !isStoreFromNewerVersion else { throw StoreRecoveryError.storeIsNewer }
        guard let folder = try Self.moveStoreFilesAside(prefix: "Store") else {
            throw StoreRecoveryError.nothingToMove
        }
        Log.persistence.info("Moved damaged store aside to \(folder.lastPathComponent, privacy: .public)")
        return folder
    }

    /// Writes `<AppSupport>/Worklog/pending-restore.json`. At the next launch `AppServices` imports `backupURL`
    /// (replace into an empty store, else merge) before seeding; nil = start fresh (CloudKit re-downloads data).
    /// `environmentMove`: "Move to iCloud <env>" — the next launch first moves the store aside (see `PendingRestore`).
    static func scheduleRecovery(backupURL: URL?, environmentMove: CloudKitEnvironment? = nil) throws {
        let marker = PendingRestore(backupPath: backupURL?.path(percentEncoded: false), createdAt: .now,
                                    environmentMove: environmentMove?.rawValue)
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

    /// Launches a new instance of the app, then terminates this one. The new instance waits until this one has
    /// exited before it opens the store (`SingleInstanceGuard.relaunchArgument`).
    static func relaunchApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = [SingleInstanceGuard.relaunchArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                Log.persistence.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Store identity (PreOpen snapshot key, H2)

    /// "1.0.1|3|Release|Production|<model hash>": a PreOpen snapshot is taken whenever this changes between launches.
    nonisolated static func snapshotKey(version: String, build: String, configuration: String,
                                        environment: CloudKitEnvironment, modelHash: String) -> String {
        [version, build, configuration, environment.rawValue, modelHash].joined(separator: "|")
    }

    /// Stable hex SHA-256 over the entity version hashes sorted by entity name (never `hashValue`, which changes per
    /// process). Same model → same string on every launch and Mac.
    nonisolated static func modelHash(entityVersionHashes: [String: Data]) -> String {
        var hasher = SHA256()
        for name in entityVersionHashes.keys.sorted() {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: entityVersionHashes[name] ?? Data())
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The managed object model SwiftData builds from `WorklogSchema.models` (nil if it can't be built).
    static let currentManagedObjectModel: NSManagedObjectModel? =
        NSManagedObjectModel.makeManagedObjectModel(for: WorklogSchema.models)

    /// `modelHash` of the running app's model ("unknown" if the model can't be built).
    static var currentModelHash: String {
        guard let model = currentManagedObjectModel else { return "unknown" }
        return modelHash(entityVersionHashes: model.entityVersionHashesByName)
    }

    /// `snapshotKey` of this launch.
    static func storeOpenKey(environment: CloudKitEnvironment) -> String {
        snapshotKey(version: AppConstants.appVersion, build: AppConstants.buildNumber,
                    configuration: AppConstants.buildConfiguration, environment: environment,
                    modelHash: currentModelHash)
    }

    // MARK: - Newer store detection (M5)

    /// True when the store's model can't be opened by this build because it is newer: it has entities this model
    /// doesn't know, or a newer app version opened it before. Only meaningful when the model is incompatible.
    nonisolated static func storeLooksNewer(storeEntityNames: Set<String>, modelEntityNames: Set<String>,
                                            newestVersionOpened: String?, currentVersion: String) -> Bool {
        if !storeEntityNames.subtracting(modelEntityNames).isEmpty { return true }
        if let newest = newestVersionOpened,
           newest.compare(currentVersion, options: .numeric) == .orderedDescending {
            return true
        }
        return false
    }

    /// Reads the store metadata: incompatible with this model and `storeLooksNewer` → true.
    private static func storeIsFromNewerVersion(at storeURL: URL, defaults: UserDefaults) -> Bool {
        guard let model = currentManagedObjectModel,
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: storeURL, options: nil) else { return false }
        guard !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { return false }
        let storeEntities = Set((metadata[NSStoreModelVersionHashesKey] as? [String: Any])?.keys.map { $0 } ?? [])
        let newer = storeLooksNewer(storeEntityNames: storeEntities,
                                    modelEntityNames: Set(model.entitiesByName.keys),
                                    newestVersionOpened: defaults.string(forKey: newestVersionOpenedKey),
                                    currentVersion: AppConstants.appVersion)
        if newer {
            Log.persistence.error("The store was made by a newer Worklog; it is left untouched")
        }
        return newer
    }

    private static func recordNewestVersionOpened(defaults: UserDefaults) {
        let current = AppConstants.appVersion
        if let newest = defaults.string(forKey: newestVersionOpenedKey),
           newest.compare(current, options: .numeric) != .orderedAscending {
            return
        }
        defaults.set(current, forKey: newestVersionOpenedKey)
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

    /// True when any of the store files exists.
    private static func storeFilesExist() -> Bool {
        AppConstants.storeFileURLs.contains { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Moves the existing store files to a new `Recovered/<prefix>-<UTC stamp>/` folder and returns it; nil when
    /// there is no store file. Never deletes anything. The store must not be open. All or nothing: when one file
    /// can't be moved, the ones already moved are put back (a store separated from its -wal would lose data).
    private static func moveStoreFilesAside(prefix: String) throws -> URL? {
        let fileManager = FileManager.default
        let existing = AppConstants.storeFileURLs.filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !existing.isEmpty else { return nil }
        let folder = uniqueFolder(named: "\(prefix)-\(AppConstants.fileTimestamp())")
        var moved: [(from: URL, to: URL)] = []
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in existing {
                let destination = folder.appending(path: url.lastPathComponent)
                try fileManager.moveItem(at: url, to: destination)
                moved.append((url, destination))
            }
        } catch {
            for item in moved.reversed() {
                do {
                    try fileManager.moveItem(at: item.to, to: item.from)
                } catch {
                    Log.persistence.fault("Couldn't put \(item.from.lastPathComponent, privacy: .public) back: \(error.localizedDescription, privacy: .public)")
                }
            }
            Log.persistence.error("Moving the store aside failed: \(error.localizedDescription, privacy: .public)")
            throw StoreRecoveryError.moveFailed(error.localizedDescription)
        }
        return folder
    }

    /// Copies the store files to `Recovered/PreOpen-<stamp>/` when `storeOpenKey` (version, build, configuration,
    /// CloudKit environment, model hash) differs from the last launch (APFS clones, so this is cheap). Keeps the
    /// newest `preOpenSnapshotsKept` snapshots. Records the key first so a launch that keeps failing doesn't replace
    /// the good snapshot with copies of the broken store.
    private static func snapshotStoreIfNeeded(environment: CloudKitEnvironment, defaults: UserDefaults) {
        let key = storeOpenKey(environment: environment)
        let previous = defaults.string(forKey: lastStoreOpenKeyKey)
        guard previous != key else { return }
        defaults.set(key, forKey: lastStoreOpenKeyKey)

        let fileManager = FileManager.default
        let existing = AppConstants.storeFileURLs.filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !existing.isEmpty else { return }     // first launch: nothing to protect
        let folder = uniqueFolder(named: "\(preOpenPrefix)\(AppConstants.fileTimestamp())")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in existing {
                try fileManager.copyItem(at: url, to: folder.appending(path: url.lastPathComponent))
            }
            Log.persistence.info("PreOpen snapshot \(folder.lastPathComponent, privacy: .public) (from \(previous ?? "unknown", privacy: .public) to \(key, privacy: .public))")
        } catch {
            Log.persistence.error("PreOpen snapshot failed: \(error.localizedDescription, privacy: .public)")
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

    /// The signed "com.apple.developer.icloud-container-environment" (a string, or a one-element array); absent or
    /// ambiguous → Development, which is what CloudKit uses then.
    static var cloudKitEnvironment: CloudKitEnvironment {
        let raw = value(for: "com.apple.developer.icloud-container-environment")
        if let text = raw as? String { return CloudKitEnvironment(entitlementValue: text) }
        if let list = raw as? [String], list.count == 1, let text = list.first {
            return CloudKitEnvironment(entitlementValue: text)
        }
        return .development
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
