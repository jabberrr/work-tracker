import SwiftData
import XCTest
@testable import Worklog

/// Shared helpers for the Worklog unit tests.
@MainActor
enum TestSupport {
    /// Containers are kept alive for the whole test run so their contexts never outlive them.
    private static var retained: [ModelContainer] = []

    static func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(UUID().uuidString, schema: WorklogSchema.schema,
                                        isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: WorklogSchema.schema, configurations: [config])
        retained.append(container)
        return container.mainContext
    }

    static func makeSettings() -> AppSettings {
        let suite = "WorklogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    /// A local-calendar date (June dates have no DST transitions).
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        return Calendar.current.date(from: components)!
    }

    /// A time on the reference day 2026-06-10.
    static func time(_ hour: Int, _ minute: Int = 0) -> Date {
        date(2026, 6, 10, hour, minute)
    }

    /// Builds an ended session with contiguous segments of the given lengths (minutes) starting at `start`.
    @discardableResult
    static func makeEndedSession(in context: ModelContext, start: Date, segmentMinutes: [Int],
                                 label: WorkLabel? = nil) -> WorkSession {
        let session = WorkSession(startedAt: start, title: "Test")
        context.insert(session)
        session.label = label
        var cursor = start
        for (index, minutes) in segmentMinutes.enumerated() {
            let segment = Segment(startedAt: cursor, sortIndex: index, focus: "Segment \(index)")
            context.insert(segment)
            segment.session = session
            cursor = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            segment.endedAt = cursor
        }
        session.endedAt = cursor
        session.recomputeStoredDuration()
        return session
    }

    /// Asserts the §2 invariants: ≥1 segment, contiguous, sortIndex 0..<n, ends match the session.
    static func assertInvariants(_ session: WorkSession, file: StaticString = #filePath, line: UInt = #line) {
        let segments = session.sortedSegments
        XCTAssertFalse(segments.isEmpty, "session has no segments", file: file, line: line)
        guard let first = segments.first, let last = segments.last else { return }
        XCTAssertEqual(first.startedAt, session.startedAt, "first segment start", file: file, line: line)
        XCTAssertEqual(last.endedAt, session.endedAt, "last segment end", file: file, line: line)
        for (index, segment) in segments.enumerated() {
            XCTAssertEqual(segment.sortIndex, index, "sortIndex", file: file, line: line)
            if index + 1 < segments.count {
                XCTAssertEqual(segment.endedAt, segments[index + 1].startedAt, "contiguity at \(index)", file: file, line: line)
            }
        }
    }
}

final class SessionMathTests: XCTestCase {

    // MARK: - PauseInterval / WorkSession math

    func testPauseOverlapIsClippedToWindow() {
        let window = DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let pause = PauseInterval(start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(pause.overlap(with: window, now: .distantFuture), 50, accuracy: 0.001)

        let outside = PauseInterval(start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(outside.overlap(with: window, now: .distantFuture), 0)

        let open = PauseInterval(start: Date(timeIntervalSince1970: 180))
        XCTAssertTrue(open.isOpen)
        XCTAssertEqual(open.overlap(with: window, now: Date(timeIntervalSince1970: 190)), 10, accuracy: 0.001)
    }

    @MainActor
    func testActiveDurationExcludesPauses() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        session.pauseIntervals = [
            PauseInterval(start: start.addingTimeInterval(10 * 60), end: start.addingTimeInterval(20 * 60)),
            PauseInterval(start: start.addingTimeInterval(30 * 60), end: start.addingTimeInterval(35 * 60)),
        ]
        XCTAssertEqual(session.wallDuration(), 3600, accuracy: 0.001)
        XCTAssertEqual(session.pausedDuration(), 15 * 60, accuracy: 0.001)
        XCTAssertEqual(session.activeDuration(), 45 * 60, accuracy: 0.001)
        session.recomputeStoredDuration()
        XCTAssertEqual(session.storedActiveDuration, 45 * 60, accuracy: 0.001)
    }

    @MainActor
    func testPausesAcrossMidnightAreSplitBetweenDays() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.date(2026, 6, 10, 22)          // 22:00
        let end = TestSupport.date(2026, 6, 11, 2)             // 02:00 next day
        let session = WorkSession(startedAt: start)
        context.insert(session)
        let segment = Segment(startedAt: start, endedAt: end)
        context.insert(segment)
        segment.session = session
        session.endedAt = end
        session.pauseIntervals = [
            PauseInterval(start: TestSupport.date(2026, 6, 10, 23, 30), end: TestSupport.date(2026, 6, 11, 0, 30)),
        ]

        let day1 = start.dayInterval
        let day2 = end.dayInterval
        XCTAssertEqual(session.activeDuration(in: day1), 1.5 * 3600, accuracy: 0.001)
        XCTAssertEqual(session.activeDuration(in: day2), 1.5 * 3600, accuracy: 0.001)
        XCTAssertEqual(session.activeDuration(), 3 * 3600, accuracy: 0.001)
        XCTAssertEqual(segment.activeDuration(in: day1) + segment.activeDuration(in: day2),
                       session.activeDuration(), accuracy: 0.001)
        XCTAssertEqual(session.activeDuration(in: TestSupport.date(2026, 6, 12, 12).dayInterval), 0)
    }

