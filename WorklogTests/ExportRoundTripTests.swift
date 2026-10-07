import SwiftData
import XCTest
@testable import Worklog

final class ExportRoundTripTests: XCTestCase {

    /// Builds a store with every kind of object. All dates are whole seconds (the archive uses ISO-8601).
    @MainActor
    private func populate(_ context: ModelContext) throws -> WorkSession {
        let label = WorkLabel(name: "Deep work", colorHex: "#5B8DEF", symbolName: "brain.head.profile", sortIndex: 0)
        let meetings = WorkLabel(name: "Meetings", colorHex: "#F2994A", symbolName: "person.2.fill", sortIndex: 1)
        context.insert(label)
        context.insert(meetings)
        let coding = WorkTag(name: "coding")
        let scoped = WorkTag(name: "swiftui", colorHex: "#FF0000")
        context.insert(coding)
        context.insert(scoped)
        scoped.label = label

        let start = TestSupport.time(9)
        let session = TestSupport.makeEndedSession(in: context, start: start, segmentMinutes: [30, 45], label: label)
        session.title = "Overlay, \"polish\"\nday"
        session.tagList = [coding]
        session.learningText = "Learned a lot"
        session.overlaySummary = "Short takeaway"
        session.showInOverlay = true
        session.pauseIntervals = [PauseInterval(start: start.addingTimeInterval(600), end: start.addingTimeInterval(900))]
        let segments = session.sortedSegments
        segments[0].label = label
        segments[1].label = meetings
        segments[1].tagList = [scoped]

        let note = Note(text: "A note", createdAt: start.addingTimeInterval(40 * 60))
        context.insert(note)
        note.session = session
        note.segment = segments[1]

        let attachment = Attachment(filename: "shot.png", data: Data([1, 2, 3, 4]), thumbnailData: Data([5, 6]),
                                    uti: "public.png", pixelWidth: 10, pixelHeight: 20)
        context.insert(attachment)
        attachment.caption = "Caption"
        attachment.createdAt = start
        attachment.session = session

        let point = LearningPoint(text: "Insight", createdAt: start, sortIndex: 0)
        context.insert(point)
        point.mastery = 4
        point.tagList = [coding, scoped]
        point.session = session

        session.recomputeStoredDuration()
        try context.save()
        return session
    }

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "WorklogTest-\(UUID().uuidString).\(ext)")
    }

    // MARK: - Round trip

    @MainActor
    func testJSONExportImportRoundTrip() throws {
        let sourceContext = try TestSupport.makeContext()
        let source = try populate(sourceContext)
        let exporter = ExportService(container: sourceContext.container)

        let url = temporaryURL("json")
        defer { try? FileManager.default.removeItem(at: url) }
        try exporter.exportJSON(to: url, includeAttachments: true)

        let destinationContext = try TestSupport.makeContext()
        let importer = ExportService(container: destinationContext.container)
        let summary = try importer.importArchive(from: url, mode: .replace)
        XCTAssertEqual(summary, ImportSummary(labels: 2, tags: 2, sessionsInserted: 1, sessionsUpdated: 0, attachments: 1))
        XCTAssertEqual(summary.description, "Imported 1 session (0 updated), 2 labels, 2 tags, 1 image.")

        let sessions = try destinationContext.fetch(FetchDescriptor<WorkSession>())
        XCTAssertEqual(sessions.count, 1)
        let copy = try XCTUnwrap(sessions.first)
        XCTAssertEqual(copy.uuid, source.uuid)
        XCTAssertEqual(copy.title, source.title)
        XCTAssertEqual(copy.startedAt, source.startedAt)
        XCTAssertEqual(copy.endedAt, source.endedAt)
        XCTAssertEqual(copy.pauseIntervals, source.pauseIntervals)
        XCTAssertEqual(copy.learningText, source.learningText)
        XCTAssertEqual(copy.overlaySummary, source.overlaySummary)
        XCTAssertTrue(copy.showInOverlay)
        XCTAssertEqual(copy.label?.uuid, source.label?.uuid)
        XCTAssertEqual(copy.tagList.map(\.uuid), source.tagList.map(\.uuid))
        XCTAssertEqual(copy.activeDuration(), source.activeDuration(), accuracy: 0.001)
        XCTAssertEqual(copy.storedActiveDuration, source.storedActiveDuration, accuracy: 0.001)

        let copySegments = copy.sortedSegments
        let sourceSegments = source.sortedSegments
        XCTAssertEqual(copySegments.map(\.uuid), sourceSegments.map(\.uuid))
        XCTAssertEqual(copySegments.map(\.startedAt), sourceSegments.map(\.startedAt))
        XCTAssertEqual(copySegments.map(\.endedAt), sourceSegments.map(\.endedAt))
        XCTAssertEqual(copySegments.map { $0.label?.name }, ["Deep work", "Meetings"])
        XCTAssertEqual(copySegments[1].tagList.map(\.name), ["swiftui"])
        TestSupport.assertInvariants(copy)

        let copyNote = try XCTUnwrap(copy.sortedNotes.first)
        XCTAssertEqual(copyNote.text, "A note")
        XCTAssertTrue(copyNote.segment === copySegments[1])

        let copyAttachment = try XCTUnwrap(copy.sortedAttachments.first)
        XCTAssertEqual(copyAttachment.data, Data([1, 2, 3, 4]))
        XCTAssertEqual(copyAttachment.thumbnailData, Data([5, 6]))
        XCTAssertEqual(copyAttachment.caption, "Caption")
        XCTAssertEqual(copyAttachment.uti, "public.png")
        XCTAssertEqual(copyAttachment.pixelWidth, 10)

        let copyPoint = try XCTUnwrap(copy.sortedLearningPoints.first)
        XCTAssertEqual(copyPoint.text, "Insight")
        XCTAssertEqual(copyPoint.mastery, 4)
        XCTAssertEqual(Set(copyPoint.tagList.map(\.name)), ["coding", "swiftui"])

        let tags = try destinationContext.fetch(FetchDescriptor<WorkTag>())
        XCTAssertEqual(tags.first(where: { $0.name == "swiftui" })?.label?.name, "Deep work", "tag parent label kept")
    }

    @MainActor
    func testMergeImportIsIdempotentAndUpdatesInPlace() throws {
        let context = try TestSupport.makeContext()
        let session = try populate(context)
        let exporter = ExportService(container: context.container)
        let archive = try exporter.makeArchive(includeAttachments: false)

        // Local edit after the export; merge restores the archived title and keeps attachment bytes.
        session.title = "Changed locally"
        try context.save()

        let summary = try exporter.importArchive(archive, mode: .merge)
        XCTAssertEqual(summary.sessionsInserted, 0)
        XCTAssertEqual(summary.sessionsUpdated, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkSession>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Segment>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkLabel>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkTag>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Attachment>()), 1)
        XCTAssertEqual(session.title, "Overlay, \"polish\"\nday")
        XCTAssertEqual(session.sortedAttachments.first?.data, Data([1, 2, 3, 4]), "bytes kept when archive has none")
        TestSupport.assertInvariants(session)

        // A second merge changes nothing structurally.
        _ = try exporter.importArchive(archive, mode: .merge)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkSession>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Note>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LearningPoint>()), 1)
    }

    @MainActor
    func testJSONDataDecodesWithMatchingStrategies() throws {
        let context = try TestSupport.makeContext()
        _ = try populate(context)
        let exporter = ExportService(container: context.container)
        let data = try exporter.jsonData(includeAttachments: true)
        let archive = try ExportService.decodeArchive(from: data)
        XCTAssertEqual(archive.formatVersion, ExportArchive.currentFormatVersion)
        XCTAssertTrue(archive.includesAttachments)
        XCTAssertEqual(archive.sessions.count, 1)
        XCTAssertEqual(archive.sessions.first?.segments.count, 2)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"formatVersion\" : 1"), "pretty-printed, sorted keys")
    }

    // MARK: - Guards & errors

    @MainActor
    func testReplaceAndDeleteAllAreBlockedWhileActive() throws {
        let context = try TestSupport.makeContext()
        let engine = SessionEngine(context: context, settings: TestSupport.makeSettings())
        engine.start(label: nil, at: TestSupport.time(9))
        let exporter = ExportService(container: context.container)
        let archive = try exporter.makeArchive(includeAttachments: false)

        XCTAssertThrowsError(try exporter.importArchive(archive, mode: .replace)) { error in
            guard case DataTransferError.sessionActive = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertThrowsError(try exporter.deleteAllData()) { error in
            guard case DataTransferError.sessionActive = error else { return XCTFail("unexpected \(error)") }
        }
        // Merge is allowed and never touches the running session.
        XCTAssertNoThrow(try exporter.importArchive(archive, mode: .merge))
        XCTAssertTrue(engine.isActive)
        XCTAssertNil(engine.activeSession?.endedAt)

        engine.stop(at: TestSupport.time(10))
        try exporter.deleteAllData()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkSession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Segment>()), 0)
    }

    @MainActor
    func testNewerFormatVersionIsRejected() throws {
        let json = #"{"formatVersion": 99, "exportedAt": "2026-10-07T10:00:00Z"}"#
        XCTAssertThrowsError(try ExportService.decodeArchive(from: Data(json.utf8))) { error in
            guard case DataTransferError.unsupportedVersion(let version) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(version, 99)
        }
        XCTAssertThrowsError(try ExportService.decodeArchive(from: Data("not json".utf8))) { error in
            guard case DataTransferError.decodingFailed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: - CSV

    @MainActor
    func testSessionsCSVQuotesFields() throws {
        let context = try TestSupport.makeContext()
        _ = try populate(context)
        let exporter = ExportService(container: context.container)

        let url = temporaryURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try exporter.exportSessionsCSV(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        let header = "id,title,label,tags,startedAt,endedAt,activeMinutes,pausedMinutes,segmentCount,noteCount,learningPointCount,learningText"
        XCTAssertTrue(text.hasPrefix(header + "\r\n"))
        XCTAssertTrue(text.contains("\"Overlay, \"\"polish\"\"\nday\""), "RFC 4180 quoting")
        XCTAssertTrue(text.contains(",70.00,5.00,2,1,1,"), "active/paused minutes and counts")

        let segmentsURL = temporaryURL("csv")
        defer { try? FileManager.default.removeItem(at: segmentsURL) }
        try exporter.exportSegmentsCSV(to: segmentsURL)
        let segmentsText = try String(contentsOf: segmentsURL, encoding: .utf8)
        XCTAssertTrue(segmentsText.hasPrefix("sessionID,sessionTitle,segmentID,index,startedAt,endedAt,activeMinutes,label,tags,focus\r\n"))
        XCTAssertEqual(segmentsText.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 3)
    }

    @MainActor
    func testDefaultFilename() {
        let name = ExportService.defaultFilename(ext: "json")
        XCTAssertTrue(name.hasPrefix("Worklog-Export-"))
        XCTAssertTrue(name.hasSuffix(".json"))
        XCTAssertEqual(name.count, "Worklog-Export-2026-10-07.json".count)
    }

    // MARK: - Search

    @MainActor
    func testSearchMatchesAcrossFieldsWithSnippets() throws {
        let context = try TestSupport.makeContext()
        let session = try populate(context)
        XCTAssertEqual(SearchService.terms(from: #"  Deep "deep work"  Café "#), ["deep", "deep work", "cafe"])
        XCTAssertTrue(SearchService.matches(session, terms: SearchService.terms(from: "meetings insight")))
        XCTAssertFalse(SearchService.matches(session, terms: SearchService.terms(from: "meetings nothinglikethis")))
        XCTAssertEqual(SearchService.filter([session], query: "").count, 1)
        XCTAssertEqual(SearchService.filter([session], query: "CAPTION").count, 1)

        let snippet = try XCTUnwrap(SearchService.snippet(for: session, query: "note"))
        XCTAssertEqual(snippet.field, .note)
        XCTAssertEqual(snippet.text, "A note")
        XCTAssertNil(SearchService.snippet(for: session, query: "polish"), "title-only matches have no snippet")

        let long = String(repeating: "x", count: 300) + " needle " + String(repeating: "y", count: 300)
        session.learningText = long
        let longSnippet = try XCTUnwrap(SearchService.snippet(for: session, query: "needle"))
        XCTAssertLessThanOrEqual(longSnippet.text.count, SearchService.snippetLength)
        XCTAssertTrue(longSnippet.text.contains("needle"))
        XCTAssertTrue(longSnippet.text.hasPrefix("…"))
        XCTAssertTrue(longSnippet.text.hasSuffix("…"))
    }
}
