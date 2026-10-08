import SwiftData
import XCTest
@testable import Worklog

/// `StatsCalculator` on hand-built snapshots (June 2026: no DST change). "Now" is Wednesday 2026-06-10 15:00.
final class StatsCalculatorTests: XCTestCase {
    @MainActor private var now: Date { TestSupport.time(15) }

    @MainActor
    private func options(_ range: StatsRange = .last7Days, bucket: StatsBucket = .day,
                         goalHours: Double = 0) -> StatsOptions {
        StatsOptions(range: range, bucket: bucket, weekStartsOnMonday: true, dailyGoalHours: goalHours)
    }

    /// An ended session with one segment [start, end) and the given pauses.
    @MainActor
    private func session(_ start: Date, _ end: Date, label: UUID? = nil, pauses: [PauseInterval] = [],
                         tags: [UUID] = []) -> StatsSessionSnapshot {
        let paused = pauses.totalOverlap(with: DateInterval(safeStart: start, end: end), now: end)
        return StatsSessionSnapshot(
            start: start, isActive: false, labelID: label, pauses: pauses,
            activeDuration: max(0, end.timeIntervalSince(start) - paused),
            segments: [StatsSegmentSnapshot(start: start, end: end, labelID: label, tagIDs: tags)],
            allTagIDs: tags, profileID: nil)
    }

    /// 9:00–10:00 on 2026-06-<day>.
    @MainActor
    private func hourOn(_ day: Int) -> StatsSessionSnapshot {
        session(TestSupport.date(2026, 6, day, 9), TestSupport.date(2026, 6, day, 10))
    }

    @MainActor
    private func snapshot(_ sessions: [StatsSessionSnapshot], labels: [UUID: StatsLabelInfo] = [:]) -> StatsSnapshot {
        StatsSnapshot(takenAt: now, sessions: sessions, labels: labels, tags: [:], profiles: [:])
    }

    // MARK: - Streaks

    @MainActor
    func testStreakCountsFromYesterdayWhenNothingTodayYet() {
        // 7, 8, 9 June; nothing on the 10th (today) yet → the streak is still 3, not 0.
        let result = StatsCalculator.compute(snapshot([hourOn(7), hourOn(8), hourOn(9)]), options: options())
        XCTAssertEqual(result.currentStreak, 3)
        XCTAssertEqual(result.bestStreak, 3)

        // Working today extends it.
        let withToday = StatsCalculator.compute(snapshot([hourOn(7), hourOn(8), hourOn(9), hourOn(10)]),
                                                options: options())
        XCTAssertEqual(withToday.currentStreak, 4)
        XCTAssertEqual(withToday.bestStreak, 4)
    }

