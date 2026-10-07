import Foundation
import Observation
import SwiftData

extension Notification.Name { static let worklogDataDidImport = Notification.Name("worklogDataDidImport") }

enum ImportMode { case merge, replace }   // merge = upsert by uuid; replace = delete everything first

struct ImportSummary: Equatable {
    var labels = 0, tags = 0, sessionsInserted = 0, sessionsUpdated = 0, attachments = 0
    /// Merge only: sessions left alone because the local copy is running or at least as new as the archived one.
    var sessionsSkipped = 0

    /// "Imported 12 sessions (3 updated), 5 labels, 9 tags." (+ " 4 sessions were already up to date." on merge)
    var description: String {
        let sessions = sessionsInserted + sessionsUpdated
        var text = "Imported \(sessions) \(sessions == 1 ? "session" : "sessions") (\(sessionsUpdated) updated), "
            + "\(labels) \(labels == 1 ? "label" : "labels"), \(tags) \(tags == 1 ? "tag" : "tags")"
        if attachments > 0 {
            text += ", \(attachments) \(attachments == 1 ? "image" : "images")"
        }
        text += "."
        if sessionsSkipped > 0 {
            text += " \(sessionsSkipped) \(sessionsSkipped == 1 ? "session was" : "sessions were") already up to date."
        }
        return text
    }
}

enum DataTransferError: LocalizedError {
    case unsupportedVersion(Int), decodingFailed(String), sessionActive, writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This file was made by a newer version of Worklog (format \(version)). Update the app to import it."
        case .decodingFailed(let reason):
            "The file couldn't be read as a Worklog export: \(reason)"
        case .sessionActive:
            "Stop the running session first. Replacing or deleting all data isn't possible while a session is active."
        case .writeFailed(let reason):
            "The data couldn't be saved: \(reason)"
        }
    }
}

/// JSON/CSV export, JSON import (merge/replace) and delete-all. Used by Settings ▸ Data and BackupService.
@MainActor @Observable
final class ExportService {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Export

    func makeArchive(includeAttachments: Bool) throws -> ExportArchive {
        let labels = try context.fetch(FetchDescriptor<WorkLabel>(sortBy: [SortDescriptor(\WorkLabel.sortIndex)]))
        let tags = try context.fetch(FetchDescriptor<WorkTag>(sortBy: [SortDescriptor(\WorkTag.createdAt)]))
        let sessions = try context.fetch(FetchDescriptor<WorkSession>(sortBy: [SortDescriptor(\WorkSession.startedAt)]))
        return ExportArchive(
            formatVersion: ExportArchive.currentFormatVersion,
            exportedAt: .now,
            appVersion: AppConstants.appVersion,
            includesAttachments: includeAttachments,
            labels: labels.filter { !$0.isDeleted }.map { Self.dto($0) },
            tags: tags.filter { !$0.isDeleted }.map { Self.dto($0) },
            sessions: sessions.filter { !$0.isDeleted }.map { Self.dto($0, includeAttachments: includeAttachments) }
        )
    }

    func jsonData(includeAttachments: Bool) throws -> Data {
        let archive = try makeArchive(includeAttachments: includeAttachments)
        do {
            return try ExportArchive.makeEncoder().encode(archive)
        } catch {
            throw DataTransferError.writeFailed(error.localizedDescription)
        }
    }

    /// Atomic write.
    func exportJSON(to url: URL, includeAttachments: Bool) throws {
        let data = try jsonData(includeAttachments: includeAttachments)
        try write(data, to: url)
    }

    /// Sessions CSV header (RFC 4180 quoting, ISO-8601 dates, tags joined by "; "):
    /// id,title,label,tags,startedAt,endedAt,activeMinutes,pausedMinutes,segmentCount,noteCount,learningPointCount,learningText
    func exportSessionsCSV(to url: URL) throws {
        let now = Date.now
        let sessions = try context.fetch(FetchDescriptor<WorkSession>(sortBy: [SortDescriptor(\WorkSession.startedAt)]))
        var rows: [[String]] = [[
            "id", "title", "label", "tags", "startedAt", "endedAt", "activeMinutes", "pausedMinutes",
            "segmentCount", "noteCount", "learningPointCount", "learningText",
        ]]
        for session in sessions where !session.isDeleted {
            rows.append([
                session.uuid.uuidString,
                session.title,
                session.label?.name ?? "",
                session.allTags.map(\.name).joined(separator: "; "),
                Self.isoString(session.startedAt),
                session.endedAt.map(Self.isoString) ?? "",
                Self.minutes(session.activeDuration(at: now)),
                Self.minutes(session.pausedDuration(at: now)),
                String((session.segments ?? []).count),
                String((session.notes ?? []).count),
                String((session.learningPoints ?? []).count),
                session.learningText,
            ])
        }
        try write(Self.csvData(rows), to: url)
    }

