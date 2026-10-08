import Foundation
import SwiftData

extension Notification.Name {
    /// Posted by `SafeSave.save` when a save failed and was rolled back. userInfo[`SafeSave.messageKey`]: String.
    /// `SessionEngine` shows it through `lastError` (RootView's alert).
    static let worklogSaveFailed = Notification.Name("worklogSaveFailed")
}

/// L5: the save used by the static edit helpers (`TaxonomyOps`, `ProfileOps`, `SessionEditor`) and Settings editors.
/// On failure the context is rolled back (so the UI never shows changes that aren't stored) and the user is told.
@MainActor
enum SafeSave {
    nonisolated static let messageKey = "message"

    /// Saves `context`; on failure rolls back, logs and posts `.worklogSaveFailed`. Returns false on failure.
    @discardableResult
    static func save(_ context: ModelContext, source: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            Log.persistence.error("\(source, privacy: .public) save failed (rolled back): \(error.localizedDescription, privacy: .public)")
            NotificationCenter.default.post(
                name: .worklogSaveFailed, object: nil,
                userInfo: [messageKey: "Couldn\u{2019}t save your change, so it was undone. \(error.localizedDescription)"])
            return false
        }
    }
}
