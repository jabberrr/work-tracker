import SwiftData

enum WorklogSchema {
    static let models: [any PersistentModel.Type] = [
        WorkSession.self, Segment.self, Note.self, Attachment.self,
        WorkLabel.self, WorkTag.self, LearningPoint.self
    ]
    static var schema: Schema { Schema(models) }
}
