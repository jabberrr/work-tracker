import Foundation
import Observation
import SwiftData

extension Notification.Name { static let worklogDataDidImport = Notification.Name("worklogDataDidImport") }

enum ImportMode { case merge, replace }   // merge = upsert by uuid; replace = delete everything first

struct ImportSummary: Equatable {
    var labels = 0, tags = 0, sessionsInserted = 0, sessionsUpdated = 0, attachments = 0
    /// Merge only: sessions left alone because the local copy is running or at least as new as the archived one.
    var sessionsSkipped = 0
    /// Profiles in the archive (inserted or already present). 0 for v1 archives.
    var profiles = 0
    /// Attachments of the archive that couldn't be imported because neither the file nor this store had the image.
    var imagesMissing = 0

    /// "Imported 12 sessions (3 updated), 5 labels, 9 tags, 2 profiles." (", N profile(s)" only when the archive has
    /// profiles; + " 4 sessions were already up to date." on merge)
    var description: String {
        let sessions = sessionsInserted + sessionsUpdated
        var text = "Imported \(sessions) \(sessions == 1 ? "session" : "sessions") (\(sessionsUpdated) updated), "
            + "\(labels) \(labels == 1 ? "label" : "labels"), \(tags) \(tags == 1 ? "tag" : "tags")"
        if attachments > 0 {
            text += ", \(attachments) \(attachments == 1 ? "image" : "images")"
        }
        if profiles > 0 {
            text += ", \(profiles) \(profiles == 1 ? "profile" : "profiles")"
        }
        text += "."
        if sessionsSkipped > 0 {
            text += " \(sessionsSkipped) \(sessionsSkipped == 1 ? "session was" : "sessions were") already up to date."
        }
        if imagesMissing > 0 {
            text += " \(imagesMissing) \(imagesMissing == 1 ? "image wasn\u{2019}t" : "images weren\u{2019}t") in the file."
        }
        return text
    }
}

enum DataTransferError: LocalizedError {
    case unsupportedVersion(Int), decodingFailed(String), sessionActive, writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This file needs a newer version of Worklog (format \(version))."
        case .decodingFailed(let reason):
            "The file couldn't be read as a Worklog export: \(reason)"
        case .sessionActive:
            "Stop the running session first."
        case .writeFailed(let reason):
            "The data couldn't be saved: \(reason)"
        }
    }
}

/// JSON/CSV export, JSON import (merge/replace) and delete-all. Used by Settings ▸ Data and BackupService.
@MainActor @Observable
final class ExportService {
    private let container: ModelContainer
    var context: ModelContext { container.mainContext }
    /// This Mac's `SessionEngine.deviceID` (set by AppServices): an archived running session owned by this Mac stays
    /// running on import; any other is ended (M2).
    @ObservationIgnored var localDeviceID: String = ""

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Export

    func makeArchive(includeAttachments: Bool) throws -> ExportArchive {
        let profiles = ProfileOps.allProfiles(in: context)
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
            sessions: sessions.filter { !$0.isDeleted }.map { Self.dto($0, includeAttachments: includeAttachments) },
            profiles: profiles.map { Self.dto($0) }
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

    /// Sessions CSV header (RFC 4180 quoting, ISO-8601 dates, tags joined by "; "; profile = profile name, "" if none):
    /// id,title,label,tags,startedAt,endedAt,activeMinutes,pausedMinutes,segmentCount,noteCount,learningPointCount,learningText,profile
    func exportSessionsCSV(to url: URL) throws {
        let now = Date.now
        let sessions = try context.fetch(FetchDescriptor<WorkSession>(sortBy: [SortDescriptor(\WorkSession.startedAt)]))
        var rows: [[String]] = [[
            "id", "title", "label", "tags", "startedAt", "endedAt", "activeMinutes", "pausedMinutes",
            "segmentCount", "noteCount", "learningPointCount", "learningText", "profile",
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
                Self.profileName(of: session),
            ])
        }
        try write(Self.csvData(rows), to: url)
    }

    /// Header: sessionID,sessionTitle,segmentID,index,startedAt,endedAt,activeMinutes,label,tags,focus,profile
    func exportSegmentsCSV(to url: URL) throws {
        let now = Date.now
        let sessions = try context.fetch(FetchDescriptor<WorkSession>(sortBy: [SortDescriptor(\WorkSession.startedAt)]))
        var rows: [[String]] = [[
            "sessionID", "sessionTitle", "segmentID", "index", "startedAt", "endedAt", "activeMinutes", "label", "tags", "focus",
            "profile",
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
                    Self.profileName(of: session),
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

    // Import (decodeArchive, importArchive, import rules): ExportService+Import.swift.
    // Model → DTO mapping and CSV helpers: ExportService+Mapping.swift.

    /// Deletes all model objects, profiles included (blocked while a session is active → .sessionActive), then
    /// recreates the default profile so the app always has one. Posts .worklogDataDidImport.
    func deleteAllData() throws {
        guard try fetchActiveSessions().isEmpty else { throw DataTransferError.sessionActive }
        try deleteEverything()
        ProfileOps.ensureDefaultProfile(legacyDefaultLabelID: nil, in: context)
        SeedData.repairSessionProfilesIfAllowed(in: context)
        ProfileOps.invalidateHomeProfileCache()
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

    /// L3: image file names (`ExportArchive.attachmentFileName`, thumbnail: false) of the attachments whose image
    /// bytes are on this Mac (an image CloudKit hasn't downloaded has none). Loads each attachment's bytes.
    func imageFileNamesWithBytes() -> Set<String> {
        var names = Set<String>()
        for attachment in (try? context.fetch(FetchDescriptor<Attachment>())) ?? [] where !attachment.isDeleted {
            guard attachment.data != nil else { continue }
            names.insert(ExportArchive.attachmentFileName(id: attachment.uuid, uti: attachment.uti, thumbnail: false))
        }
        return names
    }

    /// Number of (non-deleted) sessions in the store.
    func sessionCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<WorkSession>())) ?? 0
    }

    /// True when the store has no session, label, tag or profile (a fresh store: Replace then deletes nothing).
    func isStoreEmpty() -> Bool {
        sessionCount() == 0
            && ((try? context.fetchCount(FetchDescriptor<WorkLabel>())) ?? 0) == 0
            && ((try? context.fetchCount(FetchDescriptor<WorkTag>())) ?? 0) == 0
            && ((try? context.fetchCount(FetchDescriptor<WorkProfile>())) ?? 0) == 0
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
    // Members without `private` here are internal only for ExportService's extensions in other files
    // (ExportService+Import/+Mapping).

    func fetchActiveSessions() throws -> [WorkSession] {
        let descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.endedAt == nil })
        return try context.fetch(descriptor).filter { !$0.isDeleted }
    }

    /// Deletes every object one by one (no batch delete) so CloudKit mirroring and the in-memory graph stay correct.
    func deleteEverything() throws {
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
        for profile in try context.fetch(FetchDescriptor<WorkProfile>()) where !profile.isDeleted {
            context.delete(profile)
        }
    }

    func saveOrRollback() throws {
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

}
