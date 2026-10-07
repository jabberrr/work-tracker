import Foundation
import Observation
import Security
import SwiftData

enum StoreMode: Equatable {
    case cloudKit
    case localOnly(reason: String)   // e.g. "Not signed in to iCloud", "iCloud sync disabled", "CloudKit unavailable: <err>"
    case inMemory(reason: String)    // store failed to open; data NOT persisted — UI must warn + offer restore
}

@MainActor @Observable
final class PersistenceController {
    let container: ModelContainer
    let storeMode: StoreMode
    var mainContext: ModelContext { container.mainContext }
    var isSyncingWithICloud: Bool { storeMode == .cloudKit }

    /// Order of attempts:
    /// 1. If `cloudSyncEnabled && Entitlements.hasCloudKit && FileManager.default.ubiquityIdentityToken != nil`:
    ///    on-disk store at `AppConstants.storeURL` with `cloudKitDatabase: .private(AppConstants.cloudKitContainerID)` → .cloudKit
    /// 2. Otherwise, or if (1) throws: same URL with `cloudKitDatabase: .none` → .localOnly(reason)
    /// 3. If (2) throws: in-memory → .inMemory(reason). Never deletes/moves the on-disk store.
    /// `inMemory: true` (previews/tests) goes straight to 3 with reason "Preview".
    init(cloudSyncEnabled: Bool, inMemory: Bool = false) {
        let schema = WorklogSchema.schema

        if inMemory {
            container = Self.makeInMemoryContainer(schema: schema)
            storeMode = .inMemory(reason: "Preview")
            return
        }

        let storeURL = AppConstants.storeURL
        let localReason: String

        // 1. CloudKit
        if !cloudSyncEnabled {
            localReason = "iCloud sync disabled"
        } else if !Entitlements.hasCloudKit {
            localReason = "iCloud isn't configured for this build"
        } else if FileManager.default.ubiquityIdentityToken == nil {
            localReason = "Not signed in to iCloud"
        } else {
            do {
                let config = ModelConfiguration("Worklog", schema: schema, url: storeURL,
                                                cloudKitDatabase: .private(AppConstants.cloudKitContainerID))
                container = try ModelContainer(for: schema, configurations: [config])
                storeMode = .cloudKit
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
            Log.persistence.info("Opened local-only store: \(localReason, privacy: .public)")
            return
        } catch {
            Log.persistence.fault("Local store failed to open: \(error.localizedDescription, privacy: .public)")
            // 3. In-memory. The on-disk store is left untouched for recovery.
            container = Self.makeInMemoryContainer(schema: schema)
            storeMode = .inMemory(reason: "The data store couldn't be opened: \(error.localizedDescription)")
        }
    }

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
}

enum Entitlements {
    /// Uses SecTaskCreateFromSelf + SecTaskCopyValueForEntitlement.
    static func has(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        if let flag = value as? Bool { return flag }
        if let array = value as? [Any] { return !array.isEmpty }
        if let string = value as? String { return !string.isEmpty }
        return true
    }

    static var hasCloudKit: Bool { has("com.apple.developer.icloud-services") }    // "com.apple.developer.icloud-services"
    static var hasSignInWithApple: Bool { has("com.apple.developer.applesignin") } // "com.apple.developer.applesignin"
}
