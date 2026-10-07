import Foundation
import SwiftData

@Model
final class WorkTag {
    var uuid: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#8E8E93"
    var isArchived: Bool = false
    var createdAt: Date = Date()

    /// Optional parent label (tag acts as a sub-label). nil = global tag.
    @Relationship(deleteRule: .nullify, inverse: \WorkLabel.tags)
    var label: WorkLabel?
    var sessions: [WorkSession]? = []
    var segments: [Segment]? = []
    var learningPoints: [LearningPoint]? = []

    init(name: String, colorHex: String = "#8E8E93", uuid: UUID = UUID()) {
        self.uuid = uuid
        self.name = name
        self.colorHex = colorHex
    }
}

extension WorkTag {
    var usageCount: Int { (sessions?.count ?? 0) + (segments?.count ?? 0) + (learningPoints?.count ?? 0) }
}
