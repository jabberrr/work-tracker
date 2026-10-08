import Foundation
import SwiftData

/// How `ProfileOps.delete` treats the deleted profile's sessions.
enum ProfileDeletion: Equatable {
    /// Sessions and the profile's local labels/tags move to that (live, non-archived, other) profile.
    case moveSessions(toProfileID: UUID)
    /// Sessions are deleted; local labels/tags still used elsewhere become global, the rest are deleted.
    case deleteSessions
}

enum ProfileOpResult: Equatable {
    case ok, lastProfile, sessionRunning, invalidTarget

    /// nil, "Keep at least one profile.", "Stop the session first.", "Choose another profile."
    var message: String? {
        switch self {
        case .ok: nil
        case .lastProfile: "Keep at least one profile."
        case .sessionRunning: "Stop the session first."
        case .invalidTarget: "Choose another profile."
        }
    }
}

/// Create / archive / delete / reorder profiles, plus the default profile and unassigned sessions.
/// See ARCHITECTURE §12.
///
/// Unassigned sessions (profile nil or deleted: from an older app version on another Mac, a profile deleted
/// remotely, or a relationship CloudKit hasn't delivered yet) are shown in their *effective profile*
/// (`effectiveProfile(of:)`) everywhere. With CloudKit that is display-only: the profile is written only when the user
/// edits that session (`assignProfileIfUnassigned`). A local-only store also repairs them in the background
/// (`SeedData.repairSessionProfilesIfAllowed`).
@MainActor enum ProfileOps {
    /// 6F1C0E10-0000-4000-8000-000000000201 (fixed so the copies two Macs create when upgrading can be merged).
    nonisolated static let defaultProfileUUID = UUID(uuid: (0x6F, 0x1C, 0x0E, 0x10, 0x00, 0x00, 0x40, 0x00,
                                                            0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01))
    nonisolated static let defaultProfileName = "Work"
    nonisolated static let defaultProfileColorHex = "#5B8DEF"
    nonisolated static let defaultProfileSymbol = "briefcase.fill"

    // MARK: - Lookup

    /// Live profiles (archived included) sorted by (sortIndex, createdAt, uuidString).
    static func allProfiles(in context: ModelContext) -> [WorkProfile] {
        let fetched = (try? context.fetch(FetchDescriptor<WorkProfile>())) ?? []
        return ModelLiveness.live(fetched).sorted(by: precedes)
    }

    /// Live profile with that uuid (archived or not); nil for nil/unknown.
    static func profile(withID id: UUID?, in context: ModelContext) -> WorkProfile? {
        guard let id else { return nil }
        return allProfiles(in: context).first { $0.uuid == id }
    }

    /// Where unassigned sessions go: the default-uuid profile if live & non-archived, else first non-archived,
    /// else first profile, else nil.
    static func homeProfile(in context: ModelContext) -> WorkProfile? {
        let all = allProfiles(in: context)
        return all.first { $0.uuid == defaultProfileUUID && !$0.isArchived }
            ?? all.first { !$0.isArchived }
            ?? all.first
    }

    /// If no non-archived profile is left (e.g. an import or a merge of copies archived them all), unarchives the
    /// first profile so the app always has a current one. Does not save. Returns true when it changed something.
    @discardableResult
    static func ensureNonArchivedProfile(in context: ModelContext) -> Bool {
        let all = allProfiles(in: context)
        guard let first = all.first, !all.contains(where: { !$0.isArchived }) else { return false }
        first.isArchived = false
        first.touch()
        Log.persistence.info("Unarchived a profile so one stays active")
        return true
    }

    // MARK: - Unassigned sessions

    /// The profile `session` belongs to on every surface (scope, stats, search, today totals, takeaways, pickers):
    /// its own live profile; for an unassigned session (profile nil or deleted) the single non-archived profile that
    /// owns the local labels/tags it uses, else the home profile. Display-only: nothing is written. nil when the
    /// session isn't live or no profile exists. Unassigned sessions resolve the home profile through a short-lived
    /// cache (`invalidateHomeProfileCache()`).
    static func effectiveProfile(of session: WorkSession) -> WorkProfile? {
        guard ModelLiveness.isLive(session) else { return nil }
        if let own = ModelLiveness.live(session.profile) { return own }
        if let owner = soleLocalOwner(of: session) { return owner }
        guard let context = session.modelContext else { return nil }
        return cachedHomeProfile(in: context)
    }

