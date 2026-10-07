import SwiftData
import XCTest
@testable import Worklog

final class SessionEditorTests: XCTestCase {

    // MARK: - Split

    @MainActor
    func testSplitCreatesContiguousSegmentsAndMovesLaterNotes() throws {
        let context = try TestSupport.makeContext()
        let label = WorkLabel(name: "Deep work")
        let tag = WorkTag(name: "coding")
        context.insert(label)
        context.insert(tag)
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60], label: label)
        let original = session.sortedSegments[0]
        original.label = label
        original.tagList = [tag]

        let early = SessionEditor.addNote("early", at: start.addingTimeInterval(10 * 60), to: session, in: context)
        let late = SessionEditor.addNote("late", at: start.addingTimeInterval(45 * 60), to: session, in: context)

        let splitDate = start.addingTimeInterval(30 * 60)
        let newSegment = try SessionEditor.split(original, at: splitDate, label: nil, tags: nil, focus: " Review ",
                                                 in: context)

        let segments = session.sortedSegments
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[1] === newSegment)
        XCTAssertEqual(original.endedAt, splitDate)
        XCTAssertEqual(newSegment.startedAt, splitDate)
        XCTAssertEqual(newSegment.endedAt, session.endedAt)
        XCTAssertTrue(newSegment.label === label, "nil label → original's label")
        XCTAssertEqual(newSegment.tagList.map(\.uuid), [tag.uuid], "nil tags → copy of original's tags")
        XCTAssertEqual(newSegment.focus, "Review")
        XCTAssertTrue(early.segment === original)
        XCTAssertTrue(late.segment === newSegment)
        XCTAssertEqual(session.storedActiveDuration, 3600, accuracy: 0.001, "split doesn't change duration")
        TestSupport.assertInvariants(session)
    }

    @MainActor
    func testSplitRejectsOutOfRangeAndTooShort() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [10])
        let segment = session.sortedSegments[0]

        XCTAssertThrowsError(try SessionEditor.split(segment, at: start.addingTimeInterval(-60), label: nil, tags: nil,
                                                     focus: "", in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .dateOutOfRange)
        }
        XCTAssertThrowsError(try SessionEditor.split(segment, at: start, label: nil, tags: nil,
                                                     focus: "", in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .dateOutOfRange)
        }
        XCTAssertThrowsError(try SessionEditor.split(segment, at: start.addingTimeInterval(0.5), label: nil, tags: nil,
                                                     focus: "", in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .segmentTooShort)
        }
        XCTAssertThrowsError(try SessionEditor.split(segment, at: start.addingTimeInterval(10 * 60 - 0.5), label: nil,
                                                     tags: nil, focus: "", in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .segmentTooShort)
        }
        XCTAssertEqual(session.sortedSegments.count, 1)
    }

    @MainActor
    func testSplitWithExplicitLabelAndEmptyTags() throws {
        let context = try TestSupport.makeContext()
        let a = WorkLabel(name: "A")
        let b = WorkLabel(name: "B")
        let tag = WorkTag(name: "t")
        [a, b].forEach { context.insert($0) }
        context.insert(tag)
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [60], label: a)
        let segment = session.sortedSegments[0]
        segment.tagList = [tag]
        let new = try SessionEditor.split(segment, at: TestSupport.time(9, 20), label: b, tags: [], focus: "", in: context)
        XCTAssertTrue(new.label === b)
        XCTAssertTrue(new.tagList.isEmpty)
        XCTAssertEqual(segment.tagList.count, 1)
    }

    // MARK: - Merge / delete

    @MainActor
    func testMergeWithNextAbsorbsTimeAndNotes() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [20, 30, 10])
        let segments = session.sortedSegments
        let note = SessionEditor.addNote("in second", at: start.addingTimeInterval(25 * 60), to: session, in: context)
        XCTAssertTrue(note.segment === segments[1])

        try SessionEditor.mergeWithNext(segments[0], in: context)

        let merged = session.sortedSegments
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged[0] === segments[0])
        XCTAssertEqual(merged[0].endedAt, start.addingTimeInterval(50 * 60))
        XCTAssertTrue(note.segment === segments[0])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Segment>()), 2)
        TestSupport.assertInvariants(session)

        XCTAssertThrowsError(try SessionEditor.mergeWithNext(merged[1], in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .noAdjacentSegment)
        }
    }

    @MainActor
    func testDeleteSegmentGivesTimeToNeighbour() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [20, 30, 10])
        let segments = session.sortedSegments

        // Middle → previous absorbs it.
        try SessionEditor.deleteSegment(segments[1], in: context)
        var remaining = session.sortedSegments
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(remaining[0].endedAt, start.addingTimeInterval(50 * 60))
        TestSupport.assertInvariants(session)

        // First → next takes its start.
        try SessionEditor.deleteSegment(remaining[0], in: context)
        remaining = session.sortedSegments
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0] === segments[2])
        XCTAssertEqual(remaining[0].startedAt, start)
        TestSupport.assertInvariants(session)

        XCTAssertThrowsError(try SessionEditor.deleteSegment(remaining[0], in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .lastSegment)
        }
        XCTAssertEqual(session.storedActiveDuration, 60 * 60, accuracy: 0.001)
    }

    // MARK: - Boundaries & times

    @MainActor
    func testMoveBoundaryRespectsMinimumLengthAndReassignsNotes() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [30, 30])
        let segments = session.sortedSegments
        let note = SessionEditor.addNote("n", at: start.addingTimeInterval(25 * 60), to: session, in: context)
        XCTAssertTrue(note.segment === segments[0])

        try SessionEditor.moveBoundary(after: segments[0], to: start.addingTimeInterval(20 * 60), in: context)
        XCTAssertEqual(segments[0].endedAt, start.addingTimeInterval(20 * 60))
        XCTAssertEqual(segments[1].startedAt, start.addingTimeInterval(20 * 60))
        XCTAssertTrue(note.segment === segments[1], "note follows its timestamp")
        TestSupport.assertInvariants(session)

        XCTAssertThrowsError(try SessionEditor.moveBoundary(after: segments[0], to: start, in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .dateOutOfRange)
        }
        XCTAssertThrowsError(try SessionEditor.moveBoundary(after: segments[0], to: start.addingTimeInterval(0.5),
                                                            in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .segmentTooShort)
        }
        XCTAssertThrowsError(try SessionEditor.moveBoundary(after: segments[1], to: start.addingTimeInterval(50 * 60),
                                                            in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .noAdjacentSegment)
        }
    }

    @MainActor
    func testSetTimesClampsSegmentsAndClipsPauses() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [20, 20, 20])
        session.pauseIntervals = [
            PauseInterval(start: start.addingTimeInterval(5 * 60), end: start.addingTimeInterval(15 * 60)),
            PauseInterval(start: start.addingTimeInterval(50 * 60), end: start.addingTimeInterval(55 * 60)),
        ]

        // Shrink to [9:10, 9:45]: the first pause is clipped to 9:10–9:15, the second dropped.
        let newStart = start.addingTimeInterval(10 * 60)
        let newEnd = start.addingTimeInterval(45 * 60)
        try SessionEditor.setTimes(of: session, start: newStart, end: newEnd, in: context)

        XCTAssertEqual(session.startedAt, newStart)
        XCTAssertEqual(session.endedAt, newEnd)
        XCTAssertEqual(session.pauseIntervals, [PauseInterval(start: newStart, end: start.addingTimeInterval(15 * 60))])
        let segments = session.sortedSegments
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].startedAt, start.addingTimeInterval(20 * 60))
        XCTAssertEqual(segments[2].startedAt, start.addingTimeInterval(40 * 60))
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.interval().duration, SessionEditor.minimumSegmentLength)
        }
        XCTAssertEqual(session.storedActiveDuration, 30 * 60, accuracy: 0.001)
        TestSupport.assertInvariants(session)

        // Segments that fall entirely outside the new range are clamped to the minimum length.
        let tightEnd = newStart.addingTimeInterval(60)
        try SessionEditor.setTimes(of: session, start: newStart, end: tightEnd, in: context)
        for segment in session.sortedSegments {
            XCTAssertGreaterThanOrEqual(segment.interval().duration, SessionEditor.minimumSegmentLength)
        }
        TestSupport.assertInvariants(session)

        XCTAssertThrowsError(try SessionEditor.setTimes(of: session, start: newEnd, end: newStart, in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .dateOutOfRange)
        }
    }

    @MainActor
    func testSetTimesRejectsActiveSession() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        let session = engine.start(label: nil, at: TestSupport.time(9))
        XCTAssertThrowsError(try SessionEditor.setTimes(of: session, start: TestSupport.time(8),
                                                        end: TestSupport.time(10), in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .sessionIsActive)
        }
        XCTAssertThrowsError(try SessionEditor.deleteSession(session, in: context)) { error in
            XCTAssertEqual(error as? SessionEditError, .sessionIsActive)
        }
    }

    // MARK: - Labels, normalize, notes, learning points

    @MainActor
    func testSetPrimaryLabelUpdatesMatchingSegmentsOnly() throws {
        let context = try TestSupport.makeContext()
        let old = WorkLabel(name: "Old")
        let other = WorkLabel(name: "Other")
        let new = WorkLabel(name: "New")
        [old, other, new].forEach { context.insert($0) }
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10, 10, 10],
                                                   label: old)
        let segments = session.sortedSegments
        segments[0].label = old
        segments[1].label = other
        segments[2].label = nil

        SessionEditor.setPrimaryLabel(new, for: session, in: context)
        XCTAssertTrue(session.label === new)
        XCTAssertTrue(segments[0].label === new)
        XCTAssertTrue(segments[1].label === other)
        XCTAssertTrue(segments[2].label === new)
    }

    @MainActor
    func testNormalizeRepairsBrokenSessions() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let end = TestSupport.time(10)

        // No segments → one is created spanning the session.
        let empty = WorkSession(startedAt: start)
        context.insert(empty)
        empty.endedAt = end
        SessionEditor.normalize(empty)
        XCTAssertEqual(empty.sortedSegments.count, 1)
        TestSupport.assertInvariants(empty)

        // Gaps, wrong indices and overhangs are repaired.
        let broken = WorkSession(startedAt: start)
        context.insert(broken)
        broken.endedAt = end
        let a = Segment(startedAt: start.addingTimeInterval(-300), endedAt: start.addingTimeInterval(600), sortIndex: 7)
        let b = Segment(startedAt: start.addingTimeInterval(900), endedAt: end.addingTimeInterval(300), sortIndex: 2)
        [a, b].forEach { context.insert($0); $0.session = broken }
        SessionEditor.normalize(broken)
        XCTAssertEqual(a.startedAt, start)
        XCTAssertEqual(a.endedAt, b.startedAt)
        XCTAssertEqual(b.endedAt, end)
        XCTAssertEqual(a.sortIndex, 0)
        XCTAssertEqual(b.sortIndex, 1)
        TestSupport.assertInvariants(broken)
    }

    @MainActor
    func testNotesAndLearningPoints() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [30, 30])
        let segments = session.sortedSegments

        let note = SessionEditor.addNote(" first ", at: start.addingTimeInterval(5 * 60), to: session, in: context)
        XCTAssertEqual(note.text, "first")
        XCTAssertTrue(note.segment === segments[0])
        SessionEditor.updateNote(note, text: "moved", date: start.addingTimeInterval(40 * 60), in: context)
        XCTAssertEqual(note.text, "moved")
        XCTAssertNotNil(note.editedAt)
        XCTAssertTrue(note.segment === segments[1])
        SessionEditor.deleteNote(note, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Note>()), 0)

        let tag = WorkTag(name: "swift")
        context.insert(tag)
        let p1 = SessionEditor.addLearningPoint("one", tags: [tag], to: session, in: context)
        let p2 = SessionEditor.addLearningPoint("two", tags: [], to: session, in: context)
        XCTAssertEqual(p1.sortIndex, 0)
        XCTAssertEqual(p2.sortIndex, 1)
        XCTAssertEqual(tag.learningPoints?.count, 1)
        SessionEditor.reorderLearningPoints([p2, p1])
        XCTAssertEqual(session.sortedLearningPoints.map(\.text), ["two", "one"])
        SessionEditor.deleteLearningPoint(p2, in: context)
        XCTAssertEqual(session.sortedLearningPoints.map(\.text), ["one"])
    }

    @MainActor
    func testDeleteSessionCascades() throws {
        let context = try TestSupport.makeContext()
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10, 10])
        SessionEditor.addNote("n", at: TestSupport.time(9, 5), to: session, in: context)
        SessionEditor.addLearningPoint("p", tags: [], to: session, in: context)
        try SessionEditor.deleteSession(session, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkSession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Segment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Note>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LearningPoint>()), 0)
    }

    // MARK: - Taxonomy

    @MainActor
    func testTaxonomyMergeAndDelete() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let a = TaxonomyOps.createLabel(name: "A", colorHex: "#111111", symbolName: "circle.fill", in: context)
        let b = TaxonomyOps.createLabel(name: "B", colorHex: "#222222", symbolName: "circle.fill", in: context)
        XCTAssertEqual(b.sortIndex, a.sortIndex + 1)

        let tag1 = TaxonomyOps.createTag(name: "Swift", in: context)
        XCTAssertTrue(TaxonomyOps.createTag(name: "  swift ", in: context) === tag1, "no duplicate by name")
        let tag2 = TaxonomyOps.createTag(name: "UI", in: context)

        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10], label: a)
        session.sortedSegments[0].label = a
        session.tagList = [tag1, tag2]
        settings.defaultLabelID = a.uuid

        TaxonomyOps.mergeTag(tag1, into: tag2, in: context)
        XCTAssertEqual(session.tagList.map(\.uuid), [tag2.uuid])

        TaxonomyOps.mergeLabel(a, into: b, settings: settings, in: context)
        XCTAssertTrue(session.label === b)
        XCTAssertTrue(session.sortedSegments[0].label === b)
        XCTAssertEqual(settings.defaultLabelID, b.uuid)

        TaxonomyOps.deleteLabel(b, reassignTo: nil, settings: settings, in: context)
        XCTAssertNil(session.label)
        XCTAssertNil(settings.defaultLabelID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkLabel>()), 0)
    }

    @MainActor
    func testSeedDeduplicateMergesSameUUIDCopies() throws {
        let context = try TestSupport.makeContext()
        let id = UUID()
        let original = WorkLabel(name: "Deep work", uuid: id)
        let copy = WorkLabel(name: "Deep work", uuid: id)
        context.insert(original)
        context.insert(copy)
        original.createdAt = TestSupport.time(8)
        copy.createdAt = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(10), segmentMinutes: [10], label: copy)
        try context.save()

        SeedData.deduplicate(in: context)
        let labels = try context.fetch(FetchDescriptor<WorkLabel>())
        XCTAssertEqual(labels.count, 1)
        XCTAssertTrue(labels.first === original, "oldest createdAt survives")
        XCTAssertTrue(session.label === original)
    }

    @MainActor
    func testDedupeTieBreakIsDeterministicByInstanceID() throws {
        // Same uuid AND same createdAt (e.g. both copies came from the same archive): instanceID decides, so every
        // Mac keeps the same copy regardless of fetch order.
        let context = try TestSupport.makeContext()
        let id = UUID()
        let created = TestSupport.time(8)
        let first = WorkLabel(name: "Deep work", uuid: id)
        let second = WorkLabel(name: "Deep work", uuid: id)
        context.insert(first)
        context.insert(second)
        first.createdAt = created
        second.createdAt = created
        first.instanceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!
        second.instanceID = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
        try context.save()

        SeedData.deduplicate(in: context)
        let labels = try context.fetch(FetchDescriptor<WorkLabel>())
        XCTAssertEqual(labels.count, 1)
        XCTAssertTrue(labels.first === second, "lowest instanceID wins the tie")
    }

    @MainActor
    func testDedupeSessionsKeepsNewestThenLowestInstanceID() throws {
        let context = try TestSupport.makeContext()
        let id = UUID()
        let modified = TestSupport.time(12)
        var copies: [WorkSession] = []
        for suffix in ["0C", "0A", "0B"] {
            let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [30])
            session.uuid = id
            session.modifiedAt = modified
            session.instanceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000\(suffix)")!
            copies.append(session)
        }
        // A strictly newer copy wins regardless of instanceID.
        copies[0].modifiedAt = modified.addingTimeInterval(1)
        try context.save()

        SeedData.deduplicate(in: context)
        let sessions = try context.fetch(FetchDescriptor<WorkSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions.first === copies[0])

        // Order helpers: same total order whichever side is asked first.
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        XCTAssertEqual(SeedData.sessionPrecedes(modifiedAt: modified, instanceID: a, modified, b), true)
        XCTAssertEqual(SeedData.sessionPrecedes(modifiedAt: modified, instanceID: b, modified, a), false)
        XCTAssertNil(SeedData.sessionPrecedes(modifiedAt: modified, instanceID: a, modified, a))
        XCTAssertEqual(SeedData.taxonomyPrecedes(createdAt: modified, instanceID: b, modified.addingTimeInterval(1), a), true)
    }

    @MainActor
    func testDedupeKeepsIndistinguishableCopies() throws {
        // Identical keys (e.g. rows from before instanceID existed): deleting either could delete both across Macs.
        let context = try TestSupport.makeContext()
        let id = UUID()
        let shared = UUID()
        for _ in 0..<2 {
            let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [30])
            session.uuid = id
            session.modifiedAt = TestSupport.time(12)
            session.instanceID = shared
        }
        try context.save()
        SeedData.deduplicate(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkSession>()), 2)
    }
}
