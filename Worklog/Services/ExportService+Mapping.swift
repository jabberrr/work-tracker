import Foundation
import SwiftData

// Model → DTO mapping (JSON export) and CSV helpers.
extension ExportService {
    // MARK: DTO mapping

    static func dto(_ profile: WorkProfile) -> ProfileDTO {
        ProfileDTO(id: profile.uuid, name: profile.name, colorHex: profile.colorHex, symbolName: profile.symbolName,
                   sortIndex: profile.sortIndex, isArchived: profile.isArchived, createdAt: profile.createdAt,
                   modifiedAt: profile.modifiedAt, defaultLabelID: profile.defaultLabelUUID)
    }

    static func dto(_ label: WorkLabel) -> LabelDTO {
        LabelDTO(id: label.uuid, name: label.name, colorHex: label.colorHex, symbolName: label.symbolName,
                 sortIndex: label.sortIndex, isArchived: label.isArchived, createdAt: label.createdAt,
                 profileID: ModelLiveness.live(label.profile)?.uuid)
    }

    static func dto(_ tag: WorkTag) -> TagDTO {
        TagDTO(id: tag.uuid, name: tag.name, colorHex: tag.colorHex, labelID: tag.label?.uuid,
               isArchived: tag.isArchived, createdAt: tag.createdAt, profileID: ModelLiveness.live(tag.profile)?.uuid)
    }

    /// The session's profile name for CSV: its effective profile (an unassigned session shows where the app shows it);
    /// "" if none.
    static func profileName(of session: WorkSession) -> String {
        ProfileOps.effectiveProfile(of: session)?.name ?? ""
    }

    static func dto(_ session: WorkSession, includeAttachments: Bool) -> SessionDTO {
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
            },
            profileID: ModelLiveness.live(session.profile)?.uuid,
            ownerDeviceID: session.ownerDeviceID.isEmpty ? nil : session.ownerDeviceID
        )
    }

    // MARK: CSV helpers

    nonisolated static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", max(0, seconds) / 60)
    }

    /// RFC 4180: CRLF line endings; fields containing comma, quote, CR or LF are quoted with quotes doubled.
    nonisolated static func csvData(_ rows: [[String]]) -> Data {
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
