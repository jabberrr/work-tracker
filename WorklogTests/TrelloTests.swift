import SwiftData
import XCTest
@testable import Worklog

/// Trello activity logging: the pure action mapper and summaries, the attach rules (window, board filter, dedupe,
/// cursor), auth URL/token helpers, the model relationship, export/import round trips and dedupe.
final class TrelloTests: XCTestCase {

    // MARK: - Fixtures

    private static let board = #"{"id": "b1", "name": "Product", "shortLink": "BRD1"}"#
    private static let card = #""card": {"id": "c1", "name": "Fix login", "idShort": 7, "shortLink": "AbC123"}"#

    /// A Trello action JSON object (dictionary) with the given type and extra `data` members.
    private func action(_ type: String, id: String = "a1", date: String = "2026-10-23T09:15:02.123Z",
                        data: String) -> [String: Any] {
        let json = #"{"id": "\#(id)", "type": "\#(type)", "date": "\#(date)", "data": {\#(data), "board": \#(Self.board)}}"#
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return (object as? [String: Any]) ?? [:]
    }

    private func mapped(_ type: String, data: String) throws -> TrelloMappedAction {
        try XCTUnwrap(TrelloActionMapper.map(action(type, data: data)))
    }

    private func summary(_ m: TrelloMappedAction) -> String {
        TrelloActivity.summary(kind: m.kind, cardName: m.cardName, listName: m.listName,
                               fromListName: m.fromListName, detail: m.detail)
    }

