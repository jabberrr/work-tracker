import SwiftData

/// Guards for SwiftData models that views may still hold after they were deleted (e.g. a label in
/// `@State` that was deleted or merged in Settings, a note whose session was discarded).
/// Reading any persisted property of such a model traps, so check `ModelLiveness.isLive(_:)` first.
///
/// A model counts as gone when `isDeleted` is true (deleted, not yet saved) or it no longer has a
/// `modelContext` (deleted and saved, or detached).
enum ModelLiveness {
    /// True when `model` can be read safely.
    static func isLive<M: PersistentModel>(_ model: M) -> Bool {
        !model.isDeleted && model.modelContext != nil
    }

    /// `model` when it is live, else nil.
    static func live<M: PersistentModel>(_ model: M?) -> M? {
        guard let model, isLive(model) else { return nil }
        return model
    }

    /// The live models of `models`, in order.
    static func live<M: PersistentModel>(_ models: [M]) -> [M] {
        models.filter { isLive($0) }
    }
}
