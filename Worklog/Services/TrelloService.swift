import AppKit
import AuthenticationServices
import Foundation
import Observation
import os
import SwiftData

struct TrelloBoard: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

extension Log {
    /// Trello connection and polling. Never logs the token (or URLs, which carry it).
    static let trello = Logger(subsystem: AppConstants.bundleID, category: "trello")
}

/// Optional Trello integration: while a session runs on this Mac, the user's own Trello card actions are fetched
/// every 60 s and attached to that session as `TrelloActivity` rows (with Trello's timestamps).
///
/// - Auth: public API key (`TrelloConfig.apiKey`) + the user's read-only token, stored only in this Mac's Keychain
///   (`trelloToken`; the member's display name under `trelloMemberName`). `connect()` uses ASWebAuthenticationSession;
///   `connect(pastedToken:)` is the manual fallback (`manualAuthorizeURL`). Both validate with GET /members/me.
/// - Polling: a main-run-loop Timer runs only while connected, logging is on and there is something to fetch: the
///   active session owned by this Mac (`SessionEngine.isOwnedByThisDevice`) or a pending final fetch.
/// - Cursor: per session, UserDefaults `trello.cursor.<session uuid>` (seconds since 1970) = the end of the last
///   fully successful fetch window; starts at the session's start. Each fetch asks for actions since cursor − 60 s;
///   actions already attached (action id) or returned by the previous fetch are skipped, so a row the user removed
///   isn't added back.
/// - When the tracked session ends, its uuid goes to `trello.pendingFinalSessionIDs`; a final fetch (up to its end)
///   runs a few seconds later and at every tick until it succeeds (also after a relaunch); then its cursor is removed.
/// - 401 → token deleted, `.failed("Trello disconnected. Connect again.")`, polling stops. 429/5xx/offline →
///   `lastError`, retried at the next tick. Nothing here ever changes a session's times or blocks a save path:
///   inserted rows are removed again if their save fails.
/// - Cards: `cardDetails(shortLink:)` fetches one card as it is now (`GET /1/cards/{shortLink}`) when the user opens an
///   entry; kept in memory for 60 s (`cachedCardDetails`), never stored.
/// - Previews/tests (in-memory AppServices) never call `start()`; it is also a no-op under XCTest and previews.
@MainActor @Observable
final class TrelloService {
    enum Connection: Equatable {
        case notConfigured, disconnected, connecting, connected(name: String), failed(String)
    }

