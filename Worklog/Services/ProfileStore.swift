import CoreData
import Foundation
import Observation
import SwiftData

/// Value-type scope for pages and pickers. profileID == nil means ALL profiles (Stats "All profiles", or a store
/// that has no profile at all — graceful degrade).
///
/// Every check guards with `ModelLiveness` and reads live profiles only, so deleted models (and models whose profile
/// was deleted) are safe to pass. Sessions are matched by their *effective* profile (unassigned sessions included).
struct ProfileScope: Hashable, Sendable {
    let profileID: UUID?

    init(profileID: UUID?) {
        self.profileID = profileID
    }

    static let allProfiles = ProfileScope(profileID: nil)

    var isAllProfiles: Bool { profileID == nil }

    /// Live session whose effective profile (`ProfileOps.effectiveProfile(of:)`) has uuid == profileID: its own live
    /// profile, or — for an unassigned session (profile nil or deleted) — the profile it is shown in (the single owner
    /// of its local labels/tags, else the home profile). Nothing is written. allProfiles: any live session.
    @MainActor func contains(_ session: WorkSession) -> Bool {
        guard ModelLiveness.isLive(session) else { return false }
        guard let profileID else { return true }
        return ProfileOps.effectiveProfileID(of: session) == profileID
    }

    /// point.session (live) is contained. allProfiles: any live point.
    @MainActor func contains(_ point: LearningPoint) -> Bool {
        guard ModelLiveness.isLive(point) else { return false }
        guard profileID != nil else { return true }
        guard let session = ModelLiveness.live(point.session) else { return false }
        return contains(session)
    }

    /// Live label that is global (profile nil or deleted) or local to profileID. allProfiles: any live label.
    @MainActor func offers(_ label: WorkLabel) -> Bool {
        guard ModelLiveness.isLive(label) else { return false }
        guard let profileID else { return true }
        guard let owner = ModelLiveness.live(label.profile) else { return true }
        return owner.uuid == profileID
    }

    /// Live tag that is global (profile nil or deleted) or local to profileID. allProfiles: any live tag.
    @MainActor func offers(_ tag: WorkTag) -> Bool {
        guard ModelLiveness.isLive(tag) else { return false }
        guard let profileID else { return true }
        guard let owner = ModelLiveness.live(tag.profile) else { return true }
        return owner.uuid == profileID
    }

    /// Live sessions in scope, order preserved.
    @MainActor func filter(_ sessions: [WorkSession]) -> [WorkSession] {
        sessions.filter { contains($0) }
    }
}

/// The current ("active") profile of this Mac plus the profile lists the UI shows. Injected by `withAppServices`;
/// read with `@Environment(ProfileStore.self)`.
///
/// The selection is persisted per device (UserDefaults "profiles.activeProfileID" of `settings.defaults`). It is
/// resolved with a fallback (the first non-archived profile) that is never written back, so a profile that
/// reappears after a sync is selected again.
@MainActor @Observable
final class ProfileStore {
    static let activeProfileKey = "profiles.activeProfileID"   // UserDefaults of `settings.defaults`

    /// Live, non-archived, sorted (sortIndex, createdAt, uuid). Refreshed by reload().
    private(set) var profiles: [WorkProfile] = []
    /// Live, archived, same order.
    private(set) var archivedProfiles: [WorkProfile] = []
    /// Resolved current profile: stored id if live & non-archived, else profiles.first, else nil.
    /// The fallback is NOT written back (a profile that reappears after sync is selected again).
    private(set) var activeProfile: WorkProfile? = nil
    private(set) var activeProfileID: UUID? = nil

    var activeScope: ProfileScope { ProfileScope(profileID: activeProfileID) }
    var hasMultipleProfiles: Bool { profiles.count > 1 }
    /// More than one profile exists, archived ones included: views then show profile scope (badges, "This profile /
    /// All profiles" pickers, per-profile usage).
    var showsProfileScope: Bool { profiles.count + archivedProfiles.count > 1 }

    /// settings.quickStartProfileID resolved among `profiles`, else activeProfile.
    var quickStartProfile: WorkProfile? {
        if let id = settings.quickStartProfileID,
           let match = ModelLiveness.live(profiles).first(where: { $0.uuid == id }) {
            return match
        }
        return ModelLiveness.live(activeProfile)
    }

    var quickStartProfileID: UUID? { quickStartProfile?.uuid }