    /// uuid of `effectiveProfile(of:)`.
    static func effectiveProfileID(of session: WorkSession) -> UUID? {
        effectiveProfile(of: session)?.uuid
    }

    /// True when the live `session` has no live profile (it is shown in its effective profile).
    static func isUnassigned(_ session: WorkSession) -> Bool {
        ModelLiveness.isLive(session) && ModelLiveness.live(session.profile) == nil
    }

    /// Write path for ONE unassigned session, used when the user edits it (SessionEditor, the engine's stop/review/
    /// live edits): session.profile = its effective profile (the single non-archived owner of its local labels/tags,
    /// else homeProfile; never creates a profile), then `TaxonomyOps.conformTaxonomy`. Never touches modifiedAt and
    /// does not save (the caller's edit does). Returns the assigned profile, nil when nothing changed.
    @discardableResult
    static func assignProfileIfUnassigned(_ session: WorkSession, in context: ModelContext) -> WorkProfile? {
        guard isUnassigned(session) else { return nil }
        guard let target = soleLocalOwner(of: session) ?? homeProfile(in: context) else { return nil }
        session.profile = target
        TaxonomyOps.conformTaxonomy(of: session, to: target, in: context)
        return target
    }

    /// Drops the cached home profile used by `effectiveProfile(of:)` (ProfileStore.reload, profile edits, imports and
    /// dedupe call it; the cache also expires after 2 s).
    static func invalidateHomeProfileCache() {
        homeCache.context = nil
        homeCache.profile = nil
    }

    // MARK: - Migration & repair

    /// If NO profile exists: inserts the default profile (fixed uuid, "Work", defaultLabelUUID = legacyDefaultLabelID)
    /// and returns it; else returns nil. Does not save. Its modifiedAt is the 1970 epoch so a copy created on an
    /// upgrading or new Mac never wins the attribute merge of `SeedData` dedupe over a profile the user edited.
    @discardableResult
    static func ensureDefaultProfile(legacyDefaultLabelID: UUID?, in context: ModelContext) -> WorkProfile? {
        guard allProfiles(in: context).isEmpty else { return nil }
        let profile = WorkProfile(name: defaultProfileName, colorHex: defaultProfileColorHex,
                                  symbolName: defaultProfileSymbol, sortIndex: 0, uuid: defaultProfileUUID)
        context.insert(profile)
        profile.defaultLabelUUID = legacyDefaultLabelID
        profile.modifiedAt = Date(timeIntervalSince1970: 0)
        invalidateHomeProfileCache()
        Log.persistence.info("Created the default profile")
        return profile
    }

    /// Background repair (call it through `SeedData.repairSessionProfilesIfAllowed`, which skips it in CloudKit mode):
    /// every unassigned session → its effective profile (the single non-archived owner of its local labels/tags, else
    /// homeProfile), then `TaxonomyOps.conformTaxonomy`; creates the default profile first if no profile exists and
    /// such sessions exist. Never touches modifiedAt. Returns the number repaired. Does not save.
    @discardableResult
    static func repairSessionProfiles(in context: ModelContext) -> Int {
        let sessions = ModelLiveness.live((try? context.fetch(FetchDescriptor<WorkSession>())) ?? [])
        let orphans = sessions.filter { ModelLiveness.live($0.profile) == nil }
        guard !orphans.isEmpty else { return 0 }
        guard let home = homeProfile(in: context) ?? ensureDefaultProfile(legacyDefaultLabelID: nil, in: context) else {
            return 0
        }
        for session in orphans {
            let target = soleLocalOwner(of: session) ?? home
            session.profile = target
            TaxonomyOps.conformTaxonomy(of: session, to: target, in: context)
        }
        Log.persistence.info("Assigned \(orphans.count, privacy: .public) unassigned sessions to a profile")
        return orphans.count
    }

    // MARK: - Editing

