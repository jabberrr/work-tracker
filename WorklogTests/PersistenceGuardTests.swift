import SwiftData
import XCTest
@testable import Worklog

/// The CloudKit environment guard (C1b), the PreOpen snapshot key (H2), newer-store detection (M5) and the
/// pending-restore marker format. All pure: nothing here touches the real store or UserDefaults.
final class PersistenceGuardTests: XCTestCase {

    // MARK: - Environment guard

    func testSyncOffAlwaysOpensLocalOnly() {
        for recorded in [nil, "Development", "Production", "none"] as [String?] {
            for exists in [false, true] {
                XCTAssertEqual(PersistenceController.environmentDecision(recorded: recorded, storeExists: exists,
                                                                         build: .production, cloudKitWanted: false),
                               .localOnly, "recorded \(recorded ?? "nil"), store exists \(exists)")
            }
        }
    }

    func testMatchingEnvironmentOpensCloudKit() {
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: "Production", storeExists: true,
                                                                 build: .production, cloudKitWanted: true),
                       .openCloudKit(.production))
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: "Development", storeExists: true,
                                                                 build: .development, cloudKitWanted: true),
                       .openCloudKit(.development))
    }

    func testNewOrNeverSyncedStoreAdoptsTheBuildEnvironment() {
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: nil, storeExists: false,
                                                                 build: .production, cloudKitWanted: true),
                       .openCloudKit(.production), "first launch: nothing to protect")
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: PersistenceController.neverSyncedValue,
                                                                 storeExists: true, build: .production,
                                                                 cloudKitWanted: true),
                       .openCloudKit(.production), "a store created local-only never synced anywhere")
    }

    /// The user's first Release launch: an existing store, nothing recorded (it synced with Development).
    func testUnrecordedExistingStoreIsDevelopmentAndIsNeverSwitchedSilently() {
        let expected = EnvironmentMismatch(store: .development, build: .production)
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: nil, storeExists: true,
                                                                 build: .production, cloudKitWanted: true),
                       .localOnlyMismatch(expected))
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: nil, storeExists: true,
                                                                 build: .development, cloudKitWanted: true),
                       .openCloudKit(.development), "Debug keeps syncing an unrecorded store with Development")
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: "garbage", storeExists: true,
                                                                 build: .production, cloudKitWanted: true),
                       .localOnlyMismatch(expected), "an unreadable value is treated like a missing one")
    }

    func testRecordedOtherEnvironmentIsAMismatchBothWays() {
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: "Development", storeExists: true,
                                                                 build: .production, cloudKitWanted: true),
                       .localOnlyMismatch(EnvironmentMismatch(store: .development, build: .production)))
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: "Production", storeExists: true,
                                                                 build: .development, cloudKitWanted: true),
                       .localOnlyMismatch(EnvironmentMismatch(store: .production, build: .development)))
        // Even when the store files are gone, a recorded environment is respected (nothing to adopt silently).
        XCTAssertEqual(PersistenceController.environmentDecision(recorded: "Production", storeExists: false,
                                                                 build: .development, cloudKitWanted: true),
                       .localOnlyMismatch(EnvironmentMismatch(store: .production, build: .development)))
    }

    func testMismatchReasonIsShortAndHasNoColon() {
        let reason = EnvironmentMismatch(store: .development, build: .production).reason
        XCTAssertFalse(reason.contains(":"), "RootView's banner cuts the reason at the first colon")
        XCTAssertTrue(reason.contains("Development"))
        XCTAssertTrue(reason.contains("Production"))
        XCTAssertLessThan(reason.count, 80)
    }

    func testEntitlementValueParsing() {
        XCTAssertEqual(CloudKitEnvironment(entitlementValue: "Production"), .production)
        XCTAssertEqual(CloudKitEnvironment(entitlementValue: "production"), .production)
        XCTAssertEqual(CloudKitEnvironment(entitlementValue: "Development"), .development)
        XCTAssertEqual(CloudKitEnvironment(entitlementValue: ""), .development)
    }

    // MARK: - PreOpen snapshot key (H2)

    func testSnapshotKeyChangesWithEveryComponent() {
        let base = PersistenceController.snapshotKey(version: "1.0.1", build: "1", configuration: "Release",
                                                     environment: .production, modelHash: "abc")
        XCTAssertEqual(base, PersistenceController.snapshotKey(version: "1.0.1", build: "1", configuration: "Release",
                                                               environment: .production, modelHash: "abc"))
        let variants = [
            PersistenceController.snapshotKey(version: "1.0.2", build: "1", configuration: "Release",
                                              environment: .production, modelHash: "abc"),
            PersistenceController.snapshotKey(version: "1.0.1", build: "2", configuration: "Release",
                                              environment: .production, modelHash: "abc"),
            PersistenceController.snapshotKey(version: "1.0.1", build: "1", configuration: "Debug",
                                              environment: .production, modelHash: "abc"),
            PersistenceController.snapshotKey(version: "1.0.1", build: "1", configuration: "Release",
                                              environment: .development, modelHash: "abc"),
            PersistenceController.snapshotKey(version: "1.0.1", build: "1", configuration: "Release",
                                              environment: .production, modelHash: "abd"),
        ]
        for variant in variants {
            XCTAssertNotEqual(variant, base)
        }
        XCTAssertEqual(Set(variants).count, variants.count)
    }

    func testModelHashIsStableAndOrderIndependent() {
        let hashes: [String: Data] = ["A": Data([1]), "B": Data([2])]
        // SHA-256 of "A\0\u{1}\0B\0\u{2}\0": a fixed value, so the hash can never depend on the process.
        XCTAssertEqual(PersistenceController.modelHash(entityVersionHashes: hashes),
                       "8f6e98a3605e1087194975746189606cce7f20b8c2b116b6aac27e8459717069")
        var reordered: [String: Data] = [:]
        reordered["B"] = Data([2])
        reordered["A"] = Data([1])
        XCTAssertEqual(PersistenceController.modelHash(entityVersionHashes: reordered),
                       PersistenceController.modelHash(entityVersionHashes: hashes))
        XCTAssertNotEqual(PersistenceController.modelHash(entityVersionHashes: ["A": Data([1]), "B": Data([3])]),
                          PersistenceController.modelHash(entityVersionHashes: hashes))
        XCTAssertNotEqual(PersistenceController.modelHash(entityVersionHashes: ["A": Data([1])]),
                          PersistenceController.modelHash(entityVersionHashes: hashes), "a new entity changes it")
    }

    @MainActor
    func testCurrentModelHashCoversEveryEntity() throws {
        let model = try XCTUnwrap(PersistenceController.currentManagedObjectModel)
        XCTAssertEqual(Set(model.entitiesByName.keys).count, WorklogSchema.models.count)
        let hash = PersistenceController.currentModelHash
        XCTAssertNotEqual(hash, "unknown")
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, PersistenceController.currentModelHash, "same model, same hash")
    }

    // MARK: - Newer store (M5)

    func testStoreLooksNewer() {
        let model: Set<String> = ["WorkSession", "WorkLabel"]
        XCTAssertTrue(PersistenceController.storeLooksNewer(storeEntityNames: model.union(["FutureThing"]),
                                                            modelEntityNames: model, newestVersionOpened: nil,
                                                            currentVersion: "1.0.1"))
        XCTAssertTrue(PersistenceController.storeLooksNewer(storeEntityNames: model, modelEntityNames: model,
                                                            newestVersionOpened: "1.0.10", currentVersion: "1.0.9"),
                      "numeric comparison")
        XCTAssertFalse(PersistenceController.storeLooksNewer(storeEntityNames: model, modelEntityNames: model,
                                                             newestVersionOpened: "1.0.1", currentVersion: "1.0.1"))
        XCTAssertFalse(PersistenceController.storeLooksNewer(storeEntityNames: ["WorkSession"],
                                                             modelEntityNames: model, newestVersionOpened: "1.0.0",
                                                             currentVersion: "1.0.1"), "an older store isn't newer")
    }

    // MARK: - Marker

    func testPendingRestoreMarkerDecodesOldFormatAndRoundTripsTheMove() throws {
        let old = #"{"backupPath": "/tmp/x.json", "createdAt": "2026-10-07T10:00:00Z"}"#
        let decoded = try ExportArchive.makeDecoder().decode(PendingRestore.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.backupPath, "/tmp/x.json")
        XCTAssertNil(decoded.environmentMove, "markers from older builds are plain restores")

        let marker = PendingRestore(backupPath: "/tmp/y.json", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                    environmentMove: CloudKitEnvironment.production.rawValue)
        let data = try ExportArchive.makeEncoder().encode(marker)
        XCTAssertEqual(try ExportArchive.makeDecoder().decode(PendingRestore.self, from: data), marker)
    }

    // MARK: - Pending restore mode (M6)

    @MainActor
    func testPendingRestoreReplacesOnlyAnEmptyStore() throws {
        XCTAssertEqual(AppServices.pendingRestoreMode(storeIsEmpty: true), .replace)
        XCTAssertEqual(AppServices.pendingRestoreMode(storeIsEmpty: false), .merge)

        let context = try TestSupport.makeContext()
        let exporter = ExportService(container: context.container)
        XCTAssertTrue(exporter.isStoreEmpty())
        // Labels that CloudKit already brought (no sessions yet) must never be wiped by a Replace.
        context.insert(WorkLabel(name: "From iCloud"))
        try context.save()
        XCTAssertEqual(exporter.sessionCount(), 0)
        XCTAssertFalse(exporter.isStoreEmpty())
    }
}
