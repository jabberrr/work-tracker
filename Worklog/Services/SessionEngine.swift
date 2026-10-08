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
    private(set) var activeSession: WorkSession? = nil
    /// Ended session awaiting the end-of-session sheet. RootView presents `EndSessionSheet` while non-nil.
    /// Settable so `.sheet(item:)` bindings work; setting nil by dismissal must go through `completeReview()`.
    var pendingEndSession: WorkSession? = nil {
        didSet { pendingSessionUUID = pendingEndSession?.uuid }
    }
    /// Latest takeaway per profile uuid (nil key = unassigned sessions): the most recent ended session of that profile
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

    /// Stable per-install identifier (UserDefaults "engine.deviceID") stamped on sessions this Mac controls.
    let deviceID: String

    var isActive: Bool { activeSession != nil }
    var isPaused: Bool { activeSession?.isPaused ?? false }
    var isRunning: Bool { isActive && !isPaused }
    var currentSegment: Segment? { activeSession?.currentSegment }
    var currentLabel: WorkLabel? { currentSegment?.effectiveLabel ?? activeSession?.label }
    /// Live profile of the active session (nil when idle/unassigned).
    var activeSessionProfile: WorkProfile? {
        guard let session = ModelLiveness.live(activeSession) else { return nil }
        return ModelLiveness.live(session.profile)
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
        guard let owner = activeSession?.ownerDeviceID, !owner.isEmpty else { return false }
        return owner != deviceID
    }

    // MARK: Private
    private static let autoPauseKey = "engine.autoPauseReason"
    private static let deviceIDKey = "engine.deviceID"
    /// The session that was started while a takeaway was showing ("consumer") and that takeaway's session ("source").
    private static let takeawayConsumerKey = "engine.takeawayConsumerUUID"
    private static let takeawaySourceKey = "engine.takeawaySourceUUID"

    private let context: ModelContext
    private let settings: AppSettings
    /// The current profile (nil in tests that don't use profiles: everything then behaves as before profiles).
    private let profiles: ProfileStore?
    private var defaults: UserDefaults { settings.defaults }
    /// Identity of the pending session, captured when it is set, so reconcile never has to touch a model
    /// object that may have been deleted underneath us (import/replace, remote deletion).
    @ObservationIgnored private var pendingSessionUUID: UUID?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var isObservingSystemEvents = false
    @ObservationIgnored private var remoteChangeTask: Task<Void, Never>?
    @ObservationIgnored private var didSaveTask: Task<Void, Never>?
    /// Sessions that were discarded but not deleted yet (two-phase discard). Never adopted, never shown as takeaway.
    @ObservationIgnored private var discardingUUIDs: Set<UUID> = []
    /// The pending (ended) session discarded from the end sheet; deleted by `finishPendingDiscard()`.
    @ObservationIgnored private var pendingDiscardUUID: UUID?

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
    /// restore autoPauseReason; refreshTakeaway(); start/stop tick timer. Called once by AppServices.
    func restoreActiveSession() {
        autoPauseReason = defaults.string(forKey: Self.autoPauseKey).flatMap(AutoPauseReason.init(rawValue:))
        reconcile()
        observeSettings()
        if let session = activeSession {
            Log.engine.info("Restored active session started \(session.startedAt.ISO8601Format(), privacy: .public)")
        }
    }

    /// Re-sync with the store (after import/restore, remote CloudKit changes, app activation). Same logic as restore.
    func reconcile() {
        let actives = fetchActiveSessions()
        var changed = false
        if let newest = actives.first {
            for extra in actives.dropFirst() {
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

        if !(activeSession?.isPaused ?? false), autoPauseReason != nil {
            autoPauseReason = nil
        }
        if changed { save() }
        refreshTakeaway()
        updateTickTimer()
    }

    /// Installs NSWorkspace willSleep/didWake + NSApplication.didBecomeActive observers (called by AppServices /
    /// AppDelegate). Also observes `.worklogDataDidImport` and persistent-store remote changes (CloudKit imports).
    func startObservingSystemEvents() {
        guard !isObservingSystemEvents else { return }
        isObservingSystemEvents = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.handleWillSleep() }
        })
        workspaceObserverTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.handleDidWake() }
        })

        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.handleDidBecomeActive() }
        })
        observerTokens.append(center.addObserver(
            forName: .worklogDataDidImport, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.reconcile() }
        })
        observerTokens.append(center.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.scheduleRemoteChangeReconcile() }
        })
        observerTokens.append(center.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.scheduleTakeawayRefresh() }
        })
    }

    /// On quit: if settings.pauseOnQuit && isRunning (and this Mac owns the session) → pause(), autoPauseReason = .quit.
    /// Finishes any pending discard. Always saves.
    func prepareForTermination() {
        flushDiscards()
        if settings.pauseOnQuit && isRunning && isOwnedByThisDevice(activeSession) {
            pause()
            autoPauseReason = .quit
        }
        if let session = activeSession {
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

    /// Active (pause-excluded) seconds of the active session at `date`; 0 if none.
    func elapsed(at date: Date = .now) -> TimeInterval {
        activeSession?.activeDuration(at: date) ?? 0
    }

    /// Active seconds of the current segment at `date`; 0 if none.
    func currentSegmentElapsed(at date: Date = .now) -> TimeInterval {
        currentSegment?.activeDuration(at: date) ?? 0
    }

    /// Sum of activeDuration(in: today) over the sessions in `scope` overlapping today (fetch startedAt >= today−2d,
    /// filter in memory). The active session is included when it is in scope, even if it started earlier.
    /// `scope` defaults to .allProfiles.
    func totalActiveToday(now: Date = .now, scope: ProfileScope = .allProfiles) -> TimeInterval {
        let today = now.dayInterval
        let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: today.start)
            ?? today.start.addingTimeInterval(-2 * 86_400)
        let descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.startedAt >= cutoff })
        var sessions = (try? context.fetch(descriptor)) ?? []
        if let active = activeSession, !sessions.contains(where: { $0 === active }) {
            sessions.append(active)
        }
        return scope.filter(sessions).reduce(0) { $0 + $1.activeDuration(in: today, now: now) }
    }

    /// profile nil → profiles?.activeProfile. Candidates: non-archived labels offered in that profile
    /// (ProfileScope(profileID:)), by sortIndex. Preference: profile.defaultLabelUUID; when no profile at all, legacy
    /// settings.defaultLabelID; else first.
    func defaultLabel(for profile: WorkProfile? = nil) -> WorkLabel? {
        let target = ModelLiveness.live(profile) ?? ModelLiveness.live(profiles?.activeProfile)
        let scope = ProfileScope(profileID: target?.uuid)
        let descriptor = FetchDescriptor<WorkLabel>(sortBy: [SortDescriptor(\WorkLabel.sortIndex)])
        let labels = ((try? context.fetch(descriptor)) ?? []).filter { scope.offers($0) && !$0.isArchived }
        let preferred: UUID?
        if let target {
            preferred = target.defaultLabelUUID
        } else {
            preferred = settings.defaultLabelID   // legacy: no profile at all
        }
        if let id = preferred, let match = labels.first(where: { $0.uuid == id }) {
            return match
        }
        return labels.first
    }

    // MARK: - Controls

    /// If a session is already active, returns it unchanged. Otherwise inserts a WorkSession(startedAt: date) in
    /// the resolved profile (profile nil → profiles?.activeProfile when live & non-archived, else nil), sets
    /// session.label = label, session.tags = tags, inserts first Segment(sortIndex 0, label, focus, tags: []),
    /// saves, clears autoPauseReason, starts tick. A label not offered in that profile is replaced by
    /// defaultLabel(for:); tags not offered there are dropped.
    @discardableResult
    func start(label: WorkLabel?, tags: [WorkTag] = [], focus: String = "", at date: Date = .now,
               profile: WorkProfile? = nil) -> WorkSession {
        if let session = activeSession { return session }

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
        session.tags = resolvedTags
        rememberTakeawaySource(for: session)

        let segment = Segment(startedAt: date, endedAt: nil, sortIndex: 0, focus: focus.trimmed)
        context.insert(segment)
        segment.label = resolvedLabel
        segment.tags = []
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
        guard isRunning, let session = activeSession else { return }
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
        guard isPaused, let session = activeSession else { return }
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
        guard let session = activeSession else { return nil }
        stampOwner(session)
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
        guard let session = activeSession else { return nil }
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
        guard let session = activeSession else { return nil }
        stampOwner(session)
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
        guard let session = activeSession, let segment = session.currentSegment else { return }
        stampOwner(session)
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
        guard !trimmedText.isEmpty, let session = activeSession else { return nil }
        let note = Note(text: trimmedText, createdAt: date)
        context.insert(note)
        note.session = session
        note.segment = session.currentSegment ?? session.segment(containing: date)
        stampOwner(session)
        session.touch()
        save()
        return note
    }

    // MARK: - End-of-session review

    /// Save pending session (touch, recomputeStoredDuration), pendingEndSession = nil, refreshTakeaway().
    /// With `settings.takeawayNextSessionOnly`, the takeaway that was showing when this session started is retired.
    /// Idempotent: safe to call again from the sheet's dismissal binding.
    func completeReview() {
        if let session = pendingEndSession {
            pendingEndSession = nil
            if !session.isDeleted {
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
            let key: UUID? = ModelLiveness.live(session.profile)?.uuid
            guard newValue[key] == nil, let text = session.takeawayText else { continue }
            newValue[key] = SessionTakeaway(sessionUUID: session.uuid, title: session.displayTitle,
                                            date: session.startedAt, text: text,
                                            labelName: ModelLiveness.live(session.label)?.name, profileID: key)
        }
        if newValue != takeaways { takeaways = newValue }
    }

    /// The latest takeaway of that profile (nil = unassigned sessions).
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

    func clearAutoPauseReason() {
        autoPauseReason = nil
    }

    func clearHandoffNotice() {
        handoffNotice = nil
    }

    // MARK: - Private

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

    private func fetchSession(uuid: UUID) -> WorkSession? {
        var descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first(where: { !$0.isDeleted })
    }

    // MARK: Ownership

    /// Sessions with no owner (created before ownership existed, or imported) count as this Mac's.
    private func isOwnedByThisDevice(_ session: WorkSession?) -> Bool {
        guard let session else { return false }
        return session.ownerDeviceID.isEmpty || session.ownerDeviceID == deviceID
    }

    /// Manual control from this Mac makes it the session's owner.
    private func stampOwner(_ session: WorkSession) {
        if session.ownerDeviceID != deviceID { session.ownerDeviceID = deviceID }
    }

    /// When two Macs each started a session, the older one ends where the newer one began (the handoff), unless
    /// the older one had been idle for longer than the long-session threshold — then it ends at its last activity.
    private func handoffEnd(of extra: WorkSession, newest: WorkSession) -> Date {
        let lastActivity = extra.lastActivityDate
        let handoff = newest.startedAt
        guard handoff > lastActivity else { return lastActivity }
        let threshold = max(settings.longSessionWarningHours, 0) * 3600
        return handoff.timeIntervalSince(lastActivity) <= threshold ? handoff : lastActivity
    }

    // MARK: Discard

    private func finishDiscard(uuid: UUID) {
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

    // MARK: Takeaway lifecycle

    /// Records which takeaway was on screen when `session` started, so its review can retire it.
    private func rememberTakeawaySource(for session: WorkSession) {
        refreshTakeaway()
        if let source = takeaway(for: ModelLiveness.live(session.profile)?.uuid)?.sessionUUID {
            defaults.set(session.uuid.uuidString, forKey: Self.takeawayConsumerKey)
            defaults.set(source.uuidString, forKey: Self.takeawaySourceKey)
        } else {
            clearTakeawayLink()
        }
    }

    /// Next-session-only mode: once the session that followed a takeaway is reviewed, that takeaway is retired.
    private func consumeTakeawayIfNeeded(reviewed session: WorkSession) {
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
        let sourceProfileID = ModelLiveness.live(source.profile)?.uuid
        var descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate<WorkSession> { $0.endedAt != nil && $0.showInOverlay == true && $0.startedAt <= cutoff }
        )
        descriptor.fetchLimit = 500
        let older = (try? context.fetch(descriptor)) ?? []
        for session in older where !session.isDeleted && session !== pendingEndSession
            && ModelLiveness.live(session.profile)?.uuid == sourceProfileID {
            session.showInOverlay = false
        }
    }

    private func clearTakeawayLink() {
        defaults.removeObject(forKey: Self.takeawayConsumerKey)
        defaults.removeObject(forKey: Self.takeawaySourceKey)
    }

    // MARK: System events

    private func handleWillSleep() {
        guard settings.pauseOnSleep, isRunning, isOwnedByThisDevice(activeSession) else { return }
        pause(at: .now)
        autoPauseReason = .sleep
        Log.engine.info("Auto-paused for sleep")
    }

    private func handleDidWake() {
        // Never auto-resume; the UI offers Resume via autoPauseReason.
        tick = .now
        updateTickTimer()
    }

    private func handleDidBecomeActive() {
        SeedData.deduplicate(in: context)
        reconcile()
    }

    /// CloudKit imports arrive in bursts; coalesce them.
    private func scheduleRemoteChangeReconcile() {
        remoteChangeTask?.cancel()
        remoteChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            SeedData.deduplicate(in: self.context)
            self.reconcile()
        }
    }

    /// Any save (History/Detail edits and deletions, imports) may change which takeaway applies; coalesce them.
    private func scheduleTakeawayRefresh() {
        didSaveTask?.cancel()
        didSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.refreshTakeaway()
        }
    }

    /// Re-evaluates the tick timer whenever `settings.menuBarShowsTimer` changes.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.menuBarShowsTimer
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateTickTimer()
                self?.observeSettings()
            }
        }
    }

    /// The tick only runs while a session is running and the menu bar shows a timer; otherwise it is refreshed once.
    private func updateTickTimer() {
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
