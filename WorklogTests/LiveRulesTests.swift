import SwiftData
import XCTest
@testable import Worklog

/// The rules behind Today, the menu bar and the overlay (`LiveDayMath`, `LiveStartChoice`, `LiveLongSessionRule`),
/// which `SessionEngine.totalActiveToday` / `defaultLabel(for:)` delegate to. Reference day: 2026-06-10.
final class LiveRulesTests: XCTestCase {
    @MainActor
    private func makeProfile(_ name: String, in context: ModelContext) -> WorkProfile {
        ProfileOps.createProfile(name: name, colorHex: "#5B8DEF", symbolName: "briefcase.fill", in: context)
    }

    // MARK: - LiveDayMath

    @MainActor
    func testTotalTodayClipsToTodayFiltersByProfileAndAddsAnOldActiveSession() throws {
        let context = try TestSupport.makeContext()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        // 9 June 23:00 → 10 June 01:00 (P): 1 h today.
        let crossing = TestSupport.makeEndedSession(in: context, start: TestSupport.date(2026, 6, 9, 23),
                                                    segmentMinutes: [120])
        crossing.profile = p
        // 10 June 9:00–10:00 (P) and 11:00–11:30 (Q).
        let morning = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [60])
        morning.profile = p
        let late = TestSupport.makeEndedSession(in: context, start: TestSupport.time(11), segmentMinutes: [30])
        late.profile = q
        // Running since 7 June 9:00 (P), missing from the fetched list (it started > 2 days ago): today 0:00–12:00.
        let active = WorkSession(startedAt: TestSupport.date(2026, 6, 7, 9))
        context.insert(active)
        active.profile = p
        try context.save()

        let now = TestSupport.time(12)
        let fetched = [crossing, morning, late]
        let all = LiveDayMath.totalToday(fetched, active: active, now: now, scope: .allProfiles)
        XCTAssertEqual(all, 3600 + 3600 + 1800 + 43_200, accuracy: 0.001)
        XCTAssertEqual(LiveDayMath.totalToday(fetched, active: active, now: now, scope: ProfileScope(profileID: p.uuid)),
                       3600 + 3600 + 43_200, accuracy: 0.001)
        XCTAssertEqual(LiveDayMath.totalToday(fetched, active: active, now: now, scope: ProfileScope(profileID: q.uuid)),
                       1800, accuracy: 0.001, "the active session is only added when it is in scope")
        XCTAssertEqual(LiveDayMath.totalToday(fetched + [active], active: active, now: now, scope: .allProfiles),
                       all, accuracy: 0.001, "never counted twice")