    /// sortIndex = max+1; name trimmed ("New profile" when blank). Saves.
    @discardableResult
    static func createProfile(name: String, colorHex: String, symbolName: String,
                              in context: ModelContext) -> WorkProfile {
        let nextIndex = (allProfiles(in: context).map(\.sortIndex).max() ?? -1) + 1
        let trimmedName = name.trimmed
        let profile = WorkProfile(name: trimmedName.isEmpty ? "New profile" : trimmedName,
                                  colorHex: colorHex.isBlank ? defaultProfileColorHex : colorHex,
                                  symbolName: symbolName.isBlank ? defaultProfileSymbol : symbolName,
                                  sortIndex: nextIndex)
        context.insert(profile)
        save(context)
        return profile
    }

    /// sortIndex by array order; saves.
    static func reorder(_ profiles: [WorkProfile]) {
        let live = ModelLiveness.live(profiles)
        var changed = false
        for (index, profile) in live.enumerated() where profile.sortIndex != index {
            profile.sortIndex = index
            profile.touch()
            changed = true
        }
        if changed, let context = live.first?.modelContext {
            save(context)
        }
    }

    /// Archiving the last non-archived profile → .lastProfile; archiving a profile with a running session (endedAt ==
    /// nil) → .sessionRunning. Archiving clears settings.quickStartProfileID if it pointed to it. touch + save.
    @discardableResult
    static func setArchived(_ profile: WorkProfile, _ archived: Bool, settings: AppSettings,
                            in context: ModelContext) -> ProfileOpResult {
        guard ModelLiveness.isLive(profile) else { return .invalidTarget }
        guard profile.isArchived != archived else { return .ok }
        if archived {
            let others = allProfiles(in: context).filter { $0 !== profile && !$0.isArchived }
            guard !others.isEmpty else { return .lastProfile }
            guard !ModelLiveness.live(profile.sessions ?? []).contains(where: { $0.endedAt == nil }) else {
                return .sessionRunning
            }
            if settings.quickStartProfileID == profile.uuid {
                settings.quickStartProfileID = nil
            }
        }
        profile.isArchived = archived
        profile.touch()
        save(context)
        return .ok
    }

    /// .lastProfile when no other non-archived profile would be left. .moveSessions: target must be live,
    /// non-archived and !== profile (else .invalidTarget); every session AND every local label/tag of `profile` is
    /// re-pointed to the target (labels/tags stay local, now to the target), except that a non-archived local label/tag
    /// whose name the target already offers (non-archived, same name) is merged into that one instead
    /// (`TaxonomyOps.absorb`), so the target never shows a name twice. Unassigned sessions shown in `profile` (their
    /// effective profile) move to the target too. .deleteSessions: .sessionRunning if a
    /// session of this profile has endedAt == nil; otherwise deletes its sessions (cascade); its local labels/tags
    /// still used by a session outside this profile become global, the rest are deleted. Both:
    /// settings.quickStartProfileID cleared if it pointed here; profile deleted; saved.
    @discardableResult
    static func delete(_ profile: WorkProfile, _ deletion: ProfileDeletion, settings: AppSettings,
                       in context: ModelContext) -> ProfileOpResult {
        guard ModelLiveness.isLive(profile) else { return .invalidTarget }
        let others = allProfiles(in: context).filter { $0 !== profile && !$0.isArchived }
        guard !others.isEmpty else { return .lastProfile }

        let sessions = ModelLiveness.live(profile.sessions ?? [])
        let labels = ModelLiveness.live(profile.labels ?? [])
        let tags = ModelLiveness.live(profile.tags ?? [])

        switch deletion {
        case .moveSessions(let targetID):
            guard let target = others.first(where: { $0.uuid == targetID }) else { return .invalidTarget }
            // Decide before anything moves (an unassigned session's effective profile depends on label owners).
            let allSessions = ModelLiveness.live((try? context.fetch(FetchDescriptor<WorkSession>())) ?? [])
            let unassignedHere = allSessions.filter { isUnassigned($0) && effectiveProfile(of: $0) === profile }
            for session in sessions {
                session.profile = target
                session.touch()
            }
            for label in labels {
                if !label.isArchived,
                   let existing = TaxonomyOps.existingEquivalentLabel(for: label, in: target, in: context),
                   existing !== label, !existing.isArchived {
                    TaxonomyOps.absorb(label, into: existing, in: context)
                } else {
                    label.profile = target
                }
            }
            for tag in tags {
                if !tag.isArchived,
                   let existing = TaxonomyOps.existingEquivalentTag(for: tag, in: target, in: context),
                   existing !== tag, !existing.isArchived {
                    TaxonomyOps.absorb(tag, into: existing, in: context)
                } else {
                    tag.profile = target
                }
            }
            for session in unassignedHere {
                session.profile = target
                TaxonomyOps.conformTaxonomy(of: session, to: target, in: context)
                session.touch()
            }
            target.touch()

        case .deleteSessions:
            guard !sessions.contains(where: { $0.endedAt == nil }) else { return .sessionRunning }
            // Decide before deleting anything (deleted models must not be read).
            func isOutside(_ session: WorkSession?) -> Bool {
                guard let session = ModelLiveness.live(session) else { return false }
                return session.profile !== profile
            }
            let labelsToKeep = labels.filter { label in
                (label.sessions ?? []).contains(where: { isOutside($0) })
                    || (label.segments ?? []).contains(where: { isOutside($0.session) })
            }
            let tagsToKeep = tags.filter { tag in
                (tag.sessions ?? []).contains(where: { isOutside($0) })
                    || (tag.segments ?? []).contains(where: { isOutside($0.session) })
                    || (tag.learningPoints ?? []).contains(where: { isOutside($0.session) })
            }
            for session in sessions {
                context.delete(session)
            }
            for label in labels {
                if labelsToKeep.contains(where: { $0 === label }) {
                    label.profile = nil
                } else {
                    context.delete(label)
                }
            }
            for tag in tags {
                if tagsToKeep.contains(where: { $0 === tag }) {
                    tag.profile = nil
                } else {
                    context.delete(tag)
                }
            }
        }

        if settings.quickStartProfileID == profile.uuid {
            settings.quickStartProfileID = nil
        }
        context.delete(profile)
        save(context)
        return .ok
    }