    @MainActor
    func testStreakBreaksAfterAnEmptyYesterdayButBestStreakRemains() {
        // 1, 2 June (a 2-day run), then 5 June; nothing on the 9th or 10th → current 0, best 2.
        let result = StatsCalculator.compute(snapshot([hourOn(1), hourOn(2), hourOn(5)]), options: options(.last30Days))
        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.bestStreak, 2)
    }

    // MARK: - 60 s active-day minimum

    @MainActor
    func testADayNeedsSixtySecondsToCountAsActive() {
        let short = session(TestSupport.date(2026, 6, 9, 9), TestSupport.date(2026, 6, 9, 9).addingTimeInterval(59))
        let enough = session(TestSupport.date(2026, 6, 10, 9), TestSupport.date(2026, 6, 10, 9, 1))
        let result = StatsCalculator.compute(snapshot([short, enough]), options: options())
        XCTAssertEqual(result.totalActive, 119, accuracy: 0.001, "short days still count toward the total")
        XCTAssertEqual(result.activeDays, 1, "59 s is not an active day; 60 s is")
        XCTAssertEqual(result.currentStreak, 1, "yesterday's 59 s doesn't extend today's streak")
        XCTAssertEqual(result.bestStreak, 1)
        XCTAssertEqual(result.sessionCount, 2)
    }

    // MARK: - Midnight crossing

    @MainActor
    func testASessionCrossingMidnightCountsOnBothDaysWithoutItsPause() {
        let label = UUID()
        let labels = [label: StatsLabelInfo(uuid: label, name: "Deep", colorHex: "#111111", sortIndex: 0)]
        // 9 June 23:00 → 10 June 01:00, paused 23:30 → 00:15.
        // 9 June: 23:00–23:30 = 1800 s. 10 June: 00:15–01:00 = 2700 s.
        let pause = PauseInterval(start: TestSupport.date(2026, 6, 9, 23, 30), end: TestSupport.date(2026, 6, 10, 0, 15))
        let crossing = session(TestSupport.date(2026, 6, 9, 23), TestSupport.date(2026, 6, 10, 1), label: label,
                               pauses: [pause])
        XCTAssertEqual(crossing.activeDuration, 4500, accuracy: 0.001)

        let result = StatsCalculator.compute(snapshot([crossing], labels: labels), options: options())
        XCTAssertEqual(result.totalActive, 4500, accuracy: 0.001)
        XCTAssertEqual(result.activeDays, 2)
        XCTAssertEqual(result.currentStreak, 2)
        XCTAssertEqual(result.sessionCount, 1, "counted once, on the day it started")

        let ninth = result.bars.filter { $0.bucketStart == TestSupport.date(2026, 6, 9, 0) }
        let tenth = result.bars.filter { $0.bucketStart == TestSupport.date(2026, 6, 10, 0) }
        XCTAssertEqual(ninth.map(\.seconds), [1800])
        XCTAssertEqual(tenth.map(\.seconds), [2700])
        XCTAssertEqual(result.series.map(\.name), ["Deep"])
        XCTAssertEqual(result.series.first?.seconds ?? 0, 4500, accuracy: 0.001)
        XCTAssertEqual(result.maxBucketSeconds, 2700, accuracy: 0.001)
    }

    @MainActor
    func testTimeBeforeTheWindowIsLeftOut() {
        // 3 June is outside the last 7 days (4…10 June); it still counts for the best streak.
        let result = StatsCalculator.compute(snapshot([hourOn(3), hourOn(10)]), options: options())
        XCTAssertEqual(result.totalActive, 3600, accuracy: 0.001)
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.dayCount, 7)
    }

    // MARK: - Bucket thresholds

    @MainActor
    func testBucketsAreCoarsenedForLongWindows() {
        XCTAssertEqual(StatsCalculator.maxDailyBucketDays, 400)
        XCTAssertEqual(StatsCalculator.maxWeeklyBucketDays, 1820)
        XCTAssertEqual(StatsCalculator.effectiveBucket(.day, dayCount: 400), .day)
        XCTAssertEqual(StatsCalculator.effectiveBucket(.day, dayCount: 401), .week)
        XCTAssertEqual(StatsCalculator.effectiveBucket(.week, dayCount: 1820), .week)
        XCTAssertEqual(StatsCalculator.effectiveBucket(.week, dayCount: 1821), .month)
        XCTAssertEqual(StatsCalculator.effectiveBucket(.day, dayCount: 1821), .month, "day → week → month")
        XCTAssertEqual(StatsCalculator.effectiveBucket(.month, dayCount: 5000), .month)

        XCTAssertEqual(StatsCalculator.allowedBuckets(for: .all, dayCount: 30), [.day, .week, .month])
        XCTAssertEqual(StatsCalculator.allowedBuckets(for: .all, dayCount: 401), [.week, .month])
        XCTAssertEqual(StatsCalculator.allowedBuckets(for: .all, dayCount: 1821), [.month])
        XCTAssertEqual(StatsCalculator.allowedBuckets(for: .lastYear, dayCount: 365), [.week, .month])
    }

    @MainActor
    func testAllTimeWindowStartsAtTheFirstSessionAndCoarsensItsBucket() {
        // First session 2 years before "now" → > 400 days, so a requested daily chart uses weeks.
        let old = session(TestSupport.date(2024, 6, 10, 9), TestSupport.date(2024, 6, 10, 10))
        let result = StatsCalculator.compute(snapshot([old, hourOn(10)]), options: options(.all, bucket: .day))
        XCTAssertEqual(result.window.start, TestSupport.date(2024, 6, 10, 0))
        XCTAssertEqual(result.bucket, .week)
        XCTAssertEqual(result.totalActive, 7200, accuracy: 0.001)
    }

    // MARK: - Tag time: segment tags vs session tags

    @MainActor
    func testTagTimeCountsSegmentTagsPerSegmentAndSessionTagsForEverySegment() throws {
        let context = try TestSupport.makeContext()
        let segmentTag = WorkTag(name: "review")
        let sessionTag = WorkTag(name: "legacy")
        context.insert(segmentTag)
        context.insert(sessionTag)
        // 10 June 9:00: segment 0 = 60 min (tagged "review"), segment 1 = 30 min (untagged); the session itself
        // carries "legacy" (as sessions from older builds do).
        let model = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [60, 30])
        model.sortedSegments[0].tagList = [segmentTag]
        model.tagList = [sessionTag]
        try context.save()

        let snapshot = StatsSnapshot.make(from: [model], now: now)
        let result = StatsCalculator.compute(snapshot, options: options())
        let byName = Dictionary(uniqueKeysWithValues: result.tags.map { ($0.name, $0) })
        XCTAssertEqual(byName["#review"]?.seconds ?? 0, 3600, accuracy: 0.001, "only its own segment")
        XCTAssertEqual(byName["#legacy"]?.seconds ?? 0, 5400, accuracy: 0.001, "a session tag counts for every segment")
        XCTAssertEqual(byName["#review"]?.sessionCount, 1)
        XCTAssertEqual(byName["#legacy"]?.sessionCount, 1)
        XCTAssertEqual(result.tags.map(\.name), ["#legacy", "#review"], "most time first")
    }

    @MainActor
    func testStartTagsOnTheFirstSegmentDontCountForLaterSegments() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        settings.showEndSessionSheet = false
        let tag = WorkTag(name: "bugfix")
        context.insert(tag)
        let engine = SessionEngine(context: context, settings: settings)
        // Start with #bugfix at 9:00, split at 10:00 into an untagged segment, stop at 10:30.
        let session = engine.start(label: nil, tags: [tag], at: TestSupport.time(9))
        engine.split(label: nil, tags: [], focus: "Review", at: TestSupport.time(10))
        engine.stop(at: TestSupport.time(10, 30))

        let result = StatsCalculator.compute(StatsSnapshot.make(from: [session], now: now), options: options())
        XCTAssertEqual(result.tags.first?.name, "#bugfix")
        XCTAssertEqual(result.tags.first?.seconds ?? 0, 3600, accuracy: 0.001, "the split-off segment isn't #bugfix")
        XCTAssertEqual(result.totalActive, 5400, accuracy: 0.001)
    }
}
