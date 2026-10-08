import Foundation
import SwiftData

// Non-UI rules behind the live surfaces (Today, menu bar, overlay) and SessionEngine: today's total, the start
// label/tag choice, moving a session to another profile and the long-session warning. Pure functions over
// already-fetched models (no fetches), so views can call them in `body` and tests can cover them directly.

// MARK: - Today total

/// Today-total math on already-fetched sessions (midnight-safe: clips every session to today's interval),
/// limited to one profile's sessions (`ProfileScope.allProfiles` counts every session).
@MainActor
enum LiveDayMath {
    /// Active seconds today across the in-scope `sessions` (+ `active` if it is in scope and the query missed it,
    /// e.g. started > 2 days ago).
    static func totalToday(_ sessions: [WorkSession], active: WorkSession?, now: Date,
                           scope: ProfileScope) -> TimeInterval {
        let today = now.dayInterval
        var all = scope.filter(ModelLiveness.live(sessions))
        if let active, ModelLiveness.isLive(active), scope.contains(active),
           !all.contains(where: { $0 === active }) {
            all.append(active)
        }
        return all.reduce(0) { $0 + $1.activeDuration(in: today, now: now) }
    }

    /// Ended in-scope sessions that overlap today, newest first.
    static func endedToday(_ sessions: [WorkSession], now: Date, scope: ProfileScope) -> [WorkSession] {
        let today = now.dayInterval
        return scope.filter(ModelLiveness.live(sessions))
            .filter { session in
                guard let end = session.endedAt else { return false }
                return end > today.start && session.startedAt < today.end
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func goalSeconds(_ settings: AppSettings) -> TimeInterval {
        max(0, settings.dailyGoalHours) * 3600
    }
}

// MARK: - Start / split choices

/// Start/split choices are held in view state across Settings edits: a label or tag picked earlier may have been
/// deleted, merged or archived since, or belong to another profile after a profile switch. Resolve them right
/// before handing them to the engine.
@MainActor
enum LiveStartChoice {
    /// The picked label if it is still usable and offered in `profile` (nil = the engine's current profile, any
    /// label is accepted here and the engine checks it); otherwise `engine.defaultLabel(for: profile)`.
    /// `nil` (the user chose "None") stays `nil`.
    static func label(_ picked: WorkLabel?, engine: SessionEngine, profile: WorkProfile?) -> WorkLabel? {
        guard let picked else { return nil }
        let liveProfile = ModelLiveness.live(profile)
        if isUsable(picked, in: liveProfile?.uuid) { return picked }
        return engine.defaultLabel(for: liveProfile)
    }

    /// Like `label(_:engine:profile:)`, but a gone label becomes `nil` (the engine then keeps the current label).
    static func splitLabel(_ picked: WorkLabel?) -> WorkLabel? {
        guard let picked, isUsable(picked) else { return nil }
        return picked
    }

    static func tags(_ picked: [WorkTag]) -> [WorkTag] {
        picked.filter { ModelLiveness.isLive($0) && !$0.isArchived }
    }

    /// Usable tags that `profileID` offers (nil = all profiles).
    static func tags(_ picked: [WorkTag], in profileID: UUID?) -> [WorkTag] {
        let scope = ProfileScope(profileID: profileID)
        return tags(picked).filter { scope.offers($0) }
    }

    static func isUsable(_ label: WorkLabel) -> Bool {
        ModelLiveness.isLive(label) && !label.isArchived
    }

    /// Usable and offered in `profileID` (global or local to it; nil = all profiles).
    static func isUsable(_ label: WorkLabel, in profileID: UUID?) -> Bool {
        isUsable(label) && ProfileScope(profileID: profileID).offers(label)
    }

    /// The default-label rule (`SessionEngine.defaultLabel(for:)` delegates here), over already-fetched `labels`:
    /// non-archived labels offered in `profile`, by sort order; `profile.defaultLabelUUID` first; with no profile
    /// at all, the legacy `settings.defaultLabelID`; else the first one.
    static func defaultLabel(in labels: [WorkLabel], profile: WorkProfile?, settings: AppSettings) -> WorkLabel? {
        let liveProfile = ModelLiveness.live(profile)
        let candidates = labels
            .filter { isUsable($0, in: liveProfile?.uuid) }
            .sorted { $0.sortIndex < $1.sortIndex }
        let preferred: UUID?
        if let liveProfile {
            preferred = liveProfile.defaultLabelUUID
        } else {
            preferred = settings.defaultLabelID
        }
        if let id = preferred, let match = candidates.first(where: { $0.uuid == id }) {
            return match
        }
        return candidates.first
    }
}

// MARK: - Long-session warning

/// "Still working?": the running session has `settings.longSessionWarningHours` (0 = off) of active time. Pauses
/// (including an overnight auto-pause on sleep) don't count, and a paused session never warns: it isn't
/// accumulating anything to forget about. "Keep going" is per session (`SessionEngine.dismissLongSessionWarning`).
@MainActor
enum LiveLongSessionRule {
    /// Whole hours to show in the warning, or nil when there is nothing to warn about.
    static func warningHours(for session: WorkSession?, isPaused: Bool, isDismissed: Bool,
                             settings: AppSettings, now: Date) -> Int? {
        guard let session = ModelLiveness.live(session), session.endedAt == nil,
              !isPaused, !isDismissed, settings.longSessionWarningHours > 0 else { return nil }
        let active = session.activeDuration(at: now)
        guard active >= settings.longSessionWarningHours * 3600 else { return nil }
        return max(1, Int(active / 3600))
    }

    /// The engine's running session, with its per-session "Keep going" state.
    static func warningHours(engine: SessionEngine, settings: AppSettings, now: Date) -> Int? {
        guard let session = ModelLiveness.live(engine.activeSession) else { return nil }
        return warningHours(for: session, isPaused: engine.isPaused,
                            isDismissed: engine.isLongSessionWarningDismissed(for: session),
                            settings: settings, now: now)
    }
}

// MARK: - Moving a session to another profile

/// Moving a session (running or ended) to another profile, shared by Today's profile menu and Session detail's
/// Profile picker. A move that would copy labels or tags into the target asks first ("Move to Personal?").
@MainActor
enum LiveProfileMove {
    /// A pending confirmation. Holds the target's uuid and name, never the model (it may go away meanwhile).
    struct Request: Identifiable, Equatable {
        let id: UUID
        let name: String

        var title: String { "Move to \(name)?" }
        var message: String { "Labels and tags not in \(name) are copied." }
    }

    enum Outcome: Equatable {
        /// Moved (nothing had to be copied).
        case moved
        /// Nothing to do: already in that profile, or the session/profile is gone.
        case unchanged
        /// Labels or tags would be copied: confirm, then call `perform(_:moving:profiles:in:)`.
        case needsConfirmation(Request)
    }

    static func begin(moving session: WorkSession, to target: WorkProfile, in context: ModelContext) -> Outcome {
        guard ModelLiveness.isLive(session), ModelLiveness.isLive(target) else { return .unchanged }
        guard ProfileOps.effectiveProfileID(of: session) != target.uuid else { return .unchanged }
        if SessionEditor.taxonomyCopiedByMove(of: session, to: target).isEmpty {
            SessionEditor.moveSession(session, to: target, in: session.modelContext ?? context)
            return .moved
        }
        return .needsConfirmation(Request(id: target.uuid, name: target.displayName))
    }

    /// The confirmed move. Returns false when the session or the target profile no longer exists.
    @discardableResult
    static func perform(_ request: Request, moving session: WorkSession, profiles: ProfileStore,
                        in context: ModelContext) -> Bool {
        guard ModelLiveness.isLive(session),
              let target = ModelLiveness.live(profiles.profile(withID: request.id)) else { return false }
        SessionEditor.moveSession(session, to: target, in: session.modelContext ?? context)
        return true
    }
}
