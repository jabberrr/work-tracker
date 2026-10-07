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
    /// Most recent ended session with showInOverlay == true and a non-nil takeawayText.
    private(set) var lastTakeaway: SessionTakeaway? = nil
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

    var isActive: Bool { activeSession != nil }
    var isPaused: Bool { activeSession?.isPaused ?? false }
    var isRunning: Bool { isActive && !isPaused }
    var currentSegment: Segment? { activeSession?.currentSegment }
    var currentLabel: WorkLabel? { currentSegment?.effectiveLabel ?? activeSession?.label }

    // MARK: Private
    private static let autoPauseKey = "engine.autoPauseReason"

    private let context: ModelContext
    private let settings: AppSettings
    private var defaults: UserDefaults { settings.defaults }
    /// Identity of the pending session, captured when it is set, so reconcile never has to touch a model
    /// object that may have been deleted underneath us (import/replace, remote deletion).
    @ObservationIgnored private var pendingSessionUUID: UUID?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var isObservingSystemEvents = false
    @ObservationIgnored private var remoteChangeTask: Task<Void, Never>?

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
    }

    // MARK: - Lifecycle

    /// Fetch sessions with endedAt == nil; adopt the most recent as active (end any others at lastActivityDate);
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
                SessionEditor.endSession(extra, at: extra.lastActivityDate)
                changed = true
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
    }

    /// On quit: if settings.pauseOnQuit && isRunning → pause(), autoPauseReason = .quit. Always saves.
    func prepareForTermination() {
        if settings.pauseOnQuit && isRunning {
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

    /// Sum of activeDuration(in: today) over all sessions overlapping today (fetch startedAt >= today−2d, filter in
    /// memory). The active session is always included, even if it started earlier.
    func totalActiveToday(now: Date = .now) -> TimeInterval {
        let today = now.dayInterval
        let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: today.start)
            ?? today.start.addingTimeInterval(-2 * 86_400)
        let descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.startedAt >= cutoff })
        var sessions = (try? context.fetch(descriptor)) ?? []
        if let active = activeSession, !sessions.contains(where: { $0 === active }) {
            sessions.append(active)
        }
        return sessions.reduce(0) { $0 + $1.activeDuration(in: today, now: now) }
    }

    /// Label with uuid == settings.defaultLabelID (non-archived), else first non-archived by sortIndex, else nil.
    func defaultLabel() -> WorkLabel? {
        let descriptor = FetchDescriptor<WorkLabel>(sortBy: [SortDescriptor(\WorkLabel.sortIndex)])
        let labels = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isArchived }
        if let id = settings.defaultLabelID, let match = labels.first(where: { $0.uuid == id }) {
            return match
        }
        return labels.first
    }

    // MARK: - Controls

    /// If a session is already active, returns it unchanged. Otherwise inserts a WorkSession(startedAt: date),
    /// sets session.label = label, session.tags = tags, inserts first Segment(sortIndex 0, label, focus, tags: []),
    /// saves, clears autoPauseReason, starts tick.
    @discardableResult
    func start(label: WorkLabel?, tags: [WorkTag] = [], focus: String = "", at date: Date = .now) -> WorkSession {
        if let session = activeSession { return session }

        let session = WorkSession(startedAt: date)
        context.insert(session)
        session.label = label
        session.tags = tags

        let segment = Segment(startedAt: date, endedAt: nil, sortIndex: 0, focus: focus.trimmed)
        context.insert(segment)
        segment.label = label
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
        SessionEditor.endSession(session, at: date)
        activeSession = nil
        autoPauseReason = nil
        save()
        updateTickTimer()
        if settings.showEndSessionSheet {
            pendingEndSession = session
        } else {
            refreshTakeaway()
        }
        Log.engine.info("Stopped session (\(session.storedActiveDuration, privacy: .public)s active)")
        return session
    }

    /// Deletes the active session (cascade). Callers confirm first if settings.confirmBeforeDiscard.
    func discard() {
        guard let session = activeSession else { return }
        activeSession = nil
        autoPauseReason = nil
        context.delete(session)
        save()
        updateTickTimer()
        refreshTakeaway()
        Log.engine.info("Discarded active session")
    }

    /// Live split. Closes current segment at `date` and opens Segment(startedAt: date, sortIndex: max+1,
    /// label: label ?? currentLabel, tags: tags, focus: focus). Allowed while paused. Returns the new segment.
    /// If the current segment is shorter than `SessionEditor.minimumSegmentLength` at `date`, it is updated in
    /// place instead (no zero-length segments) and returned.
    @discardableResult
    func split(label: WorkLabel?, tags: [WorkTag] = [], focus: String = "", at date: Date = .now) -> Segment? {
        guard let session = activeSession else { return nil }
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
        session.touch()
        save()
        return note
    }

    // MARK: - End-of-session review

    /// Save pending session (touch, recomputeStoredDuration), pendingEndSession = nil, refreshTakeaway().
    /// Idempotent: safe to call again from the sheet's dismissal binding.
    func completeReview() {
        if let session = pendingEndSession {
            pendingEndSession = nil
            session.recomputeStoredDuration()
            session.touch()
            save()
        }
        refreshTakeaway()
    }

    /// Delete pending session; pendingEndSession = nil.
    func discardPendingSession() {
        guard let session = pendingEndSession else { return }
        pendingEndSession = nil
        context.delete(session)
        save()
        refreshTakeaway()
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

    func refreshTakeaway() {
        var descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate<WorkSession> { $0.endedAt != nil && $0.showInOverlay == true },
            sortBy: [SortDescriptor(\WorkSession.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        let candidates = (try? context.fetch(descriptor)) ?? []
        var newValue: SessionTakeaway?
        for session in candidates where session !== pendingEndSession && !session.isDeleted {
            guard let text = session.takeawayText else { continue }
            newValue = SessionTakeaway(sessionUUID: session.uuid, title: session.displayTitle,
                                       date: session.startedAt, text: text, labelName: session.label?.name)
            break
        }
        if newValue != lastTakeaway { lastTakeaway = newValue }
    }

    func clearAutoPauseReason() {
        autoPauseReason = nil
    }

    // MARK: - Private

    private func fetchActiveSessions() -> [WorkSession] {
        let descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate<WorkSession> { $0.endedAt == nil },
            sortBy: [SortDescriptor(\WorkSession.startedAt, order: .reverse)]
        )
        do {
            return try context.fetch(descriptor).filter { !$0.isDeleted }
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

    private func handleWillSleep() {
        guard settings.pauseOnSleep, isRunning else { return }
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
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            SeedData.deduplicate(in: self.context)
            self.reconcile()
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
