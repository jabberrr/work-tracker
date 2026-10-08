import Foundation

// Which Mac controls a running session.
extension SessionEngine {
    // MARK: Ownership

    /// Sessions with no owner (created before ownership existed, or imported) count as this Mac's.
    func isOwnedByThisDevice(_ session: WorkSession?) -> Bool {
        guard let session else { return false }
        return session.ownerDeviceID.isEmpty || session.ownerDeviceID == deviceID
    }

    /// Manual control from this Mac makes it the session's owner.
    func stampOwner(_ session: WorkSession) {
        if session.ownerDeviceID != deviceID { session.ownerDeviceID = deviceID }
    }

    /// When two Macs each started a session, the older one ends where the newer one began (the handoff), unless
    /// the older one had been idle for longer than the long-session threshold — then it ends at its last activity.
    func handoffEnd(of extra: WorkSession, newest: WorkSession) -> Date {
        let lastActivity = extra.lastActivityDate
        let handoff = newest.startedAt
        guard handoff > lastActivity else { return lastActivity }
        let threshold = max(settings.longSessionWarningHours, 0) * 3600
        return handoff.timeIntervalSince(lastActivity) <= threshold ? handoff : lastActivity
    }
}