    /// Header: sessionID,sessionTitle,segmentID,index,startedAt,endedAt,activeMinutes,label,tags,focus
    func exportSegmentsCSV(to url: URL) throws {
        let now = Date.now
        let sessions = try context.fetch(FetchDescriptor<WorkSession>(sortBy: [SortDescriptor(\WorkSession.startedAt)]))
        var rows: [[String]] = [[
            "sessionID", "sessionTitle", "segmentID", "index", "startedAt", "endedAt", "activeMinutes", "label", "tags", "focus",
        ]]
        for session in sessions where !session.isDeleted {
            for (index, segment) in session.sortedSegments.enumerated() {
                rows.append([
                    session.uuid.uuidString,
                    session.title,
                    segment.uuid.uuidString,
                    String(index),
                    Self.isoString(segment.startedAt),
                    (segment.endedAt ?? session.endedAt).map(Self.isoString) ?? "",
                    Self.minutes(segment.activeDuration(at: now)),
                    segment.effectiveLabel?.name ?? "",
                    segment.tagList.map(\.name).sorted().joined(separator: "; "),
                    segment.focus,
                ])
            }
        }
        try write(Self.csvData(rows), to: url)
    }

    /// "Worklog-Export-2026-10-07.json"
    static func defaultFilename(ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        return "Worklog-Export-\(formatter.string(from: .now)).\(cleanExt)"
    }

    // MARK: - Import

