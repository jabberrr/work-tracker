import Foundation
import SwiftData

// JSON import: decoding (with the format-version check), merge/replace, and the pure import rules.
extension ExportService {
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
            archive.missingImageCount = missing
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
    /// .replace keeps the store's own image bytes (by attachment uuid) for archived attachments that have none (an
    /// archive exported without images, or backup image files that are missing).
    ///
    /// .merge never overwrites newer local data:
    /// - labels/tags that already exist (by uuid) keep their local name, colour, parent and archived state — unless
    ///   the local row was created after the archive was exported (a re-seeded default with the same fixed uuid), then
    ///   the archived values win; only new ones are inserted;
    /// - an existing profile is updated only when the archived copy is strictly newer (`modifiedAt`);
    /// - an existing session is updated only when the archived copy is strictly newer (`modifiedAt`); otherwise it is
    ///   skipped (`sessionsSkipped`);
    /// - when updated, its segments follow the archive (they partition the session's time), while notes, images and
    ///   learning points are upserted only — local ones missing from the archive are kept;
    /// - attachment bytes are kept when the archive has none.
    /// Image bytes from the archive are accepted only if they are a JPEG/PNG/HEIC of sane size.
    /// Saves, posts .worklogDataDidImport.
    ///
    /// Profiles (v2), imported first: merge upserts by uuid (existing profiles change only when the archive is newer).
    /// New labels/tags get the archived scope (`profileID`, nil = global); in merge mode existing ones keep their
    /// scope, in replace mode the archived scope is set. A session goes to its archived profile, else its local
    /// profile, else the home profile (created when none exists) — so a v1 archive lands in the home profile with
    /// global labels/tags. Every inserted/updated session then gets `TaxonomyOps.conformTaxonomy` (labels/tags its
    /// profile doesn't offer are mapped to a same-name item or copied). If no non-archived profile is left, the first
    /// is unarchived. Unassigned sessions are repaired before saving where allowed
    /// (`SeedData.repairSessionProfilesIfAllowed`; not in CloudKit mode).
    ///
    /// Merge never touches the locally running session. A still-open session from the archive is ended at its local
    /// end time if it was already stopped here, or at its last activity when a session is running here (so an import
    /// can neither re-open a stopped session nor stop the live one). Otherwise it keeps running only when this Mac
    /// owned it (`localDeviceID`); any other is ended at max(last activity, min(exportedAt, now)) (M2).
    func importArchive(_ archive: ExportArchive, mode: ImportMode) throws -> ImportSummary {
        guard archive.formatVersion <= ExportArchive.currentFormatVersion else {
            throw DataTransferError.unsupportedVersion(archive.formatVersion)
        }
        let localActive = try fetchActiveSessions()
        var preservedImages: [UUID: PreservedImage] = [:]
        if mode == .replace {
            guard localActive.isEmpty else { throw DataTransferError.sessionActive }
            preservedImages = try imagesToPreserve(for: archive)
            try deleteEverything()
        }
        let hasLocalActive = !localActive.isEmpty
        var summary = ImportSummary()

        // Profiles
        var profilesByID = Self.index(ProfileOps.allProfiles(in: context), by: \.uuid)
        for dto in archive.profiles ?? [] {
            summary.profiles += 1
            if let existing = profilesByID[dto.id] {
                // Kept unless the archived copy is newer (a fresh default "Work" has the 1970 epoch modifiedAt).
                if dto.modifiedAt > existing.modifiedAt {
                    existing.name = dto.name
                    existing.colorHex = dto.colorHex
                    existing.symbolName = dto.symbolName
                    existing.sortIndex = dto.sortIndex
                    existing.isArchived = dto.isArchived
                    existing.defaultLabelUUID = dto.defaultLabelID
                    existing.modifiedAt = dto.modifiedAt
                }
                continue
            }
            let profile = WorkProfile(name: dto.name, colorHex: dto.colorHex, symbolName: dto.symbolName,
                                      sortIndex: dto.sortIndex, uuid: dto.id)
            context.insert(profile)
            profile.isArchived = dto.isArchived
            profile.createdAt = dto.createdAt
            profile.defaultLabelUUID = dto.defaultLabelID
            profile.modifiedAt = dto.modifiedAt
            profilesByID[dto.id] = profile
        }
        var homeProfile: WorkProfile?
        func home() -> WorkProfile? {
            if let homeProfile, ModelLiveness.isLive(homeProfile) { return homeProfile }
            homeProfile = ProfileOps.homeProfile(in: context)
                ?? ProfileOps.ensureDefaultProfile(legacyDefaultLabelID: nil, in: context)
            return homeProfile
        }

        // Labels
        let existingLabels = try context.fetch(FetchDescriptor<WorkLabel>()).filter { !$0.isDeleted }
        var labelsByID = Self.index(existingLabels, by: \.uuid)
        for dto in archive.labels {
            let label: WorkLabel
            if let existing = labelsByID[dto.id] {
                if mode == .merge && !Self.isFreshLocalCopy(createdAt: existing.createdAt, archive: archive) {
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
            label.profile = dto.profileID.flatMap { profilesByID[$0] }
            summary.labels += 1
        }

        // Tags
        let existingTags = try context.fetch(FetchDescriptor<WorkTag>()).filter { !$0.isDeleted }
        var tagsByID = Self.index(existingTags, by: \.uuid)
        for dto in archive.tags {
            let tag: WorkTag
            if let existing = tagsByID[dto.id] {
                if mode == .merge && !Self.isFreshLocalCopy(createdAt: existing.createdAt, archive: archive) {
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
            tag.profile = dto.profileID.flatMap { profilesByID[$0] }
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
            session.profile = dto.profileID.flatMap { profilesByID[$0] } ?? ModelLiveness.live(session.profile) ?? home()
            if let owner = dto.ownerDeviceID { session.ownerDeviceID = owner }

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
                if attDTO.data == nil, let kept = preservedImages[attDTO.id] {
                    // Replace: the archive has no bytes for this image, the store had them.
                    attDTO.data = kept.data
                    attDTO.thumbnailData = kept.thumbnailData
                    attDTO.uti = kept.uti
                    attDTO.pixelWidth = kept.pixelWidth
                    attDTO.pixelHeight = kept.pixelHeight
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
                } else {
                    summary.imagesMissing += 1
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
                } else if !Self.keepsArchivedSessionRunning(ownerDeviceID: dto.ownerDeviceID,
                                                             localDeviceID: localDeviceID) {
                    // Not this Mac's session: never adopt it as running here (M2).
                    SessionEditor.endSession(session, at: Self.archivedRunningSessionEnd(
                        lastActivity: session.lastActivityDate, exportedAt: archive.exportedAt, now: .now))
                }
            }
            session.recomputeStoredDuration()
            // Labels/tags its profile doesn't offer (e.g. merged into a store where they have another scope) are
            // mapped like a move: same-name equivalent, else a local copy.
            if let profile = ModelLiveness.live(session.profile) {
                TaxonomyOps.conformTaxonomy(of: session, to: profile, in: context)
            }
            session.modifiedAt = dto.modifiedAt
        }

        if mode == .replace {
            ProfileOps.ensureDefaultProfile(legacyDefaultLabelID: nil, in: context)
        }
        ProfileOps.ensureNonArchivedProfile(in: context)
        SeedData.repairSessionProfilesIfAllowed(in: context)
        ProfileOps.invalidateHomeProfileCache()
        try saveOrRollback()
        NotificationCenter.default.post(name: .worklogDataDidImport, object: nil)
        Log.persistence.info("Import finished: \(summary.description, privacy: .public)")
        return summary
    }

    func importArchive(from url: URL, mode: ImportMode) throws -> ImportSummary {
        let archive = try decodeArchive(from: url)
        return try importArchive(archive, mode: mode)
    }

    // MARK: - Import rules (pure; unit-tested)

    /// M7: a local label/tag created after the archive was exported is a re-seeded default (same fixed uuid), not a
    /// user edit, so a merge lets the archived values win. (1 s margin: archive dates are whole seconds.)
    nonisolated static func isFreshLocalCopy(createdAt: Date, archive: ExportArchive) -> Bool {
        createdAt.timeIntervalSince(archive.exportedAt) > 1
    }

    /// M2: an archived running session stays running only when this Mac owned it.
    nonisolated static func keepsArchivedSessionRunning(ownerDeviceID: String?, localDeviceID: String) -> Bool {
        guard let owner = ownerDeviceID, !owner.isEmpty, !localDeviceID.isEmpty else { return false }
        return owner == localDeviceID
    }

    /// M2: where an archived running session from another Mac ends: max(last activity, min(exportedAt, now)).
    nonisolated static func archivedRunningSessionEnd(lastActivity: Date, exportedAt: Date, now: Date) -> Date {
        max(lastActivity, min(exportedAt, now))
    }

    // MARK: - Private (import)

    /// Image bytes of a store attachment, kept across a Replace.
    private struct PreservedImage {
        var data: Data
        var thumbnailData: Data?
        var uti: String
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// Replace: the bytes of store attachments the archive lists without image bytes (loaded before everything is
    /// deleted). Only those attachments' external-storage bytes are read.
    private func imagesToPreserve(for archive: ExportArchive) throws -> [UUID: PreservedImage] {
        var wanted = Set<UUID>()
        for session in archive.sessions {
            for attachment in session.attachments where attachment.data == nil {
                wanted.insert(attachment.id)
            }
        }
        guard !wanted.isEmpty else { return [:] }
        var result: [UUID: PreservedImage] = [:]
        for attachment in try context.fetch(FetchDescriptor<Attachment>())
        where !attachment.isDeleted && wanted.contains(attachment.uuid) && result[attachment.uuid] == nil {
            guard let data = attachment.data else { continue }
            result[attachment.uuid] = PreservedImage(data: data, thumbnailData: attachment.thumbnailData,
                                                     uti: attachment.uti, pixelWidth: attachment.pixelWidth,
                                                     pixelHeight: attachment.pixelHeight)
        }
        return result
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
}
