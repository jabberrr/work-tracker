import Foundation
import SwiftData

@Model
final class Note {
    var uuid: UUID = UUID()
    /// The displayed timestamp (when the note was taken / is about).
    var createdAt: Date = Date()
    var editedAt: Date? = nil
    var text: String = ""
    var session: WorkSession?
    var segment: Segment?

    init(text: String, createdAt: Date = .now, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.text = text
        self.createdAt = createdAt
    }
}
