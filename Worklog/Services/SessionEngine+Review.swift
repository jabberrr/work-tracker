import Foundation
import SwiftData

// End-of-session review: completing it and discarding the reviewed session (two-phase). Re-opening it
// (`resumePendingSession()`) stays in SessionEngine.swift because it changes `activeSession`.
extension SessionEngine {
    // MARK: - End-of-session review

    /// Save pending session (touch, recomputeStoredDuration), pendingEndSession = nil, refreshTakeaway().
    /// With `settings.takeawayNextSessionOnly`, the takeaway that was showing when this session started is retired.
    /// Idempotent: safe to call again from the sheet's dismissal binding.
    func completeReview() {
        if let session = pendingEndSession {
            pendingEndSession = nil
            if !session.isDeleted {
                ProfileOps.assignProfileIfUnassigned(session, in: context)
                session.recomputeStoredDuration()
                session.touch()
                consumeTakeawayIfNeeded(reviewed: session)
            }
            save()
        }
        refreshTakeaway()
    }

    /// Phase 1 of discarding the pending (ended) session: remembers it and sets pendingEndSession = nil so the
    /// end sheet closes. Nothing is deleted yet — RootView's sheet `onDismiss` calls `finishPendingDiscard()` once
    /// the sheet's views are gone (a fallback finishes it after 2 s if no sheet was on screen).
    func discardPendingSession() {
        guard let session = pendingEndSession else { return }
        let uuid = session.uuid
        if let previous = pendingDiscardUUID, previous != uuid {
            finishDiscard(uuid: previous)
        }
        pendingDiscardUUID = uuid
        discardingUUIDs.insert(uuid)
        pendingEndSession = nil
        refreshTakeaway()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.pendingDiscardUUID == uuid else { return }
            self.finishPendingDiscard()
        }
    }

    /// Phase 2: deletes the session recorded by `discardPendingSession()`, saves, refreshTakeaway(). No-op otherwise.
    func finishPendingDiscard() {
        guard let uuid = pendingDiscardUUID else { return }
        pendingDiscardUUID = nil
        finishDiscard(uuid: uuid)
    }
}
