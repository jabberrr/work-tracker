import SwiftData
import XCTest
@testable import Worklog

/// Round 3: profiles (ARCHITECTURE §12). Export/CSV coverage lives in `ExportRoundTripTests`.
final class ProfileTests: XCTestCase {

    @MainActor
    private func makeProfile(_ name: String, in context: ModelContext) -> WorkProfile {
        ProfileOps.createProfile(name: name, colorHex: "#5B8DEF", symbolName: "briefcase.fill", in: context)
    }

    // MARK: - 1. Migration

    @MainActor
    func testEnsureProfilesMigratesLegacyStore() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let label = WorkLabel(name: "Deep work")
        let tag = WorkTag(name: "coding")
        context.insert(label)
        context.insert(tag)
        let first = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [30], label: label)
        let second = TestSupport.makeEndedSession(in: context, start: TestSupport.time(11), segmentMinutes: [20])
        let modified = TestSupport.time(12)
        first.modifiedAt = modified
        second.modifiedAt = modified
        settings.defaultLabelID = label.uuid
        try context.save()

        SeedData.ensureProfiles(in: context, settings: settings)

        let profiles = ProfileOps.allProfiles(in: context)
        XCTAssertEqual(profiles.count, 1)
        let work = try XCTUnwrap(profiles.first)
        XCTAssertEqual(work.uuid, ProfileOps.defaultProfileUUID)
        XCTAssertEqual(work.uuid.uuidString, "6F1C0E10-0000-4000-8000-000000000201")
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(work.symbolName, "briefcase.fill")
        XCTAssertEqual(work.defaultLabelUUID, label.uuid, "legacy default label copied")
        XCTAssertTrue(first.profile === work)
        XCTAssertTrue(second.profile === work)
        XCTAssertNil(label.profile, "existing labels stay global")
        XCTAssertNil(tag.profile, "existing tags stay global")
        XCTAssertEqual(first.modifiedAt, modified, "migration never touches modifiedAt")
        XCTAssertEqual(second.modifiedAt, modified)

        SeedData.ensureProfiles(in: context, settings: settings)
        XCTAssertEqual(ProfileOps.allProfiles(in: context).count, 1, "idempotent")
        XCTAssertTrue(first.profile === work)
    }

    @MainActor
    func testProvisionalDefaultProfileIsDiscardedWhenEmpty() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        SeedData.ensureProfiles(in: context, settings: settings, provisional: true)
        let provisional = try XCTUnwrap(ProfileOps.allProfiles(in: context).first)
        XCTAssertEqual(settings.defaults.string(forKey: SeedData.provisionalDefaultProfileKey),
                       provisional.instanceID.uuidString)

        // The first import brought another profile (the user deleted "Work" elsewhere).
        let personal = makeProfile("Personal", in: context)
        SeedData.discardProvisionalDefaultProfile(in: context, defaults: settings.defaults)
        let remaining = ProfileOps.allProfiles(in: context)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining.first === personal)
        XCTAssertNil(settings.defaults.string(forKey: SeedData.provisionalDefaultProfileKey), "key cleared")
    }

    @MainActor
    func testProvisionalDefaultProfileIsKeptWhenUsed() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        SeedData.ensureProfiles(in: context, settings: settings, provisional: true)
        let provisional = try XCTUnwrap(ProfileOps.allProfiles(in: context).first)
        _ = makeProfile("Personal", in: context)
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10])
        session.profile = provisional
        try context.save()

        SeedData.discardProvisionalDefaultProfile(in: context, defaults: settings.defaults)
        XCTAssertEqual(ProfileOps.allProfiles(in: context).count, 2)
        XCTAssertNil(settings.defaults.string(forKey: SeedData.provisionalDefaultProfileKey), "evaluated once")
    }

    // MARK: - 2. Dedupe

    @MainActor
    func testProfileDedupeKeepsOldestAndRepointsEverything() throws {
        let context = try TestSupport.makeContext()
        let id = UUID()
        let older = WorkProfile(name: "Work", uuid: id)
        let newer = WorkProfile(name: "Work", uuid: id)
        context.insert(older)
        context.insert(newer)
        older.createdAt = TestSupport.time(8)
        newer.createdAt = TestSupport.time(9)
        let defaultLabelID = UUID()
        newer.defaultLabelUUID = defaultLabelID

        let label = WorkLabel(name: "Local")
        let tag = WorkTag(name: "local")
        context.insert(label)
        context.insert(tag)
        label.profile = newer
        tag.profile = newer
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(10), segmentMinutes: [10])
        session.profile = newer
        let modified = session.modifiedAt
        try context.save()

        SeedData.deduplicate(in: context)

        let profiles = ProfileOps.allProfiles(in: context)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles.first === older, "oldest createdAt survives")
        XCTAssertTrue(session.profile === older)
        XCTAssertTrue(label.profile === older)
        XCTAssertTrue(tag.profile === older)
        XCTAssertEqual(older.defaultLabelUUID, defaultLabelID, "default label copied when the survivor has none")
        XCTAssertEqual(session.modifiedAt, modified)
    }

    @MainActor
    func testProfileDedupeKeepsIndistinguishableCopies() throws {
        let context = try TestSupport.makeContext()
        let id = UUID()
        let shared = UUID()
        let created = TestSupport.time(8)
        for _ in 0..<2 {
            let profile = WorkProfile(name: "Work", uuid: id)
            context.insert(profile)
            profile.createdAt = created
            profile.instanceID = shared
        }
        try context.save()
        SeedData.deduplicate(in: context)
        XCTAssertEqual(ProfileOps.allProfiles(in: context).count, 2, "a tie deletes nothing")
    }

    // MARK: - 3. Repair

    @MainActor
    func testRepairMovesUnassignedSessionsToHome() throws {
        let context = try TestSupport.makeContext()
        let home = makeProfile("Work", in: context)
        let side = makeProfile("Side", in: context)
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10])
        session.profile = side
        try context.save()
        let modified = session.modifiedAt

        context.delete(side)   // e.g. deleted on another Mac
        try context.save()
        XCTAssertNil(ModelLiveness.live(session.profile))

        SeedData.deduplicate(in: context)
        XCTAssertTrue(session.profile === home)
        XCTAssertEqual(session.modifiedAt, modified, "repair never touches modifiedAt")
    }

    @MainActor
    func testRepairCreatesDefaultProfileWhenNoneExists() throws {
        let context = try TestSupport.makeContext()
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10])
        try context.save()

        SeedData.deduplicate(in: context)
        let profiles = ProfileOps.allProfiles(in: context)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.uuid, ProfileOps.defaultProfileUUID)
        XCTAssertTrue(session.profile === profiles.first)
    }

    @MainActor
    func testHomeProfilePrefersDefaultUUIDThenFirstActive() throws {
        let context = try TestSupport.makeContext()
        let first = makeProfile("First", in: context)
        let second = makeProfile("Second", in: context)
        XCTAssertTrue(ProfileOps.homeProfile(in: context) === first)
        first.isArchived = true
        XCTAssertTrue(ProfileOps.homeProfile(in: context) === second)
        XCTAssertNil(ProfileOps.ensureDefaultProfile(legacyDefaultLabelID: nil, in: context), "profiles exist")
        let work = WorkProfile(name: "Work", sortIndex: 5, uuid: ProfileOps.defaultProfileUUID)
        context.insert(work)
        XCTAssertTrue(ProfileOps.homeProfile(in: context) === work, "the default uuid wins when active")
    }

    // MARK: - 4. ProfileScope

    @MainActor
    func testProfileScopeRules() throws {
        let context = try TestSupport.makeContext()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        let global = TaxonomyOps.createLabel(name: "Global", colorHex: "#111111", symbolName: "circle.fill", in: context)
        let pLocal = TaxonomyOps.createLabel(name: "P only", colorHex: "#111111", symbolName: "circle.fill",
                                             profile: p, in: context)
        let qLocal = TaxonomyOps.createLabel(name: "Q only", colorHex: "#111111", symbolName: "circle.fill",
                                             profile: q, in: context)
        let globalTag = TaxonomyOps.createTag(name: "g", in: context)
        let qTag = TaxonomyOps.createTag(name: "q", profile: q, in: context)

        let scopeP = ProfileScope(profileID: p.uuid)
        XCTAssertFalse(scopeP.isAllProfiles)
        XCTAssertTrue(ProfileScope.allProfiles.isAllProfiles)
        XCTAssertTrue(scopeP.offers(global))
        XCTAssertTrue(scopeP.offers(pLocal))
        XCTAssertFalse(scopeP.offers(qLocal))
        XCTAssertTrue(scopeP.offers(globalTag))
        XCTAssertFalse(scopeP.offers(qTag))
        XCTAssertTrue(ProfileScope.allProfiles.offers(qLocal))
        XCTAssertTrue(ProfileScope.allProfiles.offers(qTag))

        let inP = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10])
        inP.profile = p
        let inQ = TestSupport.makeEndedSession(in: context, start: TestSupport.time(10), segmentMinutes: [10])
        inQ.profile = q
        let orphan = TestSupport.makeEndedSession(in: context, start: TestSupport.time(11), segmentMinutes: [10])
        let point = LearningPoint(text: "Insight")
        context.insert(point)
        point.session = inP
        try context.save()

        XCTAssertTrue(scopeP.contains(inP))
        XCTAssertFalse(scopeP.contains(inQ))
        XCTAssertFalse(scopeP.contains(orphan), "unassigned sessions are in no specific profile")
        XCTAssertTrue(ProfileScope.allProfiles.contains(orphan))
        XCTAssertTrue(scopeP.contains(point))
        XCTAssertFalse(ProfileScope(profileID: q.uuid).contains(point))
        XCTAssertEqual(scopeP.filter([inQ, inP, orphan]).map(\.uuid), [inP.uuid])
        XCTAssertEqual(ProfileScope.allProfiles.filter([inQ, inP, orphan]).count, 3)

        // Deleted models are ignored.
        context.delete(pLocal)
        context.delete(orphan)
        XCTAssertFalse(scopeP.offers(pLocal))
        XCTAssertFalse(ProfileScope.allProfiles.offers(pLocal))
        XCTAssertFalse(ProfileScope.allProfiles.contains(orphan))

        // A label whose profile was deleted is global.
        context.delete(q)
        XCTAssertTrue(scopeP.offers(qLocal))
        XCTAssertFalse(scopeP.contains(inQ))
    }

    // MARK: - 5. createTag stays within scope

    @MainActor
    func testCreateTagDedupesWithinScope() throws {
        let context = try TestSupport.makeContext()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)

        let px = TaxonomyOps.createTag(name: "x", profile: p, in: context)
        XCTAssertTrue(px.profile === p, "new tags are local to the given profile")
        XCTAssertTrue(TaxonomyOps.createTag(name: " X ", profile: p, in: context) === px)
        let qx = TaxonomyOps.createTag(name: "x", profile: q, in: context)
        XCTAssertFalse(qx === px, "a P-local tag is not returned for Q")
        XCTAssertTrue(qx.profile === q)

        let shared = TaxonomyOps.createTag(name: "shared", in: context)
        XCTAssertNil(shared.profile)
        XCTAssertTrue(TaxonomyOps.createTag(name: "shared", profile: p, in: context) === shared)
        XCTAssertTrue(TaxonomyOps.createTag(name: "Shared", profile: q, in: context) === shared)

        let globalX = TaxonomyOps.createTag(name: "x", in: context)
        XCTAssertFalse(globalX === px)
        XCTAssertFalse(globalX === qx)
        XCTAssertNil(globalX.profile, "profile nil only checks global tags")

        let label = TaxonomyOps.createLabel(name: "L", colorHex: "#111111", symbolName: "circle.fill",
                                            profile: q, in: context)
        XCTAssertTrue(label.profile === q)
    }

    // MARK: - 6. setScope

    @MainActor
    func testSetScopeLocalGivesOtherProfilesACopy() throws {
        let context = try TestSupport.makeContext()
        let work = makeProfile("Work", in: context)
        let personal = makeProfile("Personal", in: context)
        let meetings = TaxonomyOps.createLabel(name: "Meetings", colorHex: "#F2994A", symbolName: "person.2.fill",
                                               in: context)
        let inWork = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [30],
                                                  label: meetings)
        inWork.profile = work
        inWork.sortedSegments[0].label = meetings
        let inPersonal = TestSupport.makeEndedSession(in: context, start: TestSupport.time(10), segmentMinutes: [30],
                                                      label: meetings)
        inPersonal.profile = personal
        inPersonal.sortedSegments[0].label = meetings
        personal.defaultLabelUUID = meetings.uuid
        try context.save()

        XCTAssertEqual(TaxonomyOps.scopeChangeImpact(of: meetings, to: work),
                       .copiesForOtherProfiles(profileNames: ["Personal"], sessionCount: 1))
        XCTAssertEqual(TaxonomyOps.scopeChangeImpact(of: meetings, to: nil), .none)

        TaxonomyOps.setScope(of: meetings, to: work, in: context)

        XCTAssertTrue(meetings.profile === work)
        XCTAssertTrue(inWork.label === meetings, "P's sessions are unchanged")
        XCTAssertTrue(inWork.sortedSegments[0].label === meetings)
        let copy = try XCTUnwrap(inPersonal.label)
        XCTAssertFalse(copy === meetings)
        XCTAssertEqual(copy.name, "Meetings")
        XCTAssertEqual(copy.colorHex, "#F2994A")
        XCTAssertTrue(copy.profile === personal)
        XCTAssertTrue(inPersonal.sortedSegments[0].label === copy, "segments follow to the same copy")
        XCTAssertEqual(personal.defaultLabelUUID, copy.uuid, "Q's default label follows")
        XCTAssertEqual(TaxonomyOps.scopeChangeImpact(of: meetings, to: work), .none)

        // An existing same-name label in Q is reused.
        let admin = TaxonomyOps.createLabel(name: "Admin", colorHex: "#9B9B9B", symbolName: "tray.full.fill", in: context)
        let personalAdmin = TaxonomyOps.createLabel(name: "admin", colorHex: "#000000", symbolName: "circle.fill",
                                                    profile: personal, in: context)
        inPersonal.label = admin
        try context.save()
        TaxonomyOps.setScope(of: admin, to: work, in: context)
        XCTAssertTrue(inPersonal.label === personalAdmin)

        // Making it global again is always fine.
        TaxonomyOps.setScope(of: meetings, to: nil, in: context)
        XCTAssertNil(meetings.profile)
    }

    @MainActor
    func testSetScopeOfTagCopiesForOtherProfiles() throws {
        let context = try TestSupport.makeContext()
        let work = makeProfile("Work", in: context)
        let personal = makeProfile("Personal", in: context)
        let tag = TaxonomyOps.createTag(name: "review", in: context)
        let inPersonal = TestSupport.makeEndedSession(in: context, start: TestSupport.time(10), segmentMinutes: [30])
        inPersonal.profile = personal
        inPersonal.tagList = [tag]
        let point = LearningPoint(text: "Insight")
        context.insert(point)
        point.session = inPersonal
        point.tagList = [tag]
        try context.save()

        TaxonomyOps.setScope(of: tag, to: work, in: context)
        XCTAssertTrue(tag.profile === work)
        let copy = try XCTUnwrap(inPersonal.tagList.first)
        XCTAssertFalse(copy === tag)
        XCTAssertTrue(copy.profile === personal)
        XCTAssertTrue(point.tagList.first === copy)
    }

    // MARK: - 7. moveSession

    @MainActor
    func testMoveSessionMapsOrCopiesTaxonomy() throws {
        let context = try TestSupport.makeContext()
        let work = makeProfile("Work", in: context)
        let personal = makeProfile("Personal", in: context)
        let workDeep = TaxonomyOps.createLabel(name: "Deep", colorHex: "#111111", symbolName: "circle.fill",
                                               profile: work, in: context)
        let personalDeep = TaxonomyOps.createLabel(name: "deep", colorHex: "#222222", symbolName: "circle.fill",
                                                   profile: personal, in: context)
        let errands = TaxonomyOps.createLabel(name: "Errands", colorHex: "#333333", symbolName: "cart.fill",
                                              profile: work, in: context)
        let localTag = TaxonomyOps.createTag(name: "t1", profile: work, in: context)
        let globalTag = TaxonomyOps.createTag(name: "g1", in: context)

        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [30, 30],
                                                   label: workDeep)
        session.profile = work
        session.tagList = [localTag, globalTag]
        let segments = session.sortedSegments
        segments[0].label = workDeep
        segments[1].label = errands
        segments[1].tagList = [localTag]
        let point = LearningPoint(text: "Insight")
        context.insert(point)
        point.session = session
        point.tagList = [localTag]
        try context.save()

        XCTAssertEqual(SessionEditor.taxonomyCopiedByMove(of: session, to: personal), ["Errands", "t1"])

        SessionEditor.moveSession(session, to: personal, in: context)

        XCTAssertTrue(session.profile === personal)
        XCTAssertTrue(session.label === personalDeep, "same-name equivalent is mapped")
        XCTAssertTrue(segments[0].label === personalDeep)
        let errandsCopy = try XCTUnwrap(segments[1].label)
        XCTAssertFalse(errandsCopy === errands)
        XCTAssertEqual(errandsCopy.name, "Errands")
        XCTAssertTrue(errandsCopy.profile === personal, "missing one is copied")
        XCTAssertTrue(session.tagList.contains { $0 === globalTag }, "global items are kept")
        let tagCopy = try XCTUnwrap(session.tagList.first { $0.name == "t1" })
        XCTAssertFalse(tagCopy === localTag)
        XCTAssertTrue(tagCopy.profile === personal)
        XCTAssertTrue(segments[1].tagList.first === tagCopy, "one copy per item")
        XCTAssertTrue(point.tagList.first === tagCopy)
        XCTAssertTrue(errands.profile === work, "the source profile keeps its labels")
        XCTAssertEqual(SessionEditor.taxonomyCopiedByMove(of: session, to: personal), [], "already there")
        TestSupport.assertInvariants(session)
    }

    // MARK: - 8. ProfileOps.delete / setArchived

    @MainActor
    func testDeleteProfileMovingSessions() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let work = makeProfile("Work", in: context)
        let side = makeProfile("Side", in: context)
        let label = TaxonomyOps.createLabel(name: "L", colorHex: "#111111", symbolName: "circle.fill",
                                            profile: side, in: context)
        let tag = TaxonomyOps.createTag(name: "t", profile: side, in: context)
        let session = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10],
                                                   label: label)
        session.profile = side
        session.tagList = [tag]
        settings.quickStartProfileID = side.uuid
        try context.save()

        XCTAssertEqual(ProfileOps.delete(side, .moveSessions(toProfileID: side.uuid), settings: settings, in: context),
                       .invalidTarget)
        XCTAssertEqual(ProfileOps.delete(side, .moveSessions(toProfileID: UUID()), settings: settings, in: context),
                       .invalidTarget)
        XCTAssertEqual(ProfileOps.delete(side, .moveSessions(toProfileID: work.uuid), settings: settings, in: context),
                       .ok)
        XCTAssertTrue(session.profile === work)
        XCTAssertTrue(label.profile === work, "locals stay local, now to the target")
        XCTAssertTrue(tag.profile === work)
        XCTAssertNil(settings.quickStartProfileID)
        XCTAssertEqual(ProfileOps.allProfiles(in: context).count, 1)

        XCTAssertEqual(ProfileOps.delete(work, .deleteSessions, settings: settings, in: context), .lastProfile)
        XCTAssertEqual(ProfileOpResult.lastProfile.message, "Keep at least one profile.")
        XCTAssertEqual(ProfileOpResult.sessionRunning.message, "Stop the session first.")
        XCTAssertEqual(ProfileOpResult.invalidTarget.message, "Choose another profile.")
        XCTAssertNil(ProfileOpResult.ok.message)
    }

    @MainActor
    func testDeleteProfileDeletingSessions() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let work = makeProfile("Work", in: context)
        let side = makeProfile("Side", in: context)
        let used = TaxonomyOps.createLabel(name: "used", colorHex: "#111111", symbolName: "circle.fill",
                                           profile: side, in: context)
        let unused = TaxonomyOps.createLabel(name: "unused", colorHex: "#111111", symbolName: "circle.fill",
                                             profile: side, in: context)
        let usedTag = TaxonomyOps.createTag(name: "usedTag", profile: side, in: context)
        let unusedTag = TaxonomyOps.createTag(name: "unusedTag", profile: side, in: context)
        let sideSession = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10],
                                                       label: unused)
        sideSession.profile = side
        sideSession.tagList = [unusedTag]
        let outside = TestSupport.makeEndedSession(in: context, start: TestSupport.time(10), segmentMinutes: [10])
        outside.profile = work
        outside.sortedSegments[0].label = used
        outside.tagList = [usedTag]
        let running = WorkSession(startedAt: TestSupport.time(11))
        context.insert(running)
        running.profile = side
        let sideSessionID = sideSession.uuid
        try context.save()

        XCTAssertEqual(ProfileOps.delete(side, .deleteSessions, settings: settings, in: context), .sessionRunning)
        XCTAssertEqual(ProfileOps.allProfiles(in: context).count, 2)

        SessionEditor.endSession(running, at: TestSupport.time(12))
        try context.save()
        XCTAssertEqual(ProfileOps.delete(side, .deleteSessions, settings: settings, in: context), .ok)

        let sessionIDs = try context.fetch(FetchDescriptor<WorkSession>()).map(\.uuid)
        XCTAssertFalse(sessionIDs.contains(sideSessionID))
        XCTAssertTrue(sessionIDs.contains(outside.uuid))
        let labelNames = try context.fetch(FetchDescriptor<WorkLabel>()).map(\.name)
        XCTAssertEqual(labelNames, ["used"], "used locals are kept, the rest deleted")
        XCTAssertNil(used.profile, "kept locals become global")
        let tagNames = try context.fetch(FetchDescriptor<WorkTag>()).map(\.name)
        XCTAssertEqual(tagNames, ["usedTag"])
        XCTAssertNil(usedTag.profile)
        XCTAssertEqual(ProfileOps.allProfiles(in: context).map(\.uuid), [work.uuid])
    }

    @MainActor
    func testSetArchivedRefusesLastActiveProfile() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let work = makeProfile("Work", in: context)
        XCTAssertEqual(ProfileOps.setArchived(work, true, settings: settings, in: context), .lastProfile)
        XCTAssertFalse(work.isArchived)

        let side = makeProfile("Side", in: context)
        settings.quickStartProfileID = side.uuid
        XCTAssertEqual(ProfileOps.setArchived(side, true, settings: settings, in: context), .ok)
        XCTAssertTrue(side.isArchived)
        XCTAssertNil(settings.quickStartProfileID, "quick start cleared when its profile is archived")
        XCTAssertEqual(ProfileOps.setArchived(work, true, settings: settings, in: context), .lastProfile)
        XCTAssertEqual(ProfileOps.setArchived(side, false, settings: settings, in: context), .ok)
        XCTAssertFalse(side.isArchived)
    }

    // MARK: - 9. ProfileStore

    @MainActor
    func testProfileStoreSelectionPersistsAndFallsBack() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        let r = makeProfile("R", in: context)

        let store = ProfileStore(context: context, settings: settings)
        XCTAssertEqual(store.profiles.map(\.uuid), [p.uuid, q.uuid, r.uuid])
        XCTAssertTrue(store.activeProfile === p, "fallback: first by sortIndex")
        XCTAssertTrue(store.hasMultipleProfiles)
        store.select(q)
        XCTAssertEqual(store.activeProfileID, q.uuid)
        XCTAssertEqual(store.activeScope, ProfileScope(profileID: q.uuid))

        let second = ProfileStore(context: context, settings: settings)
        XCTAssertTrue(second.activeProfile === q, "selection persists across instances")
        second.selectNext()
        XCTAssertTrue(second.activeProfile === r)
        second.selectNext()
        XCTAssertTrue(second.activeProfile === p, "wraps")
        second.select(id: q.uuid)
        XCTAssertTrue(second.activeProfile === q)

        // Archived selection: fallback without overwriting the stored id.
        q.isArchived = true
        try context.save()
        second.reload()
        XCTAssertTrue(second.activeProfile === p)
        XCTAssertEqual(second.archivedProfiles.map(\.uuid), [q.uuid])
        XCTAssertEqual(settings.defaults.string(forKey: ProfileStore.activeProfileKey), q.uuidString)
        second.select(q)
        XCTAssertTrue(second.activeProfile === p, "archived profiles can't be selected")
        q.isArchived = false
        try context.save()
        second.reload()
        XCTAssertTrue(second.activeProfile === q, "a profile that reappears is selected again")

        // Deleted selection.
        context.delete(q)
        try context.save()
        second.reload()
        XCTAssertTrue(second.activeProfile === p)
        XCTAssertNotNil(settings.defaults.string(forKey: ProfileStore.activeProfileKey))
    }

    @MainActor
    func testQuickStartProfileResolution() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        let store = ProfileStore(context: context, settings: settings)
        store.select(p)

        XCTAssertNil(settings.quickStartProfileID)
        XCTAssertTrue(store.quickStartProfile === p, "nil = current profile")
        settings.quickStartProfileID = q.uuid
        XCTAssertTrue(store.quickStartProfile === q)
        XCTAssertEqual(store.quickStartProfileID, q.uuid)
        q.isArchived = true
        try context.save()
        store.reload()
        XCTAssertTrue(store.quickStartProfile === p, "an archived quick-start profile falls back to the current one")

        // The setting persists.
        XCTAssertEqual(AppSettings(defaults: settings.defaults).quickStartProfileID, q.uuid)
    }

    @MainActor
    func testProfileStoreCreateArchiveDelete() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let work = makeProfile("Work", in: context)
        let store = ProfileStore(context: context, settings: settings)
        XCTAssertFalse(store.hasMultipleProfiles)

        let personal = store.createProfile(name: "  Personal ", colorHex: "#27AE60", symbolName: "house.fill", select: true)
        XCTAssertEqual(personal.name, "Personal")
        XCTAssertEqual(personal.sortIndex, 1)
        XCTAssertTrue(store.activeProfile === personal)
        XCTAssertEqual(store.profiles.count, 2)

        XCTAssertEqual(store.setArchived(personal, true), .ok)
        XCTAssertTrue(store.activeProfile === work, "archiving the current selects the fallback")
        XCTAssertEqual(store.setArchived(work, true), .lastProfile)
        XCTAssertEqual(store.setArchived(personal, false), .ok)
        store.select(personal)

        XCTAssertEqual(store.delete(personal, .moveSessions(toProfileID: work.uuid)), .ok)
        XCTAssertTrue(store.activeProfile === work)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.delete(work, .deleteSessions), .lastProfile)
    }

    // MARK: - 10. Engine

    @MainActor
    func testEngineStartsInProfileWithOfferedLabels() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        let pLabel = TaxonomyOps.createLabel(name: "PL", colorHex: "#111111", symbolName: "circle.fill",
                                             profile: p, in: context)
        let qLabel = TaxonomyOps.createLabel(name: "QL", colorHex: "#111111", symbolName: "circle.fill",
                                             profile: q, in: context)
        let global = TaxonomyOps.createLabel(name: "G", colorHex: "#111111", symbolName: "circle.fill", in: context)
        let qTag = TaxonomyOps.createTag(name: "qt", profile: q, in: context)
        let store = ProfileStore(context: context, settings: settings)
        store.select(p)
        let engine = SessionEngine(context: context, settings: settings, profiles: store)

        XCTAssertTrue(engine.defaultLabel() === pLabel, "nil → current profile")
        XCTAssertTrue(engine.defaultLabel(for: q) === qLabel)
        settings.defaultLabelID = pLabel.uuid   // legacy setting is ignored once profiles exist
        XCTAssertFalse(engine.defaultLabel(for: q) === pLabel, "never another profile's local label")
        q.defaultLabelUUID = global.uuid
        XCTAssertTrue(engine.defaultLabel(for: q) === global)
        q.defaultLabelUUID = pLabel.uuid
        XCTAssertTrue(engine.defaultLabel(for: q) === qLabel, "a default that isn't offered is ignored")

        let first = engine.start(label: qLabel, tags: [qTag], at: TestSupport.time(9))
        XCTAssertTrue(first.profile === p, "start() uses the current profile")
        XCTAssertTrue(first.label === pLabel, "a label from another profile is replaced by the default")
        XCTAssertTrue(first.sortedSegments.first?.label === pLabel)
        XCTAssertTrue(first.tagList.isEmpty, "tags not offered are dropped")
        XCTAssertTrue(engine.activeSessionProfile === p)
        XCTAssertEqual(engine.activeSessionProfileID, p.uuid)
        engine.stop(at: TestSupport.time(10))
        engine.completeReview()

        let second = engine.start(label: qLabel, tags: [qTag], at: TestSupport.time(11), profile: q)
        XCTAssertTrue(second.profile === q, "start(profile:) uses the one given")
        XCTAssertTrue(second.label === qLabel)
        XCTAssertEqual(second.tagList.map(\.uuid), [qTag.uuid])
        XCTAssertEqual(engine.contextProfileID, q.uuid, "the running session's profile while active")
        engine.stop(at: TestSupport.time(11, 30))
        engine.completeReview()
        XCTAssertEqual(engine.contextProfileID, p.uuid, "the current profile while idle")

        let now = TestSupport.time(12)
        XCTAssertEqual(engine.totalActiveToday(now: now, scope: ProfileScope(profileID: p.uuid)), 3600, accuracy: 0.001)
        XCTAssertEqual(engine.totalActiveToday(now: now, scope: ProfileScope(profileID: q.uuid)), 1800, accuracy: 0.001)
        XCTAssertEqual(engine.totalActiveToday(now: now), 5400, accuracy: 0.001)
    }

    // MARK: - 11. Takeaways per profile

    @MainActor
    func testTakeawaysArePerProfile() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        settings.showEndSessionSheet = false
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        let store = ProfileStore(context: context, settings: settings)
        store.select(p)
        let engine = SessionEngine(context: context, settings: settings, profiles: store)

        let inP = engine.start(label: nil, at: TestSupport.time(9))
        inP.overlaySummary = "P takeaway"
        inP.showInOverlay = true
        engine.stop(at: TestSupport.time(9, 30))
        let inQ = engine.start(label: nil, at: TestSupport.time(10), profile: q)
        inQ.overlaySummary = "Q takeaway"
        inQ.showInOverlay = true
        engine.stop(at: TestSupport.time(10, 30))

        XCTAssertEqual(engine.takeaway(for: p.uuid)?.text, "P takeaway")
        XCTAssertEqual(engine.takeaway(for: p.uuid)?.profileID, p.uuid)
        XCTAssertEqual(engine.takeaway(for: q.uuid)?.text, "Q takeaway")
        XCTAssertEqual(engine.lastTakeaway?.text, "P takeaway", "follows the current profile")
        store.select(q)
        XCTAssertEqual(engine.lastTakeaway?.text, "Q takeaway")

        engine.dismissTakeaway(engine.takeaway(for: p.uuid))
        XCTAssertNil(engine.takeaway(for: p.uuid))
        XCTAssertFalse(inP.showInOverlay)
        XCTAssertEqual(engine.takeaway(for: q.uuid)?.text, "Q takeaway", "retiring P's takeaway leaves Q's")
        XCTAssertTrue(inQ.showInOverlay)
    }

    // MARK: - 13. Search

    @MainActor
    func testScopedSearch() throws {
        let context = try TestSupport.makeContext()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        let inP = TestSupport.makeEndedSession(in: context, start: TestSupport.time(9), segmentMinutes: [10])
        inP.title = "Alpha review"
        inP.profile = p
        let inQ = TestSupport.makeEndedSession(in: context, start: TestSupport.time(10), segmentMinutes: [10])
        inQ.title = "Alpha planning"
        inQ.profile = q
        try context.save()

        let scopeP = ProfileScope(profileID: p.uuid)
        XCTAssertEqual(SearchService.filter([inP, inQ], query: "alpha", scope: scopeP).map(\.uuid), [inP.uuid])
        XCTAssertEqual(SearchService.filter([inP, inQ], query: "", scope: scopeP).map(\.uuid), [inP.uuid])
        XCTAssertEqual(SearchService.filter([inP, inQ], query: "alpha", scope: .allProfiles).count, 2)
        XCTAssertTrue(SearchService.filter([inP, inQ], query: "planning", scope: scopeP).isEmpty)
    }

    // MARK: - Taxonomy targets

    @MainActor
    func testReassignmentAndMergeTargetsKeepInvariant() throws {
        let context = try TestSupport.makeContext()
        let p = makeProfile("P", in: context)
        let q = makeProfile("Q", in: context)
        func label(_ name: String, _ profile: WorkProfile?) -> WorkLabel {
            TaxonomyOps.createLabel(name: name, colorHex: "#111111", symbolName: "circle.fill", profile: profile,
                                    in: context)
        }
        let g1 = label("G1", nil)
        let g2 = label("G2", nil)
        let archived = label("Old", nil)
        archived.isArchived = true
        let p1 = label("P1", p)
        let p2 = label("P2", p)
        let q1 = label("Q1", q)
        let all = [g1, g2, archived, p1, p2, q1]

        XCTAssertEqual(TaxonomyOps.reassignmentTargets(for: g1, among: all).map(\.name), ["G2"])
        XCTAssertEqual(TaxonomyOps.reassignmentTargets(for: p1, among: all).map(\.name), ["G1", "G2", "P2"])

        let tg = TaxonomyOps.createTag(name: "tg", in: context)
        let tp1 = TaxonomyOps.createTag(name: "tp1", profile: p, in: context)
        let tp2 = TaxonomyOps.createTag(name: "tp2", profile: p, in: context)
        let tq = TaxonomyOps.createTag(name: "tq", profile: q, in: context)
        let tags = [tg, tp1, tp2, tq]
        XCTAssertEqual(TaxonomyOps.mergeTargets(for: tg, among: tags).map(\.name), [])
        XCTAssertEqual(TaxonomyOps.mergeTargets(for: tp1, among: tags).map(\.name), ["tg", "tp2"])
    }

    @MainActor
    func testDeleteAndMergeLabelUpdateProfileDefaults() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let p = makeProfile("P", in: context)
        let a = TaxonomyOps.createLabel(name: "A", colorHex: "#111111", symbolName: "circle.fill", in: context)
        let b = TaxonomyOps.createLabel(name: "B", colorHex: "#111111", symbolName: "circle.fill", in: context)
        p.defaultLabelUUID = a.uuid
        TaxonomyOps.mergeLabel(a, into: b, settings: settings, in: context)
        XCTAssertEqual(p.defaultLabelUUID, b.uuid, "merge: the default follows")
        TaxonomyOps.deleteLabel(b, reassignTo: nil, settings: settings, in: context)
        XCTAssertNil(p.defaultLabelUUID, "delete: the default is cleared")
    }
}
