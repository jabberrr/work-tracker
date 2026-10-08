import Foundation
import SwiftData

@Model
final class WorkLabel {
    var uuid: UUID = UUID()
    /// Identifies this physical row (new on every insert); deterministic tie-break for duplicate `uuid`s.
    var instanceID: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#5B8DEF"
    var symbolName: String = "circle.fill"
    var sortIndex: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()

    var sessions: [WorkSession]? = []
    var segments: [Segment]? = []
    /// Sub-labels (tags scoped to this label).
    var tags: [WorkTag]? = []
    /// nil = global (offered in every profile); else local to that profile.
    @Relationship(deleteRule: .nullify, inverse: \WorkProfile.labels)
    var profile: WorkProfile?

    init(name: String, colorHex: String = "#5B8DEF", symbolName: String = "circle.fill",
         sortIndex: Int = 0, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
    }
}

extension WorkLabel {
    var usageCount: Int { (sessions?.count ?? 0) + (segments?.count ?? 0) }
    /// Offered in every profile (no profile). A label whose profile was deleted becomes global too.
    var isGlobal: Bool { profile == nil }
}
