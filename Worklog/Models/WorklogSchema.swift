import SwiftData

enum WorklogSchema {
    static let models: [any PersistentModel.Type] = WorklogSchemaV1.models
    /// Version 1.0.0 (the `Schema` default), matching `WorklogSchemaV1.versionIdentifier`.
    static var schema: Schema { Schema(models) }
}

/// The first shipped schema. When the model changes in a way lightweight migration can't handle, freeze the current
/// model types as nested types here, add `WorklogSchemaV2`, list both in `WorklogMigrationPlan.schemas`, add a stage,
/// and pass `migrationPlan: WorklogMigrationPlan.self` to `ModelContainer` in `PersistenceController`.
///
/// The plan is deliberately NOT passed to `ModelContainer` yet: staged migration refuses stores whose model isn't one of
/// the listed versions ("unknown model version"), and development stores created before V1 was frozen would then fail
/// to open. Additive changes (new properties with defaults) keep using automatic lightweight migration.
enum WorklogSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            WorkSession.self, Segment.self, Note.self, Attachment.self,
            WorkLabel.self, WorkTag.self, LearningPoint.self,
        ]
    }
}

enum WorklogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [WorklogSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