        // The engine uses the same rule (it fetches sessions started since 8 June, so `active` comes via `active:`).
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        engine.reconcile(now: now)
        XCTAssertTrue(engine.activeSession === active)
        XCTAssertEqual(engine.totalActiveToday(now: now), all, accuracy: 0.001)
        XCTAssertEqual(engine.totalActiveToday(now: now, scope: ProfileScope(profileID: q.uuid)), 1800, accuracy: 0.001)
    }

    @MainActor
    func testEndedTodayIsNewestFirstAndSkipsRunningSessions() throws {
        let context = try TestSupport.makeContext()
        let crossing = TestSupport.makeEndedSession(in: context, start: TestSupport.date(2026, 6, 9, 23),
                                                    segmentMinutes: [120])
        let yesterday = TestSupport.makeEndedSession(in: context, start: TestSupport.date(2026, 6, 9, 9),
                                                     segmentMinutes: [60])
        let morning = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [60])
        let running = WorkSession(startedAt: TestSupport.time(11))
        context.insert(running)
        try context.save()

        let ended = LiveDayMath.endedToday([crossing, yesterday, morning, running], now: TestSupport.time(12),
                                           scope: .allProfiles)
        XCTAssertEqual(ended.map(\.uuid), [morning.uuid, crossing.uuid])
    }

    @MainActor
    func testGoalSeconds() {
        let settings = TestSupport.makeSettings()
        settings.dailyGoalHours = 1.5
        XCTAssertEqual(LiveDayMath.goalSeconds(settings), 5400, accuracy: 0.001)
        settings.dailyGoalHours = -2
        XCTAssertEqual(LiveDayMath.goalSeconds(settings), 0)
    }

    // MARK: - LiveStartChoice

    @MainActor
    func testDefaultLabelRule() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        let first = WorkLabel(name: "First", sortIndex: 0)
        let second = WorkLabel(name: "Second", sortIndex: 1)
        let archived = WorkLabel(name: "Old", sortIndex: 2)
        let qOnly = WorkLabel(name: "Q only", sortIndex: -1)
        for label in [second, archived, first, qOnly] { context.insert(label) }
        archived.isArchived = true
        qOnly.profile = q
        try context.save()
        let labels = [second, archived, first, qOnly]     // any order: sorted by sortIndex

        XCTAssertTrue(LiveStartChoice.defaultLabel(in: labels, profile: p, settings: settings) === first,
                      "no default → the first offered label")
        p.defaultLabelUUID = second.uuid
        XCTAssertTrue(LiveStartChoice.defaultLabel(in: labels, profile: p, settings: settings) === second)
        p.defaultLabelUUID = archived.uuid
        XCTAssertTrue(LiveStartChoice.defaultLabel(in: labels, profile: p, settings: settings) === first,
                      "an archived default is ignored")
        p.defaultLabelUUID = qOnly.uuid
        XCTAssertTrue(LiveStartChoice.defaultLabel(in: labels, profile: p, settings: settings) === first,
                      "another profile's label is never the default")
        XCTAssertTrue(LiveStartChoice.defaultLabel(in: labels, profile: q, settings: settings) === qOnly,
                      "Q offers its own label (sortIndex -1) and the global ones")

        // No profile at all: the legacy setting.
        settings.defaultLabelID = second.uuid
        XCTAssertTrue(LiveStartChoice.defaultLabel(in: labels, profile: nil, settings: settings) === second)
        XCTAssertNil(LiveStartChoice.defaultLabel(in: [archived], profile: nil, settings: settings))

        // The engine applies the same rule to every label in the store.
        let store = ProfileStore(context: context, settings: settings)
        store.select(p)
        let engine = SessionEngine(context: context, settings: settings, profiles: store)
        p.defaultLabelUUID = second.uuid
        XCTAssertTrue(engine.defaultLabel() === second, "nil → the current profile")
        XCTAssertTrue(engine.defaultLabel(for: q) === qOnly)
    }

    @MainActor
    func testPickedLabelAndTagsAreResolvedBeforeStarting() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        let global = WorkLabel(name: "Global", sortIndex: 0)
        let qLabel = WorkLabel(name: "Q", sortIndex: 1)
        let gone = WorkLabel(name: "Archived", sortIndex: 2)
        for label in [global, qLabel, gone] { context.insert(label) }
        qLabel.profile = q
        gone.isArchived = true
        let tag = WorkTag(name: "ok")
        let qTag = WorkTag(name: "q")
        let oldTag = WorkTag(name: "old")
        for item in [tag, qTag, oldTag] { context.insert(item) }
        qTag.profile = q
        oldTag.isArchived = true
        try context.save()
        let engine = SessionEngine(context: context, settings: settings)

        XCTAssertNil(LiveStartChoice.label(nil, engine: engine, profile: p), "None stays None")
        XCTAssertTrue(LiveStartChoice.label(global, engine: engine, profile: p) === global)
        XCTAssertTrue(LiveStartChoice.label(gone, engine: engine, profile: p) === global, "archived → default")
        XCTAssertTrue(LiveStartChoice.label(qLabel, engine: engine, profile: p) === global, "not offered → default")
        XCTAssertTrue(LiveStartChoice.label(qLabel, engine: engine, profile: q) === qLabel)

        XCTAssertNil(LiveStartChoice.splitLabel(gone))
        XCTAssertTrue(LiveStartChoice.splitLabel(qLabel) === qLabel, "split keeps any usable label")

        XCTAssertEqual(LiveStartChoice.tags([tag, qTag, oldTag]).map(\.name), ["ok", "q"])
        XCTAssertEqual(LiveStartChoice.tags([tag, qTag, oldTag], in: p.uuid).map(\.name), ["ok"])
        XCTAssertEqual(LiveStartChoice.tags([tag, qTag, oldTag], in: q.uuid).map(\.name), ["ok", "q"])
        XCTAssertEqual(LiveStartChoice.tags([tag, qTag, oldTag], in: nil).map(\.name), ["ok", "q"])
    }

    // MARK: - LiveLongSessionRule + "Keep going"

    @MainActor
    func testLongSessionWarningAndKeepGoingPerSession() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        settings.longSessionWarningHours = 2
        settings.showEndSessionSheet = false
        let engine = SessionEngine(context: context, settings: settings)
        let session = engine.start(label: nil, at: TestSupport.time(9))

        XCTAssertNil(LiveLongSessionRule.warningHours(engine: engine, settings: settings, now: TestSupport.time(10)))
        XCTAssertEqual(LiveLongSessionRule.warningHours(engine: engine, settings: settings,
                                                        now: TestSupport.time(12)), 3)
        engine.dismissLongSessionWarning(for: session)
        XCTAssertTrue(engine.isLongSessionWarningDismissed(for: session))
        XCTAssertNil(LiveLongSessionRule.warningHours(engine: engine, settings: settings, now: TestSupport.time(12)))

        // Survives a relaunch (a new engine over the same defaults)…
        let relaunched = SessionEngine(context: context, settings: settings)
        relaunched.restoreActiveSession()
        XCTAssertTrue(relaunched.activeSession === session)
        XCTAssertTrue(relaunched.isLongSessionWarningDismissed(for: session))

        // …and is cleared when the session ends.
        relaunched.stop(at: TestSupport.time(12))
        XCTAssertFalse(relaunched.isLongSessionWarningDismissed(for: session))
        XCTAssertNil(settings.defaults.object(forKey: "engine.longWarningDismissed"))
        let next = relaunched.start(label: nil, at: TestSupport.time(13))
        XCTAssertFalse(relaunched.isLongSessionWarningDismissed(for: next))
        XCTAssertEqual(LiveLongSessionRule.warningHours(engine: relaunched, settings: settings,
                                                        now: TestSupport.time(15)), 2)
    }
}