    // MARK: - Private

    /// (sortIndex, createdAt, uuidString) ascending.
    private static func precedes(_ lhs: WorkProfile, _ rhs: WorkProfile) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    /// The single live, non-archived profile owning the local labels/tags `session` (its segments, its learning points)
    /// uses; nil when none or several do.
    private static func soleLocalOwner(of session: WorkSession) -> WorkProfile? {
        var owner: WorkProfile?
        var conflict = false
        func consider(_ profile: WorkProfile?) {
            guard !conflict, let profile = ModelLiveness.live(profile) else { return }
            if let owner {
                if owner !== profile { conflict = true }
            } else {
                owner = profile
            }
        }
        var labels: [WorkLabel?] = [session.label]
        var tags = session.tagList
        for segment in session.segments ?? [] where !segment.isDeleted {
            labels.append(segment.label)
            tags += segment.tagList
        }
        for point in session.learningPoints ?? [] where !point.isDeleted {
            tags += point.tagList
        }
        for label in labels {
            guard let label = ModelLiveness.live(label) else { continue }
            consider(label.profile)
        }
        for tag in ModelLiveness.live(tags) {
            consider(tag.profile)
        }
        guard !conflict, let owner, !owner.isArchived else { return nil }
        return owner
    }

    /// homeProfile(in:) cached per context for 2 s (the scope checks run per session on every render).
    private static func cachedHomeProfile(in context: ModelContext) -> WorkProfile? {
        let cache = homeCache
        if cache.context === context, Date.now.timeIntervalSince(cache.computedAt) < 2 {
            guard let cached = cache.profile else { return nil }
            if ModelLiveness.isLive(cached), !cached.isArchived { return cached }
        }
        let home = homeProfile(in: context)
        cache.context = context
        cache.profile = home
        cache.computedAt = .now
        return home
    }

    private static let homeCache = HomeProfileCache()

    private static func save(_ context: ModelContext) {
        invalidateHomeProfileCache()
        do {
            try context.save()
        } catch {
            Log.persistence.error("ProfileOps save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Storage for `ProfileOps.cachedHomeProfile(in:)`.
@MainActor private final class HomeProfileCache {
    weak var context: ModelContext?
    var profile: WorkProfile?
    var computedAt: Date = .distantPast
}
