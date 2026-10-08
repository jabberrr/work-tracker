import Foundation
import SwiftData

@Model
final class WorkTag {
    var uuid: UUID = UUID()
    /// Identifies this physical row (new on every insert); deterministic tie-break for duplicate `uuid`s.
    var instanceID: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#8E8E93"
    var isArchived: Bool = false
    var createdAt: Date = Date()

    /// Optional parent label (tag acts as a sub-label). nil = not scoped to a label (unrelated to `profile`).
    @Relationship(deleteRule: .nullify, inverse: \WorkLabel.tags)
    var label: WorkLabel?
    var sessions: [WorkSession]? = []
    var segments: [Segment]? = []
    var learningPoints: [LearningPoint]? = []
    /// nil = global (offered in every profile); else local to that profile.
    @Relationship(deleteRule: .nullify, inverse: \WorkProfile.tags)
    var profile: WorkProfile?

    init(name: String, colorHex: String = "#8E8E93", uuid: UUID = UUID()) {
        self.uuid = uuid
        self.name = name
        self.colorHex = colorHex
    }
}

extension WorkTag {
    var usageCount: Int { (sessions?.count ?? 0) + (segments?.count ?? 0) + (learningPoints?.count ?? 0) }
    /// Offered in every profile (no profile). A tag whose profile was deleted becomes global too.
    var isGlobal: Bool { profile == nil }
}
