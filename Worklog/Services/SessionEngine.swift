import AppKit
import CoreData
import Foundation
import Observation
import SwiftData

enum AutoPauseReason: String, Codable { case sleep, quit }

struct SessionTakeaway: Equatable {
    var sessionUUID: UUID
    var title: String        // session.displayTitle
    var date: Date           // session.startedAt
    var text: String         // session.takeawayText
    var labelName: String?
    /// uuid of the session's profile (nil = unassigned). Last, so existing memberwise calls still compile.
    var profileID: UUID? = nil
}

/// The live-session state machine shared by the main window, the menu bar extra and the overlay.
///
/// All times are wall-clock `Date`s stored on the models; elapsed time is always *computed* from them
/// (start/end/pauses), never accumulated, so sleep, relaunch and clock drift cannot corrupt it.
@MainActor @Observable
final class SessionEngine {
    // MARK: State (read-only for views unless noted)
    private(set) var activeSession: WorkSession? = nil {
        didSet {
            activeSessionUUID = activeSession.flatMap { ModelLiveness.live($0)?.uuid }
            pruneLongSessionWarningDismissals()
        }
    }
    /// Ended session awaiting the end-of-session sheet. RootView presents `EndSessionSheet` while non-nil.
    /// Settable so `.sheet(item:)` bindings work; setting nil by dismissal must go through `completeReview()`.
    /// Its uuid is persisted ("engine.pendingReviewUUID"), so quitting with the review open re-presents it at the
    /// next launch (`restoreActiveSession()`).
    var pendingEndSession: WorkSession? = nil {
        didSet { pendingSessionUUID = pendingEndSession?.uuid }
    }
    /// Latest takeaway per effective profile uuid (nil key = no profile at all): the most recent ended session of that profile
    /// with showInOverlay == true and a non-nil takeawayText. Rebuilt by refreshTakeaway().
    private(set) var takeaways: [UUID?: SessionTakeaway] = [:]
    /// The takeaway of `contextProfileID` (computed; observation tracks it through takeaways, activeSession and the
    /// ProfileStore's activeProfileID).
    var lastTakeaway: SessionTakeaway? {
        let key: UUID? = contextProfileID
        return takeaways[key]
    }
    /// Set when the engine paused automatically (sleep / quit). Persisted in UserDefaults "engine.autoPauseReason".
    private(set) var autoPauseReason: AutoPauseReason? = nil {
        didSet {
            guard oldValue != autoPauseReason else { return }
            if let autoPauseReason {
                defaults.set(autoPauseReason.rawValue, forKey: Self.autoPauseKey)
            } else {
                defaults.removeObject(forKey: Self.autoPauseKey)
            }
        }
    }
    /// Updated every 1 s while a session is running (Timer in .common run-loop mode). ONLY MenuBarLabelView reads it;
    /// every other view uses TimelineView(.periodic(from: .now, by: 1)).
    private(set) var tick: Date = .now
    var lastError: String? = nil
    /// Set when reconcile stopped an older session because a newer one was started (typically on another Mac).
    /// RootView shows it as a dismissible info banner; `clearHandoffNotice()` hides it.
    private(set) var handoffNotice: String? = nil
    /// Sessions whose long-session warning ("Still working?") was dismissed with "Keep going". Only the active
    /// session's entry is kept (cleared when it ends); persisted in UserDefaults "engine.longWarningDismissed" so the
    /// choice survives page switches and relaunches. Use `isLongSessionWarningDismissed(for:)`.
    private(set) var longSessionWarningDismissedUUIDs: Set<UUID> = [] {
        didSet {
            guard oldValue != longSessionWarningDismissedUUIDs else { return }
            if longSessionWarningDismissedUUIDs.isEmpty {
                defaults.removeObject(forKey: Self.longWarningDismissedKey)
            } else {
                defaults.set(longSessionWarningDismissedUUIDs.map(\.uuidString).sorted(),
                             forKey: Self.longWarningDismissedKey)
            }
        }
    }

    /// Stable per-install identifier (UserDefaults "engine.deviceID") stamped on sessions this Mac controls.
    let deviceID: String

