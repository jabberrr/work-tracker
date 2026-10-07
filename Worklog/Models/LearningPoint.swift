import Foundation
import SwiftData

@Model
final class LearningPoint {
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var text: String = ""
    var sortIndex: Int = 0
    /// Optional self-assessed mastery 1...5; 0 = not rated. Charted on the Learning page.
    var mastery: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \WorkTag.learningPoints)
    var tags: [WorkTag]? = []
    var session: WorkSession?

    init(text: String, createdAt: Date = .now, sortIndex: Int = 0, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.text = text
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }
}

extension LearningPoint {
    var tagList: [WorkTag] {
        get { tags ?? [] }
        set { tags = newValue }
    }
    /// Date used on the evolution timeline: the session's start, else createdAt.
    var effectiveDate: Date { session?.startedAt ?? createdAt }
}