    func decodeArchive(from url: URL) throws -> ExportArchive {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DataTransferError.decodingFailed(error.localizedDescription)
        }
        var archive = try Self.decodeArchive(from: data)
        if let store = archive.attachmentStore, !store.isEmpty {
            let folder = url.deletingLastPathComponent().appending(path: store, directoryHint: .isDirectory)
            let missing = archive.rehydrateAttachments(from: folder)
            if missing > 0 {
                Log.persistence.error("\(missing) backup images are missing from \(store, privacy: .public)")
            }
        }
        return archive
    }

    /// Decodes archive JSON, checking the format version first so newer files fail with `.unsupportedVersion`.
    static func decodeArchive(from data: Data) throws -> ExportArchive {
        let decoder = ExportArchive.makeDecoder()
        struct VersionProbe: Decodable { var formatVersion: Int }
        do {
            let probe = try decoder.decode(VersionProbe.self, from: data)
            if probe.formatVersion > ExportArchive.currentFormatVersion {
                throw DataTransferError.unsupportedVersion(probe.formatVersion)
            }
        } catch let error as DataTransferError {
            throw error
        } catch {
            throw DataTransferError.decodingFailed(Self.describe(error))
        }
        do {
            return try decoder.decode(ExportArchive.self, from: data)
        } catch {
            throw DataTransferError.decodingFailed(Self.describe(error))
        }
    }

    /// .replace throws .sessionActive if any session has endedAt == nil, then deletes everything and inserts the archive.
    ///
    /// .merge never overwrites newer local data:
    /// - labels/tags that already exist (by uuid) keep their local name, colour, parent and archived state; only new
    ///   ones are inserted;
    /// - an existing session is updated only when the archived copy is strictly newer (`modifiedAt`); otherwise it is
    ///   skipped (`sessionsSkipped`);
    /// - when updated, its segments follow the archive (they partition the session's time), while notes, images and
    ///   learning points are upserted only — local ones missing from the archive are kept;
    /// - attachment bytes are kept when the archive has none.
    /// Image bytes from the archive are accepted only if they are a JPEG/PNG/HEIC of sane size.
    /// Saves, posts .worklogDataDidImport.
    ///
    /// Merge never touches the locally running session. A still-open session from the archive is ended at its local
    /// end time if it was already stopped here, or at its last activity when a session is running here (so an import
    /// can neither re-open a stopped session nor stop the live one).
    func importArchive(_ archive: ExportArchive, mode: ImportMode) throws -> ImportSummary {
        guard archive.formatVersion <= ExportArchive.currentFormatVersion else {
            throw DataTransferError.unsupportedVersion(archive.formatVersion)
        }
        let localActive = try fetchActiveSessions()
        if mode == .replace {
            guard localActive.isEmpty else { throw DataTransferError.sessionActive }
            try deleteEverything()
        }
        let hasLocalActive = !localActive.isEmpty
        var summary = ImportSummary()

        // Labels
        let existingLabels = try context.fetch(FetchDescriptor<WorkLabel>()).filter { !$0.isDeleted }
        var labelsByID = Self.index(existingLabels, by: \.uuid)
        for dto in archive.labels {
            let label: WorkLabel
            if let existing = labelsByID[dto.id] {
                if mode == .merge {
                    summary.labels += 1
                    continue
                }
                label = existing
            } else {
                label = WorkLabel(name: dto.name, uuid: dto.id)
                context.insert(label)
                labelsByID[dto.id] = label
            }
            label.name = dto.name
            label.colorHex = dto.colorHex
            label.symbolName = dto.symbolName
            label.sortIndex = dto.sortIndex
            label.isArchived = dto.isArchived
            label.createdAt = dto.createdAt
            summary.labels += 1
        }

        // Tags
        let existingTags = try context.fetch(FetchDescriptor<WorkTag>()).filter { !$0.isDeleted }
        var tagsByID = Self.index(existingTags, by: \.uuid)
        for dto in archive.tags {
            let tag: WorkTag
            if let existing = tagsByID[dto.id] {
                if mode == .merge {
                    summary.tags += 1
                    continue
                }
                tag = existing
            } else {
                tag = WorkTag(name: dto.name, uuid: dto.id)
                context.insert(tag)
                tagsByID[dto.id] = tag
            }
            tag.name = dto.name
            tag.colorHex = dto.colorHex
            tag.isArchived = dto.isArchived
            tag.createdAt = dto.createdAt
            tag.label = dto.labelID.flatMap { labelsByID[$0] }
            summary.tags += 1
        }

        func tags(for ids: [UUID]) -> [WorkTag] {
            var seen = Set<UUID>()
            return ids.compactMap { id in seen.insert(id).inserted ? tagsByID[id] : nil }
        }

        // Sessions
        let existingSessions = try context.fetch(FetchDescriptor<WorkSession>()).filter { !$0.isDeleted }
        var sessionsByID = Self.index(existingSessions, by: \.uuid)
        for dto in archive.sessions {
            let session: WorkSession
            var localEndedAt: Date?
            if let existing = sessionsByID[dto.id] {
                if existing.endedAt == nil {
                    // Never overwrite the session that is running on this Mac.
                    summary.sessionsSkipped += 1
                    continue
                }
                if mode == .merge && existing.modifiedAt >= dto.modifiedAt {
                    // The local copy is at least as new: keep it.
                    summary.sessionsSkipped += 1
                    continue
                }
                session = existing
                localEndedAt = existing.endedAt
                summary.sessionsUpdated += 1
            } else {
                session = WorkSession(startedAt: dto.startedAt, title: dto.title, uuid: dto.id)
                context.insert(session)
                sessionsByID[dto.id] = session
                summary.sessionsInserted += 1
            }

            session.title = dto.title
            session.startedAt = dto.startedAt
            session.endedAt = dto.endedAt
            session.pauseIntervals = dto.pauseIntervals.sorted { $0.start < $1.start }
            session.learningText = dto.learningText
            session.overlaySummary = dto.overlaySummary
            session.showInOverlay = dto.showInOverlay
            session.createdAt = dto.createdAt
            session.label = dto.labelID.flatMap { labelsByID[$0] }
            session.tagList = tags(for: dto.tagIDs)

            // Segments (upsert by uuid; extras removed)
            var segmentsByID = Self.index((session.segments ?? []).filter { !$0.isDeleted }, by: \.uuid)
            var keptSegments = Set<UUID>()
            for segDTO in dto.segments {
                let segment: Segment
                if let existing = segmentsByID[segDTO.id] {
                    segment = existing
                } else {
                    segment = Segment(startedAt: segDTO.startedAt, uuid: segDTO.id)
                    context.insert(segment)
                    segment.session = session
                    segmentsByID[segDTO.id] = segment
                }
                segment.startedAt = segDTO.startedAt
                segment.endedAt = segDTO.endedAt
                segment.sortIndex = segDTO.sortIndex
                segment.focus = segDTO.focus
                segment.label = segDTO.labelID.flatMap { labelsByID[$0] }
                segment.tagList = tags(for: segDTO.tagIDs)
                keptSegments.insert(segDTO.id)
            }
            for (id, segment) in segmentsByID where !keptSegments.contains(id) {
                segment.session = nil
                context.delete(segment)
            }

            // Notes
            var notesByID = Self.index((session.notes ?? []).filter { !$0.isDeleted }, by: \.uuid)
            var keptNotes = Set<UUID>()
            for noteDTO in dto.notes {
                let note: Note
                if let existing = notesByID[noteDTO.id] {
                    note = existing
                } else {
                    note = Note(text: noteDTO.text, createdAt: noteDTO.createdAt, uuid: noteDTO.id)
                    context.insert(note)
                    note.session = session
                    notesByID[noteDTO.id] = note
                }
                note.text = noteDTO.text
                note.createdAt = noteDTO.createdAt
                note.editedAt = noteDTO.editedAt
                let segment = noteDTO.segmentID.flatMap { keptSegments.contains($0) ? segmentsByID[$0] : nil }
                note.segment = segment ?? session.segment(containing: noteDTO.createdAt)
                keptNotes.insert(noteDTO.id)
            }
            if mode == .replace {
                for (id, note) in notesByID where !keptNotes.contains(id) {
                    note.session = nil
                    note.segment = nil
                    context.delete(note)
                }
            } else {
                // Local notes the archive doesn't know about stay; re-point any whose segment was dropped.
                for (id, note) in notesByID where !keptNotes.contains(id) && (note.segment == nil || note.segment?.isDeleted == true) {
                    note.segment = session.segment(containing: note.createdAt)
                }
            }

            // Attachments (bytes kept when the archive was exported without them)
            var attachmentsByID = Self.index((session.attachments ?? []).filter { !$0.isDeleted }, by: \.uuid)
            var keptAttachments = Set<UUID>()
            for var attDTO in dto.attachments {
                if let data = attDTO.data, !AttachmentImporter.isAcceptableStoredImage(data) {
                    Log.persistence.error("Dropped an archived image that isn't a valid JPEG/PNG/HEIC")
                    attDTO.data = nil
                    attDTO.thumbnailData = nil
                } else if let thumb = attDTO.thumbnailData, !AttachmentImporter.isAcceptableStoredImage(thumb) {
                    attDTO.thumbnailData = nil
                }
                if let existing = attachmentsByID[attDTO.id] {
                    existing.createdAt = attDTO.createdAt
                    existing.filename = attDTO.filename
                    existing.caption = attDTO.caption
                    if let data = attDTO.data {
                        existing.data = data
                        existing.thumbnailData = attDTO.thumbnailData
                        existing.uti = attDTO.uti
                        existing.pixelWidth = attDTO.pixelWidth
                        existing.pixelHeight = attDTO.pixelHeight
                        summary.attachments += 1
                    }
                    keptAttachments.insert(attDTO.id)
                } else if attDTO.data != nil {
                    let attachment = Attachment(filename: attDTO.filename, data: attDTO.data,
                                                thumbnailData: attDTO.thumbnailData, uti: attDTO.uti,
                                                pixelWidth: attDTO.pixelWidth, pixelHeight: attDTO.pixelHeight,
                                                uuid: attDTO.id)
                    context.insert(attachment)
                    attachment.createdAt = attDTO.createdAt
                    attachment.caption = attDTO.caption
                    attachment.session = session
                    attachmentsByID[attDTO.id] = attachment
                    keptAttachments.insert(attDTO.id)
                    summary.attachments += 1
                }
            }
            if mode == .replace {
                for (id, attachment) in attachmentsByID where !keptAttachments.contains(id) {
                    attachment.session = nil
                    context.delete(attachment)
                }
            }

            // Learning points
            var pointsByID = Self.index((session.learningPoints ?? []).filter { !$0.isDeleted }, by: \.uuid)
            var keptPoints = Set<UUID>()
            for pointDTO in dto.learningPoints {
                let point: LearningPoint
                if let existing = pointsByID[pointDTO.id] {
                    point = existing
                } else {
                    point = LearningPoint(text: pointDTO.text, createdAt: pointDTO.createdAt,
                                          sortIndex: pointDTO.sortIndex, uuid: pointDTO.id)
                    context.insert(point)
                    point.session = session
                    pointsByID[pointDTO.id] = point
                }
                point.text = pointDTO.text
                point.createdAt = pointDTO.createdAt
                point.sortIndex = pointDTO.sortIndex
                point.mastery = min(max(pointDTO.mastery, 0), 5)
                point.tagList = tags(for: pointDTO.tagIDs)
                keptPoints.insert(pointDTO.id)
            }
            if mode == .replace {
                for (id, point) in pointsByID where !keptPoints.contains(id) {
                    point.session = nil
                    context.delete(point)
                }
            }

            SessionEditor.normalize(session)
            if session.endedAt == nil {
                if let localEndedAt {
                    // Archived while running but already stopped here: never re-open it.
                    SessionEditor.endSession(session, at: localEndedAt)
                } else if hasLocalActive {
                    SessionEditor.endSession(session, at: session.lastActivityDate)
                }
            }
            session.recomputeStoredDuration()
            session.modifiedAt = dto.modifiedAt
        }

        try saveOrRollback()
        NotificationCenter.default.post(name: .worklogDataDidImport, object: nil)
        Log.persistence.info("Import finished: \(summary.description, privacy: .public)")
        return summary
    }

    func importArchive(from url: URL, mode: ImportMode) throws -> ImportSummary {
        let archive = try decodeArchive(from: url)
        return try importArchive(archive, mode: mode)
    }

    /// Deletes all model objects (blocked while a session is active → .sessionActive). Posts .worklogDataDidImport.
    func deleteAllData() throws {
        guard try fetchActiveSessions().isEmpty else { throw DataTransferError.sessionActive }
        try deleteEverything()
        try saveOrRollback()
        NotificationCenter.default.post(name: .worklogDataDidImport, object: nil)
        Log.persistence.info("Deleted all data")
    }

    /// Backups: image (and thumbnail) bytes of every attachment whose file name
    /// (`ExportArchive.attachmentFileName`) is not in `existingFileNames`. Only those attachments' external-storage
    /// bytes are loaded.
    func backupImagePayloads(skipping existingFileNames: Set<String>) throws -> [BackupImagePayload] {
        var payloads: [BackupImagePayload] = []
        for attachment in try context.fetch(FetchDescriptor<Attachment>()) where !attachment.isDeleted {
            let name = ExportArchive.attachmentFileName(id: attachment.uuid, uti: attachment.uti, thumbnail: false)
            if !existingFileNames.contains(name), let data = attachment.data {
                payloads.append(BackupImagePayload(fileName: name, data: data))
            }
            let thumbName = ExportArchive.attachmentFileName(id: attachment.uuid, uti: attachment.uti, thumbnail: true)
            if !existingFileNames.contains(thumbName), let thumb = attachment.thumbnailData {
                payloads.append(BackupImagePayload(fileName: thumbName, data: thumb))
            }
        }
        return payloads
    }

    /// Number of (non-deleted) sessions in the store.
    func sessionCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<WorkSession>())) ?? 0
    }

    /// True when a session with endedAt == nil exists (CORE helper used by BackupService.restore).
    func hasActiveSession() -> Bool {
        ((try? fetchActiveSessions()) ?? []).isEmpty == false
    }

    /// True when the container keeps data in memory only (previews/tests or the store failed to open).
    var isEphemeralStore: Bool {
        container.configurations.contains { $0.isStoredInMemoryOnly }
    }

    // MARK: - Private

    private func fetchActiveSessions() throws -> [WorkSession] {
        let descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.endedAt == nil })
        return try context.fetch(descriptor).filter { !$0.isDeleted }
    }

    /// Deletes every object one by one (no batch delete) so CloudKit mirroring and the in-memory graph stay correct.
    private func deleteEverything() throws {
        for session in try context.fetch(FetchDescriptor<WorkSession>()) where !session.isDeleted {
            context.delete(session)
        }
        for segment in try context.fetch(FetchDescriptor<Segment>()) where !segment.isDeleted {
            context.delete(segment)
        }
        for note in try context.fetch(FetchDescriptor<Note>()) where !note.isDeleted {
            context.delete(note)
        }
        for attachment in try context.fetch(FetchDescriptor<Attachment>()) where !attachment.isDeleted {
            context.delete(attachment)
        }
        for point in try context.fetch(FetchDescriptor<LearningPoint>()) where !point.isDeleted {
            context.delete(point)
        }
        for tag in try context.fetch(FetchDescriptor<WorkTag>()) where !tag.isDeleted {
            context.delete(tag)
        }
        for label in try context.fetch(FetchDescriptor<WorkLabel>()) where !label.isDeleted {
            context.delete(label)
        }
    }

    private func saveOrRollback() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            Log.persistence.error("Import/delete save failed: \(error.localizedDescription, privacy: .public)")
            throw DataTransferError.writeFailed(error.localizedDescription)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DataTransferError.writeFailed(error.localizedDescription)
        }
    }

    private static func index<T>(_ items: [T], by key: KeyPath<T, UUID>) -> [UUID: T] {
        var result: [UUID: T] = [:]
        for item in items where result[item[keyPath: key]] == nil {
            result[item[keyPath: key]] = item
        }
        return result
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return "missing field “\(key.stringValue)”"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return context.debugDescription
        case DecodingError.dataCorrupted(let context):
            return context.debugDescription
        default:
            return error.localizedDescription
        }
    }

    // MARK: DTO mapping

    private static func dto(_ label: WorkLabel) -> LabelDTO {
        LabelDTO(id: label.uuid, name: label.name, colorHex: label.colorHex, symbolName: label.symbolName,
                 sortIndex: label.sortIndex, isArchived: label.isArchived, createdAt: label.createdAt)
    }

    private static func dto(_ tag: WorkTag) -> TagDTO {
        TagDTO(id: tag.uuid, name: tag.name, colorHex: tag.colorHex, labelID: tag.label?.uuid,
               isArchived: tag.isArchived, createdAt: tag.createdAt)
    }

    private static func dto(_ session: WorkSession, includeAttachments: Bool) -> SessionDTO {
        SessionDTO(
            id: session.uuid, title: session.title, startedAt: session.startedAt, endedAt: session.endedAt,
            pauseIntervals: session.pauseIntervals, labelID: session.label?.uuid, tagIDs: session.tagList.map(\.uuid),
            learningText: session.learningText, overlaySummary: session.overlaySummary,
            showInOverlay: session.showInOverlay, createdAt: session.createdAt, modifiedAt: session.modifiedAt,
            segments: session.sortedSegments.filter { !$0.isDeleted }.map { segment in
                SegmentDTO(id: segment.uuid, startedAt: segment.startedAt, endedAt: segment.endedAt,
                           sortIndex: segment.sortIndex, focus: segment.focus, labelID: segment.label?.uuid,
                           tagIDs: segment.tagList.map(\.uuid))
            },
            notes: session.sortedNotes.filter { !$0.isDeleted }.map { note in
                NoteDTO(id: note.uuid, createdAt: note.createdAt, editedAt: note.editedAt, text: note.text,
                        segmentID: note.segment?.uuid)
            },
            attachments: session.sortedAttachments.filter { !$0.isDeleted }.map { attachment in
                AttachmentDTO(id: attachment.uuid, createdAt: attachment.createdAt, filename: attachment.filename,
                              caption: attachment.caption, uti: attachment.uti,
                              pixelWidth: attachment.pixelWidth, pixelHeight: attachment.pixelHeight,
                              data: includeAttachments ? attachment.data : nil,
                              thumbnailData: includeAttachments ? attachment.thumbnailData : nil)
            },
            learningPoints: session.sortedLearningPoints.filter { !$0.isDeleted }.map { point in
                LearningPointDTO(id: point.uuid, createdAt: point.createdAt, text: point.text,
                                 sortIndex: point.sortIndex, mastery: point.mastery, tagIDs: point.tagList.map(\.uuid))
            }
        )
    }

    // MARK: CSV helpers

    nonisolated private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func minutes(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", max(0, seconds) / 60)
    }

    /// RFC 4180: CRLF line endings; fields containing comma, quote, CR or LF are quoted with quotes doubled.
    nonisolated private static func csvData(_ rows: [[String]]) -> Data {
        let text = rows.map { row in row.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }

    /// Formula-injection guard: a value starting with = + - @ TAB or CR is prefixed with "'" so spreadsheet apps show
    /// it as text instead of evaluating it. Then RFC 4180 quoting.
    nonisolated static func csvField(_ raw: String) -> String {
        var value = raw
        let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]
        if let first = value.unicodeScalars.first, formulaStarts.contains(first) {
            value = "'" + value
        }
        let needsQuoting = value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