    private static let referenceDate: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026; components.month = 10; components.day = 23
        components.hour = 9; components.minute = 15; components.second = 2
        components.nanosecond = 123_000_000
        return components.date!
    }()

    // MARK: - Mapper

    func testOnlyTheMembersOwnActionsAreKept() {
        let page: [Any] = [
            ["id": "a1", "idMemberCreator": "me"],
            ["id": "a2", "idMemberCreator": "someone-else"],
            ["id": "a3"],
            "not an action",
        ]
        let kept = TrelloActionMapper.madeBy("me", page).compactMap { ($0 as? [String: Any])?["id"] as? String }
        XCTAssertEqual(kept, ["a1"])
    }

    func testCreateCard() throws {
        let m = try mapped("createCard", data: Self.card + #", "list": {"id": "l1", "name": "Doing"}"#)
        XCTAssertEqual(m.kind, .created)
        XCTAssertEqual(m.actionID, "a1")
        XCTAssertEqual(m.occurredAt.timeIntervalSince1970, Self.referenceDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(m.cardName, "Fix login")
        XCTAssertEqual(m.cardShortLink, "AbC123")
        XCTAssertEqual(m.boardID, "b1")
        XCTAssertEqual(m.boardName, "Product")
        XCTAssertEqual(m.listName, "Doing")
        XCTAssertEqual(summary(m), "Added \u{201C}Fix login\u{201D} to Doing")
    }

    func testMoveBetweenLists() throws {
        let m = try mapped("updateCard", data: Self.card + #", "old": {"idList": "l1"}, "#
            + #""listBefore": {"id": "l1", "name": "Doing"}, "listAfter": {"id": "l2", "name": "Done"}"#)
        XCTAssertEqual(m.kind, .moved)
        XCTAssertEqual(m.fromListName, "Doing")
        XCTAssertEqual(m.listName, "Done")
        XCTAssertEqual(summary(m), "Moved \u{201C}Fix login\u{201D} from Doing to Done")
    }

    func testArchiveAndRestore() throws {
        let archived = try mapped("updateCard", data: #""card": {"id": "c1", "name": "Fix login", "closed": true}, "#
            + #""old": {"closed": false}, "list": {"id": "l1", "name": "Done"}"#)
        XCTAssertEqual(archived.kind, .archived)
        XCTAssertEqual(summary(archived), "Archived \u{201C}Fix login\u{201D}")

        let restored = try mapped("updateCard", data: #""card": {"id": "c1", "name": "Fix login", "closed": false}, "#
            + #""old": {"closed": true}"#)
        XCTAssertEqual(restored.kind, .unarchived)
        XCTAssertEqual(summary(restored), "Restored \u{201C}Fix login\u{201D}")

        // No current value on the card: inferred from the old one.
        let inferred = try mapped("updateCard", data: #""card": {"id": "c1", "name": "X"}, "old": {"closed": false}"#)
        XCTAssertEqual(inferred.kind, .archived)
    }

    func testCompleteAndReopen() throws {
        let done = try mapped("updateCard", data: #""card": {"id": "c1", "name": "Fix login", "dueComplete": true}, "#
            + #""old": {"dueComplete": false}"#)
        XCTAssertEqual(done.kind, .completed)
        XCTAssertEqual(summary(done), "Completed \u{201C}Fix login\u{201D}")

        let reopened = try mapped("updateCard", data: #""card": {"id": "c1", "name": "Fix login", "dueComplete": false}, "#
            + #""old": {"dueComplete": true}"#)
        XCTAssertEqual(reopened.kind, .reopened)
        XCTAssertEqual(summary(reopened), "Reopened \u{201C}Fix login\u{201D}")
    }

    func testRename() throws {
        let m = try mapped("updateCard", data: #""card": {"id": "c1", "name": "Fix sign-in"}, "old": {"name": "Fix login"}"#)
        XCTAssertEqual(m.kind, .renamed)
        XCTAssertEqual(m.detail, "Fix login")
        XCTAssertEqual(summary(m), "Renamed \u{201C}Fix login\u{201D} to \u{201C}Fix sign-in\u{201D}")
    }

    func testIrrelevantCardUpdatesAreNotLogged() {
        XCTAssertNil(TrelloActionMapper.map(action("updateCard", data: Self.card + #", "old": {"pos": 16384}"#)))
        XCTAssertNil(TrelloActionMapper.map(action("updateCard", data: Self.card + #", "old": {"desc": ""}"#)))
        XCTAssertNil(TrelloActionMapper.map(action("updateCard", data: Self.card + #", "old": {"due": null}"#)))
        XCTAssertNil(TrelloActionMapper.map(action("updateCard", data: Self.card)))
        XCTAssertNil(TrelloActionMapper.map(action("addMemberToCard", data: Self.card)))
    }

    func testMalformedActionsAreDropped() {
        XCTAssertNil(TrelloActionMapper.map(action("createCard", date: "yesterday", data: Self.card)))
        XCTAssertNil(TrelloActionMapper.map(action("createCard", id: "", data: Self.card)))
        XCTAssertNil(TrelloActionMapper.map([:]))
        // Dates without fractional seconds are fine too.
        XCTAssertNotNil(TrelloActionMapper.map(action("createCard", date: "2026-10-23T09:15:02Z", data: Self.card)))
    }

    func testCommentExcerpt() throws {
        let long = String(repeating: "word ", count: 80)
        let m = try mapped("commentCard", data: Self.card + #", "text": "First line\n\nsecond   line "# + "\(long)\"")
        XCTAssertEqual(m.kind, .commented)
        XCTAssertTrue(m.detail.hasPrefix("First line second line word"))
        XCTAssertFalse(m.detail.contains("\n"))
        XCTAssertLessThanOrEqual(m.detail.count, TrelloActionMapper.detailLimit)
        XCTAssertTrue(m.detail.hasSuffix("\u{2026}"))
        XCTAssertEqual(summary(m), "Commented on \u{201C}Fix login\u{201D}")
        XCTAssertEqual(TrelloActionMapper.excerpt("  short\ttext \n"), "short text")
    }

    func testChecklistItems() throws {
        let checked = try mapped("updateCheckItemStateOnCard", data: Self.card
            + #", "checklist": {"id": "k1", "name": "Tasks"}, "checkItem": {"id": "i1", "name": "Write tests", "state": "complete"}"#)
        XCTAssertEqual(checked.kind, .checkedItem)
        XCTAssertEqual(checked.detail, "Write tests")
        XCTAssertEqual(summary(checked), "Checked \u{201C}Write tests\u{201D} on \u{201C}Fix login\u{201D}")

        let unchecked = try mapped("updateCheckItemStateOnCard", data: Self.card
            + #", "checkItem": {"id": "i1", "name": "Write tests", "state": "incomplete"}"#)
        XCTAssertEqual(unchecked.kind, .uncheckedItem)
        XCTAssertEqual(summary(unchecked), "Unchecked \u{201C}Write tests\u{201D} on \u{201C}Fix login\u{201D}")
    }

    func testDeleteMoveToBoardCopyAndConvert() throws {
        let deleted = try mapped("deleteCard", data: #""card": {"id": "c1", "idShort": 7, "shortLink": "AbC123"}, "#
            + #""list": {"id": "l1", "name": "Doing"}"#)
        XCTAssertEqual(deleted.kind, .deleted)
        XCTAssertEqual(summary(deleted), "Deleted a card from Doing")

        let moved = try mapped("moveCardToBoard", data: Self.card + #", "boardSource": {"id": "b0"}"#)
        XCTAssertEqual(moved.kind, .movedToBoard)
        XCTAssertEqual(summary(moved), "Moved \u{201C}Fix login\u{201D} to another board")

        let copied = try mapped("copyCard", data: Self.card + #", "cardSource": {"id": "c0", "name": "Template"}"#)
        XCTAssertEqual(copied.kind, .copied)
        XCTAssertEqual(summary(copied), "Copied \u{201C}Fix login\u{201D}")

        let converted = try mapped("convertToCardFromCheckItem", data: Self.card + #", "list": {"id": "l1", "name": "To do"}"#)
        XCTAssertEqual(converted.kind, .created)
        XCTAssertEqual(summary(converted), "Added \u{201C}Fix login\u{201D} to To do")
    }

    func testMapAllSkipsUnloggedEntries() throws {
        let json = """
        [{"id": "a2", "type": "commentCard", "date": "2026-10-23T09:20:00.000Z", "data": {"text": "hi"}},
         {"id": "a3", "type": "updateCard", "date": "2026-10-23T09:21:00.000Z", "data": {"old": {"pos": 1}}},
         42]
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(TrelloActionMapper.mapAll(object).map(\.actionID), ["a2"])
        XCTAssertEqual(TrelloActionMapper.mapAll(["not": "an array"]), [])
    }

    func testSummariesAndSymbolsCoverEveryKind() {
        for kind in TrelloActivityKind.allCases {
            XCTAssertFalse(kind.systemImage.isEmpty)
            XCTAssertFalse(TrelloActivity.summary(kind: kind, cardName: "X", listName: "", fromListName: "",
                                                  detail: "").isEmpty)
        }
        XCTAssertEqual(TrelloActivity.summary(kind: .other, cardName: "X", listName: "", fromListName: "", detail: ""),
                       "Updated \u{201C}X\u{201D}")
        XCTAssertEqual(TrelloActivity.summary(kind: .moved, cardName: "X", listName: "Done", fromListName: "",
                                              detail: ""), "Moved \u{201C}X\u{201D} to Done")
        XCTAssertEqual(TrelloActivity.summary(kind: .completed, cardName: " ", listName: "", fromListName: "",
                                              detail: ""), "Completed a card")
    }

    // MARK: - Attach rules

    private func mappedAction(_ id: String, at date: Date, board: String = "b1") -> TrelloMappedAction {
        TrelloMappedAction(actionID: id, occurredAt: date, kind: .created, cardName: id, boardID: board)
    }

    func testBoardFilter() {
        let onB1 = mappedAction("x", at: .now, board: "b1")
        XCTAssertTrue(TrelloActionMapper.isOnWatchedBoard(onB1, watched: []))
        XCTAssertTrue(TrelloActionMapper.isOnWatchedBoard(onB1, watched: ["b1", "b2"]))
        XCTAssertFalse(TrelloActionMapper.isOnWatchedBoard(onB1, watched: ["b2"]))
    }

    @MainActor   // TestSupport is main-actor isolated
    func testActionsToAttachWindowFilterAndDedupe() {
        let start = TestSupport.time(9)
        let end = TestSupport.time(10)
        let actions = [
            mappedAction("late", at: end.addingTimeInterval(1)),
            mappedAction("b", at: start.addingTimeInterval(120)),
            mappedAction("early", at: start.addingTimeInterval(-1)),
            mappedAction("a", at: start),
            mappedAction("known", at: start.addingTimeInterval(60)),
            mappedAction("b", at: start.addingTimeInterval(120)),            // same action twice in a response
            mappedAction("other-board", at: start.addingTimeInterval(30), board: "b9"),
            mappedAction("edge", at: end),
        ]
        let result = TrelloActionMapper.actionsToAttach(actions, existingActionIDs: ["known"],
                                                        watchedBoardIDs: ["b1"], start: start, end: end)
        XCTAssertEqual(result.map(\.actionID), ["a", "b", "edge"])

        // Running session: no upper bound; empty board filter = all boards.
        let running = TrelloActionMapper.actionsToAttach(actions, existingActionIDs: [], watchedBoardIDs: [],
                                                         start: start, end: nil)
        XCTAssertEqual(running.map(\.actionID), ["a", "other-board", "known", "b", "edge", "late"])
    }

    @MainActor   // TestSupport is main-actor isolated
    func testFetchStartUsesTheCursorWithOverlap() {
        let start = TestSupport.time(9)
        XCTAssertEqual(TrelloActionMapper.fetchStart(sessionStart: start, cursor: nil), start)
        XCTAssertEqual(TrelloActionMapper.fetchStart(sessionStart: start, cursor: start.addingTimeInterval(30)), start,
                       "never before the session start")
        XCTAssertEqual(TrelloActionMapper.fetchStart(sessionStart: start, cursor: start.addingTimeInterval(600)),
                       start.addingTimeInterval(540))
        XCTAssertEqual(TrelloService.cursorKey(for: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
                       "trello.cursor.00000000-0000-0000-0000-000000000001")
    }

    func testDateFormattingRoundTrips() throws {
        let text = TrelloActionMapper.formatDate(Self.referenceDate)
        XCTAssertTrue(text.hasPrefix("2026-10-23T09:15:02."), text)
        XCTAssertTrue(text.hasSuffix("Z"), text)
        let parsed = try XCTUnwrap(TrelloActionMapper.parseDate(text))
        XCTAssertEqual(parsed.timeIntervalSince1970, Self.referenceDate.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Auth helpers

    func testAuthorizeURLs() throws {
        XCTAssertNil(TrelloAPI.authorizeURL(key: "", withCallback: true))
        let web = try XCTUnwrap(TrelloAPI.authorizeURL(key: "KEY", withCallback: true)).absoluteString
        XCTAssertTrue(web.hasPrefix("https://trello.com/1/authorize?"))
        for part in ["expiration=never", "name=Diptychon", "scope=read", "response_type=token", "key=KEY",
                     "callback_method=fragment", "return_url=diptychon-trello%3A%2F%2Fauth"] {
            XCTAssertTrue(web.contains(part), part)
        }
        let manual = try XCTUnwrap(TrelloAPI.authorizeURL(key: "KEY", withCallback: false)).absoluteString
        XCTAssertTrue(manual.contains("scope=read"))
        XCTAssertFalse(manual.contains("return_url"))
        XCTAssertFalse(manual.contains("callback_method"))
    }

    func testTokenParsing() throws {
        let callback = try XCTUnwrap(URL(string: "diptychon-trello://auth#token=ATTAabc123DEF"))
        XCTAssertEqual(TrelloAPI.token(fromCallback: callback), "ATTAabc123DEF")
        XCTAssertNil(TrelloAPI.token(fromCallback: try XCTUnwrap(URL(string: "diptychon-trello://auth#error=denied"))))
        XCTAssertNil(TrelloAPI.token(fromCallback: try XCTUnwrap(URL(string: "https://evil.example/#token=abc"))))

        XCTAssertEqual(TrelloAPI.normalizedToken("  abc123\n"), "abc123")
        XCTAssertEqual(TrelloAPI.normalizedToken("https://trello.com/x#token=abc123&x=1"), "abc123")
        XCTAssertNil(TrelloAPI.normalizedToken(""))
        XCTAssertNil(TrelloAPI.normalizedToken("not a token"))
    }

    func testCardURL() {
        XCTAssertEqual(TrelloActivity.cardURL(shortLink: "AbC123")?.absoluteString, "https://trello.com/c/AbC123")
        XCTAssertNil(TrelloActivity.cardURL(shortLink: ""))
        XCTAssertNil(TrelloActivity.cardURL(shortLink: "../x"))
    }

    // MARK: - Model

    @MainActor
    private func addActivity(_ actionID: String, kind: TrelloActivityKind = .created, card: String = "Fix login",
                             at date: Date, to session: WorkSession, in context: ModelContext,
                             uuid: UUID = UUID()) -> TrelloActivity {
        let activity = TrelloActivity(actionID: actionID, occurredAt: date, kind: kind, uuid: uuid)
        context.insert(activity)
        activity.cardName = card
        activity.cardShortLink = "AbC123"
        activity.boardName = "Product"
        activity.listName = "Doing"
        activity.session = session
        return activity
    }

    @MainActor
    func testSessionRelationshipSortingAndCascade() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        _ = addActivity("a2", at: start.addingTimeInterval(600), to: session, in: context)
        _ = addActivity("a1", at: start.addingTimeInterval(60), to: session, in: context)
        _ = addActivity("a2", at: start.addingTimeInterval(600), to: session, in: context)   // logged twice
        let unknown = addActivity("a3", at: start.addingTimeInterval(900), to: session, in: context)
        unknown.kindRaw = "somethingNewer"
        try context.save()

        XCTAssertEqual(session.sortedTrelloActivities.map(\.actionID), ["a1", "a2", "a3"])
        XCTAssertEqual(unknown.kind, .other)
        XCTAssertEqual(unknown.summary, "Updated \u{201C}Fix login\u{201D}")
        XCTAssertEqual(unknown.cardURL?.absoluteString, "https://trello.com/c/AbC123")

        try SessionEditor.deleteSession(session, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TrelloActivity>()), 0, "deleted with the session")
    }

    @MainActor
    func testRemovingOneActivity() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        let keep = addActivity("a1", at: start.addingTimeInterval(60), to: session, in: context)
        let remove = addActivity("a2", at: start.addingTimeInterval(120), to: session, in: context)
        try context.save()
        SessionEditor.deleteTrelloActivity(remove, in: context)
        XCTAssertEqual(session.sortedTrelloActivities.map(\.uuid), [keep.uuid])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TrelloActivity>()), 1)
    }

    @MainActor
    func testSearchMatchesCardNames() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        _ = addActivity("a1", card: "Fix the löGin flow", at: start, to: session, in: context)
        try context.save()
        XCTAssertEqual(SearchService.filter([session], query: "login").count, 1)
        XCTAssertEqual(SearchService.filter([session], query: "payments").count, 0)
    }

    // MARK: - Export / import

    @MainActor
    func testExportRoundTripIncludesActivities() throws {
        let source = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: source, start: start, segmentMinutes: [60])
        let moved = addActivity("a1", kind: .moved, at: start.addingTimeInterval(60), to: session, in: source)
        moved.fromListName = "To do"
        let comment = addActivity("a2", kind: .commented, at: start.addingTimeInterval(120), to: session, in: source)
        comment.detail = "Looks good"
        try source.save()

        let data = try ExportService(container: source.container).jsonData(includeAttachments: false)
        let archive = try ExportService.decodeArchive(from: data)
        XCTAssertEqual(archive.formatVersion, 2, "format version not bumped")
        XCTAssertEqual(archive.sessions.first?.trelloActivities?.map(\.actionID), ["a1", "a2"])

        let destination = try TestSupport.makeContext()
        _ = try ExportService(container: destination.container).importArchive(archive, mode: .replace)
        let copy = try XCTUnwrap(try destination.fetch(FetchDescriptor<WorkSession>()).first)
        let activities = copy.sortedTrelloActivities
        XCTAssertEqual(activities.map(\.uuid), [moved.uuid, comment.uuid])
        XCTAssertEqual(activities.map(\.kind), [.moved, .commented])
        XCTAssertEqual(activities[0].fromListName, "To do")
        XCTAssertEqual(activities[0].listName, "Doing")
        XCTAssertEqual(activities[0].boardName, "Product")
        XCTAssertEqual(activities[0].cardShortLink, "AbC123")
        XCTAssertEqual(activities[1].detail, "Looks good")
        XCTAssertEqual(activities[1].occurredAt, start.addingTimeInterval(120))
    }

    @MainActor
    func testMergeKeepsLocalActivitiesAndSkipsKnownActions() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        _ = addActivity("a1", at: start.addingTimeInterval(60), to: session, in: context)
        try context.save()
        let exporter = ExportService(container: context.container)
        var archive = try exporter.makeArchive(includeAttachments: false)

        // Locally: a newer action. In the archive: the same action a1 under another uuid, plus a new one.
        _ = addActivity("a9", at: start.addingTimeInterval(300), to: session, in: context)
        try context.save()
        archive.sessions[0].trelloActivities?.append(TrelloActivityDTO(
            id: UUID(), actionID: "a1", occurredAt: start.addingTimeInterval(60), kind: "created", cardName: "dup",
            cardShortLink: "", boardName: "", listName: "", fromListName: "", detail: ""))
        archive.sessions[0].trelloActivities?.append(TrelloActivityDTO(
            id: UUID(), actionID: "a5", occurredAt: start.addingTimeInterval(200), kind: "completed",
            cardName: "Fix login", cardShortLink: "", boardName: "", listName: "", fromListName: "", detail: ""))
        archive.sessions[0].modifiedAt = session.modifiedAt.addingTimeInterval(3600)

        let summary = try exporter.importArchive(archive, mode: .merge)
        XCTAssertEqual(summary.sessionsUpdated, 1)
        XCTAssertEqual(session.sortedTrelloActivities.map(\.actionID), ["a1", "a5", "a9"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TrelloActivity>()), 3)
    }

    @MainActor
    func testArchiveWithoutTrelloKeyDecodesAndImports() throws {
        let sessionID = UUID()
        let json = """
        {"formatVersion": 2, "exportedAt": "2026-06-10T12:00:00Z", "appVersion": "1.0", "includesAttachments": false,
         "labels": [], "tags": [], "profiles": [],
         "sessions": [{"id": "\(sessionID.uuidString)", "title": "Old", "startedAt": "2026-06-10T09:00:00Z",
           "endedAt": "2026-06-10T10:00:00Z", "pauseIntervals": [], "tagIDs": [], "learningText": "",
           "overlaySummary": "", "showInOverlay": false, "createdAt": "2026-06-10T09:00:00Z",
           "modifiedAt": "2026-06-10T10:00:00Z",
           "segments": [{"id": "\(UUID().uuidString)", "startedAt": "2026-06-10T09:00:00Z",
             "endedAt": "2026-06-10T10:00:00Z", "sortIndex": 0, "focus": "", "tagIDs": []}],
           "notes": [], "attachments": [], "learningPoints": []}]}
        """
        let archive = try ExportService.decodeArchive(from: Data(json.utf8))
        XCTAssertNil(archive.sessions.first?.trelloActivities)

        let context = try TestSupport.makeContext()
        let summary = try ExportService(container: context.container).importArchive(archive, mode: .replace)
        XCTAssertEqual(summary.sessionsInserted, 1)
        let session = try XCTUnwrap(try context.fetch(FetchDescriptor<WorkSession>()).first)
        XCTAssertEqual(session.uuid, sessionID)
        XCTAssertTrue(session.sortedTrelloActivities.isEmpty)

        // A session without activity exports without the key (archives look like before).
        let data = try ExportService(container: context.container).jsonData(includeAttachments: false)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("trelloActivities"))
    }

    @MainActor
    func testDeleteAllRemovesActivities() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        _ = addActivity("a1", at: start, to: session, in: context)
        try context.save()
        try ExportService(container: context.container).deleteAllData()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TrelloActivity>()), 0)
    }

    // MARK: - Dedupe

    @MainActor
    func testSessionDedupeMovesActivitiesTheSurvivorLacks() throws {
        let context = try TestSupport.makeContext()
        let id = UUID()
        let start = TestSupport.time(9)
        let survivor = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        survivor.uuid = id
        survivor.modifiedAt = start.addingTimeInterval(7200)
        let loser = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        loser.uuid = id
        loser.modifiedAt = start.addingTimeInterval(3600)
        _ = addActivity("a1", at: start, to: survivor, in: context)
        _ = addActivity("a1", at: start, to: loser, in: context)            // same action, other row
        _ = addActivity("a2", at: start.addingTimeInterval(60), to: loser, in: context)
        try context.save()

        SeedData.deduplicate(in: context)
        let sessions = try context.fetch(FetchDescriptor<WorkSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sortedTrelloActivities.map(\.actionID), ["a1", "a2"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TrelloActivity>()), 2)
    }

    @MainActor
    func testActivityDedupeKeepsTheSmallestUUID() throws {
        let context = try TestSupport.makeContext()
        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [60])
        let small = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let large = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        _ = addActivity("a1", at: start, to: session, in: context, uuid: large)
        _ = addActivity("a1", at: start, to: session, in: context, uuid: small)
        _ = addActivity("a2", at: start, to: session, in: context)
        try context.save()

        SeedData.deduplicate(in: context)
        let remaining = try context.fetch(FetchDescriptor<TrelloActivity>())
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains { $0.uuid == small })
        XCTAssertFalse(remaining.contains { $0.uuid == large })
    }

    // MARK: - Service

    @MainActor
    func testServiceInitialStateAndPersistedPreferences() throws {
        let context = try TestSupport.makeContext()
        let settings = TestSupport.makeSettings()
        let engine = SessionEngine(context: context, settings: settings)
        let keychain = KeychainStore(service: "WorklogTests.\(UUID().uuidString)")
        let service = TrelloService(context: context, settings: settings, engine: engine, keychain: keychain)
        service.start()   // no-op under XCTest: never touches the network

        XCTAssertEqual(service.connection, TrelloConfig.apiKey.isEmpty ? .notConfigured : .disconnected)
        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(service.isLoggingEnabled, "on by default")
        XCTAssertTrue(service.watchedBoardIDs.isEmpty)
        XCTAssertFalse(service.isTrackingActiveSession)
        XCTAssertEqual(service.manualAuthorizeURL == nil, TrelloConfig.apiKey.isEmpty)

        service.isLoggingEnabled = false
        service.watchedBoardIDs = ["b2", "b1"]
        let again = TrelloService(context: context, settings: settings, engine: engine, keychain: keychain)
        XCTAssertFalse(again.isLoggingEnabled)
        XCTAssertEqual(again.watchedBoardIDs, ["b1", "b2"])
        XCTAssertEqual(settings.defaults.stringArray(forKey: "trello.watchedBoardIDs"), ["b1", "b2"])
    }

    func testBoardsSortByName() {
        let boards = [TrelloBoard(id: "3", name: "zeta"), TrelloBoard(id: "1", name: "Alpha"),
                      TrelloBoard(id: "2", name: "beta")]
        XCTAssertEqual(TrelloService.sortedBoards(boards).map(\.id), ["1", "2", "3"])
    }
}
