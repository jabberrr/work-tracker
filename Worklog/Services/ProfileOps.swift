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

/// Create / archive / delete / reorder profiles, plus the default profile and the repair of unassigned sessions.
/// See ARCHITECTURE §12.
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

    // MARK: - Migration & repair

    /// If NO profile exists: inserts the default profile (fixed uuid, "Work", defaultLabelUUID = legacyDefaultLabelID)
    /// and returns it; else returns nil. Does not save.
    @discardableResult
    static func ensureDefaultProfile(legacyDefaultLabelID: UUID?, in context: ModelContext) -> WorkProfile? {
        guard allProfiles(in: context).isEmpty else { return nil }
        let profile = WorkProfile(name: defaultProfileName, colorHex: defaultProfileColorHex,
                                  symbolName: defaultProfileSymbol, sortIndex: 0, uuid: defaultProfileUUID)
        context.insert(profile)
        profile.defaultLabelUUID = legacyDefaultLabelID
        Log.persistence.info("Created the default profile")
        return profile
    }

    /// Sessions whose profile is nil (or deleted) → homeProfile; creates the default profile first if no profile
    /// exists and such sessions exist. Never touches modifiedAt. Returns the number repaired. Does not save.
    @discardableResult
    static func repairSessionProfiles(in context: ModelContext) -> Int {
        let sessions = ModelLiveness.live((try? context.fetch(FetchDescriptor<WorkSession>())) ?? [])
        let orphans = sessions.filter { ModelLiveness.live($0.profile) == nil }
        guard !orphans.isEmpty else { return 0 }
        guard let home = homeProfile(in: context) ?? ensureDefaultProfile(legacyDefaultLabelID: nil, in: context) else {
            return 0
        }
        for session in orphans {
            session.profile = home
        }
        Log.persistence.info("Assigned \(orphans.count, privacy: .public) unassigned sessions to the home profile")
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

    /// Archiving the last non-archived profile → .lastProfile. Archiving clears settings.quickStartProfileID if it
    /// pointed to it. touch + save.
    @discardableResult
    static func setArchived(_ profile: WorkProfile, _ archived: Bool, settings: AppSettings,
                            in context: ModelContext) -> ProfileOpResult {
        guard ModelLiveness.isLive(profile) else { return .invalidTarget }
        guard profile.isArchived != archived else { return .ok }
        if archived {
            let others = allProfiles(in: context).filter { $0 !== profile && !$0.isArchived }
            guard !others.isEmpty else { return .lastProfile }
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
    /// re-pointed to the target (labels/tags stay local, now to the target). .deleteSessions: .sessionRunning if a
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
            for session in sessions {
                session.profile = target
                session.touch()
            }
            for label in labels { label.profile = target }
            for tag in tags { tag.profile = target }
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

    private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            Log.persistence.error("ProfileOps save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
