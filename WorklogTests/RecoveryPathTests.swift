import SwiftData
import XCTest
@testable import Worklog

/// The recovery paths on disk, run against a temporary folder (`AppConstants.rootDirectoryOverride`), never the
/// user's data: the pending-restore marker, PreOpen snapshot pruning, moving a damaged store aside (Recover…) and a
/// skipped environment move.
final class RecoveryPathTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "WorklogRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppConstants.rootDirectoryOverride = root
    }

    override func tearDownWithError() throws {
        AppConstants.rootDirectoryOverride = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "WorklogRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - Pending restore marker

    @MainActor
    func testPendingRecoveryMarkerRoundTrip() throws {
        XCTAssertTrue(AppConstants.pendingRestoreURL.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false)),
                      "the override is used")
        XCTAssertNil(PersistenceController.pendingRecovery())

        let backup = root.appending(path: "Worklog-Backup.json")
        try PersistenceController.scheduleRecovery(backupURL: backup, environmentMove: .production)
        XCTAssertTrue(exists(AppConstants.pendingRestoreURL))
        let marker = try XCTUnwrap(PersistenceController.pendingRecovery())
        XCTAssertEqual(marker.backupPath, backup.path(percentEncoded: false))
        XCTAssertEqual(marker.environmentMove, "Production")

        try PersistenceController.scheduleRecovery(backupURL: nil)
        let fresh = try XCTUnwrap(PersistenceController.pendingRecovery())
        XCTAssertNil(fresh.backupPath, "nil = start with a fresh store")
        XCTAssertNil(fresh.environmentMove)

        PersistenceController.clearPendingRecovery()
        XCTAssertFalse(exists(AppConstants.pendingRestoreURL))
        XCTAssertNil(PersistenceController.pendingRecovery())
        PersistenceController.clearPendingRecovery()     // no marker: no-op

        try Data("{ broken".utf8).write(to: AppConstants.pendingRestoreURL)
        XCTAssertNil(PersistenceController.pendingRecovery(), "an unreadable marker reads as none")
    }

    // MARK: - Damaged store: PreOpen snapshot, in-memory fallback, Recover… (quarantine)

    @MainActor
    func testDamagedStoreOpensInMemoryAndCanBeMovedAside() throws {
        let fileManager = FileManager.default
        // A store file that isn't a database, plus its -wal.
        let garbage = Data(repeating: 0x41, count: 4096)
        try garbage.write(to: AppConstants.storeURL)
        try garbage.write(to: AppConstants.storeFileURLs[1])
        // Three older PreOpen snapshots: with the new one, only the newest two may stay.
        let recovered = AppConstants.recoveredURL
        for day in 1...3 {
            try fileManager.createDirectory(at: recovered.appending(path: "PreOpen-2020-01-0\(day)T00-00-00Z"),
                                            withIntermediateDirectories: true)
        }

        let controller = PersistenceController(cloudSyncEnabled: false, defaults: makeDefaults())
        XCTAssertTrue(controller.isRecoveryMode, "a store that can't be opened falls back to memory")
        XCTAssertFalse(controller.isStoreFromNewerVersion)
        XCTAssertTrue(exists(AppConstants.storeURL), "the damaged store is never deleted")

        let snapshots = try fileManager.contentsOfDirectory(atPath: recovered.path(percentEncoded: false))
            .filter { $0.hasPrefix("PreOpen-") }.sorted()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.first, "PreOpen-2020-01-03T00-00-00Z")
        let newest = try XCTUnwrap(snapshots.last)
        XCTAssertTrue(exists(recovered.appending(path: newest).appending(path: "Worklog.store")),
                      "this launch's snapshot holds a copy of the store")

        let folder = try controller.quarantineStore()
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("Store-"))
        XCTAssertFalse(exists(AppConstants.storeURL))
        XCTAssertFalse(exists(AppConstants.storeFileURLs[1]))
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "Worklog.store")), garbage)
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "Worklog.store-wal")), garbage)

        XCTAssertThrowsError(try controller.quarantineStore(), "nothing left to move") { error in
            guard case StoreRecoveryError.nothingToMove = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    @MainActor
    func testAnOpenStoreIsNeverMovedAside() throws {
        let controller = PersistenceController(cloudSyncEnabled: false, defaults: makeDefaults())
        guard case .localOnly = controller.storeMode else {
            return XCTFail("a new store opens local-only with sync off")
        }
        XCTAssertThrowsError(try controller.quarantineStore()) { error in
            guard case StoreRecoveryError.storeIsOpen = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertTrue(exists(AppConstants.storeURL))
    }

    // MARK: - Environment move that doesn't apply

    @MainActor
    func testEnvironmentMoveIsSkippedWhenSyncIsOffAndTheStoreIsKept() throws {
        let other: CloudKitEnvironment = Entitlements.cloudKitEnvironment == .production ? .development : .production
        try PersistenceController.scheduleRecovery(backupURL: root.appending(path: "b.json"), environmentMove: other)

        let controller = PersistenceController(cloudSyncEnabled: false, defaults: makeDefaults())
        XCTAssertNil(PersistenceController.pendingRecovery(), "the marker is removed (one attempt only)")
        XCTAssertNil(controller.environmentMove)
        XCTAssertEqual(controller.launchNotice, "The move to iCloud \(other.rawValue) was skipped, so nothing changed.")
        XCTAssertFalse(controller.launchNoticeOffersRestore)
        guard case .localOnly = controller.storeMode else {
            return XCTFail("sync off opens local-only")
        }
        let recoveredItems = (try? FileManager.default.contentsOfDirectory(
            atPath: AppConstants.recoveredURL.path(percentEncoded: false))) ?? []
        XCTAssertFalse(recoveredItems.contains { $0.hasPrefix("Env-") }, "nothing was moved aside")
    }

    @MainActor
    func testLaunchNoticeRestoreOfferResetsWithANewNotice() {
        let controller = PersistenceController(cloudSyncEnabled: false, inMemory: true)
        controller.launchNotice = "Your data shrank."
        controller.launchNoticeOffersRestore = true
        controller.launchNotice = "Restored “x”."
        XCTAssertFalse(controller.launchNoticeOffersRestore)
    }
}
