import Foundation

/// Format history: 1 = round 1–2; 2 = round 3 (profiles). Every v2 addition is optional, so v1 archives decode
/// (synthesized Decodable uses decodeIfPresent for optionals): a v1 import puts sessions in the home profile and
/// labels/tags become global.
struct ExportArchive: Codable {
    static let currentFormatVersion = 2
    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String          // CFBundleShortVersionString
    var includesAttachments: Bool
    var labels: [LabelDTO]
    var tags: [TagDTO]
    var sessions: [SessionDTO]
    /// Backups only: name of a folder next to the archive holding image files `<attachment id>.<ext>` (and
    /// `<id>.thumb.<ext>`) instead of base64 bytes in the JSON. nil = bytes (if any) are embedded. Older app versions
    /// ignore the key. `ExportService.decodeArchive(from: URL)` rehydrates the bytes from that folder.
    var attachmentStore: String? = nil
    /// v2+. v2 always writes it (possibly []); nil when decoding a v1 archive.
    var profiles: [ProfileDTO]? = nil
    /// Not encoded: images listed by an `attachmentStore` archive whose files couldn't be read when it was decoded
    /// (`ExportService.decodeArchive(from:)`). Shown before a restore; Replace keeps the store's own bytes for them.
    var missingImageCount: Int = 0

    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, appVersion, includesAttachments, labels, tags, sessions, attachmentStore, profiles
    }

    /// Attachments in the archive that carry no image bytes (exported without images, or missing files).
    var attachmentsWithoutImageCount: Int {
        sessions.reduce(0) { total, session in total + session.attachments.filter { $0.data == nil }.count }
    }

    /// Backup image file names (`attachmentFileName`, image and thumbnail) of every attachment in the archive.
    var imageFileNames: Set<String> {
        var names = Set<String>()
        for session in sessions {
            for attachment in session.attachments {
                names.insert(Self.attachmentFileName(id: attachment.id, uti: attachment.uti, thumbnail: false))
                names.insert(Self.attachmentFileName(id: attachment.id, uti: attachment.uti, thumbnail: true))
            }
        }
        return names
    }

    /// Image file names (`attachmentFileName`, thumbnail: false) of the attachments that carry no image bytes.
    var imageFileNamesWithoutBytes: Set<String> {
        var names = Set<String>()
        for session in sessions {
            for attachment in session.attachments where attachment.data == nil {
                names.insert(Self.attachmentFileName(id: attachment.id, uti: attachment.uti, thumbnail: false))
            }
        }
        return names
    }
}
struct ProfileDTO: Codable, Hashable {
    var id: UUID; var name: String; var colorHex: String; var symbolName: String; var sortIndex: Int
    var isArchived: Bool; var createdAt: Date; var modifiedAt: Date; var defaultLabelID: UUID?
}
struct LabelDTO: Codable, Hashable {
    var id: UUID; var name: String; var colorHex: String; var symbolName: String
    var sortIndex: Int; var isArchived: Bool; var createdAt: Date
    /// v2+: the profile the label is local to; nil = global.
    var profileID: UUID? = nil
}
struct TagDTO: Codable, Hashable {
    var id: UUID; var name: String; var colorHex: String; var labelID: UUID?
    var isArchived: Bool; var createdAt: Date
    /// v2+: the profile the tag is local to; nil = global.
    var profileID: UUID? = nil
}
struct SessionDTO: Codable {
    var id: UUID; var title: String; var startedAt: Date; var endedAt: Date?
    var pauseIntervals: [PauseInterval]; var labelID: UUID?; var tagIDs: [UUID]
    var learningText: String; var overlaySummary: String; var showInOverlay: Bool
    var createdAt: Date; var modifiedAt: Date
    var segments: [SegmentDTO]; var notes: [NoteDTO]
    var attachments: [AttachmentDTO]; var learningPoints: [LearningPointDTO]
    /// v2+: the session's profile; nil = unassigned (imported into the home profile).
    var profileID: UUID? = nil
    /// The Mac that last controlled the session while it was running ("" = unknown). Lets an import keep this Mac's
    /// own running session running and end any other (see `ExportService.importArchive`). Optional (older files).
    var ownerDeviceID: String? = nil
}
struct SegmentDTO: Codable {
    var id: UUID; var startedAt: Date; var endedAt: Date?; var sortIndex: Int
    var focus: String; var labelID: UUID?; var tagIDs: [UUID]
}
struct NoteDTO: Codable {
    var id: UUID; var createdAt: Date; var editedAt: Date?; var text: String; var segmentID: UUID?
}
struct AttachmentDTO: Codable {
    var id: UUID; var createdAt: Date; var filename: String; var caption: String; var uti: String
    var pixelWidth: Int; var pixelHeight: Int
    var data: Data?            // nil when exported without attachments
    var thumbnailData: Data?
}
struct LearningPointDTO: Codable {
    var id: UUID; var createdAt: Date; var text: String; var sortIndex: Int; var mastery: Int; var tagIDs: [UUID]
}

extension ExportArchive {
    /// `.iso8601` dates, `.base64` data, `[.prettyPrinted, .sortedKeys]` (backups use `pretty: false`).
    static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    /// Matching decoder. Accepts ISO-8601 with or without fractional seconds.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: string) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(string)")
        }
        return decoder
    }
}

extension ExportArchive {
    /// Default `attachmentStore` folder name used by backups.
    static let backupAttachmentFolder = "Attachments"

    /// "<id>.png" / "<id>.jpg", or "<id>.thumb.png" for the thumbnail.
    static func attachmentFileName(id: UUID, uti: String, thumbnail: Bool) -> String {
        let ext = uti == "public.png" ? "png" : (uti == "public.heic" ? "heic" : "jpg")
        return thumbnail ? "\(id.uuidString).thumb.\(ext)" : "\(id.uuidString).\(ext)"
    }

    /// Fills missing attachment bytes from `folder` (see `attachmentStore`). Missing files leave `data` nil.
    /// Returns the number of attachments that still have no bytes.
    @discardableResult
    mutating func rehydrateAttachments(from folder: URL) -> Int {
        var missing = 0
        for sessionIndex in sessions.indices {
            for attachmentIndex in sessions[sessionIndex].attachments.indices {
                var attachment = sessions[sessionIndex].attachments[attachmentIndex]
                guard attachment.data == nil else { continue }
                let file = folder.appending(path: Self.attachmentFileName(id: attachment.id, uti: attachment.uti, thumbnail: false))
                attachment.data = try? Data(contentsOf: file)
                if attachment.data == nil { missing += 1 }
                if attachment.thumbnailData == nil {
                    let thumb = folder.appending(path: Self.attachmentFileName(id: attachment.id, uti: attachment.uti, thumbnail: true))
                    attachment.thumbnailData = try? Data(contentsOf: thumb)
                }
                sessions[sessionIndex].attachments[attachmentIndex] = attachment
            }
        }
        return missing
    }
}