    private let context: ModelContext
    private let settings: AppSettings
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var didSaveTask: Task<Void, Never>?
    @ObservationIgnored private var remoteChangeTask: Task<Void, Never>?

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
        reload()
    }

    // MARK: - Loading

    /// Re-fetch + re-resolve; assigns only when changed (compare persistentModelIDs/uuid) to avoid churn.
    func reload() {
        ProfileOps.invalidateHomeProfileCache()
        let all = ProfileOps.allProfiles(in: context)
        let active = all.filter { !$0.isArchived }
        let archived = all.filter { $0.isArchived }
        if !Self.sameModels(profiles, active) { profiles = active }
        if !Self.sameModels(archivedProfiles, archived) { archivedProfiles = archived }
        resolveActive()
    }

    /// ModelContext.didSave (coalesced 200 ms), .worklogDataDidImport, .NSPersistentStoreRemoteChange (1.5 s) → reload().
    func startObserving() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.scheduleDidSaveReload() }
        })
        observerTokens.append(center.addObserver(
            forName: .worklogDataDidImport, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.reload() }
        })
        observerTokens.append(center.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.scheduleRemoteChangeReload() }
        })
    }

    // MARK: - Selection

    /// Ignores archived/deleted. Writes UserDefaults; updates activeProfile/ID immediately.
    func select(_ profile: WorkProfile) {
        guard ModelLiveness.isLive(profile), !profile.isArchived else { return }
        settings.defaults.set(profile.uuid.uuidString, forKey: Self.activeProfileKey)
        if activeProfile !== profile { activeProfile = profile }
        if activeProfileID != profile.uuid { activeProfileID = profile.uuid }
    }

    func select(id: UUID) {
        if let match = profile(withID: id) {
            select(match)
            return
        }
        reload()
        if let match = profile(withID: id) {
            select(match)
        }
    }

    /// Cycles `profiles` in order (wraps). No-op with < 2.
    func selectNext() {
        let live = ModelLiveness.live(profiles)
        guard live.count > 1 else { return }
        let index = live.firstIndex(where: { $0 === activeProfile }) ?? -1
        select(live[(index + 1) % live.count])
    }

    /// Live profile (archived or not) with that uuid among the loaded lists; nil for nil/unknown. No fetch.
    func profile(withID id: UUID?) -> WorkProfile? {
        guard let id else { return nil }
        return ModelLiveness.live(profiles).first { $0.uuid == id }
            ?? ModelLiveness.live(archivedProfiles).first { $0.uuid == id }
    }

    // MARK: - Editing

    /// ProfileOps.createProfile; select when asked; reload.
    @discardableResult
    func createProfile(name: String, colorHex: String, symbolName: String, select: Bool) -> WorkProfile {
        let profile = ProfileOps.createProfile(name: name, colorHex: colorHex, symbolName: symbolName, in: context)
        reload()
        if select { self.select(profile) }
        return profile
    }

    /// ProfileOps.setArchived; reload (archiving the current → fallback becomes current and is selected).
    @discardableResult
    func setArchived(_ profile: WorkProfile, _ archived: Bool) -> ProfileOpResult {
        let wasCurrent = profile === activeProfile
        let result = ProfileOps.setArchived(profile, archived, settings: settings, in: context)
        reload()
        if result == .ok, archived, wasCurrent, let fallback = profiles.first {
            select(fallback)
        }
        return result
    }

    /// ProfileOps.delete; if it was current → select the move target, else the fallback; reload;
    /// posts .worklogDataDidImport after .deleteSessions so the engine reconciles.
    @discardableResult
    func delete(_ profile: WorkProfile, _ deletion: ProfileDeletion) -> ProfileOpResult {
        guard ModelLiveness.isLive(profile) else { return .invalidTarget }
        let wasCurrent = profile.uuid == activeProfileID
        let result = ProfileOps.delete(profile, deletion, settings: settings, in: context)
        reload()
        guard result == .ok else { return result }
        if wasCurrent {
            switch deletion {
            case .moveSessions(let targetID):
                select(id: targetID)
            case .deleteSessions:
                if let fallback = profiles.first { select(fallback) }
            }
        }
        if deletion == .deleteSessions {
            NotificationCenter.default.post(name: .worklogDataDidImport, object: nil)
        }
        return result
    }

    func reorder(_ ordered: [WorkProfile]) {
        ProfileOps.reorder(ordered)
        reload()
    }

    // MARK: - Private

    private func resolveActive() {
        let stored = settings.defaults.string(forKey: Self.activeProfileKey).flatMap(UUID.init(uuidString:))
        let resolved = stored.flatMap { id in profiles.first(where: { $0.uuid == id }) } ?? profiles.first
        if activeProfile !== resolved { activeProfile = resolved }
        let resolvedID = resolved?.uuid
        if activeProfileID != resolvedID { activeProfileID = resolvedID }
    }

    private func scheduleDidSaveReload() {
        didSaveTask?.cancel()
        didSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.reload()
        }
    }

    private func scheduleRemoteChangeReload() {
        remoteChangeTask?.cancel()
        remoteChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            self.reload()
        }
    }

    private static func sameModels(_ lhs: [WorkProfile], _ rhs: [WorkProfile]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 === $1 }
    }
}
