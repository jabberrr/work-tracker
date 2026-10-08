import SwiftData
import XCTest
@testable import Worklog

/// Round 4b engine/model behavior: start tags on the first segment, the persisted pending review, the pause-interval
/// decode cache and creating a tag/label whose name matches an archived one.
final class EngineStateTests: XCTestCase {

    // MARK: - Start tags

    @MainActor
    func testStartTagsGoOnTheFirstSegmentAndAreEditableThere() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let tag = WorkTag(name: "bugfix")
        context.insert(tag)
        let engine = SessionEngine(context: context, settings: settings)

        let session = engine.start(label: nil, tags: [tag], focus: "Crash", at: TestSupport.time(9))
        XCTAssertTrue(session.tagList.isEmpty)
        XCTAssertEqual(engine.currentSegment?.tagList.map(\.uuid), [tag.uuid])
        XCTAssertEqual(session.allTags.map(\.uuid), [tag.uuid], "the header still shows it")

        // Editing the focus line can remove it (it is on the segment the form edits).
        engine.updateCurrentSegment(label: nil, tags: [], focus: "Crash")
        XCTAssertTrue(session.allTags.isEmpty)
    }

    // MARK: - Pending review survives a relaunch

    @MainActor
    func testPendingReviewIsPersistedAndClearedByCompletingIt() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        settings.showEndSessionSheet = true
        let engine = SessionEngine(context: context, settings: settings)
        engine.start(label: nil, at: TestSupport.time(9))
        let stopped = try XCTUnwrap(engine.stop(at: TestSupport.time(10)))
        XCTAssertTrue(engine.pendingEndSession === stopped)
        XCTAssertEqual(settings.defaults.string(forKey: "engine.pendingReviewUUID"), stopped.uuid.uuidString)

        // "Quit" with the sheet open, relaunch: the review comes back.
        let relaunched = SessionEngine(context: context, settings: settings)
        relaunched.restoreActiveSession()
        XCTAssertTrue(relaunched.pendingEndSession === stopped)
        XCTAssertNil(relaunched.activeSession)

        relaunched.completeReview()
        XCTAssertNil(relaunched.pendingEndSession)
        XCTAssertNil(settings.defaults.string(forKey: "engine.pendingReviewUUID"))
        let third = SessionEngine(context: context, settings: settings)
        third.restoreActiveSession()
        XCTAssertNil(third.pendingEndSession)
    }

    @MainActor
    func testPersistedReviewOfADeletedSessionIsDropped() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let engine = SessionEngine(context: context, settings: settings)
        engine.start(label: nil, at: TestSupport.time(9))
        let stopped = try XCTUnwrap(engine.stop(at: TestSupport.time(10)))
        context.delete(stopped)
        try context.save()

        let relaunched = SessionEngine(context: context, settings: settings)
        relaunched.restoreActiveSession()
        XCTAssertNil(relaunched.pendingEndSession)
        XCTAssertNil(settings.defaults.string(forKey: "engine.pendingReviewUUID"))
    }

    // MARK: - Pause intervals (decode cache)

    @MainActor
    func testPauseIntervalsFollowEveryChange() throws {
        let context = try TestSupport.makeContext()
        let session = WorkSession(startedAt: TestSupport.time(9))
        context.insert(session)
        XCTAssertTrue(session.pauseIntervals.isEmpty)

        let first = PauseInterval(start: TestSupport.time(10), end: TestSupport.time(10, 15))
        session.pauseIntervals = [first]
        XCTAssertEqual(session.pauseIntervals, [first])
        XCTAssertEqual(session.pauseIntervals, [first], "a cached read returns the same value")

        let open = PauseInterval(start: TestSupport.time(11))
        session.pauseIntervals = [first, open]
        XCTAssertEqual(session.pauseIntervals, [first, open], "a new encoding is never answered from the cache")
        XCTAssertTrue(session.isPaused)

        // Another session with the same bytes gets an equal (independent) value.
        let other = WorkSession(startedAt: TestSupport.time(9))
        context.insert(other)
        other.pauseIntervalsData = session.pauseIntervalsData
        XCTAssertEqual(other.pauseIntervals, [first, open])

        // Written directly (as an import or iCloud sync does).
        session.pauseIntervalsData = try JSONEncoder().encode([first])
        XCTAssertEqual(session.pauseIntervals, [first])
        XCTAssertFalse(session.isPaused)

        session.pauseIntervals = []
        XCTAssertNil(session.pauseIntervalsData)
        XCTAssertTrue(session.pauseIntervals.isEmpty)

        session.pauseIntervalsData = Data("not json".utf8)
        XCTAssertTrue(session.pauseIntervals.isEmpty, "undecodable bytes read as no pauses, as before")
    }

    // MARK: - Archived tag/label names (bug 24)

    @MainActor
    func testCreatingAnArchivedTagsNameUnarchivesItInsteadOfDuplicating() throws {
        let context = try TestSupport.makeContext()
        let work = ProfileOps.createProfile(name: "Work", colorHex: "#5B8DEF", symbolName: "briefcase.fill", in: context)
        let old = TaxonomyOps.createTag(name: "Refactor", profile: work, in: context)
        old.isArchived = true
        try context.save()

        XCTAssertTrue(TaxonomyOps.archivedTag(named: " refactor ", profile: work, in: context) === old)
        XCTAssertNil(TaxonomyOps.archivedTag(named: "refactor", profile: nil, in: context),
                     "profile nil looks at global tags only")
        XCTAssertNil(TaxonomyOps.archivedTag(named: "   ", profile: work, in: context))

        let created = TaxonomyOps.createTag(name: "refactor", profile: work, in: context)
        XCTAssertTrue(created === old)
        XCTAssertFalse(old.isArchived)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkTag>()), 1)
        XCTAssertNil(TaxonomyOps.archivedTag(named: "refactor", profile: work, in: context), "active now")

        // An archived GLOBAL tag is offered in every profile, so it is the one unarchived.
        let globalArchived = TaxonomyOps.createTag(name: "Docs", in: context)
        globalArchived.isArchived = true
        XCTAssertTrue(TaxonomyOps.createTag(name: "docs", profile: work, in: context) === globalArchived)
        XCTAssertFalse(globalArchived.isArchived)

        // An active same-name tag offered there wins: the archived one stays archived.
        let archivedLocal = WorkTag(name: "Notes")
        context.insert(archivedLocal)
        archivedLocal.profile = work
        archivedLocal.isArchived = true
        let activeGlobal = WorkTag(name: "notes")
        context.insert(activeGlobal)
        try context.save()
        XCTAssertNil(TaxonomyOps.archivedTag(named: "Notes", profile: work, in: context))
        XCTAssertTrue(TaxonomyOps.createTag(name: "NOTES", profile: work, in: context) === activeGlobal)
        XCTAssertTrue(archivedLocal.isArchived)
    }

    @MainActor
    func testCreatingAnArchivedLabelsNameUnarchivesIt() throws {
        let context = try TestSupport.makeContext()
        let label = TaxonomyOps.createLabel(name: "Meetings", colorHex: "#F2994A", symbolName: "person.2.fill",
                                            in: context)
        label.isArchived = true
        TaxonomyOps.clearDefaultLabel(label, in: context)
        try context.save()

        let again = TaxonomyOps.createLabel(name: "meetings", colorHex: "#000000", symbolName: "circle.fill",
                                            in: context)
        XCTAssertTrue(again === label)
        XCTAssertFalse(label.isArchived)
        XCTAssertEqual(label.colorHex, "#F2994A", "its own color and symbol are kept")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkLabel>()), 1)
    }

    @MainActor
    func testClearDefaultLabelClearsEveryProfilePointingAtIt() throws {
        let context = try TestSupport.makeContext()
        let p = ProfileOps.createProfile(name: "P", colorHex: "#5B8DEF", symbolName: "briefcase.fill", in: context)
        let q = ProfileOps.createProfile(name: "Q", colorHex: "#5B8DEF", symbolName: "briefcase.fill", in: context)
        let a = TaxonomyOps.createLabel(name: "A", colorHex: "#111111", symbolName: "circle.fill", in: context)
        let b = TaxonomyOps.createLabel(name: "B", colorHex: "#111111", symbolName: "circle.fill", in: context)
        p.defaultLabelUUID = a.uuid
        q.defaultLabelUUID = b.uuid
        TaxonomyOps.clearDefaultLabel(a, in: context)
        XCTAssertNil(p.defaultLabelUUID)
        XCTAssertEqual(q.defaultLabelUUID, b.uuid)
    }

    // MARK: - ProfileStore.showsProfileScope

    @MainActor
    func testShowsProfileScopeCountsArchivedProfiles() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let store = ProfileStore(context: context, settings: settings)
        let first = store.createProfile(name: "Work", colorHex: "#5B8DEF", symbolName: "briefcase.fill", select: true)
        store.reload()
        XCTAssertFalse(store.showsProfileScope)
        let second = store.createProfile(name: "Old", colorHex: "#5B8DEF", symbolName: "briefcase.fill", select: false)
        store.reload()
        XCTAssertTrue(store.showsProfileScope)
        _ = store.setArchived(second, true)
        store.reload()
        XCTAssertFalse(store.hasMultipleProfiles)
        XCTAssertTrue(store.showsProfileScope, "an archived profile still has its own data")
        _ = first
    }
}
