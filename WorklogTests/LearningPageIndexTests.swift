import SwiftData
import XCTest
@testable import Worklog

/// Learning page: every learning the user wrote is listed, and each filter's count matches its rows.
final class LearningPageIndexTests: XCTestCase {

    @MainActor
    private func makeSession(_ title: String, hour: Int, in context: ModelContext) -> WorkSession {
        let session = WorkSession(startedAt: TestSupport.time(hour), title: title)
        context.insert(session)
        return session
    }

    @MainActor
    @discardableResult
    private func addPoint(_ text: String, tags: [WorkTag] = [], to session: WorkSession?,
                          in context: ModelContext) -> LearningPoint {
        let point = LearningPoint(text: text, createdAt: TestSupport.time(8))
        context.insert(point)
        point.tags = tags
        point.session = session
        return point
    }

    /// Counts and listed rows agree for every filter.
    private func assertConsistent(_ index: LearningPageIndex, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(index.entries(for: .all).count, index.allCount, "All", file: file, line: line)
        XCTAssertEqual(index.entries(for: .untagged).count, index.untaggedCount, "Untagged", file: file, line: line)
        for row in index.tagRows {
            XCTAssertEqual(index.entries(for: .tag(row.tag.uuid)).count, row.count, row.tag.name, file: file, line: line)
        }
    }

    @MainActor
    func testFreeTextOnlyLearningsAreListedUnderAllAndUntagged() throws {
        let context = try TestSupport.makeContext()
        let session = makeSession("Parser", hour: 9, in: context)
        session.learningText = "Table-driven tests keep the tokenizer honest."
        try context.save()

        let index = LearningPageIndex(points: [], reflectionSessions: [session], query: "")

        XCTAssertFalse(index.isEmpty)
        XCTAssertEqual(index.allCount, 1)
        XCTAssertEqual(index.untaggedCount, 1, "session notes have no tags")
        XCTAssertTrue(index.tagRows.isEmpty)
        assertConsistent(index)
    }

    @MainActor
    func testNotesOfASessionWithPointsAreTheirOwnEntry() throws {
        let context = try TestSupport.makeContext()
        let tag = WorkTag(name: "swift")
        context.insert(tag)
        tag.isArchived = true
        let session = makeSession("Refactor", hour: 10, in: context)
        session.learningText = "Smaller views compile faster."
        let tagged = addPoint("Prefer value types.", tags: [tag], to: session, in: context)
        let untagged = addPoint("Read the error twice.", to: session, in: context)
        try context.save()

        let index = LearningPageIndex(points: [tagged, untagged], reflectionSessions: [session], query: "")

        XCTAssertEqual(index.allCount, 3)
        XCTAssertEqual(index.untaggedCount, 2, "untagged point + session notes")
        XCTAssertEqual(index.tagRows.map(\.tag.name), ["swift"], "archived tags still count")
        assertConsistent(index)
        XCTAssertTrue(index.entries(for: .all).first.map { $0.point == nil } ?? false, "notes come before the points")
        XCTAssertTrue(LearningPageIndex.sessionsNeedingContext(in: index.entries(for: .all)).isEmpty)
        XCTAssertEqual(LearningPageIndex.sessionsNeedingContext(in: index.entries(for: .tag(tag.uuid))),
                       [session.persistentModelID])
    }

    @MainActor
    func testTakeawayOnlySessionIsListed() throws {
        let context = try TestSupport.makeContext()
        let session = makeSession("Review", hour: 11, in: context)
        session.overlaySummary = "Ask for the spec first."
        try context.save()

        let index = LearningPageIndex(points: [], reflectionSessions: [session], query: "spec")

        XCTAssertEqual(index.allCount, 1)
        XCTAssertEqual(index.untaggedCount, 1)
        XCTAssertEqual(LearningPageIndex.takeaway(of: session), "Ask for the spec first.")
        XCTAssertNil(LearningPageIndex.notesText(of: session))
    }

    @MainActor
    func testBlankNotesAreIgnored() throws {
        let context = try TestSupport.makeContext()
        let session = makeSession("Blank", hour: 12, in: context)
        session.learningText = "  \n "
        try context.save()

        let index = LearningPageIndex(points: [], reflectionSessions: [session], query: "")

        XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(index.allCount, 0)
    }

    @MainActor
    func testPointWithoutSessionShowsInHomeProfileOnly() throws {
        let context = try TestSupport.makeContext()
        let home = ProfileOps.createProfile(name: "Work", colorHex: "#5B8DEF", symbolName: "briefcase.fill", in: context)
        let other = ProfileOps.createProfile(name: "Side", colorHex: "#5B8DEF", symbolName: "star", in: context)
        let session = makeSession("Work session", hour: 9, in: context)
        session.profile = home
        let inSession = addPoint("In a session", to: session, in: context)
        let orphan = addPoint("No session", to: nil, in: context)
        try context.save()
        let points = [inSession, orphan]

        let homeScoped = LearningPageIndex.scopedPoints(points, in: ProfileScope(profileID: home.uuid)) { home.uuid }
        let otherScoped = LearningPageIndex.scopedPoints(points, in: ProfileScope(profileID: other.uuid)) { home.uuid }
        let allScoped = LearningPageIndex.scopedPoints(points, in: .allProfiles) { home.uuid }

        XCTAssertEqual(Set(homeScoped.map(\.uuid)), [inSession.uuid, orphan.uuid])
        XCTAssertTrue(otherScoped.isEmpty)
        XCTAssertEqual(allScoped.count, 2)
    }
}