    var isActive: Bool { activeSession != nil }
    /// Reads guard with `ModelLiveness`: the active session may have been deleted underneath (remote deletion,
    /// replace import) until `verifyTrackedSessions()` / `reconcile()` clears it.
    var isPaused: Bool { ModelLiveness.live(activeSession)?.isPaused ?? false }
    var isRunning: Bool { isActive && !isPaused }
    var currentSegment: Segment? { ModelLiveness.live(ModelLiveness.live(activeSession)?.currentSegment) }
    var currentLabel: WorkLabel? {
        ModelLiveness.live(currentSegment?.effectiveLabel) ?? ModelLiveness.live(ModelLiveness.live(activeSession)?.label)
    }
    /// Effective profile of the active session (`ProfileOps.effectiveProfile(of:)`: an unassigned session started by
    /// an older app version counts as the profile it is shown in); nil when idle.
    var activeSessionProfile: WorkProfile? {
        guard let session = ModelLiveness.live(activeSession) else { return nil }
        return ProfileOps.effectiveProfile(of: session)
    }
    var activeSessionProfileID: UUID? { activeSessionProfile?.uuid }
    /// Profile whose takeaway/today context applies: active session's profile when active, else
    /// profiles?.activeProfileID.
    var contextProfileID: UUID? {
        if activeSession != nil { return activeSessionProfileID }
        return profiles?.activeProfileID
    }
    /// The active session was last controlled from another Mac (its owner is set and isn't this install).
    var isActiveSessionOnAnotherMac: Bool {
        guard let owner = ModelLiveness.live(activeSession)?.ownerDeviceID, !owner.isEmpty else { return false }
        return owner != deviceID
    }

    // MARK: Private
    // Members without `private` below are internal only so SessionEngine's extensions in other files
    // (SessionEngine+Review/+Takeaway/+Ownership/+SystemEvents) can use them; views must not.
    private static let autoPauseKey = "engine.autoPauseReason"
    private static let deviceIDKey = "engine.deviceID"
    /// uuid of the session awaiting review (`pendingEndSession`).
    private static let pendingReviewKey = "engine.pendingReviewUUID"
    private static let longWarningDismissedKey = "engine.longWarningDismissed"
    /// The session that was started while a takeaway was showing ("consumer") and that takeaway's session ("source").
    static let takeawayConsumerKey = "engine.takeawayConsumerUUID"
    static let takeawaySourceKey = "engine.takeawaySourceUUID"

    let context: ModelContext
    let settings: AppSettings
    /// The current profile (nil in tests that don't use profiles: everything then behaves as before profiles).
    private let profiles: ProfileStore?
    var defaults: UserDefaults { settings.defaults }
    /// Identity of the pending session, captured when it is set, so reconcile never has to touch a model
    /// object that may have been deleted underneath us (import/replace, remote deletion).
    @ObservationIgnored private var pendingSessionUUID: UUID? {
        didSet {
            guard oldValue != pendingSessionUUID else { return }
            if let pendingSessionUUID {
                defaults.set(pendingSessionUUID.uuidString, forKey: Self.pendingReviewKey)
            } else {
                defaults.removeObject(forKey: Self.pendingReviewKey)
            }
        }
    }
    /// Identity of the active session (same reason).
    @ObservationIgnored private var activeSessionUUID: UUID?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored var workspaceObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored var isObservingSystemEvents = false
    @ObservationIgnored var remoteChangeTask: Task<Void, Never>?
    @ObservationIgnored var didSaveTask: Task<Void, Never>?
    /// Sessions that were discarded but not deleted yet (two-phase discard). Never adopted, never shown as takeaway.
    @ObservationIgnored var discardingUUIDs: Set<UUID> = []
    /// The pending (ended) session discarded from the end sheet; deleted by `finishPendingDiscard()`.
    @ObservationIgnored var pendingDiscardUUID: UUID?

    init(context: ModelContext, settings: AppSettings, profiles: ProfileStore? = nil) {
        self.context = context
        self.settings = settings
        self.profiles = profiles
        if let stored = settings.defaults.string(forKey: Self.deviceIDKey), !stored.isEmpty {
            deviceID = stored
        } else {
            let fresh = UUID().uuidString
            settings.defaults.set(fresh, forKey: Self.deviceIDKey)
            deviceID = fresh
        }
    }

    // MARK: - Lifecycle

