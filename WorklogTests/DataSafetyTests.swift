import AppKit
import SwiftData
import XCTest
@testable import Worklog

/// Round-4 data-safety fixes: session dedupe keeps children (H4), imported running sessions (M2), Replace keeps the
/// store's images (M1), merge updates fresh defaults and newer profiles (M7), reconcile ownership (L6) and the
/// engine's liveness guards (M3).
final class DataSafetyTests: XCTestCase {

    private static func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - H4: session dedupe re-parents children

    @MainActor
    func testSessionDedupeMovesChildrenTheSurvivorLacks() throws {
        let context = try TestSupport.makeContext()
        let id = UUID()
        let start = TestSupport.time(9)
        let survivor = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [30, 30])
        survivor.uuid = id
        survivor.modifiedAt = start.addingTimeInterval(7200)          // newer → survives
        let loser = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [30, 30])
        loser.uuid = id
        loser.modifiedAt = start.addingTimeInterval(3600)

        let sharedNoteID = UUID()
        let survivorNote = Note(text: "shared", createdAt: start.addingTimeInterval(60), uuid: sharedNoteID)
        context.insert(survivorNote)
        survivorNote.session = survivor
        let loserCopyOfNote = Note(text: "shared", createdAt: start.addingTimeInterval(60), uuid: sharedNoteID)
        context.insert(loserCopyOfNote)
        loserCopyOfNote.session = loser
        let onlyOnLoser = Note(text: "added on the other Mac", createdAt: start.addingTimeInterval(45 * 60))
        context.insert(onlyOnLoser)
        onlyOnLoser.session = loser
        onlyOnLoser.segment = loser.sortedSegments[1]

        // Same image on both, but the survivor's copy has no bytes yet; plus an image only the loser has.
        let image = Self.pngData(width: 4, height: 4)
        let sharedImageID = UUID()
        let emptyCopy = Attachment(filename: "a.png", data: nil, uti: "public.png", uuid: sharedImageID)
        context.insert(emptyCopy)
        emptyCopy.session = survivor
        let fullCopy = Attachment(filename: "a.png", data: image, thumbnailData: image, uti: "public.png",
                                  pixelWidth: 4, pixelHeight: 4, uuid: sharedImageID)
        context.insert(fullCopy)
        fullCopy.session = loser
        let loserImage = Attachment(filename: "b.png", data: image, uti: "public.png", pixelWidth: 4, pixelHeight: 4)
        context.insert(loserImage)
        loserImage.session = loser

        let point = LearningPoint(text: "only here", createdAt: start)
        context.insert(point)
        point.session = loser
        try context.save()
        let survivorModified = survivor.modifiedAt

        SeedData.deduplicate(in: context)

        let sessions = try context.fetch(FetchDescriptor<WorkSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions.first === survivor)
        XCTAssertEqual(Set((survivor.notes ?? []).map(\.uuid)), [sharedNoteID, onlyOnLoser.uuid])
        XCTAssertTrue(onlyOnLoser.segment === survivor.sortedSegments[1], "re-pointed to the survivor's segment")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Note>()), 2, "the loser's copy of the shared note goes")
        XCTAssertEqual(Set((survivor.attachments ?? []).map(\.uuid)), [sharedImageID, loserImage.uuid])
        XCTAssertEqual(emptyCopy.data, image, "missing bytes filled from the duplicate")
        XCTAssertEqual(emptyCopy.pixelWidth, 4)
        XCTAssertEqual((survivor.learningPoints ?? []).map(\.uuid), [point.uuid])
        XCTAssertEqual(survivor.modifiedAt, survivorModified, "dedupe never touches modifiedAt")
    }

    // MARK: - M2: running sessions in an archive

    func testArchivedRunningSessionRules() {
        XCTAssertTrue(ExportService.keepsArchivedSessionRunning(ownerDeviceID: "mac-a", localDeviceID: "mac-a"))
        XCTAssertFalse(ExportService.keepsArchivedSessionRunning(ownerDeviceID: "mac-b", localDeviceID: "mac-a"))
        XCTAssertFalse(ExportService.keepsArchivedSessionRunning(ownerDeviceID: nil, localDeviceID: "mac-a"))
        XCTAssertFalse(ExportService.keepsArchivedSessionRunning(ownerDeviceID: "", localDeviceID: ""))

        let last = Date(timeIntervalSince1970: 1_000)
        let exported = Date(timeIntervalSince1970: 5_000)
        let now = Date(timeIntervalSince1970: 9_000)
        XCTAssertEqual(ExportService.archivedRunningSessionEnd(lastActivity: last, exportedAt: exported, now: now),
                       exported)
        XCTAssertEqual(ExportService.archivedRunningSessionEnd(lastActivity: last, exportedAt: now.addingTimeInterval(60),
                                                               now: now), now, "a future export date is capped at now")
        XCTAssertEqual(ExportService.archivedRunningSessionEnd(lastActivity: now, exportedAt: exported, now: now), now,
                       "never before the last activity")
    }

    @MainActor
    func testImportEndsAnotherMacsRunningSessionButKeepsOurOwn() throws {
        let source = try TestSupport.makeContext()
        let engine = SessionEngine(context: source, settings: TestSupport.makeSettings())
        let started = Date.now.addingTimeInterval(-7200)
        let running = engine.start(label: nil, at: started)
        let archive = try ExportService(container: source.container).makeArchive(includeAttachments: false)
        XCTAssertEqual(archive.sessions.first?.ownerDeviceID, engine.deviceID, "the owner travels with the archive")

        // Another Mac: the session is ended, not adopted as running.
        let other = try TestSupport.makeContext()
        let otherExporter = ExportService(container: other.container)
        otherExporter.localDeviceID = "another-mac"
        _ = try otherExporter.importArchive(archive, mode: .replace)
        let imported = try XCTUnwrap(try other.fetch(FetchDescriptor<WorkSession>()).first)
        let end = try XCTUnwrap(imported.endedAt)
        XCTAssertEqual(end.timeIntervalSince1970, archive.exportedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(imported.ownerDeviceID, engine.deviceID)
        TestSupport.assertInvariants(imported)

        // This Mac (e.g. a restore after moving the store): it keeps running.
        let mine = try TestSupport.makeContext()
        let myExporter = ExportService(container: mine.container)
        myExporter.localDeviceID = engine.deviceID
        _ = try myExporter.importArchive(archive, mode: .replace)
        let restored = try XCTUnwrap(try mine.fetch(FetchDescriptor<WorkSession>()).first)
        XCTAssertNil(restored.endedAt)
        XCTAssertEqual(restored.uuid, running.uuid)
    }

    // MARK: - M1: Replace keeps the store's own image bytes

    @MainActor
    func testReplaceWithoutImagesKeepsTheStoresBytes() throws {
        let context = try TestSupport.makeContext()
        let image = Self.pngData(width: 6, height: 3)
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10])
        let attachment = Attachment(filename: "x.png", data: image, thumbnailData: image, uti: "public.png",
                                    pixelWidth: 6, pixelHeight: 3)
        context.insert(attachment)
        attachment.session = session
        let gone = TestSupport.makeEndedSession(in: context, start: TestSupport.time(11), segmentMinutes: [10])
        let goneImage = Attachment(filename: "y.png", data: image, uti: "public.png")
        context.insert(goneImage)
        goneImage.session = gone
        try context.save()
        let exporter = ExportService(container: context.container)
        var archive = try exporter.makeArchive(includeAttachments: false)
        archive.sessions.removeAll { $0.id == gone.uuid }
        XCTAssertEqual(archive.attachmentsWithoutImageCount, 1)

        let summary = try exporter.importArchive(archive, mode: .replace)
        let attachments = try context.fetch(FetchDescriptor<Attachment>())
        XCTAssertEqual(attachments.count, 1, "only images the archive lists come back")
        XCTAssertEqual(attachments.first?.data, image)
        XCTAssertEqual(attachments.first?.pixelWidth, 6)
        XCTAssertEqual(summary.imagesMissing, 0)
    }

    @MainActor
    func testMissingBackupImagesAreCounted() throws {
        let context = try TestSupport.makeContext()
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10])
        let attachment = Attachment(filename: "x.png", data: Self.pngData(width: 2, height: 2), uti: "public.png")
        context.insert(attachment)
        attachment.session = session
        try context.save()
        var archive = try ExportService(container: context.container).makeArchive(includeAttachments: false)
        archive.includesAttachments = true
        archive.attachmentStore = ExportArchive.backupAttachmentFolder
        let folder = FileManager.default.temporaryDirectory.appending(path: "WorklogMissing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Worklog-Backup-2026-06-10T09-00-00Z-manual-n1.json")
        try ExportArchive.makeEncoder(pretty: false).encode(archive).write(to: url)

        let decoded = try ExportService(container: context.container).decodeArchive(from: url)
        XCTAssertEqual(decoded.missingImageCount, 1, "no Attachments folder next to the backup")
        let reencoded = try XCTUnwrap(String(data: ExportArchive.makeEncoder().encode(decoded), encoding: .utf8))
        XCTAssertFalse(reencoded.contains("missingImageCount"), "the count is never written to files")

        let empty = try TestSupport.makeContext()
        let summary = try ExportService(container: empty.container).importArchive(decoded, mode: .replace)
        XCTAssertEqual(summary.imagesMissing, 1)
        XCTAssertTrue(summary.description.contains("1 image wasn\u{2019}t in the file."))
    }

    // MARK: - M7: merge updates fresh defaults and newer profiles

    @MainActor
    func testMergeUpdatesFreshDefaultsAndNewerProfiles() throws {
        let source = try TestSupport.makeContext()
        let labelID = UUID()
        let label = WorkLabel(name: "Focus time", colorHex: "#FF0000", uuid: labelID)
        source.insert(label)
        label.createdAt = TestSupport.time(8)
        let tagID = UUID()
        let tag = WorkTag(name: "swift", uuid: tagID)
        source.insert(tag)
        tag.createdAt = TestSupport.time(8)
        let profile = WorkProfile(name: "Office", colorHex: "#00FF00", uuid: ProfileOps.defaultProfileUUID)
        source.insert(profile)
        profile.modifiedAt = TestSupport.time(8)
        try source.save()
        var archive = try ExportService(container: source.container).makeArchive(includeAttachments: false)
        archive.exportedAt = TestSupport.time(9)

        // Destination: the defaults were re-created after the export (same fixed uuids), plus a label the user
        // made before the export and renamed since.
        let destination = try TestSupport.makeContext()
        let fresh = WorkLabel(name: "Deep work", uuid: labelID)
        destination.insert(fresh)
        fresh.createdAt = TestSupport.time(10)
        let freshTag = WorkTag(name: "coding", uuid: tagID)
        destination.insert(freshTag)
        freshTag.createdAt = TestSupport.time(10)
        let work = try XCTUnwrap(ProfileOps.ensureDefaultProfile(legacyDefaultLabelID: nil, in: destination))
        try destination.save()

        _ = try ExportService(container: destination.container).importArchive(archive, mode: .merge)
        XCTAssertEqual(fresh.name, "Focus time", "a default re-created after the export takes the archived values")
        XCTAssertEqual(fresh.colorHex, "#FF0000")
        XCTAssertEqual(freshTag.name, "swift")
        XCTAssertEqual(work.name, "Office", "the archived profile is newer than the fresh default (epoch)")
        XCTAssertEqual(work.colorHex, "#00FF00")
        XCTAssertEqual(ProfileOps.allProfiles(in: destination).count, 1)

        // A profile edited here after the archive was made is kept.
        work.name = "Edited here"
        work.modifiedAt = TestSupport.time(12)
        try destination.save()
        _ = try ExportService(container: destination.container).importArchive(archive, mode: .merge)
        XCTAssertEqual(work.name, "Edited here")
    }

    func testFreshLocalCopyRuleHasAOneSecondMargin() throws {
        let archive = ExportArchive(formatVersion: 2, exportedAt: Date(timeIntervalSince1970: 1_000), appVersion: "1",
                                    includesAttachments: false, labels: [], tags: [], sessions: [])
        XCTAssertFalse(ExportService.isFreshLocalCopy(createdAt: Date(timeIntervalSince1970: 1_000.5), archive: archive),
                       "archive dates are whole seconds")
        XCTAssertFalse(ExportService.isFreshLocalCopy(createdAt: Date(timeIntervalSince1970: 900), archive: archive))
        XCTAssertTrue(ExportService.isFreshLocalCopy(createdAt: Date(timeIntervalSince1970: 1_002), archive: archive))
    }

    // MARK: - L6: reconcile ownership

    func testShouldEndExtraSession() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(SessionEngine.shouldEndExtraSession(ownerDeviceID: "me", deviceID: "me",
                                                          startedAt: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(SessionEngine.shouldEndExtraSession(ownerDeviceID: "", deviceID: "me",
                                                          startedAt: now.addingTimeInterval(-5), now: now))
        XCTAssertFalse(SessionEngine.shouldEndExtraSession(ownerDeviceID: "other", deviceID: "me",
                                                           startedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(SessionEngine.shouldEndExtraSession(ownerDeviceID: "other", deviceID: "me",
                                                          startedAt: now.addingTimeInterval(-61), now: now))
    }

    @MainActor
    func testReconcileLeavesAnotherMacsJustStartedSession() throws {
        let context = try TestSupport.makeContext()
        let now = Date.now
        let theirs = WorkSession(startedAt: now.addingTimeInterval(-20))
        context.insert(theirs)
        theirs.ownerDeviceID = "another-mac"
        let theirSegment = Segment(startedAt: theirs.startedAt)
        context.insert(theirSegment)
        theirSegment.session = theirs
        let newest = WorkSession(startedAt: now.addingTimeInterval(-10))
        context.insert(newest)
        let newestSegment = Segment(startedAt: newest.startedAt)
        context.insert(newestSegment)
        newestSegment.session = newest
        try context.save()

        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        engine.reconcile(now: now)
        XCTAssertTrue(engine.activeSession === newest)
        XCTAssertNil(theirs.endedAt, "left to the Mac that owns it")

        engine.reconcile(now: now.addingTimeInterval(120))
        XCTAssertNotNil(theirs.endedAt, "ended once it is older than a minute")
    }

    // MARK: - M3: liveness

    @MainActor
    func testEngineForgetsAnActiveSessionDeletedUnderneath() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        let session = engine.start(label: nil, at: Date.now.addingTimeInterval(-600))
        XCTAssertTrue(engine.isActive)

        context.delete(session)          // e.g. deleted on another Mac and imported by CloudKit
        try context.save()
        XCTAssertEqual(engine.elapsed(), 0, "reads are guarded before the engine catches up")
        XCTAssertFalse(engine.isPaused)
        XCTAssertNil(engine.currentSegment)

        engine.verifyTrackedSessions()
        XCTAssertFalse(engine.isActive)
        XCTAssertNil(engine.stop(), "nothing to stop")
    }
}
