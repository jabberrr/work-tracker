import Foundation

struct ExportArchive: Codable {
    static let currentFormatVersion = 1
    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String          // CFBundleShortVersionString
    var includesAttachments: Bool
    var labels: [LabelDTO]
    var tags: [TagDTO]
    var sessions: [SessionDTO]
}
struct LabelDTO: Codable, Hashable {
    var id: UUID; var name: String; var colorHex: String; var symbolName: String
    var sortIndex: Int; var isArchived: Bool; var createdAt: Date
}
struct TagDTO: Codable, Hashable {
    var id: UUID; var name: String; var colorHex: String; var labelID: UUID?
    var isArchived: Bool; var createdAt: Date
}
struct SessionDTO: Codable {
    var id: UUID; var title: String; var startedAt: Date; var endedAt: Date?
    var pauseIntervals: [PauseInterval]; var labelID: UUID?; var tagIDs: [UUID]
    var learningText: String; var overlaySummary: String; var showInOverlay: Bool
    var createdAt: Date; var modifiedAt: Date
    var segments: [SegmentDTO]; var notes: [NoteDTO]
    var attachments: [AttachmentDTO]; var learningPoints: [LearningPointDTO]
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
    /// `.iso8601` dates, `.base64` data, `[.prettyPrinted, .sortedKeys]`.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