    /// Fetch sessions with endedAt == nil; adopt the most recent as active (end any others at the handoff — see
    /// `handoffEnd`); set `handoffNotice` when that happens;
    /// restore autoPauseReason, the session awaiting review (re-presented when it still exists and has ended) and the
    /// long-session warning dismissal; refreshTakeaway(); start/stop tick timer. Called once by AppServices.
    func restoreActiveSession() {
        autoPauseReason = defaults.string(forKey: Self.autoPauseKey).flatMap(AutoPauseReason.init(rawValue:))
        pendingSessionUUID = defaults.string(forKey: Self.pendingReviewKey).flatMap(UUID.init(uuidString:))
        longSessionWarningDismissedUUIDs = Set((defaults.stringArray(forKey: Self.longWarningDismissedKey) ?? [])
            .compactMap(UUID.init(uuidString:)))
        reconcile()
        pruneLongSessionWarningDismissals()
        observeSettings()
        if let session = activeSession {
            Log.engine.info("Restored active session started \(session.startedAt.ISO8601Format(), privacy: .public)")
        }
    }

    /// Re-sync with the store (after import/restore, remote CloudKit changes, app activation). Same logic as restore.
    /// Extra running sessions are ended only when this Mac owns them or they started more than a minute ago
    /// (`shouldEndExtraSession`): a session another Mac started a moment ago is left to that Mac.
    func reconcile(now: Date = .now) {
        let actives = fetchActiveSessions()
        var changed = false
        if let newest = actives.first {
            for extra in actives.dropFirst() {
                guard Self.shouldEndExtraSession(ownerDeviceID: extra.ownerDeviceID, deviceID: deviceID,
                                                 startedAt: extra.startedAt, now: now) else {
                    Log.engine.info("Reconcile: left another Mac\u{2019}s just-started session to that Mac")
                    continue
                }
                let end = handoffEnd(of: extra, newest: newest)
                let extraOwner = extra.ownerDeviceID
                let newestOwner = newest.ownerDeviceID
                SessionEditor.endSession(extra, at: end)
                changed = true
                let time = (extra.endedAt ?? end).shortTime
                if extraOwner == deviceID && newestOwner != deviceID {
                    handoffNotice = "Stopped here at \(time); newer session on another Mac."
                } else if !extraOwner.isEmpty && extraOwner != deviceID {
                    handoffNotice = "Stopped another Mac\u{2019}s session at \(time)."
                } else {
                    handoffNotice = "Stopped an older running session at \(time)."
                }
                Log.engine.info("Reconcile: ended an older active session (handoff)")
            }
            if activeSession !== newest { activeSession = newest }
        } else if activeSession != nil {
            activeSession = nil
        }

        // The pending review session may have been deleted (replace import, delete-all, another Mac).
        if let pendingUUID = pendingSessionUUID {
            let found = fetchSession(uuid: pendingUUID)
            if let found, found.endedAt != nil {
                if pendingEndSession !== found { pendingEndSession = found }
            } else {
                pendingEndSession = nil
            }
        }

        if !isPaused, autoPauseReason != nil {
            autoPauseReason = nil
        }
        if changed { save() }
        refreshTakeaway()
        updateTickTimer()
    }

    /// L6 (pure): an extra running session is ended when this Mac owns it (or it has no owner), or it started more
    /// than 60 s ago.
    nonisolated static func shouldEndExtraSession(ownerDeviceID: String, deviceID: String, startedAt: Date,
                                                  now: Date) -> Bool {
        if ownerDeviceID.isEmpty || ownerDeviceID == deviceID { return true }
        return now.timeIntervalSince(startedAt) > 60
    }

    /// M3: right after a remote change, drop an active/pending session that was deleted or can't be fetched any
    /// more, so views never read a deleted model while the coalesced `reconcile()` is still waiting.
    func verifyTrackedSessions() {
        if let session = activeSession {
            let gone = !ModelLiveness.isLive(session)
                || activeSessionUUID.map { fetchSession(uuid: $0) == nil } ?? true
            if gone {
                activeSession = nil
                updateTickTimer()
                Log.engine.info("The active session was deleted elsewhere")
            }
        }
        if let pending = pendingEndSession {
            let gone = !ModelLiveness.isLive(pending)
                || pendingSessionUUID.map { fetchSession(uuid: $0) == nil } ?? true
            if gone { pendingEndSession = nil }
        }
    }