    @MainActor
    func testOpenPauseCountsUntilNow() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = WorkSession(startedAt: start)
        context.insert(session)
        session.pauseIntervals = [PauseInterval(start: start.addingTimeInterval(600))]
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(session.isPaused)
        let now = start.addingTimeInterval(1800)
        XCTAssertEqual(session.activeDuration(at: now), 600, accuracy: 0.001)
        XCTAssertEqual(session.pausedDuration(at: now), 1200, accuracy: 0.001)
    }

    @MainActor
    func testSegmentDurationsSumToSessionActiveDuration() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [20, 30, 10])
        session.pauseIntervals = [
            PauseInterval(start: start.addingTimeInterval(15 * 60), end: start.addingTimeInterval(25 * 60)),
        ]
        let segments = session.sortedSegments
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].activeDuration(), 15 * 60, accuracy: 0.001)
        XCTAssertEqual(segments[1].activeDuration(), 25 * 60, accuracy: 0.001)
        XCTAssertEqual(segments[2].activeDuration(), 10 * 60, accuracy: 0.001)
        let sum = segments.reduce(0) { $0 + $1.activeDuration() }
        XCTAssertEqual(sum, session.activeDuration(), accuracy: 0.001)
        XCTAssertTrue(session.segment(containing: start.addingTimeInterval(25 * 60)) === segments[1])
        XCTAssertTrue(session.segment(containing: start.addingTimeInterval(-60)) === segments[0])
    }

    @MainActor
    func testLastActivityDateAndTakeaway() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [30, 30])
        let note = Note(text: "late note", createdAt: start.addingTimeInterval(50 * 60))
        context.insert(note)
        note.session = session
        XCTAssertEqual(session.lastActivityDate, start.addingTimeInterval(50 * 60))

        XCTAssertNil(session.takeawayText)
        session.learningText = "  learned  "
        XCTAssertEqual(session.takeawayText, "learned")
        session.overlaySummary = "summary"
        XCTAssertEqual(session.takeawayText, "summary")
    }

    // MARK: - SessionEngine

    @MainActor
    func testEngineStartPauseResumeSplitStop() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let engine = SessionEngine(context: context, settings: settings)
        let label = WorkLabel(name: "Deep work")
        let other = WorkLabel(name: "Meetings")
        context.insert(label)
        context.insert(other)

        let t0 = TestSupport.time(9)
        let session = engine.start(label: label, focus: "  Plan  ", at: t0)
        XCTAssertTrue(engine.isActive)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(session.sortedSegments.count, 1)
        XCTAssertEqual(session.sortedSegments.first?.focus, "Plan")
        XCTAssertTrue(engine.start(label: other, at: t0.addingTimeInterval(5)) === session, "start is idempotent")

        engine.pause(at: t0.addingTimeInterval(10 * 60))
        XCTAssertTrue(engine.isPaused)
        engine.pause(at: t0.addingTimeInterval(11 * 60))   // no-op while paused
        XCTAssertEqual(session.pauseIntervals.count, 1)
        XCTAssertEqual(engine.elapsed(at: t0.addingTimeInterval(14 * 60)), 10 * 60, accuracy: 0.001)

        engine.resume(at: t0.addingTimeInterval(15 * 60))
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.elapsed(at: t0.addingTimeInterval(20 * 60)), 15 * 60, accuracy: 0.001)

        let second = engine.split(label: other, focus: "Sync", at: t0.addingTimeInterval(30 * 60))
        XCTAssertNotNil(second)
        XCTAssertEqual(session.sortedSegments.count, 2)
        XCTAssertTrue(engine.currentSegment === second)
        XCTAssertTrue(engine.currentLabel === other)
        XCTAssertEqual(engine.currentSegmentElapsed(at: t0.addingTimeInterval(40 * 60)), 10 * 60, accuracy: 0.001)

        let note = engine.addNote("  hello  ", at: t0.addingTimeInterval(35 * 60))
        XCTAssertEqual(note?.text, "hello")
        XCTAssertTrue(note?.segment === second)
        XCTAssertNil(engine.addNote("   "), "blank notes are ignored")

        let stopped = engine.stop(at: t0.addingTimeInterval(60 * 60))
        XCTAssertTrue(stopped === session)
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.pendingEndSession === session, "showEndSessionSheet defaults to true")
        XCTAssertEqual(session.endedAt, t0.addingTimeInterval(60 * 60))
        XCTAssertEqual(session.storedActiveDuration, 55 * 60, accuracy: 0.001)
        let segments = session.sortedSegments
        XCTAssertEqual(segments[0].activeDuration(), 25 * 60, accuracy: 0.001)
        XCTAssertEqual(segments[1].activeDuration(), 30 * 60, accuracy: 0.001)
        TestSupport.assertInvariants(session)

        engine.completeReview()
        XCTAssertNil(engine.pendingEndSession)
        engine.completeReview()   // idempotent (sheet dismissal binding calls it again)
    }

    @MainActor
    func testStopWhilePausedClosesPauseAndDropsLaterPauses() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        let t0 = TestSupport.time(9)
        let session = engine.start(label: nil, at: t0)
        engine.pause(at: t0.addingTimeInterval(20 * 60))
        engine.stop(at: t0.addingTimeInterval(30 * 60))

        XCTAssertFalse(session.isPaused)
        XCTAssertEqual(session.pauseIntervals, [PauseInterval(start: t0.addingTimeInterval(20 * 60),
                                                              end: t0.addingTimeInterval(30 * 60))])
        XCTAssertEqual(session.activeDuration(), 20 * 60, accuracy: 0.001)
        TestSupport.assertInvariants(session)
    }

    @MainActor
    func testStopIsClampedToCurrentSegmentStart() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        let t0 = TestSupport.time(9)
        let session = engine.start(label: nil, at: t0)
        engine.split(label: nil, focus: "B", at: t0.addingTimeInterval(30 * 60))
        engine.stop(at: t0.addingTimeInterval(10 * 60))   // earlier than the current segment start
        XCTAssertEqual(session.endedAt, t0.addingTimeInterval(30 * 60))
        TestSupport.assertInvariants(session)
    }

    @MainActor
    func testSplitAtSegmentStartUpdatesInPlace() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        let label = WorkLabel(name: "L")
        context.insert(label)
        let t0 = TestSupport.time(9)
        let session = engine.start(label: nil, at: t0)
        let segment = engine.split(label: label, focus: "Focus", at: t0)
        XCTAssertEqual(session.sortedSegments.count, 1)
        XCTAssertTrue(segment === session.sortedSegments.first)
        XCTAssertTrue(session.label === label, "single segment: session label follows")
    }

    @MainActor
    func testWithoutEndSheetStopRefreshesTakeaway() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        settings.showEndSessionSheet = false
        let engine = SessionEngine(context: context, settings: settings)
        let t0 = TestSupport.time(9)
        let session = engine.start(label: nil, at: t0)
        session.overlaySummary = "Remember the thing"
        session.showInOverlay = true
        engine.stop(at: t0.addingTimeInterval(600))
        XCTAssertNil(engine.pendingEndSession)
        XCTAssertEqual(engine.lastTakeaway?.text, "Remember the thing")
        XCTAssertEqual(engine.lastTakeaway?.sessionUUID, session.uuid)
    }

    @MainActor
    func testRestoreAdoptsNewestActiveAndEndsOthers() throws {
        let context = try TestSupport.makeContext()
        let t0 = TestSupport.time(9)
        let older = WorkSession(startedAt: t0)
        context.insert(older)
        let olderSegment = Segment(startedAt: t0)
        context.insert(olderSegment)
        olderSegment.session = older
        let note = Note(text: "last", createdAt: t0.addingTimeInterval(600))
        context.insert(note)
        note.session = older

        let newer = WorkSession(startedAt: t0.addingTimeInterval(3600))
        context.insert(newer)
        let newerSegment = Segment(startedAt: newer.startedAt)
        context.insert(newerSegment)
        newerSegment.session = newer
        newer.pauseIntervals = [PauseInterval(start: newer.startedAt.addingTimeInterval(60))]
        try context.save()

        let settings = TestSupport.makeSettings()
        settings.defaults.set(AutoPauseReason.quit.rawValue, forKey: "engine.autoPauseReason")
        let engine = SessionEngine(context: context, settings: settings)
        engine.restoreActiveSession()

        XCTAssertTrue(engine.activeSession === newer)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.autoPauseReason, .quit)
        XCTAssertEqual(older.endedAt, t0.addingTimeInterval(600), "extra active session ends at its last activity")
        TestSupport.assertInvariants(older)

        engine.resume(at: newer.startedAt.addingTimeInterval(120))
        XCTAssertNil(engine.autoPauseReason)
        XCTAssertNil(settings.defaults.string(forKey: "engine.autoPauseReason"))
    }

    @MainActor
    func testResumePendingSessionAddsGapAsPause() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        let t0 = Date.now.addingTimeInterval(-3600)
        let session = engine.start(label: nil, at: t0)
        engine.stop(at: t0.addingTimeInterval(1200))
        XCTAssertTrue(engine.pendingEndSession === session)

        engine.resumePendingSession()
        XCTAssertTrue(engine.activeSession === session)
        XCTAssertNil(engine.pendingEndSession)
        XCTAssertNil(session.endedAt)
        XCTAssertNil(session.sortedSegments.last?.endedAt)
        XCTAssertEqual(session.pauseIntervals.count, 1)
        XCTAssertEqual(session.pauseIntervals.first?.start, t0.addingTimeInterval(1200))
        XCTAssertFalse(engine.isPaused)
        // Only the 20 minutes before the stop count; the gap is a pause.
        XCTAssertEqual(engine.elapsed(at: .now), 1200, accuracy: 2)
    }

    @MainActor
    func testDiscardDeletesActiveSession() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        engine.start(label: nil, at: TestSupport.time(9))
        engine.addNote("note", at: TestSupport.time(9, 5))
        engine.discard()
        XCTAssertFalse(engine.isActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkSession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Note>()), 0, "notes cascade")
    }

    @MainActor
    func testTotalActiveTodayClipsAtMidnight() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        let now = TestSupport.date(2026, 6, 11, 10)
        let yesterdayLate = TestSupport.date(2026, 6, 10, 23)
        let session = TestSupport.makeEndedSession(in: context, start: yesterdayLate, segmentMinutes: [120]) // 23:00–01:00
        XCTAssertNotNil(session.endedAt)
        TestSupport.makeEndedSession(in: context, start: TestSupport.date(2026, 6, 11, 8), segmentMinutes: [30])
        try context.save()
        XCTAssertEqual(engine.totalActiveToday(now: now), 90 * 60, accuracy: 0.001)
    }

    @MainActor
    func testDefaultLabelPrefersSettingThenSortIndex() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let engine = SessionEngine(context: context, settings: settings)
        let first = WorkLabel(name: "First", sortIndex: 0)
        let second = WorkLabel(name: "Second", sortIndex: 1)
        context.insert(first)
        context.insert(second)
        XCTAssertTrue(engine.defaultLabel() === first)
        settings.defaultLabelID = second.uuid
        XCTAssertTrue(engine.defaultLabel() === second)
        second.isArchived = true
        XCTAssertTrue(engine.defaultLabel() === first)
    }

    // MARK: - Formatting

    @MainActor
    func testFormatting() {
        XCTAssertEqual(TimeInterval(307).formattedClock, "05:07")
        XCTAssertEqual(TimeInterval(3907).formattedClock, "1:05:07")
        XCTAssertEqual(TimeInterval(-5).formattedClock, "00:00")
        XCTAssertEqual(TimeInterval(45).formattedShort, "45s")
        XCTAssertEqual(TimeInterval(12 * 60).formattedShort, "12m")
        XCTAssertEqual(TimeInterval(3900).formattedShort, "1h 05m")
        XCTAssertEqual(TimeInterval(7200).formattedShort, "2h")
        XCTAssertEqual(TimeInterval(5400).formattedHoursDecimal, "1.5h")
        XCTAssertEqual("  hi \n".trimmed, "hi")
        XCTAssertTrue(" \n ".isBlank)
        XCTAssertNil("   ".nilIfBlank)

        let a = Date(timeIntervalSince1970: 100)
        let b = Date(timeIntervalSince1970: 50)
        XCTAssertEqual(DateInterval(safeStart: a, end: b).duration, 0, "never traps on end < start")

        let wednesday = TestSupport.date(2026, 6, 10, 15)     // Wednesday
        XCTAssertEqual(Calendar.current.component(.weekday, from: wednesday.startOfWeek(mondayFirst: true)), 2)
        XCTAssertEqual(Calendar.current.component(.weekday, from: wednesday.startOfWeek(mondayFirst: false)), 1)
        XCTAssertEqual(wednesday.startOfNextDay, TestSupport.date(2026, 6, 11, 0))
    }
}