    private(set) var connection: Connection
    /// This build has a Trello API key.
    var isConfigured: Bool { !TrelloConfig.apiKey.isEmpty }
    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }
    /// Persisted ("trello.loggingEnabled"), default true. Only matters while connected.
    var isLoggingEnabled: Bool {
        didSet {
            guard oldValue != isLoggingEnabled else { return }
            defaults.set(isLoggingEnabled, forKey: Keys.loggingEnabled)
            syncTrackedSession()
        }
    }
    /// Persisted ("trello.watchedBoardIDs"); empty = all boards.
    var watchedBoardIDs: Set<String> {
        didSet {
            guard oldValue != watchedBoardIDs else { return }
            if watchedBoardIDs.isEmpty {
                defaults.removeObject(forKey: Keys.watchedBoardIDs)
            } else {
                defaults.set(watchedBoardIDs.sorted(), forKey: Keys.watchedBoardIDs)
            }
        }
    }
    /// The user's open boards, sorted by name (`refreshBoards()`).
    private(set) var boards: [TrelloBoard] = []
    private(set) var isLoadingBoards = false
    private(set) var isChecking = false
    /// End of the last fully successful check.
    private(set) var lastCheckedAt: Date? = nil
    /// Short user-facing text, nil when fine.
    private(set) var lastError: String? = nil
    /// Trello's authorize page without a callback: it shows the token for pasting. nil when not configured.
    var manualAuthorizeURL: URL? { TrelloAPI.authorizeURL(key: TrelloConfig.apiKey, withCallback: false) }
    /// Connected, logging on, and the active session is owned by this Mac.
    var isTrackingActiveSession: Bool { trackableActiveSession() != nil }

    // MARK: Private state

    private enum Keys {
        static let loggingEnabled = "trello.loggingEnabled"
        static let watchedBoardIDs = "trello.watchedBoardIDs"
        static let pendingFinals = "trello.pendingFinalSessionIDs"
        static let cursorPrefix = "trello.cursor."
        static let token = "trelloToken"
        static let memberName = "trelloMemberName"
    }

    static let pollInterval: TimeInterval = 60
    /// Delay before the final fetch of a session that just ended (Trello can list an action a moment late).
    static let finalFetchDelay: Duration = .seconds(5)

    private let context: ModelContext
    private let settings: AppSettings
    private let engine: SessionEngine
    private let keychain: KeychainStore
    private var defaults: UserDefaults { settings.defaults }

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var timer: Timer?
    /// The active session being logged (live, owned by this Mac).
    @ObservationIgnored private var trackedSessionUUID: UUID?
    /// Per session: action ids returned by the last successful fetch (covers the overlap of the next one).
    @ObservationIgnored private var seenActionIDs: [UUID: Set<String>] = [:]
    /// Cards fetched for `cardDetails(shortLink:)`, by short link (in memory only, `cardCacheLifetime`).
    @ObservationIgnored private var cardCache: [String: CachedCard] = [:]
    /// Card lookups in flight, by short link: concurrent requests for the same card share one fetch.
    @ObservationIgnored private var cardFetches: [String: Task<TrelloCardLookup, Never>] = [:]

    private struct CachedCard {
        var details: TrelloCardDetails
        var fetchedAt: Date
    }

    /// How long a fetched card is reused without asking Trello again.
    static let cardCacheLifetime: TimeInterval = 60

    init(context: ModelContext, settings: AppSettings, engine: SessionEngine, keychain: KeychainStore = KeychainStore()) {
        self.context = context
        self.settings = settings
        self.engine = engine
        self.keychain = keychain
        let defaults = settings.defaults
        isLoggingEnabled = defaults.object(forKey: Keys.loggingEnabled) as? Bool ?? true
        watchedBoardIDs = Set(defaults.stringArray(forKey: Keys.watchedBoardIDs) ?? [])
        connection = TrelloConfig.apiKey.isEmpty ? .notConfigured : .disconnected
    }

    // MARK: - Lifecycle

    /// Restores the stored token (optimistically connected, then validated), removes stale cursors, observes the
    /// engine's active session, processes pending final fetches and starts polling when needed. Once; no-op under
    /// XCTest and in SwiftUI previews. Called by AppServices at the end of init (not for in-memory instances).
    func start() {
        guard !isStarted, !Self.isEphemeralProcess else { return }
        isStarted = true
        guard isConfigured else {
            connection = .notConfigured
            return
        }
        if let stored = keychain.string(for: Keys.token).flatMap(TrelloAPI.normalizedToken) {
            token = stored
            connection = .connected(name: keychain.string(for: Keys.memberName)?.nilIfBlank ?? "Trello")
        }
        removeStaleCursors()
        observeEngine()
        syncTrackedSession()
        guard token != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.validateStoredToken()
            await self.refreshBoards()
            await self.checkNow()
        }
    }

    // MARK: - Connect / disconnect

    /// Trello's authorize page in an ASWebAuthenticationSession (anchored to the key or main window). The token
    /// comes back in the callback (diptychon-trello://auth#token=…) and is validated. Cancel → previous state.
    func connect() async {
        guard isConfigured, connection != .connecting,
              let url = TrelloAPI.authorizeURL(key: TrelloConfig.apiKey, withCallback: true) else { return }
        let previous = connection
        connection = .connecting
        lastError = nil
        do {
            let callback = try await authenticate(url: url)
            guard let token = TrelloAPI.token(fromCallback: callback) else {
                connection = .failed("Trello didn\u{2019}t send a token. Try again, or paste one.")
                return
            }
            _ = await finishConnecting(token: token)
        } catch {
            let ns = error as NSError
            if ns.domain == ASWebAuthenticationSessionError.errorDomain,
               ns.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                connection = previous
                return
            }
            Log.trello.error("Trello sign-in failed: \(error.localizedDescription, privacy: .public)")
            connection = .failed("Couldn\u{2019}t open Trello sign-in. Paste a token instead.")
        }
    }

    /// Manual fallback: validates the pasted token (a "…token=…" URL is accepted too). True when connected.
    func connect(pastedToken: String) async -> Bool {
        guard isConfigured, connection != .connecting else { return false }
        guard let token = TrelloAPI.normalizedToken(pastedToken) else {
            connection = .failed("That doesn\u{2019}t look like a Trello token.")
            return false
        }
        lastError = nil
        return await finishConnecting(token: token)
    }

    /// Forgets the token (Keychain), the board choice, pending fetches and cursors, then revokes the token at Trello
    /// (best effort). Logged activity stays with the sessions.
    func disconnect() async {
        let oldToken = token
        keychain.delete(Keys.token)
        keychain.delete(Keys.memberName)
        token = nil
        boards = []
        watchedBoardIDs = []
        trackedSessionUUID = nil
        seenActionIDs = [:]
        cardCache = [:]
        defaults.removeObject(forKey: Keys.pendingFinals)
        removeCursors { _ in true }
        lastError = nil
        lastCheckedAt = nil
        connection = isConfigured ? .disconnected : .notConfigured
        updateTimer()
        Log.trello.info("Disconnected from Trello")
        if let oldToken, let api = makeAPI(token: oldToken) {
            await api.revokeToken()
        }
    }

    // MARK: - Boards / checks

    func refreshBoards() async {
        guard isConnected, !isLoadingBoards, let token, let api = makeAPI(token: token) else { return }
        isLoadingBoards = true
        defer { isLoadingBoards = false }
        do {
            let fetched = try await api.boards()
            guard self.token == token else { return }
            boards = fetched
        } catch TrelloAPIError.unauthorized {
            if self.token == token { handleUnauthorized() }
        } catch {
            if self.token == token { lastError = "Couldn\u{2019}t load your Trello boards." }
        }
    }

    /// One poll now: pending final fetches first, then the tracked active session. No-op when not connected,
    /// logging is off, or a check is running.
    func checkNow() async {
        guard isStarted, isConnected, isLoggingEnabled, !isChecking,
              let token, let api = makeAPI(token: token) else { return }
        isChecking = true
        defer { isChecking = false }
        syncTrackedSession()
        var failure: Error?

        for uuid in pendingFinalIDs {
            guard failure == nil else { break }
            guard let session = engine.fetchSession(uuid: uuid) else {
                finishFinal(uuid)   // deleted meanwhile
                continue
            }
            guard session.endedAt != nil else {
                // Running again (resumed from the review): logged as the active session if this Mac tracks it.
                removePendingFinal(uuid)
                continue
            }
            do {
                guard try await fetch(sessionUUID: uuid, api: api) else { continue }
                if let again = engine.fetchSession(uuid: uuid), again.endedAt == nil {
                    removePendingFinal(uuid)   // resumed while fetching: keep its cursor for the live tracking
                } else {
                    finishFinal(uuid)
                }
            } catch {
                failure = error
            }
        }
        if failure == nil, let uuid = trackedSessionUUID {
            do {
                _ = try await fetch(sessionUUID: uuid, api: api)
            } catch {
                failure = error
            }
        }

        guard self.token == token else { return }   // disconnected meanwhile
        if let failure {
            if let apiError = failure as? TrelloAPIError {
                if apiError == .unauthorized {
                    handleUnauthorized()
                    return
                }
                lastError = apiError.userMessage
                Log.trello.error("Trello check failed: \(String(describing: apiError), privacy: .public)")
            } else {
                lastError = "Couldn\u{2019}t save Trello activity. Trying again in a minute."
            }
        } else {
            lastError = nil
            lastCheckedAt = .now
        }
        updateTimer()
    }

    // MARK: - Cards

    /// The card of a logged entry as it is now in Trello (`GET /1/cards/{shortLink}`), reused from memory for
    /// `cardCacheLifetime` unless `forceRefresh`. Concurrent requests for the same card share one fetch. Never
    /// throws: a 404 is `.deleted`; everything else that goes wrong is `.unavailable` with a short reason. A 401 is
    /// handled like polling (disconnect) once `GET /members/me` confirms the token itself is gone; otherwise the
    /// user just can't see that card any more.
    func cardDetails(shortLink: String, forceRefresh: Bool = false) async -> TrelloCardLookup {
        let link = shortLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TrelloActivity.cardURL(shortLink: link) != nil else { return .unavailable(CardMessage.noLink) }
        guard isConfigured else { return .unavailable(CardMessage.notConfigured) }
        guard isConnected, let token, let api = makeAPI(token: token) else {
            return .unavailable(CardMessage.notConnected)
        }
        if !forceRefresh, let cached = cachedCardDetails(shortLink: link) { return .loaded(cached) }
        if let running = cardFetches[link] { return await running.value }
        let lookup = Task { await self.loadCard(link, api: api) }
        cardFetches[link] = lookup
        return await lookup.value
    }

    /// The card fetched for `shortLink` within the last `cardCacheLifetime`, if any (no network).
    func cachedCardDetails(shortLink: String) -> TrelloCardDetails? {
        let link = shortLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cached = cardCache[link], Date.now.timeIntervalSince(cached.fetchedAt) < Self.cardCacheLifetime,
              isConnected else { return nil }
        return cached.details
    }

    // MARK: - Pure helpers

    /// Boards sorted by name (case-insensitive), then id.
    nonisolated static func sortedBoards(_ boards: [TrelloBoard]) -> [TrelloBoard] {
        boards.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// UserDefaults key of a session's cursor.
    nonisolated static func cursorKey(for sessionUUID: UUID) -> String {
        "trello.cursor." + sessionUUID.uuidString
    }

    // MARK: - Private: connection

    private static var isEphemeralProcess: Bool {
        AppServices.isRunningUnitTests || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Short user-facing reasons of `TrelloCardLookup.unavailable`.
    enum CardMessage {
        static let noLink = "Trello didn\u{2019}t send a link for this card."
        static let notConfigured = "Trello isn\u{2019}t set up in this build."
        static let notConnected = "Connect Trello in Settings to see the full card."
        static let offline = "Can\u{2019}t reach Trello right now."
        static let noAccess = "You can\u{2019}t see this card in Trello anymore."
        static let failed = "Couldn\u{2019}t load this card from Trello."
    }

    /// One card fetch (`cardDetails`): caches a loaded card, maps errors, then leaves `cardFetches`.
    private func loadCard(_ link: String, api: TrelloAPI) async -> TrelloCardLookup {
        defer { cardFetches[link] = nil }
        let failure: TrelloAPIError
        do {
            let details = try await api.card(shortLink: link)
            guard token == api.token else { return .unavailable(CardMessage.notConnected) }
            let now = Date.now
            cardCache = cardCache.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.cardCacheLifetime }
            cardCache[link] = CachedCard(details: details, fetchedAt: now)
            return .loaded(details)
        } catch let error as TrelloAPIError {
            failure = error
        } catch {
            failure = .invalidResponse
        }
        guard token == api.token else { return .unavailable(CardMessage.notConnected) }
        Log.trello.error("Trello card lookup failed: \(String(describing: failure), privacy: .public)")
        switch failure {
        case .http(404):
            cardCache[link] = nil
            return .deleted
        case .unauthorized:
            // Trello also answers 401 for a card on a board the user can no longer see: check the token itself.
            do {
                _ = try await api.memberID()
                return .unavailable(CardMessage.noAccess)
            } catch TrelloAPIError.unauthorized {
                if token == api.token { handleUnauthorized() }
                return .unavailable(TrelloAPIError.unauthorized.userMessage)
            } catch {
                return .unavailable(CardMessage.offline)
            }
        case .offline, .rateLimited, .server:
            return .unavailable(CardMessage.offline)
        case .http, .invalidResponse:
            return .unavailable(CardMessage.failed)
        }
    }

    private func makeAPI(token: String) -> TrelloAPI? {
        isConfigured ? TrelloAPI(key: TrelloConfig.apiKey, token: token) : nil
    }

    private func finishConnecting(token: String) async -> Bool {
        guard let api = makeAPI(token: token) else { return false }
        connection = .connecting
        do {
            let name = try await api.memberName()
            keychain.set(token, for: Keys.token)
            keychain.set(name, for: Keys.memberName)
            self.token = token
            connection = .connected(name: name)
            lastError = nil
            Log.trello.info("Connected to Trello")
            syncTrackedSession()
            Task { @MainActor [weak self] in await self?.refreshBoards() }
            return true
        } catch TrelloAPIError.unauthorized {
            connection = .failed("Trello didn\u{2019}t accept that token. Try again.")
        } catch {
            connection = .failed("Can\u{2019}t reach Trello. Check your connection and try again.")
        }
        return false
    }

    /// At launch: refresh the member name; a revoked token disconnects. Offline keeps the connected state.
    private func validateStoredToken() async {
        guard let token, let api = makeAPI(token: token) else { return }
        do {
            let name = try await api.memberName()
            guard self.token == token else { return }
            keychain.set(name, for: Keys.memberName)
            connection = .connected(name: name)
        } catch TrelloAPIError.unauthorized {
            if self.token == token { handleUnauthorized() }
        } catch {
            Log.trello.info("Trello token check skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 401: the token is gone (revoked at Trello). Pending final fetches and cursors stay for a reconnect.
    private func handleUnauthorized() {
        Log.trello.info("Trello token no longer valid; disconnected")
        keychain.delete(Keys.token)
        keychain.delete(Keys.memberName)
        token = nil
        boards = []
        trackedSessionUUID = nil
        cardCache = [:]
        lastError = nil
        connection = .failed(TrelloAPIError.unauthorized.userMessage)
        updateTimer()
    }

    private func authenticate(url: URL) async throws -> URL {
        // The anchor is picked here, on the main actor; the presenter only hands it back (any thread).
        let anchor = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) ?? NSWindow()
        let presenter = TrelloAuthPresenter(anchor: anchor)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let box = TrelloWebAuthBox()
            box.presenter = presenter   // presentationContextProvider is weak
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: TrelloConfig.callbackScheme) {
                callbackURL, error in
                box.session = nil   // breaks the box ↔ session cycle that keeps the session alive while it runs
                box.presenter = nil
                guard box.claim() else { return }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? TrelloAPIError.invalidResponse)
                }
            }
            box.session = session
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            if !session.start(), box.claim() {
                box.session = nil
                box.presenter = nil
                continuation.resume(throwing: TrelloAPIError.invalidResponse)
            }
        }
    }

    // MARK: - Private: tracking

    private func trackableActiveSession() -> WorkSession? {
        guard isConnected, isLoggingEnabled, let session = ModelLiveness.live(engine.activeSession),
              session.endedAt == nil, engine.isOwnedByThisDevice(session) else { return nil }
        return session
    }

    private func observeEngine() {
        withObservationTracking {
            _ = engine.activeSession
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncTrackedSession()
                self?.observeEngine()
            }
        }
    }

    /// Follows the engine: a newly trackable active session is tracked (cursor = its start); a tracked session that
    /// ended gets a final fetch; one that is no longer trackable for another reason (logging off, another Mac took
    /// over) is just dropped. Then starts/stops the timer.
    private func syncTrackedSession() {
        guard isStarted else { return }
        let current = trackableActiveSession()
        if let tracked = trackedSessionUUID, tracked != current?.uuid {
            trackedSessionUUID = nil
            if isConnected, isLoggingEnabled, let old = engine.fetchSession(uuid: tracked), old.endedAt != nil {
                // seenActionIDs stay until the final fetch is done (a removed entry in the overlap isn't re-added).
                addPendingFinal(tracked)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: TrelloService.finalFetchDelay)
                    await self?.checkNow()
                }
            } else {
                seenActionIDs[tracked] = nil
            }
        }
        if trackedSessionUUID == nil, let current {
            trackedSessionUUID = current.uuid
            if cursor(for: current.uuid) == nil { setCursor(current.startedAt, for: current.uuid) }
        }
        updateTimer()
    }

    private func updateTimer() {
        let needed = isStarted && isConnected && isLoggingEnabled
            && (trackedSessionUUID != nil || !pendingFinalIDs.isEmpty)
        guard needed else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in
                guard let self else { return }
                Task { @MainActor in await self.checkNow() }
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Fetches since the session's cursor and attaches new actions. A running session's window is open-ended; an
    /// ended one stops at its end. Returns true when the fetch fully succeeded (the cursor then advances); false
    /// when the session is gone or the connection changed meanwhile. Throws `TrelloAPIError` or a save error.
    private func fetch(sessionUUID uuid: UUID, api: TrelloAPI) async throws -> Bool {
        guard let session = engine.fetchSession(uuid: uuid) else { return false }
        let end = session.endedAt
        let since = TrelloActionMapper.fetchStart(sessionStart: session.startedAt, cursor: cursor(for: uuid))
        let requestedAt = Date.now
        let actions = try await api.actions(since: since, before: end.map { $0.addingTimeInterval(60) })

        // The session may have been edited, stopped or deleted while waiting.
        guard self.token == api.token, let live = engine.fetchSession(uuid: uuid) else { return false }
        var known = Set(ModelLiveness.live(live.trelloActivities ?? []).map(\.actionID))
        known.formUnion(seenActionIDs[uuid] ?? [])
        let toAttach = TrelloActionMapper.actionsToAttach(actions, existingActionIDs: known,
                                                          watchedBoardIDs: watchedBoardIDs,
                                                          start: live.startedAt, end: live.endedAt)
        if !toAttach.isEmpty {
            try attach(toAttach, to: live)
        }
        seenActionIDs[uuid] = Set(actions.map(\.actionID))
        let windowEnd = live.endedAt.map { min($0, requestedAt) } ?? requestedAt
        setCursor(max(windowEnd, cursor(for: uuid) ?? live.startedAt), for: uuid)
        return true
    }

    /// Inserts the rows and saves. On a failed save the rows are removed again (nothing else is rolled back) and the
    /// error is rethrown; the next tick retries.
    private func attach(_ actions: [TrelloMappedAction], to session: WorkSession) throws {
        var inserted: [TrelloActivity] = []
        for action in actions {
            let activity = TrelloActivity(actionID: action.actionID, occurredAt: action.occurredAt, kind: action.kind)
            context.insert(activity)
            activity.cardName = action.cardName
            activity.cardShortLink = action.cardShortLink
            activity.boardName = action.boardName
            activity.listName = action.listName
            activity.fromListName = action.fromListName
            activity.detail = action.detail
            activity.session = session
            inserted.append(activity)
        }
        session.touch()
        do {
            try context.save()
            Log.trello.info("Logged \(inserted.count, privacy: .public) Trello actions")
        } catch {
            for activity in inserted {
                activity.session = nil
                context.delete(activity)
            }
            Log.trello.error("Saving Trello activity failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Private: persisted bookkeeping

    private var pendingFinalIDs: [UUID] {
        (defaults.stringArray(forKey: Keys.pendingFinals) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func setPendingFinalIDs(_ ids: [UUID]) {
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        if unique.isEmpty {
            defaults.removeObject(forKey: Keys.pendingFinals)
        } else {
            defaults.set(unique.map(\.uuidString), forKey: Keys.pendingFinals)
        }
    }

    private func addPendingFinal(_ uuid: UUID) {
        setPendingFinalIDs(pendingFinalIDs + [uuid])
    }

    private func removePendingFinal(_ uuid: UUID) {
        setPendingFinalIDs(pendingFinalIDs.filter { $0 != uuid })
    }

    /// The session's final fetch is done (or it was deleted): forget it and its cursor.
    private func finishFinal(_ uuid: UUID) {
        removePendingFinal(uuid)
        seenActionIDs[uuid] = nil
        defaults.removeObject(forKey: Self.cursorKey(for: uuid))
    }

    private func cursor(for uuid: UUID) -> Date? {
        (defaults.object(forKey: Self.cursorKey(for: uuid)) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    private func setCursor(_ date: Date, for uuid: UUID) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.cursorKey(for: uuid))
    }

    /// At launch: a cursor of a session that is neither active nor pending was tracked when the app quit, and the
    /// session ended meanwhile (e.g. stopped on another Mac): it gets its final fetch. Other cursors are removed.
    private func removeStaleCursors() {
        var keep = Set(pendingFinalIDs)
        if let active = ModelLiveness.live(engine.activeSession) { keep.insert(active.uuid) }
        let canFetch = token != nil && isLoggingEnabled
        removeCursors { uuid in
            guard !keep.contains(uuid) else { return false }
            guard canFetch, let session = engine.fetchSession(uuid: uuid), session.endedAt != nil else { return true }
            addPendingFinal(uuid)
            return false
        }
    }

    private func removeCursors(where shouldRemove: (UUID) -> Bool) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Keys.cursorPrefix) {
            let id = UUID(uuidString: String(key.dropFirst(Keys.cursorPrefix.count)))
            if id.map(shouldRemove) ?? true { defaults.removeObject(forKey: key) }
        }
    }
}

/// ASWebAuthenticationSession's window, chosen on the main actor before the session starts (the key window, else
/// the main window, else the first visible one); returned as-is, so this never touches AppKit off the main thread.
final class TrelloAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

/// Keeps a running ASWebAuthenticationSession (and its weakly held presenter) alive and makes sure its continuation
/// resumes once.
private final class TrelloWebAuthBox {
    var session: ASWebAuthenticationSession?
    var presenter: TrelloAuthPresenter?
    private let lock = NSLock()
    private var claimed = false

    /// True the first time only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