    /// On quit: if settings.pauseOnQuit && isRunning (and this Mac owns the session) → pause(), autoPauseReason = .quit.
    /// Finishes any pending discard. Always saves.
    func prepareForTermination() {
        flushDiscards()
        if settings.pauseOnQuit && isRunning && isOwnedByThisDevice(activeSession) {
            pause()
            autoPauseReason = .quit
        }
        if let session = ModelLiveness.live(activeSession) {
            session.recomputeStoredDuration()
        }
        save()
    }

    /// try context.save(); on error sets lastError + logs.
    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
            Log.engine.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Time

    /// Active (pause-excluded) seconds of the active session at `date`; 0 if none (or deleted underneath).
    func elapsed(at date: Date = .now) -> TimeInterval {
        ModelLiveness.live(activeSession)?.activeDuration(at: date) ?? 0
    }

    /// Active seconds of the current segment at `date`; 0 if none.
    func currentSegmentElapsed(at date: Date = .now) -> TimeInterval {
        currentSegment?.activeDuration(at: date) ?? 0
    }

    /// Active seconds today of the sessions in `scope` (fetch startedAt >= today−2d), the active session included
    /// when it is in scope even if it started earlier. One rule with the UI: `LiveDayMath.totalToday`.
    /// `scope` defaults to .allProfiles.
    func totalActiveToday(now: Date = .now, scope: ProfileScope = .allProfiles) -> TimeInterval {
        let today = now.dayInterval
        let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: today.start)
            ?? today.start.addingTimeInterval(-2 * 86_400)
        let descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.startedAt >= cutoff })
        let sessions = (try? context.fetch(descriptor)) ?? []
        return LiveDayMath.totalToday(sessions, active: ModelLiveness.live(activeSession), now: now, scope: scope)
    }

    /// profile nil → profiles?.activeProfile. One rule with the UI: `LiveStartChoice.defaultLabel(in:profile:settings:)`
    /// over all labels (non-archived labels offered in that profile, by sortIndex; profile.defaultLabelUUID first;
    /// with no profile at all the legacy settings.defaultLabelID; else the first).
    func defaultLabel(for profile: WorkProfile? = nil) -> WorkLabel? {
        let target = ModelLiveness.live(profile) ?? ModelLiveness.live(profiles?.activeProfile)
        let descriptor = FetchDescriptor<WorkLabel>(sortBy: [SortDescriptor(\WorkLabel.sortIndex)])
        let labels = (try? context.fetch(descriptor)) ?? []
        return LiveStartChoice.defaultLabel(in: labels, profile: target, settings: settings)
    }

    // MARK: - Controls

    /// If a session is already active, returns it unchanged. Otherwise inserts a WorkSession(startedAt: date) in
    /// the resolved profile (profile nil → profiles?.activeProfile when live & non-archived, else nil), sets
    /// session.label = label, inserts the first Segment(sortIndex 0, label, focus, tags), saves, clears
    /// autoPauseReason, starts tick. A label not offered in that profile is replaced by defaultLabel(for:); tags not
    /// offered there are dropped.
    /// Start tags go on the FIRST SEGMENT (session.tags stays empty): Today's edit/split forms show and change them,
    /// and a later segment doesn't inherit them in Stats or filters. (Sessions from older builds may still carry
    /// session-level tags; they keep counting for every segment.)
    @discardableResult
    func start(label: WorkLabel?, tags: [WorkTag] = [], focus: String = "", at date: Date = .now,
               profile: WorkProfile? = nil) -> WorkSession {
        if let session = ModelLiveness.live(activeSession) { return session }

        let resolvedProfile: WorkProfile?
        if let given = ModelLiveness.live(profile) {
            resolvedProfile = given
        } else if let current = ModelLiveness.live(profiles?.activeProfile), !current.isArchived {
            resolvedProfile = current
        } else {
            resolvedProfile = nil
        }
        let scope = ProfileScope(profileID: resolvedProfile?.uuid)
        let resolvedLabel: WorkLabel?
        if let label {
            resolvedLabel = scope.offers(label) ? label : defaultLabel(for: resolvedProfile)
        } else {
            resolvedLabel = nil
        }
        let resolvedTags = tags.filter { scope.offers($0) }

        let session = WorkSession(startedAt: date)
        context.insert(session)
        session.ownerDeviceID = deviceID
        session.profile = resolvedProfile
        session.label = resolvedLabel
        session.tags = []
        rememberTakeawaySource(for: session)

        let segment = Segment(startedAt: date, endedAt: nil, sortIndex: 0, focus: focus.trimmed)
        context.insert(segment)
        segment.label = resolvedLabel
        segment.tags = resolvedTags
        segment.session = session

        activeSession = session
        autoPauseReason = nil
        save()
        updateTickTimer()
        Log.engine.info("Started session")
        return session
    }

    /// No-op unless running. Appends PauseInterval(start: date).
    func pause(at date: Date = .now) {
        guard isRunning, let session = ModelLiveness.live(activeSession) else { return }
        var pauses = session.pauseIntervals
        let lowerBound = max(session.startedAt, pauses.last?.end ?? session.startedAt)
        pauses.append(PauseInterval(start: max(date, lowerBound)))
        session.pauseIntervals = pauses
        stampOwner(session)
        session.touch()
        save()
        updateTickTimer()
    }

    /// No-op unless paused. Closes the open interval with end = date; clears autoPauseReason.
    func resume(at date: Date = .now) {
        guard isPaused, let session = ModelLiveness.live(activeSession) else { return }
        var pauses = session.pauseIntervals
        guard let lastIndex = pauses.indices.last else { return }
        pauses[lastIndex].end = max(date, pauses[lastIndex].start)
        session.pauseIntervals = pauses
        stampOwner(session)
        session.touch()
        autoPauseReason = nil
        save()
        updateTickTimer()
    }

    func togglePause() {
        if isPaused {
            resume()
        } else if isRunning {
            pause()
        }
    }

    /// No-op (returns nil) if not active. Clamps `date` to ≥ current segment start; closes open pause at `date`
    /// and drops/clips pauses after `date`; sets segment.endedAt and session.endedAt = date;
    /// recomputeStoredDuration; save; activeSession = nil; stop tick;
    /// pendingEndSession = session if settings.showEndSessionSheet, else refreshTakeaway().
    /// Callers outside the main window MUST call `router.showMainWindow()` afterwards so the sheet is visible.
    @discardableResult
    func stop(at date: Date = .now) -> WorkSession? {
        guard let session = ModelLiveness.live(activeSession) else {
            clearStaleActiveSession()
            return nil
        }
        stampOwner(session)
        ProfileOps.assignProfileIfUnassigned(session, in: context)
        SessionEditor.endSession(session, at: date)
        activeSession = nil
        autoPauseReason = nil
        if settings.showEndSessionSheet {
            save()
            pendingEndSession = session
        } else {
            // No review sheet: the review is complete right away.
            consumeTakeawayIfNeeded(reviewed: session)
            save()
            refreshTakeaway()
        }
        updateTickTimer()
        Log.engine.info("Stopped session (\(session.storedActiveDuration, privacy: .public)s active)")
        return session
    }

    /// Deletes the active session (cascade). Callers confirm first if settings.confirmBeforeDiscard.
    /// Safe to call while views still show the session: `activeSession` becomes nil immediately (views switch away),
    /// the delete + save happen on the next main-actor turn. The returned task completes after the delete
    /// (tests can `await engine.discard()?.value`); nil when there was no active session.
    @discardableResult
    func discard() -> Task<Void, Never>? {
        guard let session = ModelLiveness.live(activeSession) else {
            clearStaleActiveSession()
            return nil
        }
        let uuid = session.uuid
        discardingUUIDs.insert(uuid)
        activeSession = nil
        autoPauseReason = nil
        updateTickTimer()
        Log.engine.info("Discarded active session")
        return Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishDiscard(uuid: uuid)
        }
    }

    /// Live split. Closes current segment at `date` and opens Segment(startedAt: date, sortIndex: max+1,
    /// label: label ?? currentLabel, tags: tags, focus: focus). Allowed while paused. Returns the new segment.
    /// If the current segment is shorter than `SessionEditor.minimumSegmentLength` at `date`, it is updated in
    /// place instead (no zero-length segments) and returned.
    @discardableResult
    func split(label: WorkLabel?, tags: [WorkTag] = [], focus: String = "", at date: Date = .now) -> Segment? {
        guard let session = ModelLiveness.live(activeSession) else { return nil }
        stampOwner(session)
        ProfileOps.assignProfileIfUnassigned(session, in: context)
        let resolvedLabel = label ?? currentLabel
        let segments = session.sortedSegments
        let current = session.currentSegment ?? segments.last

        if let current, date.timeIntervalSince(current.startedAt) < SessionEditor.minimumSegmentLength {
            current.label = resolvedLabel
            current.tags = tags
            current.focus = focus.trimmed
            if segments.count == 1 { session.label = resolvedLabel }
            session.touch()
            save()
            return current
        }

        let splitDate = max(date, current?.startedAt ?? session.startedAt)
        current?.endedAt = splitDate
        let nextIndex = (segments.map(\.sortIndex).max() ?? -1) + 1
        let segment = Segment(startedAt: splitDate, endedAt: nil, sortIndex: nextIndex, focus: focus.trimmed)
        context.insert(segment)
        segment.label = resolvedLabel
        segment.tags = tags
        segment.session = session
        session.touch()
        save()
        return segment
    }

    /// Edit the current segment in place (no split). If the session has exactly one segment, session.label follows.
    func updateCurrentSegment(label: WorkLabel?, tags: [WorkTag], focus: String) {
        guard let session = ModelLiveness.live(activeSession), let segment = session.currentSegment else { return }
        stampOwner(session)
        ProfileOps.assignProfileIfUnassigned(session, in: context)
        segment.label = label
        segment.tags = tags
        segment.focus = focus.trimmed
        if (session.segments ?? []).count == 1 {
            session.label = label
        }
        session.touch()
        save()
    }

    /// Trims; ignores blank or no active session. Note(text, createdAt: date), session = active, segment = currentSegment.
    @discardableResult
    func addNote(_ text: String, at date: Date = .now) -> Note? {
        let trimmedText = text.trimmed
        guard !trimmedText.isEmpty, let session = ModelLiveness.live(activeSession) else { return nil }
        let note = Note(text: trimmedText, createdAt: date)
        context.insert(note)
        note.session = session
        note.segment = session.currentSegment ?? session.segment(containing: date)
        stampOwner(session)
        ProfileOps.assignProfileIfUnassigned(session, in: context)
        session.touch()
        save()
        return note
    }

    // MARK: - End-of-session review (re-open)
    // completeReview / discardPendingSession / finishPendingDiscard: SessionEngine+Review.swift.

    /// Re-open pending session (only if no active session): endedAt = nil, last segment endedAt = nil,
    /// the gap [old endedAt, now] is appended as a closed PauseInterval; becomes activeSession; pendingEndSession = nil.
    func resumePendingSession() {
        guard let session = pendingEndSession, activeSession == nil else { return }
        let now = Date.now
        let oldEnd = session.endedAt ?? now
        var pauses = session.pauseIntervals
        if now > oldEnd {
            pauses.append(PauseInterval(start: oldEnd, end: now))
        }
        session.pauseIntervals = pauses
        session.endedAt = nil
        session.sortedSegments.last?.endedAt = nil
        stampOwner(session)
        ProfileOps.assignProfileIfUnassigned(session, in: context)
        SessionEditor.normalize(session)
        session.recomputeStoredDuration(now: now)
        session.touch()

        pendingEndSession = nil
        activeSession = session
        autoPauseReason = nil
        save()
        updateTickTimer()
        refreshTakeaway()
    }

    /// Rebuilds `takeaways`: per profile uuid, the newest candidate (fetch limit 200) wins. Assigns only on change.
    func refreshTakeaway() {
        var descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate<WorkSession> { $0.endedAt != nil && $0.showInOverlay == true },
            sortBy: [SortDescriptor(\WorkSession.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        let candidates = (try? context.fetch(descriptor)) ?? []
        var newValue: [UUID?: SessionTakeaway] = [:]
        for session in candidates where session !== pendingEndSession && !session.isDeleted
            && !discardingUUIDs.contains(session.uuid) {
            let key: UUID? = ProfileOps.effectiveProfileID(of: session)
            guard newValue[key] == nil, let text = session.takeawayText else { continue }
            newValue[key] = SessionTakeaway(sessionUUID: session.uuid, title: session.displayTitle,
                                            date: session.startedAt, text: text,
                                            labelName: ModelLiveness.live(session.label)?.name, profileID: key)
        }
        if newValue != takeaways { takeaways = newValue }
    }

    // takeaway(for:) / dismissTakeaway and the takeaway lifecycle: SessionEngine+Takeaway.swift.

    func clearAutoPauseReason() {
        autoPauseReason = nil
    }

    func clearHandoffNotice() {
        handoffNotice = nil
    }

    // MARK: - Long-session warning

    /// True when "Keep going" was chosen for `session`'s long-session warning (see
    /// `longSessionWarningDismissedUUIDs`). False for a deleted session.
    func isLongSessionWarningDismissed(for session: WorkSession) -> Bool {
        guard let session = ModelLiveness.live(session) else { return false }
        return longSessionWarningDismissedUUIDs.contains(session.uuid)
    }

    /// "Keep going": hides the long-session warning for `session` until it ends. Only for the running session.
    func dismissLongSessionWarning(for session: WorkSession) {
        guard let session = ModelLiveness.live(session), session.endedAt == nil,
              session.uuid == activeSessionUUID else { return }
        longSessionWarningDismissedUUIDs.insert(session.uuid)
    }

    /// Keeps only the active session's dismissal (an ended, discarded or replaced session's entry is dropped).
    private func pruneLongSessionWarningDismissals() {
        guard !longSessionWarningDismissedUUIDs.isEmpty else { return }
        let kept = longSessionWarningDismissedUUIDs.filter { $0 == activeSessionUUID }
        if kept != longSessionWarningDismissedUUIDs { longSessionWarningDismissedUUIDs = kept }
    }

    // MARK: - Private

    /// The active session was deleted underneath (it can't be read any more): forget it.
    private func clearStaleActiveSession() {
        guard activeSession != nil else { return }
        activeSession = nil
        updateTickTimer()
    }

    private func fetchActiveSessions() -> [WorkSession] {
        let descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate<WorkSession> { $0.endedAt == nil },
            sortBy: [SortDescriptor(\WorkSession.startedAt, order: .reverse)]
        )
        do {
            let excluded = discardingUUIDs
            return try context.fetch(descriptor).filter { !$0.isDeleted && !excluded.contains($0.uuid) }
        } catch {
            Log.engine.error("Fetching active sessions failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func fetchSession(uuid: UUID) -> WorkSession? {
        var descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first(where: { !$0.isDeleted })
    }

    // Ownership (isOwnedByThisDevice, stampOwner, handoffEnd): SessionEngine+Ownership.swift.

    // MARK: Discard

    func finishDiscard(uuid: UUID) {
        defer { discardingUUIDs.remove(uuid) }
        if pendingDiscardUUID == uuid { pendingDiscardUUID = nil }
        if let session = fetchSession(uuid: uuid) {
            if activeSession === session { activeSession = nil }
            if pendingEndSession === session { pendingEndSession = nil }
            context.delete(session)
            save()
        }
        if defaults.string(forKey: Self.takeawayConsumerKey) == uuid.uuidString {
            clearTakeawayLink()
        }
        refreshTakeaway()
        updateTickTimer()
    }

    /// Completes every outstanding discard synchronously (quit).
    private func flushDiscards() {
        pendingDiscardUUID = nil
        for uuid in discardingUUIDs {
            finishDiscard(uuid: uuid)
        }
    }

    // MARK: System events

    func handleWillSleep() {
        guard settings.pauseOnSleep, isRunning, isOwnedByThisDevice(activeSession) else { return }
        pause(at: .now)
        autoPauseReason = .sleep
        Log.engine.info("Auto-paused for sleep")
    }

    func handleDidWake() {
        // Never auto-resume; the UI offers Resume via autoPauseReason.
        tick = .now
        updateTickTimer()
    }

    func handleDidBecomeActive() {
        SeedData.deduplicate(in: context)
        reconcile()
    }

    /// The tick only runs while a session is running and the menu bar shows a timer; otherwise it is refreshed once.
    func updateTickTimer() {
        tick = .now
        let shouldRun = isRunning && settings.menuBarShowsTimer
        if shouldRun {
            guard tickTimer == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { () -> Void in self?.tick = .now }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }
}