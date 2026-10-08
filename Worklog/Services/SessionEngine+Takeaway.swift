import Foundation
import SwiftData

// Takeaways: per-profile lookup, "Done", and the next-session-only lifecycle. `refreshTakeaway()` (which writes
// `takeaways`) stays in SessionEngine.swift.
extension SessionEngine {
    /// The latest takeaway of that profile (unassigned sessions count as their effective profile's).
    func takeaway(for profileID: UUID?) -> SessionTakeaway? {
        takeaways[profileID]
    }

    /// "Done" on a takeaway (nil → lastTakeaway): turns off showInOverlay on its session (and on older sessions of
    /// the same profile that would otherwise resurface in its place), saves, refreshTakeaway(). Other profiles'
    /// takeaways are untouched.
    func dismissTakeaway(_ takeaway: SessionTakeaway? = nil) {
        guard let takeaway = takeaway ?? lastTakeaway else { return }
        if let source = fetchSession(uuid: takeaway.sessionUUID) {
            retireTakeaways(through: source)
            source.touch()
        }
        if defaults.string(forKey: Self.takeawaySourceKey) == takeaway.sessionUUID.uuidString {
            clearTakeawayLink()   // already retired; nothing left for the next review to consume
        }
        save()
        refreshTakeaway()
    }

    // MARK: Takeaway lifecycle

    /// Records which takeaway was on screen when `session` started, so its review can retire it.
    func rememberTakeawaySource(for session: WorkSession) {
        refreshTakeaway()
        if let source = takeaway(for: ProfileOps.effectiveProfileID(of: session))?.sessionUUID {
            defaults.set(session.uuid.uuidString, forKey: Self.takeawayConsumerKey)
            defaults.set(source.uuidString, forKey: Self.takeawaySourceKey)
        } else {
            clearTakeawayLink()
        }
    }

    /// Next-session-only mode: once the session that followed a takeaway is reviewed, that takeaway is retired.
    func consumeTakeawayIfNeeded(reviewed session: WorkSession) {
        guard defaults.string(forKey: Self.takeawayConsumerKey) == session.uuid.uuidString else { return }
        let sourceString = defaults.string(forKey: Self.takeawaySourceKey)
        clearTakeawayLink()
        guard settings.takeawayNextSessionOnly,
              let sourceUUID = sourceString.flatMap(UUID.init(uuidString:)),
              sourceUUID != session.uuid,
              let source = fetchSession(uuid: sourceUUID) else { return }
        retireTakeaways(through: source)
    }

    /// showInOverlay = false on `source` and on every older ended session OF THE SAME PROFILE that still has it on (so
    /// dismissing or retiring a takeaway never brings back an older one). Filtered by profile in memory.
    private func retireTakeaways(through source: WorkSession) {
        if source.showInOverlay { source.showInOverlay = false }
        let cutoff = source.startedAt
        let sourceProfileID = ProfileOps.effectiveProfileID(of: source)
        var descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate<WorkSession> { $0.endedAt != nil && $0.showInOverlay == true && $0.startedAt <= cutoff }
        )
        descriptor.fetchLimit = 500
        let older = (try? context.fetch(descriptor)) ?? []
        for session in older where !session.isDeleted && session !== pendingEndSession
            && ProfileOps.effectiveProfileID(of: session) == sourceProfileID {
            session.showInOverlay = false
        }
    }

    func clearTakeawayLink() {
        defaults.removeObject(forKey: Self.takeawayConsumerKey)
        defaults.removeObject(forKey: Self.takeawaySourceKey)
    }
}
